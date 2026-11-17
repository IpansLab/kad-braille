import SwiftUI

struct ScannerView: View {
    @EnvironmentObject private var database: LocalAudioDatabase
    @EnvironmentObject private var audioPlayer: AudioPlayerManager
    @EnvironmentObject private var nfcManager: NFCTagManager

    @Binding var autoRescanAfterAudio: Bool
    @Binding var unmatchedTag: ScannedTagInfo?

    @State private var showBindSheet: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Giant Braille / VoiceOver Accessible Scan Button
                    scanButton

                    // Continuous Flow Setting
                    Toggle(isOn: $autoRescanAfterAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Wait for Next Tag")
                                .font(.headline)
                            Text("Re-arm NFC reader automatically after audio finishes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    // Error Alert Card
                    if let error = nfcManager.errorMessage ?? audioPlayer.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }

                    // Unmatched Tag Action Card
                    if let tag = unmatchedTag {
                        unmatchedTagCard(tag)
                    }

                    // Now Playing Audio Card
                    if let track = audioPlayer.currentTrack {
                        nowPlayingCard(track)
                    }

                    // Last Scanned Tag Info Card
                    if let tag = nfcManager.lastScannedTag {
                        lastTagCard(tag)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Kad Braille")
            .sheet(isPresented: $showBindSheet) {
                if let tag = unmatchedTag {
                    BindUnknownTagSheet(
                        tag: tag,
                        tracks: database.tracks,
                        onAssignUID: { track in
                            database.assignUID(tag.uid, toTrackId: track.id)
                            if let url = database.audioURL(for: track) {
                                audioPlayer.play(track: track, url: url)
                            }
                            unmatchedTag = nil
                            showBindSheet = false
                        },
                        onWriteNDEF: { track in
                            showBindSheet = false
                            unmatchedTag = nil
                            nfcManager.startWriteText(track.title)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Subviews

    private var scanButton: some View {
        Button {
            if nfcManager.isScanning {
                nfcManager.stopScanning()
            } else {
                nfcManager.startScanForAudio()
            }
        } label: {
            VStack(spacing: 16) {
                Image(systemName: nfcManager.isScanning ? "wave.3.right.circle.fill" : "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 64))
                    .symbolEffect(.pulse, isActive: nfcManager.isScanning)
                    .foregroundStyle(.white)

                Text(nfcManager.isScanning ? "Waiting for NFC Tag..." : "Tap to Scan Braille Card")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text(nfcManager.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(24)
            .background(
                LinearGradient(
                    colors: nfcManager.isScanning
                        ? [Color.green, Color.teal]
                        : [Color.blue, Color.indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .shadow(color: (nfcManager.isScanning ? Color.green : Color.blue).opacity(0.28), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nfcManager.isScanning ? "Waiting for NFC tag. Tap to stop." : "Tap to scan Braille card")
        .accessibilityHint("Hold a Braille algebra NFC card near the top of your iPhone.")
    }

    private func nowPlayingCard(_ track: AudioTrackItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(audioPlayer.isPlaying ? "NOW PLAYING" : "LAST PLAYED")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(track.title)
                        .font(.title.bold())
                }
                Spacer()
                Text(track.source.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        track.source == .googleDrive ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(track.source == .googleDrive ? .blue : .orange)
            }

            if audioPlayer.duration > 0 {
                ProgressView(value: min(audioPlayer.currentTime, audioPlayer.duration), total: audioPlayer.duration)
                    .tint(.accentColor)
                HStack {
                    Text(formatTime(audioPlayer.currentTime))
                    Spacer()
                    Text(formatTime(audioPlayer.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    audioPlayer.replayCurrent(using: database)
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                if audioPlayer.isPlaying {
                    Button(role: .destructive) {
                        audioPlayer.stop(notifyFinished: false)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func unmatchedTagCard(_ tag: ScannedTagInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Unmapped NFC Tag Detected", systemImage: "questionmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Dismiss") {
                    unmatchedTag = nil
                }
                .font(.caption)
            }

            Text("UID: \(tag.uid.isEmpty ? "Unknown" : tag.uid)")
                .font(.caption.monospaced())
            if let text = tag.primaryTextPayload {
                Text("Tag NDEF Text: \"\(text)\" (no matching audio found)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("This tag has no matching NDEF text and its UID is not bound to an audio file yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showBindSheet = true
            } label: {
                Label("Link This Tag to an Audio Track", systemImage: "link.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func lastTagCard(_ tag: ScannedTagInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST SCANNED CHIP")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LabeledContent("UID", value: tag.uid.isEmpty ? "N/A" : tag.uid)
                .font(.subheadline.monospaced())
            LabeledContent("Technology", value: tag.tech.displayName)
                .font(.subheadline)
            if let text = tag.primaryTextPayload {
                LabeledContent("NDEF Payload", value: text)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct BindUnknownTagSheet: View {
    let tag: ScannedTagInfo
    let tracks: [AudioTrackItem]
    let onAssignUID: (AudioTrackItem) -> Void
    let onWriteNDEF: (AudioTrackItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Scanned UID", value: tag.uid)
                        .font(.subheadline.monospaced())
                    LabeledContent("Chip Tech", value: tag.tech.displayName)
                } header: {
                    Text("Scanned Tag")
                }

                Section {
                    ForEach(tracks) { track in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(track.title)
                                .font(.headline)
                            Text(track.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("Bind UID (Instant)") {
                                    onAssignUID(track)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("Write NDEF Label") {
                                    onWriteNDEF(track)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Choose Audio Track")
                } footer: {
                    Text("'Bind UID' links this physical card's serial number inside the app database immediately. 'Write NDEF Label' programs the text directly onto the NFC chip.")
                }
            }
            .navigationTitle("Link Tag to Audio")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
