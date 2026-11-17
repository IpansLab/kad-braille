import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var database: LocalAudioDatabase
    @EnvironmentObject private var driveSync: GoogleDriveSyncService
    @EnvironmentObject private var audioPlayer: AudioPlayerManager
    @EnvironmentObject private var nfcManager: NFCTagManager

    @AppStorage("autoRescanAfterAudio") private var autoRescanAfterAudio: Bool = true
    @State private var selectedMainTab: Int = 0
    @State private var unmatchedTag: ScannedTagInfo?
    @State private var toastMessage: String?
    @State private var lastTriggeredByCoreNFC: Bool = false

    var body: some View {
        TabView(selection: $selectedMainTab) {
            ScannerView(
                autoRescanAfterAudio: $autoRescanAfterAudio,
                unmatchedTag: $unmatchedTag
            )
            .tag(0)
            .tabItem {
                Label("Scan & Play", systemImage: "wave.3.right.circle.fill")
            }

            DatabaseSyncView()
                .tag(1)
                .tabItem {
                    Label("Database & Sync", systemImage: "icloud.and.arrow.down")
                }

            NFCToolsView()
                .tag(2)
                .tabItem {
                    Label("NFC Tools", systemImage: "cpu")
                }
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            wireCallbacks()
        }
        .onOpenURL { url in
            handleIncomingDeepLink(url)
        }
    }

    private func handleIncomingDeepLink(_ url: URL) {
        selectedMainTab = 0
        lastTriggeredByCoreNFC = false

        if let matchedTrack = database.resolveTrack(fromDeepLink: url),
           let fileURL = database.audioURL(for: matchedTrack) {
            unmatchedTag = nil
            audioPlayer.play(track: matchedTrack, url: fileURL)
            nfcManager.statusMessage = "Triggered via NFC URL: \(matchedTrack.title)"
            showToast("Playing: \(matchedTrack.title)")
        } else {
            audioPlayer.triggerWarningHaptic()
            nfcManager.statusMessage = "Unrecognized NFC URL: \(url.absoluteString)"
            showToast("No matching audio for link")
        }
    }

    private func wireCallbacks() {
        nfcManager.onTagScannedForAudio = { scannedTag in
            if let matchedTrack = database.resolveTrack(for: scannedTag),
               let fileURL = database.audioURL(for: matchedTrack) {
                lastTriggeredByCoreNFC = true
                unmatchedTag = nil
                audioPlayer.play(track: matchedTrack, url: fileURL)
                nfcManager.statusMessage = "Playing: \(matchedTrack.title)"
            } else {
                lastTriggeredByCoreNFC = false
                audioPlayer.triggerWarningHaptic()
                unmatchedTag = scannedTag
                nfcManager.statusMessage = "Unrecognized tag (\(scannedTag.uid))"
            }
        }

        nfcManager.onUIDCapturedForBinding = { uid, track in
            database.assignUID(uid, toTrackId: track.id)
            audioPlayer.triggerSuccessHaptic()
            showToast("Bound \(uid) to \"\(track.title)\"")
            if unmatchedTag?.uid == uid {
                unmatchedTag = nil
            }
        }

        nfcManager.onWriteSuccess = { message in
            audioPlayer.triggerSuccessHaptic()
            showToast(message)
        }

        audioPlayer.onPlaybackFinished = {
            guard autoRescanAfterAudio && lastTriggeredByCoreNFC else { return }
            // Brief delay allows the previous CoreNFC sheet dismissal to complete cleanly on iOS
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !nfcManager.isScanning && !audioPlayer.isPlaying {
                    nfcManager.startScanForAudio()
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation {
            toastMessage = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation {
                if toastMessage == text {
                    toastMessage = nil
                }
            }
        }
    }
}
