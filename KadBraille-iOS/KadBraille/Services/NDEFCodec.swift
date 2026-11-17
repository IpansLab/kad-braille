import CoreNFC
import Foundation

/// NDEF encoder/decoder & raw TLV parser ported from `ntgui.jar`:
/// `NDEFHelper.java` (`j/a.class`), `NDEFRecord.java` (`j/c.class`),
/// `NDEFText.java` (`k/d.class`), and `NDEFUri.java` (`k/e.class`).
enum NDEFCodec {

    /// NFC Forum RTD-URI prefix table (`0x00`..`0x23`), matching `NDEFUri.java` (`k/e.class`).
    static let uriPrefixTable: [String] = [
        "",                             // 0x00
        "http://www.",                  // 0x01
        "https://www.",                 // 0x02
        "http://",                      // 0x03
        "https://",                     // 0x04
        "tel:",                         // 0x05
        "mailto:",                      // 0x06
        "ftp://anonymous:anonymous@",   // 0x07
        "ftp://ftp.",                   // 0x08
        "ftps://",                      // 0x09
        "sftp://",                      // 0x0A
        "smb://",                       // 0x0B
        "nfs://",                       // 0x0C
        "ftp://",                       // 0x0D
        "dav://",                       // 0x0E
        "news:",                        // 0x0F
        "telnet://",                    // 0x10
        "imap:",                        // 0x11
        "rtsp://",                      // 0x12
        "urn:",                         // 0x13
        "pop:",                         // 0x14
        "sip:",                         // 0x15
        "sips:",                        // 0x16
        "tftp:",                        // 0x17
        "btspp://",                     // 0x18
        "btl2cap://",                   // 0x19
        "btgoep://",                    // 0x1A
        "tcpobex://",                   // 0x1B
        "irdaobex://",                  // 0x1C
        "file://",                      // 0x1D
        "urn:epc:id:",                  // 0x1E
        "urn:epc:tag:",                 // 0x1F
        "urn:epc:pat:",                 // 0x20
        "urn:epc:raw:",                 // 0x21
        "urn:epc:",                     // 0x22
        "urn:nfc:"                      // 0x23
    ]

    /// Decodes a `CoreNFC` `NFCNDEFPayload` into a `DecodedNDEFRecord`.
    static func decode(payload: NFCNDEFPayload) -> DecodedNDEFRecord {
        let tnfName = tnfLabel(payload.typeNameFormat)
        let typeString = String(data: payload.type, encoding: .utf8) ?? payload.type.hexString
        let rawBytes = [UInt8](payload.payload)
        let rawHex = rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        return decodeRawRecord(
            tnfFormat: payload.typeNameFormat,
            tnfLabel: tnfName,
            typeString: typeString,
            payloadBytes: rawBytes,
            rawHex: rawHex
        )
    }

    /// Creates a Well-Known Text (`"T"`) `NFCNDEFPayload`, matching `NDEFText.java` (`k/d.class`).
    static func createTextPayload(text: String, language: String = "en") -> NFCNDEFPayload? {
        guard let langData = language.data(using: .ascii),
              let textData = text.data(using: .utf8),
              langData.count <= 0x3F else {
            return nil
        }

        // Status byte: bit 7 = 0 (UTF-8), bits 5..0 = language code byte length
        let statusByte = UInt8(langData.count & 0x3F)
        var data = Data([statusByte])
        data.append(langData)
        data.append(textData)

        return NFCNDEFPayload(
            format: .nfcWellKnown,
            type: Data("T".utf8),
            identifier: Data(),
            payload: data
        )
    }

    /// Creates a Well-Known URI (`"U"`) `NFCNDEFPayload`, matching `NDEFUri.java` (`k/e.class`).
    static func createURIPayload(urlString: String) -> NFCNDEFPayload? {
        var matchedPrefixIndex: UInt8 = 0x00
        var stripped = urlString

        // Match longest prefix first (excluding index 0 "")
        for index in 1..<uriPrefixTable.count {
            let prefix = uriPrefixTable[index]
            if urlString.lowercased().hasPrefix(prefix) {
                matchedPrefixIndex = UInt8(index)
                stripped = String(urlString.dropFirst(prefix.count))
                break
            }
        }

        guard let suffixData = stripped.data(using: .utf8) else { return nil }
        var data = Data([matchedPrefixIndex])
        data.append(suffixData)

        return NFCNDEFPayload(
            format: .nfcWellKnown,
            type: Data("U".utf8),
            identifier: Data(),
            payload: data
        )
    }

    /// Parses Type 2 Tag raw user memory bytes (starting at Page 4) looking for the NDEF TLV (`0x03 <len> <NDEF> 0xFE`).
    /// Ported from `NDEFHelper.java` (`j/a.class`) & `NFCCard.java` (`i/d.class`).
    static func parseRawTLV(bytes: [UInt8]) -> [DecodedNDEFRecord] {
        var idx = 0
        while idx < bytes.count {
            let tag = bytes[idx]
            if tag == 0x00 {
                // NULL TLV - skip
                idx += 1
                continue
            }
            if tag == 0xFE {
                // Terminator TLV
                break
            }
            idx += 1
            guard idx < bytes.count else { break }

            // Length field: 1 byte if < 0xFF, or 3 bytes [0xFF, high, low]
            var length = Int(bytes[idx])
            idx += 1
            if length == 0xFF {
                guard idx + 1 < bytes.count else { break }
                length = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
                idx += 2
            }

            guard idx + length <= bytes.count else { break }
            let valueSlice = Array(bytes[idx..<(idx + length)])
            idx += length

            if tag == 0x03 {
                // NDEF Message TLV found
                return parseNDEFMessageBytes(valueSlice)
            }
        }
        return []
    }

    // MARK: - Internal Helpers

