import SwiftUI

struct NFCToolsView: View {
    enum ToolSubtab: String, CaseIterable, Identifiable {
        case information = "Info"
        case write = "Write"
        case memory = "Memory"
        case other = "Other"

        var id: String { rawValue }
    }

    enum CustomWriteType: String, CaseIterable, Identifiable {
        case text = "Text (T)"
        case uri = "URL / URI (U)"

        var id: String { rawValue }
    }

    @EnvironmentObject private var database: LocalAudioDatabase
    @EnvironmentObject private var nfcManager: NFCTagManager

    @State private var selectedTab: ToolSubtab = .information
    @State private var selectedPresetTrackId: String = ""
    @State private var customWriteType: CustomWriteType = .text
    @State private var customWriteInput: String = ""
    @State private var customCommandHex: String = "30 04"
    @State private var showLockConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("NFC Tool Tab", selection: $selectedTab) {
                    ForEach(ToolSubtab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                switch selectedTab {
                case .information:
                    informationTab
                case .write:
                    writeTab
                case .memory:
                    memoryTab
                case .other:
                    otherTab
                }
            }
            .navigationTitle("NFC Tools")
            .onAppear {
                if selectedPresetTrackId.isEmpty, let first = database.tracks.first {
                    selectedPresetTrackId = first.id
                }
            }
        }
    }

    // MARK: - 1. Information Tab (Ported from InformationTab.java)

    private var informationTab: some View {
        List {
            Section {
                Button {
                    nfcManager.startInspectTag()
                } label: {
                    Label("Scan & Inspect NFC Tag", systemImage: "wave.3.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                if let err = nfcManager.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let tag = nfcManager.lastScannedTag {
                Section("Tag Metadata") {
                    LabeledContent("TECH", value: tag.tech.displayName)
                    LabeledContent("UID", value: tag.uid.isEmpty ? "N/A" : tag.uid)
                        .font(.subheadline.monospaced())
                    LabeledContent("MEMORY INFO", value: tag.tech.memoryDescription)
                    LabeledContent("NDEF CAPACITY", value: "\(tag.capacityBytes) bytes")
                    LabeledContent("ACCESS", value: tag.isWritable ? "Readable & Writable" : "Read-Only")
                }

                Section("NDEF Records (\(tag.records.count))") {
                    if tag.records.isEmpty {
                        Text("No NDEF records found on this chip.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tag.records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.recordType)
                                        .font(.headline)
                                    Spacer()
                                    Text(record.tnf)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(record.payloadText.isEmpty ? "(Empty)" : record.payloadText)
                                    .font(.body)
                                    .textSelection(.enabled)
                                if let lang = record.languageCode {
                                    Text("Language: \(lang)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("HEX: \(record.rawHex)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Waiting for an NFC Tag",
                        systemImage: "sensor.tag.radiowaves.forward",
                        description: Text("Tap 'Scan & Inspect NFC Tag' to view chip technology, UID, NDEF records, and memory pages.")
                    )
                }
            }
        }
    }

    // MARK: - 2. Write Tab (Ported from WriteTab.java)

    private var writeTab: some View {
        Form {
            Section {
                if database.tracks.isEmpty {
                    Text("No audio tracks in database.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Algebra Expression", selection: $selectedPresetTrackId) {
                        ForEach(database.tracks) { track in
                            Text(track.title).tag(track.id)
                        }
                    }

                    Button {
                        if let selected = database.tracks.first(where: { $0.id == selectedPresetTrackId }) ?? database.tracks.first {
                            nfcManager.startWriteText(selected.title)
                        }
                    } label: {
                        Label("Write Algebra Label to Tag", systemImage: "square.and.pencil")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Quick Program Braille Card")
            } footer: {
                Text("Writes a Well-Known NDEF Text ('T') record matching the selected audio clip so any iPhone running Kad Braille can recognize it automatically.")
            }

            Section {
                Picker("Record Type", selection: $customWriteType) {
                    ForEach(CustomWriteType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                TextField(
                    customWriteType == .text ? "Enter text (e.g. 3x + x)" : "Enter URL (e.g. https://...)",
                    text: $customWriteInput
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    let trimmed = customWriteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    switch customWriteType {
                    case .text:
                        nfcManager.startWriteText(trimmed)
                    case .uri:
                        nfcManager.startWriteURI(trimmed)
                    }
                } label: {
                    Label("Write Custom Record", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(customWriteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Custom NDEF Record")
            }
        }
    }

    // MARK: - 3. Memory Tab (Ported from MemoryTab.java)

    private var memoryTab: some View {
        List {
            Section {
                Button {
                    nfcManager.startInspectTag()
                } label: {
                    Label("Read Tag Memory Pages", systemImage: "memorychip")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }

            if let tag = nfcManager.lastScannedTag, !tag.memoryPages.isEmpty {
                Section("Memory Dump (\(tag.memoryPages.count) pages)") {
                    ForEach(tag.memoryPages) { page in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(page.addressHex)
                                    .font(.caption.bold().monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                                Text(page.dataHex)
                                    .font(.subheadline.monospaced())

                                Spacer()

                                Text(page.asciiString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(page.accessDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No Memory Dump Loaded",
                        systemImage: "memorychip",
                        description: Text("Tap 'Read Tag Memory Pages' and hold an NTAG21x / MIFARE Ultralight tag to inspect pages 0x00 upward.")
                    )
                }
            }
        }
    }

    // MARK: - 4. Other & Advanced APDU Tab (Ported from OtherTab.java)

    private var otherTab: some View {
        Form {
            Section {
                Button {
                    nfcManager.startEraseTag()
                } label: {
                    Label("Erase Tag (Write Empty NDEF)", systemImage: "eraser.fill")
                }

                Button(role: .destructive) {
                    showLockConfirmation = true
                } label: {
                    Label("Lock Tag Permanently (Read-Only)", systemImage: "lock.fill")
                }
            } header: {
                Text("Tag Maintenance")
            } footer: {
                Text("Locking an NFC chip is permanent and irreversible. Use Erase if you want to rewrite the tag later.")
            }
            .confirmationDialog(
                "Permanently Lock NFC Tag?",
                isPresented: $showLockConfirmation,
                titleVisibility: .visible
            ) {
                Button("Lock Permanently as Read-Only", role: .destructive) {
                    nfcManager.startLockReadOnly()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Once locked, this NFC tag can never be modified or erased again.")
            }

            Section {
                TextField("Hex command (e.g. 60 or 30 04)", text: $customCommandHex)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                HStack {
                    Button("GET_VERSION (60)") {
                        customCommandHex = "60"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("READ P4-7 (30 04)") {
                        customCommandHex = "30 04"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Button {
                        nfcManager.startSendCustomCommand(hexString: customCommandHex)
                    } label: {
                        Label("Send Command", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clear Logs") {
                        nfcManager.apduLogs.removeAll()
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("Advanced NFC Commands (APDU / MiFare)")
            }

            if !nfcManager.apduLogs.isEmpty {
                Section("Command Logs") {
                    ForEach(nfcManager.apduLogs, id: \.self) { entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
