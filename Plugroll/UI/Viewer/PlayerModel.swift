import AVFoundation
import Observation

/// Playback state for the video on screen. The viewer keeps one of these at a time,
/// for the current page only, so swiping never leaves players running.
@MainActor
@Observable
final class PlayerModel {
    let url: URL
    let player: AVPlayer

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var isScrubbing = false
    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var resumeAfterScrub = false

    init(url: URL, knownDuration: Double?) {
        self.url = url
        duration = knownDuration ?? 0
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                // While the finger is on the scrub bar, the bar owns the time.
                guard let self, !self.isScrubbing, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }

        Task { [weak self] in
            guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
            self?.duration = seconds
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func skip(by seconds: Double) {
        var target = max(0, currentTime + seconds)
        if duration > 0 { target = min(target, duration) }
        seek(to: target, precise: true)
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        player.pause()
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        // Loose tolerance keeps the picture following the finger without stalling.
        seek(to: seconds, precise: false)
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: currentTime, precise: true)
        if resumeAfterScrub { player.play() }
    }

    /// Stops playback and releases the file. Call when the page leaves the screen.
    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    private func seek(to seconds: Double, precise: Bool) {
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        if precise { currentTime = seconds }
    }

    /// Like Photos: back to the first frame, paused.
    private func didReachEnd() {
        seek(to: 0, precise: true)
    }
}
