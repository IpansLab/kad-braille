import Foundation

/// NFC chip technologies reverse-engineered from `ntgui.jar` (`l/D.class` TechHelper.java and `l/*.class`).
enum NFCChipTech: String, Codable, CaseIterable {
    case ntag210
    case ntag212
    case ntag213
    case ntag215
    case ntag216
    case mifareUltralight
    case mifareClassic1k
    case mifareClassic4k
    case icodeSLIX
    case felica
    case iso7816Generic
    case unknown

    var displayName: String {
        switch self {
        case .ntag210: return "NXP - NTAG210"
        case .ntag212: return "NXP - NTAG212"
        case .ntag213: return "NXP - NTAG213"
        case .ntag215: return "NXP - NTAG215"
        case .ntag216: return "NXP - NTAG216"
        case .mifareUltralight: return "NXP - MIFARE Ultralight"
        case .mifareClassic1k: return "NXP - MIFARE Classic 1K"
        case .mifareClassic4k: return "NXP - MIFARE Classic 4K"
        case .icodeSLIX: return "NXP - ICODE SLIX (ISO 15693)"
        case .felica: return "Sony - FeliCa"
        case .iso7816Generic: return "ISO 14443-4 / ISO 7816"
        case .unknown: return "Unknown NFC Tag"
        }
    }

    /// Memory layout description matching `ntgui.jar` (`l/v.class`, `l/x.class`, `l/y.class`, `l/A.class`, `l/B.class`).
    var memoryDescription: String {
        switch self {
        case .ntag210: return "80 bytes : 20 pages, 4 bytes each"
        case .ntag212: return "164 bytes : 41 pages, 4 bytes each"
        case .ntag213: return "180 bytes : 45 pages, 4 bytes each"
        case .ntag215: return "540 bytes : 135 pages, 4 bytes each"
        case .ntag216: return "924 bytes : 231 pages, 4 bytes each"
        case .mifareUltralight: return "64 bytes : 16 pages, 4 bytes each"
        case .mifareClassic1k: return "1 KB : 16 sectors of 4 blocks, 16 bytes per block"
        case .mifareClassic4k: return "4 KB : 32 sectors of 4 blocks and 8 sectors of 16 blocks"
        case .icodeSLIX: return "112 bytes : 28 blocks, 4 bytes each"
        case .felica: return "FeliCa Block Memory"
        case .iso7816Generic: return "ISO 7816 NDEF Application"
        case .unknown: return "Unknown memory layout"
        }
    }

    /// Total physical page count for Type 2 NTAG / Ultralight tags used when dumping memory pages.
    var totalPageCount: Int {
        switch self {
        case .ntag210: return 20
        case .ntag212: return 41
        case .ntag213: return 45
        case .ntag215: return 135
        case .ntag216: return 231
        case .mifareUltralight: return 16
        default: return 45
        }
    }

    /// Infers NTAG chip model from the Capability Container (Page 3, byte 2) or GET_VERSION (0x60) response.
    /// Ported from `NFCCard.java` / `TechHelper.java` in `ntgui.jar`.
    static func inferFromNTAGVersion(_ versionBytes: [UInt8]) -> NFCChipTech {
        // NXP GET_VERSION returns 8 bytes: [header, vendor, type, subtype, major, minor, storageSize, protocol]
        guard versionBytes.count >= 7 else { return .mifareUltralight }
        switch versionBytes[6] {
        case 0x0B: return .ntag210
        case 0x0E: return .ntag212
        case 0x0F: return .ntag213
        case 0x11: return .ntag215
        case 0x13: return .ntag216
        default: return .mifareUltralight
        }
    }

    static func inferFromNDEFCapacity(_ capacityBytes: Int) -> NFCChipTech {
        switch capacityBytes {
        case ...64: return .mifareUltralight
        case 65...135: return .ntag212
        case 136...160: return .ntag213
        case 161...512: return .ntag215
        case 513...1024: return .ntag216
        default: return .ntag213
        }
    }
}

/// Decoded NDEF record representation ported from `NDEFRecord.java` (`j/c.class`).
struct DecodedNDEFRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var tnf: String
    var recordType: String
    var payloadText: String
    var languageCode: String?
    var rawHex: String
}

/// Single memory page entry ported from `MemoryTab.java` (`n/b.class`) and `TechHelper.java` (`l/D.class`).
struct MemoryPageBlock: Identifiable, Codable, Equatable {
    var id: Int { pageIndex }
    var pageIndex: Int
    var addressHex: String
    var dataHex: String
    var asciiString: String
    var accessDescription: String

    /// Returns human-readable sector/page role matching `TechHelper.java` (`l/D.class`).
    static func pageAnnotation(for pageIndex: Int, totalPages: Int) -> String {
        switch pageIndex {
        case 0: return "UID0 - UID2 / BCC0"
        case 1: return "UID3 - UID6"
        case 2: return "BCC1 / INT. / LOCK0 - LOCK1"
        case 3: return "OTP0 - OTP3 (CC)"
        default:
            if totalPages >= 45 && pageIndex == totalPages - 5 {
                return "LOCK2 - LOCK4"
            } else if totalPages >= 45 && pageIndex == totalPages - 4 {
                return "CFG 0 (MIRROR / AUTH0)"
            } else if totalPages >= 45 && pageIndex == totalPages - 3 {
                return "CFG 1 (ACCESS)"
            } else if totalPages >= 45 && pageIndex == totalPages - 2 {
                return "PWD0 - PWD3"
            } else if totalPages >= 45 && pageIndex == totalPages - 1 {
                return "PACK0 - PACK1"
            }
            return "User Memory"
        }
    }
}

/// Complete snapshot of a scanned NFC tag, matching `InformationTab.java` (`n/a.class`).
struct ScannedTagInfo: Identifiable, Equatable {
    var id: UUID = UUID()
    var uid: String
    var tech: NFCChipTech
    var isWritable: Bool
    var capacityBytes: Int
    var records: [DecodedNDEFRecord]
    var memoryPages: [MemoryPageBlock]
    var scannedAt: Date

    /// Returns the first meaningful text or URI payload from the tag, if present.
    var primaryTextPayload: String? {
        records.first(where: { !$0.payloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.payloadText
    }
}
