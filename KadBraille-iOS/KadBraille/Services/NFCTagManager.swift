import CoreNFC
import Foundation

/// CoreNFC reader/writer manager reverse-engineered from `ntgui.jar`:
/// - `NFCThread.java` (`i/f.class`) & `NFCListener.java` (`i/e.class`)
/// - `NFCCard.java` (`i/d.class`) & `APDUHelper.java` (`i/a.class`)
/// - `TechHelper.java` (`l/D.class`)
/// - `WriteTab.java` (`n/e.class`) & `OtherTab.java` (`n/d.class`)
@MainActor
final class NFCTagManager: NSObject, ObservableObject {

    enum OperationMode {
        case readAndPlayAudio
        case inspectTag
        case writeTextRecord(String)
        case writeURIRecord(String)
        case eraseTag
        case lockReadOnly
        case bindUIDToTrack(AudioTrackItem)
        case sendCustomCommand(Data)
    }

    @Published var isScanning: Bool = false
    @Published var lastScannedTag: ScannedTagInfo?
    @Published var statusMessage: String = "Tap below to wait for an NFC tag"
    @Published var errorMessage: String?
    @Published var apduLogs: [String] = []

    var onTagScannedForAudio: ((ScannedTagInfo) -> Void)?
    var onUIDCapturedForBinding: ((String, AudioTrackItem) -> Void)?
    var onWriteSuccess: ((String) -> Void)?

    private var session: NFCTagReaderSession?
    private var activeMode: OperationMode = .readAndPlayAudio

    var isNFCSupported: Bool {
        NFCTagReaderSession.readingAvailable
    }

    // MARK: - Session Starters

    func startScanForAudio() {
        startSession(
            mode: .readAndPlayAudio,
            alertMessage: "Hold a Braille Algebra NFC card near the top of your iPhone."
        )
    }

    func startInspectTag() {
        startSession(
            mode: .inspectTag,
            alertMessage: "Hold an NFC tag near your iPhone to inspect chip & memory."
        )
    }

    func startWriteText(_ text: String) {
        startSession(
            mode: .writeTextRecord(text),
            alertMessage: "Hold an NFC tag near your iPhone to write \"\(text)\"."
        )
    }

    func startWriteURI(_ uri: String) {
        startSession(
            mode: .writeURIRecord(uri),
            alertMessage: "Hold an NFC tag near your iPhone to write URI."
        )
    }

    func startEraseTag() {
        startSession(
            mode: .eraseTag,
            alertMessage: "Hold an NFC tag near your iPhone to erase NDEF records."
        )
    }

    func startLockReadOnly() {
        startSession(
            mode: .lockReadOnly,
            alertMessage: "Warning: Hold tag to permanently lock it as Read-Only."
        )
    }

    func startBindUID(to track: AudioTrackItem) {
        startSession(
            mode: .bindUIDToTrack(track),
            alertMessage: "Hold the NFC card to bind its UID to \"\(track.title)\"."
        )
    }

    func startSendCustomCommand(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let commandData = Self.hexStringToData(cleaned), !commandData.isEmpty else {
            errorMessage = "Invalid hex command. Example: 30 04 or 60"
            return
        }

        appendAPDULog("TX > \(commandData.map { String(format: "%02X", $0) }.joined(separator: " "))")
        startSession(
            mode: .sendCustomCommand(commandData),
            alertMessage: "Hold NFC tag to transmit command."
        )
    }

    func stopScanning() {
        session?.invalidate()
        session = nil
        isScanning = false
        statusMessage = "Scanner paused"
    }

    private func startSession(mode: OperationMode, alertMessage: String) {
        guard NFCTagReaderSession.readingAvailable else {
            errorMessage = "NFC Tag Reading is not available on this device (requires a physical iPhone 7 or newer)."
            statusMessage = "NFC unavailable"
            return
        }

        session?.invalidate()
        activeMode = mode
        errorMessage = nil

        guard let newSession = NFCTagReaderSession(
            pollingOption: [.iso14443, .iso15693, .iso18092],
            delegate: self,
            queue: nil
        ) else {
            errorMessage = "Failed to initialize CoreNFC reader session."
            return
        }

        newSession.alertMessage = alertMessage
        self.session = newSession
        self.isScanning = true
        self.statusMessage = "Waiting for an NFC tag..."
        newSession.begin()
    }

