import Foundation

/// Synchronizes a public Google Drive folder (online database) into the internal `LocalAudioDatabase`
/// whenever the user taps "Sync Now".
///
/// Supports 3 discovery strategies automatically:
/// 1. Public Google Drive Embedded Folder View (`embeddedfolderview?id=...#list`) — requires no API key.
/// 2. Optional Google Drive v3 REST API (if an API key is provided).
/// 3. Optional `manifest.json` inside the Drive folder for explicit UID/alias mappings.
@MainActor
final class GoogleDriveSyncService: ObservableObject {

    struct DriveFileEntry: Equatable {
        let fileId: String
        let name: String
    }

    struct ManifestTrackEntry: Codable {
        let title: String?
        let fileName: String
        let fileId: String?
        let assignedUIDs: [String]?
        let aliases: [String]?
    }

    struct ManifestContainer: Codable {
        let tracks: [ManifestTrackEntry]
    }

    @Published var folderInput: String {
        didSet { UserDefaults.standard.set(folderInput, forKey: Self.folderDefaultsKey) }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.apiKeyDefaultsKey) }
    }
    @Published var isSyncing: Bool = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = "Ready to sync"
    @Published var syncedCount: Int = 0
    @Published var lastSyncDate: Date?
    @Published var syncLog: [String] = []
    @Published var lastErrorMessage: String?

    private static let folderDefaultsKey = "kadbraille_gdrive_folder_input"
    private static let apiKeyDefaultsKey = "kadbraille_gdrive_api_key"
    private static let lastSyncDefaultsKey = "kadbraille_gdrive_last_sync"
    private static let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf"]

    private let session: URLSession

    init() {
        self.folderInput = UserDefaults.standard.string(forKey: Self.folderDefaultsKey) ?? ""
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
        if let ts = UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date {
            self.lastSyncDate = ts
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Extracts a Google Drive folder ID from either a full URL or raw ID string.
    static func extractFolderID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Match .../folders/<FOLDER_ID>...
        if let range = trimmed.range(of: #"/folders/([a-zA-Z0-9_-]+)"#, options: .regularExpression) {
            let match = String(trimmed[range])
            return match.replacingOccurrences(of: "/folders/", with: "")
        }

        // Match ?id=<FOLDER_ID> or &id=<FOLDER_ID>
        if let components = URLComponents(string: trimmed),
           let idItem = components.queryItems?.first(where: { $0.name == "id" }),
           let value = idItem.value, !value.isEmpty {
            return value
        }

        // If user pasted a direct JSON URL, don't treat as folder ID
        if trimmed.lowercased().hasPrefix("http") && trimmed.lowercased().contains(".json") {
            return nil
        }

        // Otherwise accept raw alphanumeric/hyphen/underscore Drive ID
        if trimmed.range(of: #"^[a-zA-Z0-9_-]{10,}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }

    /// Manually triggers synchronization from the configured public Google Drive folder to `database`.
    func syncNow(into database: LocalAudioDatabase) async {
        guard !isSyncing else { return }

        let trimmedInput = folderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            lastErrorMessage = "Please enter your public Google Drive Folder URL or Folder ID first."
            syncStatus = "Missing Google Drive URL"
            return
        }

        isSyncing = true
        syncProgress = 0.05
        syncedCount = 0
        lastErrorMessage = nil
        syncLog.removeAll()

        defer { isSyncing = false }

        do {
            var discoveredFiles: [DriveFileEntry] = []
            var manifestMappings: [String: ManifestTrackEntry] = [:]

            // Check if user provided a direct manifest.json URL
            if trimmedInput.lowercased().hasPrefix("http") && trimmedInput.lowercased().contains(".json"),
               let directURL = URL(string: trimmedInput) {
                appendLog("Fetching direct manifest JSON...")
                let manifestEntries = try await fetchManifest(from: directURL)
                for entry in manifestEntries {
                    let key = AudioTrackItem.normalize(entry.fileName)
                    manifestMappings[key] = entry
                    if let fid = entry.fileId {
                        discoveredFiles.append(DriveFileEntry(fileId: fid, name: entry.fileName))
                    }
                }
            } else {
                guard let folderId = Self.extractFolderID(from: trimmedInput) else {
                    throw SyncError.invalidFolderInput
                }

                syncStatus = "Scanning Google Drive folder..."
                appendLog("Folder ID: \(folderId)")

                let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanKey.isEmpty {
                    appendLog("Querying Google Drive v3 API...")
                    discoveredFiles = try await listFilesViaDriveAPI(folderId: folderId, apiKey: cleanKey)
                } else {
                    appendLog("Reading public embedded folder view (no API key)...")
                    discoveredFiles = try await listFilesViaPublicEmbeddedView(folderId: folderId)
                }

                // Check for optional manifest.json in the folder
                if let manifestEntry = discoveredFiles.first(where: { $0.name.lowercased() == "manifest.json" }) {
                    appendLog("Found manifest.json — loading UID & alias mappings...")
                    let url = downloadURL(for: manifestEntry.fileId, apiKey: cleanKey)
                    let entries = try await fetchManifest(from: url)
                    for item in entries {
                        manifestMappings[AudioTrackItem.normalize(item.fileName)] = item
                    }
                }
            }

            let audioEntries = discoveredFiles.filter { entry in
                let ext = (entry.name as NSString).pathExtension.lowercased()
                return Self.supportedAudioExtensions.contains(ext)
            }

            guard !audioEntries.isEmpty else {
                throw SyncError.noAudioFilesFound
            }

            appendLog("Found \(audioEntries.count) audio file(s) in Google Drive.")
            syncStatus = "Downloading \(audioEntries.count) audio files..."

            let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, entry) in audioEntries.enumerated() {
                syncStatus = "Downloading \(entry.name) (\(index + 1)/\(audioEntries.count))..."
                let fileURL = downloadURL(for: entry.fileId, apiKey: cleanKey)
                let destinationURL = database.audioLibraryDirectory.appendingPathComponent(entry.name)

                let data = try await downloadBinaryData(from: fileURL)
                try data.write(to: destinationURL, options: .atomic)

                let mapKey = AudioTrackItem.normalize(entry.name)
                let manifestMeta = manifestMappings[mapKey]
                let title = manifestMeta?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? manifestMeta!.title!
                    : AudioTrackItem.cleanTitle(fromFileName: entry.name)

                database.upsertSyncedTrack(
                    title: title,
                    fileName: entry.name,
                    driveFileId: entry.fileId,
                    extraUIDs: manifestMeta?.assignedUIDs ?? [],
                    aliases: manifestMeta?.aliases ?? []
                )

                syncedCount += 1
                syncProgress = 0.15 + (0.85 * Double(index + 1) / Double(audioEntries.count))
                appendLog("Synced: \(entry.name) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
            }

            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncDefaultsKey)
            syncStatus = "Sync complete — \(syncedCount) audio file(s) updated."
            syncProgress = 1.0
        } catch {
            lastErrorMessage = error.localizedDescription
            syncStatus = "Sync failed"
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Discovery Implementations

    private func listFilesViaDriveAPI(folderId: String, apiKey: String) async throws -> [DriveFileEntry] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(folderId)' in parents and trashed = false"),
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size)"),
            URLQueryItem(name: "pageSize", value: "200")
        ]

        guard let url = components.url else { throw SyncError.invalidFolderInput }
        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response, data: data)

        struct DriveAPIResponse: Decodable {
            struct FileItem: Decodable {
                let id: String
                let name: String
            }
            let files: [FileItem]
        }

        let decoded = try JSONDecoder().decode(DriveAPIResponse.self, from: data)
        return decoded.files.map { DriveFileEntry(fileId: $0.id, name: $0.name) }
    }

    private func listFilesViaPublicEmbeddedView(folderId: String) async throws -> [DriveFileEntry] {
        guard let url = URL(string: "https://drive.google.com/embeddedfolderview?id=\(folderId)#list") else {
            throw SyncError.invalidFolderInput
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SyncError.unreadableResponse
        }

        if html.contains("ServiceLogin") || html.contains("accounts.google.com/v3/signin") {
            throw SyncError.folderNotPublic
        }

        // Parse Drive embedded view items:
        // <div class="flip-entry" id="entry-<FILE_ID>" ...> ... <div class="flip-entry-title">filename.m4a</div>
        let pattern = #"id="entry-([a-zA-Z0-9_-]+)"[\s\S]*?class="flip-entry-title"[^>]*>([^<]+)<"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)

        var entries: [DriveFileEntry] = []
        var seenIds = Set<String>()

        for match in regex.matches(in: html, options: [], range: nsRange) {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let fileId = String(html[idRange])
            let rawName = decodeHTMLEntities(String(html[nameRange])).trimmingCharacters(in: .whitespacesAndNewlines)

            if !seenIds.contains(fileId) && !rawName.isEmpty {
                seenIds.insert(fileId)
                entries.append(DriveFileEntry(fileId: fileId, name: rawName))
            }
        }

        return entries
    }

    // MARK: - Download & Manifest Helpers

    private func downloadURL(for fileId: String, apiKey: String) -> URL {
        if !apiKey.isEmpty {
            return URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media&key=\(apiKey)")!
        }
        return URL(string: "https://drive.google.com/uc?export=download&id=\(fileId)")!
    }

    private func downloadBinaryData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response, data: data)

        // Guard against Drive HTML confirmation pages on larger files
        if let prefix = String(data: data.prefix(64), encoding: .utf8)?.lowercased(),
           prefix.contains("<html") || prefix.contains("<!doctype html") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "confirm", value: "t"))
            components?.queryItems = items

            if let retryURL = components?.url {
                let (retryData, retryResponse) = try await session.data(from: retryURL)
                try validateHTTPResponse(retryResponse, data: retryData)
                if let retryPrefix = String(data: retryData.prefix(64), encoding: .utf8)?.lowercased(),
                   retryPrefix.contains("<html") || retryPrefix.contains("<!doctype html") {
                    throw SyncError.fileDownloadBlocked
                }
                return retryData
            }
            throw SyncError.fileDownloadBlocked
        }

        return data
    }

    private func fetchManifest(from url: URL) async throws -> [ManifestTrackEntry] {
        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        if let container = try? decoder.decode(ManifestContainer.self, from: data) {
            return container.tracks
        }
        return try decoder.decode([ManifestTrackEntry].self, from: data)
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.unreadableResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw SyncError.httpError(code: http.statusCode, detail: bodyPreview)
        }
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        syncLog.append("[\(formatter.string(from: Date()))] \(message)")
    }

    enum SyncError: LocalizedError {
        case invalidFolderInput
        case folderNotPublic
        case noAudioFilesFound
        case fileDownloadBlocked
        case unreadableResponse
        case httpError(code: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidFolderInput:
                return "Could not extract a Google Drive Folder ID from the URL provided."
            case .folderNotPublic:
                return "Google Drive folder appears private. Set sharing to 'Anyone with the link'."
            case .noAudioFilesFound:
                return "No .m4a, .mp3, .wav, or .aac files were found in that Google Drive folder."
            case .fileDownloadBlocked:
                return "Google Drive returned an HTML page instead of the audio file. Verify public sharing permissions."
            case .unreadableResponse:
                return "Received an unreadable response from Google Drive."
            case .httpError(let code, let detail):
                return "Google Drive HTTP \(code): \(detail)"
            }
        }
    }
}
