import Foundation

/// Internal on-device audio database backed by `Documents/audio_database.json`
/// and `Documents/AudioLibrary/`, seeded with the 8 bundled `UNGKAPAN ALGEBRA` clips.
@MainActor
final class LocalAudioDatabase: ObservableObject {

    @Published private(set) var tracks: [AudioTrackItem] = []

    private let fileManager = FileManager.default

    static let bundledFileNames: [String] = [
        "12x.m4a",
        "3x + x.m4a",
        "4x + 5x.m4a",
        "4x.m4a",
        "6x.m4a",
        "8x + 4x.m4a",
        "9x.m4a",
        "x+5x.m4a"
    ]

    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var databaseFileURL: URL {
        documentsDirectory.appendingPathComponent("audio_database.json")
    }

    var audioLibraryDirectory: URL {
        documentsDirectory.appendingPathComponent("AudioLibrary", isDirectory: true)
    }

    init() {
        ensureDirectoriesExist()
        loadOrSeed()
    }

    // MARK: - Persistence

    private func ensureDirectoriesExist() {
        if !fileManager.fileExists(atPath: audioLibraryDirectory.path) {
            try? fileManager.createDirectory(at: audioLibraryDirectory, withIntermediateDirectories: true)
        }
    }

    func loadOrSeed() {
        if fileManager.fileExists(atPath: databaseFileURL.path),
           let data = try? Data(contentsOf: databaseFileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([AudioTrackItem].self, from: data), !loaded.isEmpty {
                self.tracks = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return
            }
        }
        seedBundledTracks()
    }

    func seedBundledTracks() {
        let seeded = Self.bundledFileNames.map { fileName in
            let title = AudioTrackItem.cleanTitle(fromFileName: fileName)
            return AudioTrackItem(
                id: "bundled-\(AudioTrackItem.normalize(title))",
                title: title,
                fileName: fileName,
                source: .bundled
            )
        }
        self.tracks = seeded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        save()
    }

    func save() {
        ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(tracks) {
            try? data.write(to: databaseFileURL, options: .atomic)
        }
    }

    // MARK: - Resolution Engine (UID + NDEF Text)

    /// Matches a scanned NFC tag to a track in the local database.
    /// Priority 1: Hardware UID match (`assignedUIDs`).
    /// Priority 2: Normalized NDEF Text / URI payload match.
    func resolveTrack(for tag: ScannedTagInfo) -> AudioTrackItem? {
        let normalizedTagUID = AudioTrackItem.normalizeUID(tag.uid)

        // 1. Hardware UID match (works even on completely blank/unformatted tags)
        if !normalizedTagUID.isEmpty,
           let uidMatch = tracks.first(where: { track in
               track.assignedUIDs.contains { AudioTrackItem.normalizeUID($0) == normalizedTagUID }
           }) {
            return uidMatch
        }

        // 2. NDEF payload match (Text record, URI tail, etc.)
        for record in tag.records {
            let rawPayload = record.payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPayload.isEmpty else { continue }

            let candidateKey = AudioTrackItem.normalize(rawPayload)
            let urlTailKey: String? = URL(string: rawPayload).map { AudioTrackItem.normalize($0.lastPathComponent) }

            if let textMatch = tracks.first(where: { track in
                if track.normalizedKey == candidateKey ||
                    AudioTrackItem.normalize(track.title) == candidateKey ||
                    AudioTrackItem.normalize(track.fileName) == candidateKey {
                    return true
                }
                if let tail = urlTailKey, !tail.isEmpty, track.normalizedKey == tail {
                    return true
                }
                return track.ndefAliases.contains { AudioTrackItem.normalize($0) == candidateKey }
            }) {
                return textMatch
            }
        }

        return nil
    }

    /// Resolves a track from an incoming deep-link URL such as `kadbraille://play?card=3x%2Bx`,
    /// `kadbraille://play?uid=04:A1:2B:3C:4D:5E:6F`, or `kadbraille://3x+x`.
    func resolveTrack(fromDeepLink url: URL) -> AudioTrackItem? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        if let uidValue = queryItems.first(where: { $0.name.lowercased() == "uid" })?.value {
            let normalizedUID = AudioTrackItem.normalizeUID(uidValue)
            if !normalizedUID.isEmpty,
               let uidMatch = tracks.first(where: { track in
                   track.assignedUIDs.contains { AudioTrackItem.normalizeUID($0) == normalizedUID }
               }) {
                return uidMatch
            }
        }

        let queryCandidate = queryItems.first(where: {
            let name = $0.name.lowercased()
            return name == "card" || name == "key" || name == "play"
        })?.value