    private static func parseNDEFMessageBytes(_ bytes: [UInt8]) -> [DecodedNDEFRecord] {
        var records: [DecodedNDEFRecord] = []
        var offset = 0

        while offset < bytes.count {
            let header = bytes[offset]
            offset += 1

            let isShortRecord = (header & 0x10) != 0
            let hasIDLength = (header & 0x08) != 0
            let tnfRaw = header & 0x07
            let tnfFormat = NFCTypeNameFormat(rawValue: tnfRaw) ?? .unknown

            guard offset < bytes.count else { break }
            let typeLength = Int(bytes[offset])
            offset += 1

            let payloadLength: Int
            if isShortRecord {
                guard offset < bytes.count else { break }
                payloadLength = Int(bytes[offset])
                offset += 1
            } else {
                guard offset + 3 < bytes.count else { break }
                payloadLength = (Int(bytes[offset]) << 24)
                    | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8)
                    | Int(bytes[offset + 3])
                offset += 4
            }

            var idLength = 0
            if hasIDLength {
                guard offset < bytes.count else { break }
                idLength = Int(bytes[offset])
                offset += 1
            }

            guard offset + typeLength + idLength + payloadLength <= bytes.count else { break }
            let typeBytes = Array(bytes[offset..<(offset + typeLength)])
            offset += typeLength
            offset += idLength
            let payloadBytes = Array(bytes[offset..<(offset + payloadLength)])
            offset += payloadLength

            let typeStr = String(bytes: typeBytes, encoding: .utf8) ?? typeBytes.map { String(format: "%02X", $0) }.joined()
            let rawHex = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")

            records.append(
                decodeRawRecord(
                    tnfFormat: tnfFormat,
                    tnfLabel: tnfLabel(tnfFormat),
                    typeString: typeStr,
                    payloadBytes: payloadBytes,
                    rawHex: rawHex
                )
            )

            // Message End (ME) bit set
            if (header & 0x40) != 0 {
                break
            }
        }

        return records
    }

    private static func decodeRawRecord(
        tnfFormat: NFCTypeNameFormat,
        tnfLabel: String,
        typeString: String,
        payloadBytes: [UInt8],
        rawHex: String
    ) -> DecodedNDEFRecord {
        if tnfFormat == .nfcWellKnown && typeString == "T" {
            // Well-Known Text Record (RTD_TEXT)
            guard !payloadBytes.isEmpty else {
                return DecodedNDEFRecord(
                    tnf: tnfLabel,
                    recordType: "Text (T)",
                    payloadText: "",
                    languageCode: nil,
                    rawHex: rawHex
                )
            }
            let status = payloadBytes[0]
            let isUTF16 = (status & 0x80) != 0
            let langLength = Int(status & 0x3F)

            if payloadBytes.count > 1 + langLength {
                let langBytes = Array(payloadBytes[1..<(1 + langLength)])
                let langCode = String(bytes: langBytes, encoding: .ascii)
                let textBytes = Array(payloadBytes[(1 + langLength)...])
                let encoding: String.Encoding = isUTF16 ? .utf16 : .utf8
                let decodedText = String(bytes: textBytes, encoding: encoding)
                    ?? String(bytes: textBytes, encoding: .utf8)
                    ?? rawHex

                return DecodedNDEFRecord(
                    tnf: tnfLabel,
                    recordType: "Text (T)",
                    payloadText: decodedText,
                    languageCode: langCode,
                    rawHex: rawHex
                )
            }
        } else if tnfFormat == .nfcWellKnown && typeString == "U" {
            // Well-Known URI Record (RTD_URI)
            guard !payloadBytes.isEmpty else {
                return DecodedNDEFRecord(
                    tnf: tnfLabel,
                    recordType: "URI (U)",
                    payloadText: "",
                    languageCode: nil,
                    rawHex: rawHex
                )
            }
            let prefixIdx = Int(payloadBytes[0])
            let prefix = prefixIdx < uriPrefixTable.count ? uriPrefixTable[prefixIdx] : ""
            let suffix = String(bytes: Array(payloadBytes.dropFirst()), encoding: .utf8) ?? ""
            return DecodedNDEFRecord(
                tnf: tnfLabel,
                recordType: "URI (U)",
                payloadText: prefix + suffix,
                languageCode: nil,
                rawHex: rawHex
            )
        } else if tnfFormat == .media {
            let decoded = String(bytes: payloadBytes, encoding: .utf8) ?? rawHex
            return DecodedNDEFRecord(
                tnf: tnfLabel,
                recordType: "MIME (\(typeString))",
                payloadText: decoded,
                languageCode: nil,
                rawHex: rawHex
            )
        } else if tnfFormat == .nfcExternal {
            let decoded = String(bytes: payloadBytes, encoding: .utf8) ?? rawHex
            return DecodedNDEFRecord(
                tnf: tnfLabel,
                recordType: "External (\(typeString))",
                payloadText: decoded,
                languageCode: nil,
                rawHex: rawHex
            )
        }

        let fallback = String(bytes: payloadBytes, encoding: .utf8) ?? rawHex
        return DecodedNDEFRecord(
            tnf: tnfLabel,
            recordType: typeString.isEmpty ? "Unknown" : typeString,
            payloadText: fallback,
            languageCode: nil,
            rawHex: rawHex
        )
    }

    private static func tnfLabel(_ format: NFCTypeNameFormat) -> String {
        switch format {
        case .empty: return "Empty"
        case .nfcWellKnown: return "NFC Well-Known"
        case .media: return "Media / MIME"
        case .absoluteURI: return "Absolute URI"
        case .nfcExternal: return "NFC External"
        case .unknown: return "Unknown"
        case .unchanged: return "Unchanged"
        @unknown default: return "Other"
        }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
