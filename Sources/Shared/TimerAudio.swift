import AVFoundation
import Foundation
import OSLog
#if os(iOS)
import Combine
#endif

@MainActor
final class TimerAudio: NSObject, AVAudioPlayerDelegate {
    private static let noiseVolume: Float = 0.27
    private static let fadeDuration: TimeInterval = 0.15

    private let logger = Logger(subsystem: "com.pomodorotimer.apricot", category: "audio")
    private var whiteNoisePlayer: AVAudioPlayer?
    private var chimePlayer: AVAudioPlayer?
    private var stopAfterFade: Task<Void, Never>?
    private var whiteNoiseRequested = false

#if os(iOS)
    private let audioSession = AVAudioSession.sharedInstance()
    private var interruptionObserver: AnyCancellable?
    private var interrupted = false
    private var playbackSessionActive = false

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in self?.handleInterruption(notification) }
    }
#endif

    func setWhiteNoisePlaying(_ shouldPlay: Bool) {
        whiteNoiseRequested = shouldPlay
        if shouldPlay {
            startWhiteNoise()
        } else {
            fadeOutWhiteNoise()
        }
    }

    func playChime() {
        guard let url = Bundle.main.url(forResource: "FocusChime", withExtension: "wav") else { return }
        if !whiteNoiseRequested { stopWhiteNoise() }

        do {
#if os(iOS)
            guard !interrupted else { return }
            if !playbackSessionActive {
                try audioSession.setCategory(.ambient)
            }
#endif
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            if player.play() {
                chimePlayer?.stop()
                chimePlayer = player
            }
        } catch {
            logger.error("Chime playback failed: \(error.localizedDescription)")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let chimePlayer, ObjectIdentifier(chimePlayer) == identifier else { return }
            self.chimePlayer = nil
            releasePlaybackSessionIfIdle()
        }
    }

    private func startWhiteNoise() {
        stopAfterFade?.cancel()
        stopAfterFade = nil

        if let whiteNoisePlayer, whiteNoisePlayer.isPlaying {
            whiteNoisePlayer.setVolume(Self.noiseVolume, fadeDuration: Self.fadeDuration)
            return
        }

        do {
#if os(iOS)
            guard !interrupted else { return }
#endif
            if whiteNoisePlayer == nil,
               let url = Bundle.main.url(forResource: "WhiteNoise", withExtension: "wav") {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                whiteNoisePlayer = player
            }
            guard let whiteNoisePlayer else {
                logger.error("The bundled white noise track is missing.")
                return
            }

#if os(iOS)
            if !playbackSessionActive {
                try audioSession.setCategory(.playback, options: .mixWithOthers)
                try audioSession.setActive(true)
                playbackSessionActive = true
            }
#endif
            whiteNoisePlayer.volume = 0
            if whiteNoisePlayer.play() {
                whiteNoisePlayer.setVolume(Self.noiseVolume, fadeDuration: Self.fadeDuration)
            } else {
                releasePlaybackSessionIfIdle()
                logger.error("The white noise player did not start.")
            }
        } catch {
            logger.error("White noise playback failed: \(error.localizedDescription)")
        }
    }

    private func fadeOutWhiteNoise() {
        guard stopAfterFade == nil else { return }
        guard let whiteNoisePlayer, whiteNoisePlayer.isPlaying else {
            stopWhiteNoise()
            return
        }
        whiteNoisePlayer.setVolume(0, fadeDuration: Self.fadeDuration)
        stopAfterFade = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.fadeDuration))
            } catch {
                return
            }
            guard let self, !whiteNoiseRequested else { return }
            stopWhiteNoise()
        }
    }

    private func stopWhiteNoise() {
        stopAfterFade?.cancel()
        stopAfterFade = nil
        whiteNoisePlayer?.stop()
        whiteNoisePlayer?.currentTime = 0
        releasePlaybackSessionIfIdle()
    }

    private func releasePlaybackSessionIfIdle() {
#if os(iOS)
        guard playbackSessionActive,
              whiteNoisePlayer?.isPlaying != true,
              chimePlayer?.isPlaying != true else { return }
        do {
            try audioSession.setActive(false)
            playbackSessionActive = false
        } catch {
            logger.error("Audio session deactivation failed: \(error.localizedDescription)")
        }
#endif
    }

#if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let value = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }

        switch type {
        case .began:
            interrupted = true
            playbackSessionActive = false
            whiteNoisePlayer?.pause()
        case .ended:
            interrupted = false
            let value = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if whiteNoiseRequested, AVAudioSession.InterruptionOptions(rawValue: value).contains(.shouldResume) {
                startWhiteNoise()
            }
        @unknown default:
            break
        }
    }
#endif
}