        var candidateStrings: [String] = []
        if let queryCandidate, !queryCandidate.isEmpty {
            candidateStrings.append(queryCandidate)
        }
        let pathLast = url.lastPathComponent
        if !pathLast.isEmpty && pathLast != "/" && pathLast.lowercased() != "play" {
            candidateStrings.append(pathLast)
        }
        if let host = url.host, !host.isEmpty && host.lowercased() != "play" {
            candidateStrings.append(host)
        }

        for candidate in candidateStrings {
            let key = AudioTrackItem.normalize(candidate)
            guard !key.isEmpty else { continue }
            if let match = tracks.first(where: { track in
                track.normalizedKey == key ||
                AudioTrackItem.normalize(track.title) == key ||
                AudioTrackItem.normalize(track.fileName) == key ||
                track.ndefAliases.contains { AudioTrackItem.normalize($0) == key }
            }) {
                return match
            }
        }

        return nil
    }

    /// Generates a shareable custom URL scheme deep link for iOS Shortcuts NFC Automation or `nfctoolsgui.exe`.
    func deepLinkURLString(for track: AudioTrackItem) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = track.normalizedKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? track.normalizedKey
        return "kadbraille://play?card=\(encoded)"
    }

    /// Resolves a playable local file URL for a track.
    /// Checks synced files in `Documents/AudioLibrary/` first, then falls back to `Bundle.main`.
    func audioURL(for track: AudioTrackItem) -> URL? {
        let syncedFileURL = audioLibraryDirectory.appendingPathComponent(track.fileName)
        if fileManager.fileExists(atPath: syncedFileURL.path) {
            return syncedFileURL
        }

        let nsName = track.fileName as NSString
        let resource = nsName.deletingPathExtension
        let ext = nsName.pathExtension.isEmpty ? "m4a" : nsName.pathExtension

        if let rootURL = Bundle.main.url(forResource: resource, withExtension: ext) {
            return rootURL
        }
        if let subdirURL = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "BundledAudio") {
            return subdirURL
        }

        return nil
    }

    // MARK: - Tag UID Binding & Mutations

    /// Assigns an NFC tag's hardware UID to a specific audio track (removing it from any other track first).
    func assignUID(_ uid: String, toTrackId trackId: String) {
        let normalized = AudioTrackItem.normalizeUID(uid)
        guard !normalized.isEmpty else { return }

        for index in tracks.indices {
            tracks[index].assignedUIDs.removeAll { AudioTrackItem.normalizeUID($0) == normalized }
            if tracks[index].id == trackId {
                tracks[index].assignedUIDs.append(normalized)
                tracks[index].updatedAt = Date()
            }
        }
        save()
    }

    func unassignUID(_ uid: String, fromTrackId trackId: String) {
        let normalized = AudioTrackItem.normalizeUID(uid)
        guard let index = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        tracks[index].assignedUIDs.removeAll { AudioTrackItem.normalizeUID($0) == normalized }
        tracks[index].updatedAt = Date()
        save()
    }

    /// Inserts or updates a track synced from Google Drive while preserving any existing UID assignments.
    func upsertSyncedTrack(
        title: String,
        fileName: String,
        driveFileId: String,
        extraUIDs: [String] = [],
        aliases: [String] = []
    ) {
        let normalized = AudioTrackItem.normalize(title)
        let normalizedExtraUIDs = extraUIDs.map { AudioTrackItem.normalizeUID($0) }.filter { !$0.isEmpty }

        if let existingIndex = tracks.firstIndex(where: {
            $0.driveFileId == driveFileId ||
            $0.normalizedKey == normalized ||
            $0.fileName.caseInsensitiveCompare(fileName) == .orderedSame
        }) {
            var existing = tracks[existingIndex]
            existing.title = title
            existing.normalizedKey = normalized
            existing.fileName = fileName
            existing.source = .googleDrive
            existing.driveFileId = driveFileId
            existing.updatedAt = Date()

            for uid in normalizedExtraUIDs where !existing.assignedUIDs.contains(uid) {
                existing.assignedUIDs.append(uid)
            }
            for alias in aliases where !existing.ndefAliases.contains(alias) {
                existing.ndefAliases.append(alias)
            }
            tracks[existingIndex] = existing
        } else {
            let newItem = AudioTrackItem(
                id: "gdrive-\(driveFileId)",
                title: title,
                fileName: fileName,
                source: .googleDrive,
                driveFileId: driveFileId,
                assignedUIDs: normalizedExtraUIDs,
                ndefAliases: aliases,
                updatedAt: Date()
            )
            tracks.append(newItem)
        }

        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        save()
    }

    func removeTrack(id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = tracks.remove(at: index)
        if removed.source == .googleDrive {
            let fileURL = audioLibraryDirectory.appendingPathComponent(removed.fileName)
            try? fileManager.removeItem(at: fileURL)
        }
        save()
    }

    func resetToBundledDefaults() {
        if let files = try? fileManager.contentsOfDirectory(at: audioLibraryDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        seedBundledTracks()
    }
}
