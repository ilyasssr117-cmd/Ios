import AVFoundation
import Combine
import Observation

/// Full-screen player engine; the replacement for `VideoPlayerController`
/// in player_page.dart.
///
/// MIGRATION NOTES
/// - `VideoPlayerValue` (a ValueNotifier listened to by many timers) becomes
///   observable properties; `PlayerViewModel` samples them at 4 Hz.
/// - `initialize().timeout(30s)` is `load(...)`, which waits for
///   `.readyToPlay` racing a timeout.
/// - The serialized native-disposal queue (`_pendingDisposals`) is not needed:
///   `replaceCurrentItem(with: nil)` is synchronous on AVFoundation.
@MainActor @Observable
final class PlayerEngine {
    private(set) var isReady = false
    private(set) var hasError = false
    private(set) var errorDescription: String?
    private(set) var isPlaying = false      // playing or waiting to play
    private(set) var isBuffering = false    // genuinely stalled on the network
    private(set) var didReachEnd = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedEnd: Double = 0
    private(set) var videoSize: CGSize = .zero

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var itemBag = Set<AnyCancellable>()
    @ObservationIgnored private var playerBag = Set<AnyCancellable>()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var speed: Float = 1

    var aspectRatio: CGFloat {
        videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : 16 / 9
    }

    init() {
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = true

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaying = status != .paused
                    self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                    if status == .playing { self.didReachEnd = false }
                }
            }
            .store(in: &playerBag)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isReady else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = seconds }
            }
        }
    }

    // MARK: Loading

    struct LoadTimeout: Error {}

    /// Loads and waits until the item is ready to play (or throws).
    func load(url: URL, headers: [String: String]?, timeout: Duration = .seconds(30)) async throws {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        itemBag.removeAll()
        isReady = false
        hasError = false
        errorDescription = nil
        didReachEnd = false
        position = 0
        duration = 0
        bufferedEnd = 0

        let asset = AVURLAsset(
            url: url,
            options: (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
        )
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await status in item.publisher(for: \.status).values {
                    switch status {
                    case .readyToPlay: return
                    case .failed: throw item.error ?? URLError(.cannotParseResponse)
                    default: continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoadTimeout()
            }
            _ = try await group.next()
            group.cancelAll()
        }

        let seconds = item.duration.seconds
        duration = seconds.isFinite ? seconds : 0
        videoSize = item.presentationSize
        isReady = true
        observeOngoing(item)
    }

    /// Errors after a successful start (stream dropped, etc.) -> `value.hasError`.
    private func observeOngoing(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, status == .failed else { return }
                    self.hasError = true
                    self.errorDescription = item.error?.localizedDescription
                }
            }
            .store(in: &itemBag)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.hasError = true } }
            .store(in: &itemBag)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.didReachEnd = true } }
            .store(in: &itemBag)

        item.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ranges in
                MainActor.assumeIsolated {
                    if let end = ranges.last?.timeRangeValue.end.seconds, end.isFinite { self?.bufferedEnd = end }
                }
            }
            .store(in: &itemBag)

        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in MainActor.assumeIsolated { self?.videoSize = size } }
            .store(in: &itemBag)
    }

    // MARK: Controls

    func play() {
        didReachEnd = false
        player.defaultRate = speed
        player.play()
    }

    func pause() { player.pause() }

    func setSpeed(_ value: Float) {
        speed = value
        player.defaultRate = value
        if player.timeControlStatus != .paused { player.rate = value }
    }

    func seek(to seconds: Double) async {
        let target = min(max(seconds, 0), duration > 0 ? duration : seconds)
        position = target
        didReachEnd = false
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemBag.removeAll()
        playerBag.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isReady = false
    }
}
