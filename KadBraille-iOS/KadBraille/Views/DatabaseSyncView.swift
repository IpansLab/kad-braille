import SwiftUI
import UIKit

struct DatabaseSyncView: View {
    @EnvironmentObject private var database: LocalAudioDatabase
    @EnvironmentObject private var driveSync: GoogleDriveSyncService
    @EnvironmentObject private var audioPlayer: AudioPlayerManager
    @EnvironmentObject private var nfcManager: NFCTagManager

    @State private var showAPIKeyField: Bool = false
    @State private var showSyncLog: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var copiedTrackId: String?

    var body: some View {
        NavigationStack {
            List {
                googleDriveSyncSection
                internalDatabaseSection
            }
            .navigationTitle("Database & Sync")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset DB", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .confirmationDialog(
                "Reset Internal Database?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset to 8 Bundled Audio Tracks", role: .destructive) {
                    database.resetToBundledDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears synced Google Drive files and custom UID bindings, restoring the original 8 bundled UNGKAPAN ALGEBRA tracks.")
            }
        }
    }

    // MARK: - Google Drive Section

    private var googleDriveSyncSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Public Google Drive Folder URL or ID")
                    .font(.subheadline.weight(.semibold))

                TextField("https://drive.google.com/drive/folders/...", text: $driveSync.folderInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                DisclosureGroup("Optional: Google Drive API Key", isExpanded: $showAPIKeyField) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("AIza... (leave blank for public folder view)", text: $driveSync.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Public folders set to 'Anyone with the link' sync without an API key. Add a Drive v3 API key if your folder contains over 50 files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)

                Button {
                    Task {
                        await driveSync.syncNow(into: database)
                    }
                } label: {
                    HStack {
                        if driveSync.isSyncing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(driveSync.isSyncing ? "Syncing..." : "Sync Now from Google Drive")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(driveSync.isSyncing)

                if driveSync.isSyncing || driveSync.syncProgress > 0 {
                    ProgressView(value: driveSync.syncProgress)
                }

                HStack {
                    Text(driveSync.syncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let lastSync = driveSync.lastSyncDate {
                        Text(lastSync, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = driveSync.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !driveSync.syncLog.isEmpty {
                    DisclosureGroup("Sync Activity Log (\(driveSync.syncLog.count))", isExpanded: $showSyncLog) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(driveSync.syncLog, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Online Database (Google Drive)")
        } footer: {
            Text("Set your Google Drive audio folder to 'Anyone with the link' (Viewer). Tap Sync Now whenever you upload or update .m4a/.mp3 files to download them into offline app storage.")
        }
    }

    // MARK: - Internal Database Section

    private var internalDatabaseSection: some View {
        Section {
            ForEach(database.tracks) { track in
                trackRow(track)
            }
            .onDelete { offsets in
                for index in offsets {
                    let track = database.tracks[index]
                    database.removeTrack(id: track.id)
                }
            }
        } header: {
            Text("Internal App Database (\(database.tracks.count) Tracks)")
        } footer: {
            Text("Each track plays offline from internal storage when a card matches either its NDEF Text label (e.g. \"\(database.tracks.first?.title ?? "3x + x")\") or a bound NFC Tag UID.")
        }
    }

    private func trackRow(_ track: AudioTrackItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                    Text(track.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(track.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        track.source == .googleDrive ? Color.blue.opacity(0.14) : Color.orange.opacity(0.14),
                        in: Capsule()
                    )
                    .foregroundStyle(track.source == .googleDrive ? .blue : .orange)
            }

            // Assigned UIDs list
            if !track.assignedUIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(track.assignedUIDs, id: \.self) { uid in
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .font(.caption2)
                                Text(uid)
                                    .font(.caption2.monospaced())
                                Button {
                                    database.unassignUID(uid, fromTrackId: track.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                        }
                    }
                }
            } else {
                Text("No UIDs bound (matches via NDEF text \"\(track.title)\")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Deep Link URL for $0 Free Signing / iOS Shortcuts Automation
            let deepLink = database.deepLinkURLString(for: track)
            Text("NFC Link: \(deepLink)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            // Row Action Buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        if let url = database.audioURL(for: track) {
                            audioPlayer.play(track: track, url: url)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        UIPasteboard.general.string = deepLink
                        copiedTrackId = track.id
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if copiedTrackId == track.id {
                                copiedTrackId = nil
                            }
                        }
                    } label: {
                        Label(
                            copiedTrackId == track.id ? "Copied!" : "Copy NFC URL",
                            systemImage: copiedTrackId == track.id ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        nfcManager.startBindUID(to: track)
                    } label: {
                        Label("Bind UID", systemImage: "link")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        nfcManager.startWriteText(track.title)
                    } label: {
                        Label("Write Tag", systemImage: "square.and.pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