    // MARK: - Helpers

    func appendAPDULog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        apduLogs.append("[\(formatter.string(from: Date()))] \(line)")
    }

    static func hexStringToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}

// MARK: - NFCTagReaderSessionDelegate

extension NFCTagManager: NFCTagReaderSessionDelegate {

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        Task { @MainActor [weak self] in
            self?.isScanning = true
            self?.statusMessage = "Waiting for an NFC tag..."
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isScanning = false
            self.session = nil

            if let nfcError = error as? NFCReaderError {
                switch nfcError.code {
                case .readerSessionInvalidationErrorUserCanceled,
                     .readerSessionInvalidationErrorFirstNDEFTagRead:
                    self.statusMessage = "Ready to scan"
                case .readerSessionInvalidationErrorSessionTimeout:
                    self.statusMessage = "Session timed out. Tap to wait again."
                default:
                    self.errorMessage = nfcError.localizedDescription
                    self.statusMessage = "Scan ended"
                }
            } else {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Scan ended"
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let firstTag = tags.first else { return }

        if tags.count > 1 {
            session.alertMessage = "More than 1 tag detected. Please hold a single card."
            session.restartPolling()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let mode = self.activeMode
            self.processDetectedTag(firstTag, in: session, mode: mode)
        }
    }

    // MARK: - Tag Processing Pipeline

    private func processDetectedTag(_ tag: NFCTag, in session: NFCTagReaderSession, mode: OperationMode) {
        let metadata = Self.extractMetadata(from: tag)

        session.connect(to: tag) { [weak self] connectError in
            if let connectError {
                session.invalidate(errorMessage: "Unable to connect: \(connectError.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.errorMessage = connectError.localizedDescription
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                switch mode {
                case .bindUIDToTrack(let track):
                    session.alertMessage = "Bound UID \(metadata.uid) to \"\(track.title)\""
                    session.invalidate()
                    self.statusMessage = "Bound UID \(metadata.uid)"
                    self.onUIDCapturedForBinding?(metadata.uid, track)

                case .sendCustomCommand(let cmdData):
                    self.executeRawCommand(cmdData, on: tag, session: session)

                case .writeTextRecord(let text):
                    guard let payload = NDEFCodec.createTextPayload(text: text) else {
                        session.invalidate(errorMessage: "Could not encode text payload.")
                        return
                    }
                    let msg = NFCNDEFMessage(records: [payload])
                    self.writeNDEFMessage(msg, to: metadata.ndefTag, uid: metadata.uid, session: session, successBanner: "Written \"\(text)\"")

                case .writeURIRecord(let uri):
                    guard let payload = NDEFCodec.createURIPayload(urlString: uri) else {
                        session.invalidate(errorMessage: "Could not encode URI payload.")
                        return
                    }
                    let msg = NFCNDEFMessage(records: [payload])
                    self.writeNDEFMessage(msg, to: metadata.ndefTag, uid: metadata.uid, session: session, successBanner: "URI written!")

                case .eraseTag:
                    let emptyRecord = NFCNDEFPayload(format: .empty, type: Data(), identifier: Data(), payload: Data())
                    let msg = NFCNDEFMessage(records: [emptyRecord])
                    self.writeNDEFMessage(msg, to: metadata.ndefTag, uid: metadata.uid, session: session, successBanner: "Tag erased!")

                case .lockReadOnly:
                    self.lockTag(metadata.ndefTag, session: session)

                case .readAndPlayAudio:
                    self.readTag(
                        tag: tag,
                        uid: metadata.uid,
                        initialTech: metadata.initialTech,
                        ndefTag: metadata.ndefTag,
                        includeMemoryDump: false,
                        session: session
                    )

                case .inspectTag:
                    self.readTag(
                        tag: tag,
                        uid: metadata.uid,
                        initialTech: metadata.initialTech,
                        ndefTag: metadata.ndefTag,
                        includeMemoryDump: true,
                        session: session
                    )
                }
            }
        }
    }

    private struct TagMetadata {
        let uid: String
        let initialTech: NFCChipTech
        let ndefTag: NFCNDEFTag?
    }

    private static func extractMetadata(from tag: NFCTag) -> TagMetadata {
        switch tag {
        case .miFare(let mifare):
            let tech: NFCChipTech
            switch mifare.mifareFamily {
            case .ultralight: tech = .mifareUltralight
            case .plus, .desfire: tech = .iso7816Generic
            case .unknown: tech = .unknown
            @unknown default: tech = .unknown
            }
            return TagMetadata(uid: mifare.identifier.hexString, initialTech: tech, ndefTag: mifare)

        case .iso7816(let iso7816):
            return TagMetadata(uid: iso7816.identifier.hexString, initialTech: .iso7816Generic, ndefTag: iso7816)

        case .iso15693(let iso15693):
            return TagMetadata(uid: iso15693.identifier.hexString, initialTech: .icodeSLIX, ndefTag: iso15693)

        case .feliCa(let felica):
            return TagMetadata(uid: felica.currentIDm.hexString, initialTech: .felica, ndefTag: felica)

        @unknown default:
            return TagMetadata(uid: "", initialTech: .unknown, ndefTag: nil)
        }
    }

    // MARK: - Read & Inspect (Ported from NFCCard.java & TechHelper.java)

    private func readTag(
        tag: NFCTag,
        uid: String,
        initialTech: NFCChipTech,
        ndefTag: NFCNDEFTag?,
        includeMemoryDump: Bool,
        session: NFCTagReaderSession
    ) {
        guard let ndefTag else {
            let info = ScannedTagInfo(
                uid: uid,
                tech: initialTech,
                isWritable: false,
                capacityBytes: 0,
                records: [],
                memoryPages: [],
                scannedAt: Date()
            )
            self.lastScannedTag = info
            session.invalidate()
            self.onTagScannedForAudio?(info)
            return
        }

        ndefTag.queryNDEFStatus { [weak self] status, capacity, statusError in
            if let statusError, status == .notSupported {
                // Still inspect raw pages if MiFare Ultralight / NTAG
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.finalizeRead(
                        tag: tag,
                        uid: uid,
                        tech: initialTech,
                        isWritable: false,
                        capacity: capacity,
                        records: [],
                        includeMemoryDump: includeMemoryDump,
                        session: session,
                        fallbackError: statusError
                    )
                }
                return
            }

            let writable = (status == .readWrite)

            ndefTag.readNDEF { [weak self] message, readError in
                let decodedRecords = message?.records.map { NDEFCodec.decode(payload: $0) } ?? []

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.finalizeRead(
                        tag: tag,
                        uid: uid,
                        tech: initialTech,
                        isWritable: writable,
                        capacity: capacity,
                        records: decodedRecords,
                        includeMemoryDump: includeMemoryDump,
                        session: session,
                        fallbackError: readError
                    )
                }
            }
        }
    }

