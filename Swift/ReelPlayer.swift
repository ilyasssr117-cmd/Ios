import AVFoundation
import Combine
import Observation

/// One reel's player. Replaces Flutter's `VideoPlayerController` plus the
/// hand-written init/timeout/fallback/stall bookkeeping in `_build()`.
///
/// MIGRATION NOTES
/// - `AVPlayer` already reports buffering (`timeControlStatus`), so the Dart
///   `_StallSpinner` timer polling becomes the `isWaiting` flag.
/// - Looping is done by seeking to zero on `AVPlayerItemDidPlayToEndTime`.
/// - Teardown is `replaceCurrentItem(with: nil)`, which is synchronous and
///   cheap, so the serialized `_disposeTail` queue is not needed.
@MainActor @Observable
final class ReelPlayer {
    enum State { case loading, ready, failed }

    private(set) var state: State = .loading
    private(set) var isPlaying = false      // intent: playing or waiting to play
    private(set) var isWaiting = false      // actually stalled on the network
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var buffered: Double = 0   // 0...1 of duration

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var itemBag = Set<AnyCancellable>()
    @ObservationIgnored private var playerBag = Set<AnyCancellable>()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackURL: URL?
    @ObservationIgnored private let headers: [String: String]
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var speed: Float = 1
    @ObservationIgnored private var isTornDown = false

    init(url: URL, fallback: URL?, headers: [String: String]) {
        self.fallbackURL = fallback
        self.headers = headers
        player.actionAtItemEnd = .none
        player.isMuted = true
        player.allowsExternalPlayback = false

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.isPlaying = status != .paused
                    self?.isWaiting = status == .waitingToPlayAtSpecifiedRate
                }
            }
            .store(in: &playerBag)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.state == .ready else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = seconds }
            }
        }
        load(url)
    }

    // MARK: Loading

    private func load(_ url: URL) {
        timeoutTask?.cancel()
        itemBag.removeAll()
        state = .loading
        position = 0
        buffered = 0

        // Same media headers the Flutter client sent (Referer/Origin/UA).
        let asset = makeStreamAsset(url: url, headers: headers)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4 // keep the speculative decoder light

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.statusChanged(status, item: item) }
            }
            .store(in: &itemBag)

        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let seconds = value.seconds
                    if seconds.isFinite && seconds > 0 { self.duration = seconds }
                }
            }
            .store(in: &itemBag)

        item.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ranges in
                MainActor.assumeIsolated {
                    guard let self, self.duration > 0,
                          let end = ranges.last?.timeRangeValue.end.seconds, end.isFinite else { return }
                    self.buffered = min(1, max(0, end / self.duration))
                }
            }
            .store(in: &itemBag)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.player.seek(to: .zero)
                    if self.wantsPlay { self.startPlayback() }
                }
            }
            .store(in: &itemBag)

        player.replaceCurrentItem(with: item)

        // initialize().timeout(28s)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(28))
            guard !Task.isCancelled else { return }
            self?.handleFailure()
        }
    }

    private func statusChanged(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        guard !isTornDown, player.currentItem === item else { return }
        switch status {
        case .readyToPlay:
            timeoutTask?.cancel()
            let seconds = item.duration.seconds
            if seconds.isFinite && seconds > 0 { duration = seconds }
            state = .ready
            if wantsPlay { startPlayback() }
        case .failed:
            handleFailure()
        default:
            break
        }
    }

    private func handleFailure() {
        guard !isTornDown, state != .ready else { return }
        if let fallback = fallbackURL {
            fallbackURL = nil
            load(fallback) // mp4 failed -> try the HLS URL
        } else {
            timeoutTask?.cancel()
            state = .failed
        }
    }

    // MARK: Controls

    private func startPlayback() {
        player.defaultRate = speed
        player.play()
    }

    func setPlaying(_ on: Bool) {
        wantsPlay = on
        guard state == .ready else { return }
        if on { startPlayback() } else { player.pause() }
    }

    func togglePlay() { setPlaying(!isPlaying) }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func setSpeed(_ value: Float) {
        speed = value
        player.defaultRate = value
        if player.timeControlStatus != .paused { player.rate = value }
    }

    func seek(to seconds: Double) async {
        guard state == .ready, duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func seek(toFraction fraction: Double) async {
        await seek(to: duration * min(max(fraction, 0), 1))
    }

    func teardown() {
        isTornDown = true
        timeoutTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemBag.removeAll()
        playerBag.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
