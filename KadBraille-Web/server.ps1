param(
    [int]$Port = 8080,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)

$mimeTypes = @{
    ".html"        = "text/html; charset=utf-8"
    ".css"         = "text/css; charset=utf-8"
    ".js"          = "application/javascript; charset=utf-8"
    ".webmanifest" = "application/manifest+json; charset=utf-8"
    ".json"        = "application/json; charset=utf-8"
    ".svg"         = "image/svg+xml"
    ".png"         = "image/png"
    ".m4a"         = "audio/mp4"
    ".mp3"         = "audio/mpeg"
    ".wav"         = "audio/wav"
    ".aac"         = "audio/aac"
}

function Parse-QueryString {
    param([string]$Query)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Query)) { return $map }
    $q = $Query.TrimStart('?')
    foreach ($pair in ($q -split '&')) {
        if (-not $pair) { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -ge 0) {
            $k = [Uri]::UnescapeDataString($pair.Substring(0, $eq).Replace('+', ' '))
            $v = [Uri]::UnescapeDataString($pair.Substring($eq + 1).Replace('+', ' '))
            $map[$k] = $v
        } else {
            $k = [Uri]::UnescapeDataString($pair.Replace('+', ' '))
            $map[$k] = ""
        }
    }
    return $map
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$Reason,
        [string]$ContentType,
        [byte[]]$BodyBytes,
        [int]$Offset = 0,
        [int]$Count = -1,
        [hashtable]$ExtraHeaders = @{}
    )
    if ($Count -lt 0) { $Count = $BodyBytes.Length - $Offset }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $StatusCode $Reason`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $Count`r`n")
    [void]$sb.Append("Connection: close`r`n")
    foreach ($key in $ExtraHeaders.Keys) {
        [void]$sb.Append("${key}: $($ExtraHeaders[$key])`r`n")
    }
    [void]$sb.Append("`r`n")

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Count -gt 0) {
        $Stream.Write($BodyBytes, $Offset, $Count)
    }
    $Stream.Flush()
}

function Send-TextResponse {
    param([System.IO.Stream]$Stream, [int]$StatusCode, [string]$Reason, [string]$Body, [string]$ContentType = "text/plain; charset=utf-8")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    Write-HttpResponse -Stream $Stream -StatusCode $StatusCode -Reason $Reason -ContentType $ContentType -BodyBytes $bytes
}

function Send-FileResponse {
    param([System.IO.Stream]$Stream, [hashtable]$Headers, [string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { "application/octet-stream" }
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $totalLen = $fileBytes.Length

    $extra = @{
        "Accept-Ranges" = "bytes"
        "Cache-Control" = "no-cache"
    }

    $rangeHeader = $Headers["range"]
    if ($rangeHeader -and $rangeHeader -match '^bytes=(\d*)-(\d*)$' -and $totalLen -gt 0) {
        $start = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
        $end = if ($Matches[2]) { [Math]::Min([int]$Matches[2], $totalLen - 1) } else { $totalLen - 1 }
        if ($start -le $end -and $start -lt $totalLen) {
            $len = $end - $start + 1
            $extra["Content-Range"] = "bytes $start-$end/$totalLen"
            Write-HttpResponse -Stream $Stream -StatusCode 206 -Reason "Partial Content" -ContentType $contentType -BodyBytes $fileBytes -Offset $start -Count $len -ExtraHeaders $extra
            return
        }
    }

    Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -ContentType $contentType -BodyBytes $fileBytes -ExtraHeaders $extra
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()

$localUrl = "http://localhost:$Port/"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Kad Braille Web App running at: $localUrl" -ForegroundColor Green
try {
    $lanIPs = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_) } |
        Select-Object -ExpandProperty IPAddressToString
    foreach ($ip in $lanIPs) {
        Write-Host " LAN URL (same Wi-Fi): http://${ip}:$Port/" -ForegroundColor Yellow
    }
} catch {}
Write-Host " Serving folder: $root"
Write-Host " Press Ctrl+C in this window to stop the server."
Write-Host "==================================================" -ForegroundColor Cyan

if ($OpenBrowser) {
    Start-Process $localUrl
}

Add-Type -AssemblyName System.Net.Http
$httpClient = New-Object System.Net.Http.HttpClient
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 10000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                $client.Close()
                continue
            }

            $headers = @{}
            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
                $colon = $line.IndexOf(':')
                if ($colon -gt 0) {
                    $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim()
                }
            }

            $parts = $requestLine -split '\s+'
            $rawTarget = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
            $qIdx = $rawTarget.IndexOf('?')
            $rawPath = if ($qIdx -ge 0) { $rawTarget.Substring(0, $qIdx) } else { $rawTarget }
            $rawQuery = if ($qIdx -ge 0) { $rawTarget.Substring($qIdx) } else { "" }
            $query = Parse-QueryString -Query $rawQuery

            if ($rawPath -eq "/api/gdrive-list") {
                $folderId = $query["folderId"]
                if (-not $folderId -or $folderId -notmatch '^[a-zA-Z0-9_-]{5,}$') {
                    Send-TextResponse -Stream $stream -StatusCode 400 -Reason "Bad Request" -Body "Invalid folderId"
                    continue
                }
                $driveUrl = "https://drive.google.com/embeddedfolderview?id=$folderId#list"
                $html = $httpClient.GetStringAsync($driveUrl).GetAwaiter().GetResult()
                if ($html -match 'ServiceLogin|accounts\.google\.com/v3/signin') {
                    Send-TextResponse -Stream $stream -StatusCode 403 -Reason "Forbidden" -Body "Google Drive folder appears private. Set sharing to 'Anyone with the link'."
                    continue
                }

                $pattern = 'id="entry-([a-zA-Z0-9_-]+)"[\s\S]*?class="flip-entry-title"[^>]*>([^<]+)<'
                $matches = [regex]::Matches($html, $pattern)
                $seen = @{}
                $items = @()
                foreach ($m in $matches) {
                    $fid = $m.Groups[1].Value
                    $fname = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
                    if ($fid -and $fname -and -not $seen.ContainsKey($fid)) {
                        $seen[$fid] = $true
                        $items += @{ id = $fid; name = $fname }
                    }
                }
                $json = @{ files = @($items) } | ConvertTo-Json -Depth 4
                Send-TextResponse -Stream $stream -StatusCode 200 -Reason "OK" -Body $json -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($rawPath -eq "/api/gdrive-download") {
                $fileId = $query["fileId"]
                if (-not $fileId -or $fileId -notmatch '^[a-zA-Z0-9_-]{5,}$') {
                    Send-TextResponse -Stream $stream -StatusCode 400 -Reason "Bad Request" -Body "Invalid fileId"
                    continue
                }
                $dlUrl = "https://drive.google.com/uc?export=download&id=$fileId"
                $bytes = $httpClient.GetByteArrayAsync($dlUrl).GetAwaiter().GetResult()
                $head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(64, $bytes.Length)).ToLowerInvariant()
                if ($head -match '<html|<!doctype') {
                    $bytes = $httpClient.GetByteArrayAsync("$dlUrl&confirm=t").GetAwaiter().GetResult()
                }
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason "OK" -ContentType "application/octet-stream" -BodyBytes $bytes
                continue
            }

            $relPath = [Uri]::UnescapeDataString($rawPath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($relPath)) {
                $relPath = "index.html"
            }

            $relOsPath = $relPath -replace '/', '\'
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $relOsPath))

            if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-TextResponse -Stream $stream -StatusCode 403 -Reason "Forbidden" -Body "Forbidden"
                continue
            }

            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Send-TextResponse -Stream $stream -StatusCode 404 -Reason "Not Found" -Body "Not Found: $relPath"
                continue
            }

            Send-FileResponse -Stream $stream -Headers $headers -FilePath $candidate
        } catch {
            try {
                if ($stream) {
                    Send-TextResponse -Stream $stream -StatusCode 500 -Reason "Internal Server Error" -Body $_.Exception.Message
                }
            } catch {}
        } finally {
            $client.Close()
        }
    }
} finally {
    $httpClient.Dispose()
    $listener.Stop()
}