    private func finalizeRead(
        tag: NFCTag,
        uid: String,
        tech: NFCChipTech,
        isWritable: Bool,
        capacity: Int,
        records: [DecodedNDEFRecord],
        includeMemoryDump: Bool,
        session: NFCTagReaderSession,
        fallbackError: Error?
    ) {
        // If this is a MiFare Type 2 tag, detect exact NTAG21x model via GET_VERSION (0x60)
        // and optionally dump memory pages or recover NDEF TLV from raw pages.
        if case .miFare(let mifareTag) = tag, mifareTag.mifareFamily == .ultralight {
            let needRawTLVFallback = records.isEmpty
            if includeMemoryDump || needRawTLVFallback {
                Self.detectNTAGAndReadPages(
                    mifareTag: mifareTag,
                    capacity: capacity,
                    fullDump: includeMemoryDump
                ) { [weak self] detectedTech, pages in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var finalRecords = records
                        if finalRecords.isEmpty && !pages.isEmpty {
                            let userBytes = self.extractUserBytes(from: pages)
                            finalRecords = NDEFCodec.parseRawTLV(bytes: userBytes)
                        }

                        let resolvedTech = detectedTech != .unknown ? detectedTech : NFCChipTech.inferFromNDEFCapacity(capacity)
                        let info = ScannedTagInfo(
                            uid: uid,
                            tech: resolvedTech,
                            isWritable: isWritable,
                            capacityBytes: capacity,
                            records: finalRecords,
                            memoryPages: pages,
                            scannedAt: Date()
                        )
                        self.lastScannedTag = info
                        session.alertMessage = finalRecords.first?.payloadText ?? "Tag Read: \(uid)"
                        session.invalidate()

                        if !includeMemoryDump {
                            self.onTagScannedForAudio?(info)
                        } else {
                            self.statusMessage = "Inspected \(resolvedTech.displayName) (\(uid))"
                        }
                    }
                }
                return
            }
        }

