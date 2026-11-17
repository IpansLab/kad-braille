import AVFoundation
import Foundation
import UIKit

/// Plays matched Braille Algebra `.m4a` clips via `AVAudioPlayer` using `.playback` audio session
/// so audio stays audible even when the iPhone hardware Ring/Silent switch is muted.
@MainActor
final class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published var isPlaying: Bool = false
    @Published var currentTrack: AudioTrackItem?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?

    var onPlaybackFinished: (() -> Void)?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    override init() {
        super.init()
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
        }
    }

    func play(track: AudioTrackItem, url: URL) {
        stop(notifyFinished: false)
        configureAudioSession()

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.play()

            self.player = audioPlayer
            self.currentTrack = track
            self.duration = audioPlayer.duration
            self.currentTime = 0
            self.isPlaying = true
            self.errorMessage = nil

            triggerSuccessHaptic()
            startProgressTimer()
        } catch {
            self.errorMessage = "Cannot play \(track.fileName): \(error.localizedDescription)"
            self.isPlaying = false
            triggerErrorHaptic()
        }
    }

    func replayCurrent(using database: LocalAudioDatabase) {
        guard let track = currentTrack, let url = database.audioURL(for: track) else { return }
        play(track: track, url: url)
    }

    func stop(notifyFinished: Bool = false) {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        if notifyFinished {
            onPlaybackFinished?()
        }
    }

    func triggerSuccessHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    func triggerWarningHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    func triggerErrorHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.isPlaying = false
            self.currentTime = self.duration
            self.onPlaybackFinished?()
        }
    }
}
