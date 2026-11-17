import SwiftUI

@main
struct KadBrailleApp: App {
    @StateObject private var database = LocalAudioDatabase()
    @StateObject private var driveSync = GoogleDriveSyncService()
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var nfcManager = NFCTagManager()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(database)
                .environmentObject(driveSync)
                .environmentObject(audioPlayer)
                .environmentObject(nfcManager)
        }
    }
}