        let resolvedTech: NFCChipTech = tech == .mifareUltralight
            ? NFCChipTech.inferFromNDEFCapacity(capacity)
            : tech

        let info = ScannedTagInfo(
            uid: uid,
            tech: resolvedTech,
            isWritable: isWritable,
            capacityBytes: capacity,
            records: records,
            memoryPages: [],
            scannedAt: Date()
        )
        self.lastScannedTag = info
        if let fallbackError, records.isEmpty {
            self.errorMessage = fallbackError.localizedDescription
        }
        session.alertMessage = records.first?.payloadText ?? "Tag Read: \(uid)"
        session.invalidate()

        if !includeMemoryDump {
            self.onTagScannedForAudio?(info)
        } else {
            self.statusMessage = "Inspected \(resolvedTech.displayName) (\(uid))"
        }
    }

    /// Sends `GET_VERSION` (0x60) and Type 2 `READ` (0x30 <page>) commands to dump 4-byte pages.
    nonisolated private static func detectNTAGAndReadPages(
        mifareTag: NFCMiFareTag,
        capacity: Int,
        fullDump: Bool,
        completion: @escaping (NFCChipTech, [MemoryPageBlock]) -> Void
    ) {
        // Command 0x60 = NXP GET_VERSION
        mifareTag.sendMiFareCommand(commandPacket: Data([0x60])) { versionData, versionErr in
            let detectedTech: NFCChipTech
            if versionErr == nil && versionData.count >= 7 {
                detectedTech = NFCChipTech.inferFromNTAGVersion([UInt8](versionData))
            } else {
                detectedTech = NFCChipTech.inferFromNDEFCapacity(capacity)
            }

            let targetPages = fullDump ? min(detectedTech.totalPageCount, 135) : 16
            Self.readPageChunks(
                mifareTag: mifareTag,
                startPage: 0,
                maxPage: targetPages,
                totalTechPages: detectedTech.totalPageCount,
                accumulated: []
            ) { pages in
                completion(detectedTech, pages)
            }
        }
    }

    /// Reads 16 bytes (4 pages) per MiFare `0x30` command recursively.
    nonisolated private static func readPageChunks(
        mifareTag: NFCMiFareTag,
        startPage: Int,
        maxPage: Int,
        totalTechPages: Int,
        accumulated: [MemoryPageBlock],
        completion: @escaping ([MemoryPageBlock]) -> Void
    ) {
        guard startPage < maxPage else {
            completion(accumulated)
            return
        }

        let cmd = Data([0x30, UInt8(startPage & 0xFF)])
        mifareTag.sendMiFareCommand(commandPacket: cmd) { data, error in
            guard error == nil, data.count >= 4 else {
                completion(accumulated)
                return
            }

            var updated = accumulated
            let bytes = [UInt8](data)
            let pagesInPacket = min(4, bytes.count / 4)

            for offset in 0..<pagesInPacket {
                let pageIndex = startPage + offset
                guard pageIndex < maxPage else { break }
                let slice = Array(bytes[(offset * 4)..<((offset + 1) * 4)])
                let hex = slice.map { String(format: "%02X", $0) }.joined(separator: ":")
                let ascii = String(slice.map { ($0 >= 0x20 && $0 <= 0x7E) ? Character(UnicodeScalar($0)) : "." })
                let block = MemoryPageBlock(
                    pageIndex: pageIndex,
                    addressHex: String(format: "0x%02X", pageIndex),
                    dataHex: hex,
                    asciiString: ascii,
                    accessDescription: MemoryPageBlock.pageAnnotation(for: pageIndex, totalPages: totalTechPages)
                )
                updated.append(block)
            }

            Self.readPageChunks(
                mifareTag: mifareTag,
                startPage: startPage + 4,
                maxPage: maxPage,
                totalTechPages: totalTechPages,
                accumulated: updated,
                completion: completion
            )
        }
    }

    private func extractUserBytes(from pages: [MemoryPageBlock]) -> [UInt8] {
        var result: [UInt8] = []
        for page in pages where page.pageIndex >= 4 {
            let parts = page.dataHex.split(separator: ":")
            for part in parts {
                if let byte = UInt8(part, radix: 16) {
                    result.append(byte)
                }
            }
        }
        return result
    }

    // MARK: - Write, Erase, Lock & Raw APDU (Ported from WriteTab.java & OtherTab.java)

    private func writeNDEFMessage(
        _ message: NFCNDEFMessage,
        to ndefTag: NFCNDEFTag?,
        uid: String,
        session: NFCTagReaderSession,
        successBanner: String
    ) {
        guard let ndefTag else {
            session.invalidate(errorMessage: "Tag does not support NDEF writing.")
            return
        }

        ndefTag.queryNDEFStatus { [weak self] status, capacity, error in
            if let error {
                session.invalidate(errorMessage: "Status error: \(error.localizedDescription)")
                return
            }

            guard status == .readWrite else {
                session.invalidate(errorMessage: "Tag is Read-Only or NDEF-unsupported.")
                return
            }

            let messageLength = message.length
            guard messageLength <= capacity else {
                session.invalidate(errorMessage: "Payload (\(messageLength) B) exceeds tag capacity (\(capacity) B).")
                return
            }

            ndefTag.writeNDEF(message) { [weak self] writeError in
                if let writeError {
                    session.invalidate(errorMessage: "Write failed: \(writeError.localizedDescription)")
                    Task { @MainActor [weak self] in
                        self?.errorMessage = writeError.localizedDescription
                    }
                    return
                }

                session.alertMessage = successBanner
                session.invalidate()
                Task { @MainActor [weak self] in
                    self?.statusMessage = "\(successBanner) (UID: \(uid))"
                    self?.onWriteSuccess?(successBanner)
                }
            }
        }
    }

    private func lockTag(_ ndefTag: NFCNDEFTag?, session: NFCTagReaderSession) {
        guard let ndefTag else {
            session.invalidate(errorMessage: "Tag does not support NDEF locking.")
            return
        }

        ndefTag.writeLock { [weak self] error in
            if let error {
                session.invalidate(errorMessage: "Lock failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
                return
            }
            session.alertMessage = "Tag permanently locked as Read-Only."
            session.invalidate()
            Task { @MainActor [weak self] in
                self?.statusMessage = "Tag locked Read-Only"
                self?.onWriteSuccess?("Tag locked Read-Only")
            }
        }
    }

    private func executeRawCommand(_ commandData: Data, on tag: NFCTag, session: NFCTagReaderSession) {
        switch tag {
        case .miFare(let mifareTag):
            mifareTag.sendMiFareCommand(commandPacket: commandData) { [weak self] response, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.appendAPDULog("ERR < \(error.localizedDescription)")
                        session.invalidate(errorMessage: error.localizedDescription)
                        return
                    }
                    let rxHex = response.map { String(format: "%02X", $0) }.joined(separator: " ")
                    self.appendAPDULog("RX < \(rxHex)")
                    self.statusMessage = "Command OK (\(response.count) bytes)"
                    session.alertMessage = "RX: \(rxHex)"
                    session.invalidate()
                }
            }

        case .iso7816(let iso7816Tag):
            guard let apdu = NFCISO7816APDU(data: commandData) else {
                session.invalidate(errorMessage: "Invalid ISO 7816 APDU structure.")
                return
            }
            iso7816Tag.sendCommand(apdu: apdu) { [weak self] data, sw1, sw2, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.appendAPDULog("ERR < \(error.localizedDescription)")
                        session.invalidate(errorMessage: error.localizedDescription)
                        return
                    }
                    let dataHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let statusHex = String(format: "SW1=%02X SW2=%02X", sw1, sw2)
                    self.appendAPDULog("RX < \(dataHex) [\(statusHex)]")
                    self.statusMessage = "APDU \(statusHex)"
                    session.alertMessage = statusHex
                    session.invalidate()
                }
            }

        default:
            session.invalidate(errorMessage: "Raw APDU / MiFare commands are supported on ISO 14443 / MiFare tags.")
        }
    }
}
