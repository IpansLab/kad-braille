import Foundation

/// Where an audio file originates in the local app database.
enum AudioSourceType: String, Codable, CaseIterable {
    case bundled = "Bundled"
    case googleDrive = "Google Drive"
}

/// Represents a single Braille Algebra audio item stored in the internal app database.
struct AudioTrackItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var normalizedKey: String
    var fileName: String
    var source: AudioSourceType
    var driveFileId: String?
    var assignedUIDs: [String]
    var ndefAliases: [String]
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        fileName: String,
        source: AudioSourceType,
        driveFileId: String? = nil,
        assignedUIDs: [String] = [],
        ndefAliases: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.normalizedKey = Self.normalize(title)
        self.fileName = fileName
        self.source = source
        self.driveFileId = driveFileId
        self.assignedUIDs = assignedUIDs.map { Self.normalizeUID($0) }
        self.ndefAliases = ndefAliases
        self.updatedAt = updatedAt
    }

    /// Normalizes text labels and filenames so "3x + x", "3x+x", and "3x + x.m4a"
    /// resolve deterministically to "3x+x".
    static func normalize(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let audioExtensions = [".m4a", ".mp3", ".wav", ".aac", ".caf"]
        for ext in audioExtensions where cleaned.hasSuffix(ext) {
            cleaned = String(cleaned.dropLast(ext.count))
            break
        }
        return cleaned.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Strips file extension to form a clean human-readable title.
    static func cleanTitle(fromFileName fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioExtensions = [".m4a", ".mp3", ".wav", ".aac", ".caf"]
        for ext in audioExtensions where trimmed.lowercased().hasSuffix(ext) {
            return String(trimmed.dropLast(ext.count))
        }
        return trimmed
    }

    /// Formats a tag hardware UID consistently as uppercase colon-separated hex (e.g. "04:A1:2B:3C:4D:5E:6F").
    static func normalizeUID(_ uid: String) -> String {
        let hexOnly = uid
            .uppercased()
            .filter { $0.isHexDigit }
        var pairs: [String] = []
        var idx = hexOnly.startIndex
        while idx < hexOnly.endIndex {
            let nextIdx = hexOnly.index(idx, offsetBy: 2, limitedBy: hexOnly.endIndex) ?? hexOnly.endIndex
            pairs.append(String(hexOnly[idx..<nextIdx]))
            idx = nextIdx
        }
        return pairs.joined(separator: ":")
    }
}
