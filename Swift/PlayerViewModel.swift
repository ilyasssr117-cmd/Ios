import SwiftUI
import Observation

/// Port of the logic in `_PlayerPageState`.
///
/// MIGRATION NOTES
/// - The pile of `Timer`s and `ValueNotifier`s becomes `Task`s plus
///   `@Observable` properties. A single 4 Hz `monitor` replaces
///   `_onControllerChanged` (spinner delay, stall detection, completion).
/// - Every async path still checks `initGeneration` / `reloadToken`, exactly
///   like the Dart `generation != _initializationGeneration` guards.
/// - Android-style `PopScope`/`_handleBack` is gone; iOS back is the button.
@MainActor @Observable
final class PlayerViewModel {
    // MARK: Types
    struct Problem: Equatable { let title: String; let message: String; let systemImage: String }
    enum Side { case left, right }
    struct SeekFlash: Equatable { let side: Side; let seconds: Int }

    private struct MissingStreamError: Error {}
    private struct InvalidLinkError: Error {}

    static let controlsTimeout: Duration = .seconds(4)
    static let scrubCommitDelay: Duration = .milliseconds(350)
    static let maxAutoRetries = 3
    static let stallAfter: TimeInterval = 8
    static let autoplaySeconds = 5
    static let seekStep = 10
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: Observable state
    private(set) var video: Video
    private(set) var engine: PlayerEngine?
    private(set) var isLoading = true
    private(set) var showControls = true
    private(set) var completed = false
    private(set) var problem: Problem?
    private(set) var reconnecting = false
    private(set) var manualReload = false
    private(set) var autoRetries = 0
    private(set) var isReloading = false
    private(set) var stalled = false
    private(set) var spinnerVisible = false
    private(set) var scrubTarget: Double?
    private(set) var scrubOrigin: Double = 0
    private(set) var scrubBadge = true
    private(set) var speed: Double = 1.0
    private(set) var boosting = false
    var dragging = false
    private(set) var flash: SeekFlash?
    private(set) var lastFlash: SeekFlash?
    private(set) var countdown: Int?
    private(set) var autoplayCancelled = false
    private(set) var portrait = false
    var toast: String?
    var showSpeedSheet = false

    @ObservationIgnored let surface = PlayerSurface()
    @ObservationIgnored var dismiss: (() -> Void)?

    // MARK: Private state
    @ObservationIgnored private let queue: [Video]?
    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let progress: PlaybackProgress
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let downloads: DownloadStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let miniPlayer: MiniPlayer
    @ObservationIgnored private var adopted: MiniSession?
    @ObservationIgnored private var initialSource: PlaybackSource?
    @ObservationIgnored private var localPath: String?
    @ObservationIgnored private var resumeAt: TimeInterval?
    @ObservationIgnored private var recordedID: String?
    @ObservationIgnored private var activeURL: String?
    @ObservationIgnored private var activeHeaders: [String: String]?
    @ObservationIgnored private var activeIsFile = false
    @ObservationIgnored private var usedKnownSource = false
    @ObservationIgnored private var orientationForced = false
    @ObservationIgnored private var initGeneration = 0
    @ObservationIgnored private var reloadToken = 0
    @ObservationIgnored private var isLeaving = false
    @ObservationIgnored private var popping = false
    @ObservationIgnored private var pipBusy = false
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    @ObservationIgnored private var retryBase: TimeInterval = 0
    @ObservationIgnored private var wasPlayingBeforePause = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastSeen: TimeInterval = 0
    @ObservationIgnored private var bufferingSince: Date?
    @ObservationIgnored private var spinnerSince: Date?
    @ObservationIgnored private var stalledSince: Date?
    @ObservationIgnored private var lastTapAt: Date?
    @ObservationIgnored private var lastTapSide: Side?
    @ObservationIgnored private var boostPreviousSpeed: Double = 1
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var scrubTask: Task<Void, Never>?
    @ObservationIgnored private var scrubVersion = 0
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var autoplayTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    var isPortraitVideo: Bool { portrait }
    var isLive: Bool { (engine?.isReady ?? false) && problem == nil }
    var pipSupported: Bool { PiPCoordinator.isSupported }

    init(route: PlayerRoute, dependencies: AppDependencies,
         settings: AppSettings = .shared, miniPlayer: MiniPlayer = .shared) {
        self.video = route.video
        self.queue = route.queue
        self.resolver = dependencies.resolver
        self.progress = dependencies.progress
        self.history = dependencies.history
        self.downloads = dependencies.downloads
        self.settings = settings
        self.miniPlayer = miniPlayer
        self.resumeAt = route.startAt
        self.initialSource = route.initialSource
        self.localPath = route.localPath
        self.adopted = route.adopted
        if let adopted = route.adopted { self.speed = Double(adopted.speed) }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        AppOrientation.player(portrait: false)
        Task { await initialize() }
    }

    private func isCurrent(_ generation: Int) -> Bool { generation == initGeneration && !isLeaving }

    // MARK: Initialization (_initializePlayer)

    func initialize(refreshSource: Bool = false) async {
        guard !isLeaving else { return }
        initGeneration += 1
        let generation = initGeneration
        cancelTimers()
        countdown = nil
        stalled = false
        spinnerVisible = false
        scrubTarget = nil
        resetBufferingClock()
        if refreshSource, lastPosition > 3 { resumeAt = lastPosition - 2 }

        monitorTask?.cancel()
        if let old = engine {
            engine = nil
            old.teardown()
        }
        guard isCurrent(generation) else { return }
        isLoading = true
        problem = nil
        completed = false
        showControls = true

        // Adopted live session (from mini player / PiP): reuse its engine.
        if let live = adopted {
            adopted = nil
            activeURL = live.url
            activeHeaders = live.headers
            activeIsFile = live.isFile
            engine = live.engine
            usedKnownSource = false
            retryBase = live.engine.position
            applyVideoOrientation(live.engine)
            isLoading = false
            reconnecting = false
            manualReload = false
            startMonitor()
            scheduleHide()
            return
        }

        let lookAgain = refreshSource && !(reconnecting && autoRetries < 2)
        if lookAgain, localPath == nil {
            var bare = video
            bare.streamURL = ""
            if let fresh = try? await resolver.resolveForPlayback(bare, refresh: true),
               !fresh.streamURL.trimmingCharacters(in: .whitespaces).isEmpty {
                video = fresh
            }
            guard isCurrent(generation) else { return }
        }

        let newEngine = PlayerEngine()
        do {
            guard let source = try await makeSource(generation, refresh: lookAgain) else { return }
            engine = newEngine
            try await newEngine.load(url: source.url, headers: source.headers)
            guard isCurrent(generation) else {
                newEngine.teardown()
                return
            }
            if let start = resumeAt, start > 0 {
                let limit = newEngine.duration - 5
                await newEngine.seek(to: limit > 0 && start > limit ? limit : start)
            }
            resumeAt = nil
            newEngine.setSpeed(Float(speed))
            newEngine.play()
            usedKnownSource = false
            retryBase = newEngine.position
            applyVideoOrientation(newEngine)
            if recordedID != video.id {
                recordedID = video.id
                history.record(video)
            }
            isLoading = false
            reconnecting = false
            manualReload = false
            startMonitor()
            scheduleHide()
        } catch {
            newEngine.teardown()
            if engine === newEngine { engine = nil }
            guard isCurrent(generation) else { return }
            if usedKnownSource {
                usedKnownSource = false
                Task { await initialize(refreshSource: true) }
                return
            }
            if reconnecting, autoRetries < Self.maxAutoRetries {
                autoRetries += 1
                try? await Task.sleep(for: .seconds(2 * autoRetries))
                guard isCurrent(generation) else { return }
                Task { await initialize(refreshSource: true) }
                return
            }
            isLoading = false
            reconnecting = false
            manualReload = false
            problem = describeProblem(error)
        }
    }

    /// `_createController`: file -> known source -> resolved network source.
    private func makeSource(_ generation: Int, refresh: Bool) async throws
        -> (url: URL, headers: [String: String]?)? {
        if let path = localPath, FileManager.default.fileExists(atPath: path) {
            activeURL = path
            activeIsFile = true
            activeHeaders = nil
            return (URL(fileURLWithPath: path), nil)
        }
        localPath = nil
        activeIsFile = false

        if let known = initialSource, !refresh {
            initialSource = nil
            usedKnownSource = true
            activeURL = known.url
            activeHeaders = known.headers
            guard let url = URL(string: known.url) else { throw InvalidLinkError() }
            return (url, known.headers)
        }
        initialSource = nil

        let preferredStream = video.stream(forQuality: settings.preferredQuality)
        let raw = preferredStream.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { throw MissingStreamError() }
        guard let streamURL = URL(string: raw), let scheme = streamURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https", streamURL.host?.isEmpty == false
        else { throw InvalidLinkError() }

        let source = try await resolver.resolveSource(
            streamURL: streamURL, pageURL: video.pageURL?.absoluteString,
            refresh: refresh, preserveURL: true)
        guard isCurrent(generation) else { return nil }
        guard let final = URL(string: source.url) else { throw InvalidLinkError() }
        activeURL = source.url
        activeHeaders = source.headers
        return (final, source.headers)
    }

    private func describeProblem(_ error: Error) -> Problem {
        if error is MissingStreamError {
            return Problem(title: "No video link",
                           message: "This video doesn’t have a playable link right now.",
                           systemImage: "video.slash")
        }
        if error is InvalidLinkError {
            return Problem(title: "Invalid video link",
                           message: "The link for this video isn’t valid, so it can’t be played.",
                           systemImage: "exclamationmark.triangle")
        }
        if error is PlayerEngine.LoadTimeout || error is URLError {
            return Problem(title: "Connection problem",
                           message: "The video server didn’t respond. Check your network and try again.",
                           systemImage: "wifi.slash")
        }
        return Problem(title: "Playback failed",
                       message: "This video couldn’t be played. Try again, or go back and pick another.",
                       systemImage: "exclamationmark.circle")
    }

    // MARK: Orientation

    private func applyVideoOrientation(_ engine: PlayerEngine) {
        guard !orientationForced else { return }
        let size = engine.videoSize
        setPortrait(size.width > 0 && size.height > size.width)
    }

    private func setPortrait(_ value: Bool) {
        guard portrait != value else { return }
        portrait = value
        AppOrientation.player(portrait: value)
    }

    func toggleOrientation() {
        orientationForced = true
        setPortrait(!portrait)
        revealControls()
    }

    // MARK: Reload / reconnect

    /// `_reloadInPlace`: build a fresh engine beside the live one and swap.
    func reloadInPlace(auto: Bool = false, keepSource: Bool = false) async {
        guard let old = engine, old.isReady, !isLeaving, !isReloading else { return }
        reloadToken += 1
        let token = reloadToken
        let generation = initGeneration
        let wasPlaying = old.isPlaying
        isReloading = true
        if !auto { Haptics.play(.light) }
        resetBufferingClock()
        stalled = false

        func cancelled() -> Bool { token != reloadToken || isLeaving || generation != initGeneration }
        let lookAgain = !keepSource && (!auto || autoRetries >= 2)
        var fresh: PlayerEngine?
        defer { if token == reloadToken { isReloading = false } }
        do {
            if lookAgain, localPath == nil {
                var bare = video
                bare.streamURL = ""
                if let next = try? await resolver.resolveForPlayback(bare, refresh: true),
                   !next.streamURL.trimmingCharacters(in: .whitespaces).isEmpty { video = next }
            }
            if cancelled() { return }
            guard let source = try await makeSource(generation, refresh: lookAgain), !cancelled() else { return }
            let candidate = PlayerEngine()
            fresh = candidate
            try await candidate.load(url: source.url, headers: source.headers)
            if cancelled() { candidate.teardown(); return }
            let target = old.position
            if target > 0 { await candidate.seek(to: target) }
            candidate.setSpeed(Float(speed))
            if wasPlaying { candidate.play() }
            if cancelled() { candidate.teardown(); return }

            monitorTask?.cancel()
            engine = candidate
            retryBase = candidate.position
            spinnerVisible = false
            problem = nil
            old.teardown()
            fresh = nil
            startMonitor()
        } catch {
            fresh?.teardown()
            if !cancelled() { toast = "Couldn’t reconnect. Try again in a moment." }
        }
    }

    func cancelReload() {
        guard isReloading else { return }
        reloadToken += 1
        isReloading = false
        Haptics.play(.light)
        engine?.pause()
    }

    func reload() {
        if isReloading { cancelReload(); return }
        if let engine, engine.isReady, problem == nil, !isLoading {
            Task { await reloadInPlace() }
            return
        }
        autoRetries = 0
        reconnecting = false
        manualReload = true
        Task { await initialize(refreshSource: true) }
    }

    private func autoReconnect() {
        guard !isLeaving, !isReloading else { return }
        if autoRetries >= Self.maxAutoRetries {
            monitorTask?.cancel()
            reconnecting = false
            isLoading = false
            problem = Problem(title: "Playback stopped",
                              message: "The stream was interrupted. Check your connection and try again.",
                              systemImage: "exclamationmark.circle")
            return
        }
        autoRetries += 1
        if let engine, engine.isReady, !isLoading {
            Task { await reloadInPlace(auto: true) }
            return
        }
        reconnecting = true
        Task { await initialize(refreshSource: true) }
    }

    // MARK: Monitor (_onControllerChanged at 4 Hz)

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func resetBufferingClock() {
        bufferingSince = nil
        spinnerSince = nil
        stalledSince = nil
    }

    private func tick() {
        guard !isLeaving, let engine, engine.isReady else { return }

        if engine.hasError {
            if problem == nil, !isLoading, !isReloading { autoReconnect() }
            return
        }

        lastPosition = engine.position
        if autoRetries > 0, engine.position - retryBase > 10 { autoRetries = 0 }

        let atEnd = engine.duration > 0 && engine.position >= engine.duration - 0.8
        let moving = engine.position != lastSeen && engine.isPlaying
        lastSeen = engine.position
        let buffering = engine.isBuffering && !atEnd && !moving
        let now = Date()

        if !buffering {
            if spinnerVisible {
                spinnerVisible = false
                stalled = false
            }
            resetBufferingClock()
        } else {
            if bufferingSince == nil { bufferingSince = now }
            if !spinnerVisible, now.timeIntervalSince(bufferingSince!) >= 0.7, !completed {
                spinnerVisible = true
                spinnerSince = now
            }
            if spinnerVisible, !stalled, let since = spinnerSince,
               now.timeIntervalSince(since) >= Self.stallAfter {
                stalled = true
                stalledSince = now
                revealControls()
            }
            if stalled, let since = stalledSince, now.timeIntervalSince(since) >= Self.stallAfter {
                stalledSince = now
                autoReconnect()
            }
        }

        let finished = atEnd && !engine.isPlaying && engine.didReachEnd
        if finished != completed {
            completed = finished
            if finished {
                showControls = false
                hideTask?.cancel()
                progress.markCompleted(video.id)
                startAutoplay()
            } else {
                autoplayTask?.cancel()
                countdown = nil
            }
        }
    }

    // MARK: Queue / autoplay

    var nextVideo: Video? {
        guard let queue, let i = queue.firstIndex(where: { $0.id == video.id }), i + 1 < queue.count else { return nil }
        return queue[i + 1]
    }

    var previousVideo: Video? {
        guard let queue, let i = queue.firstIndex(where: { $0.id == video.id }), i > 0 else { return nil }
        return queue[i - 1]
    }

    var showsUpNext: Bool { nextVideo != nil && !autoplayCancelled && settings.autoplayNext }

    private func startAutoplay() {
        autoplayTask?.cancel()
        guard !autoplayCancelled, nextVideo != nil, settings.autoplayNext else {
            countdown = nil
            return
        }
        countdown = Self.autoplaySeconds
        autoplayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, !self.isLeaving else { return }
                let left = (self.countdown ?? 0) - 1
                if left <= 0 {
                    self.countdown = nil
                    await self.playNext()
                    return
                }
                self.countdown = left
            }
        }
    }

    func cancelAutoplay() {
        autoplayTask?.cancel()
        countdown = nil
        autoplayCancelled = true
    }

    func playNext() async { await switchTo(nextVideo) }
    func playPrevious() async { await switchTo(previousVideo) }

    private func switchTo(_ next: Video?) async {
        guard let next, !isLeaving else { return }
        if !completed { saveProgress() }
        autoplayTask?.cancel()
        countdown = nil
        autoplayCancelled = false
        video = next
        localPath = downloads.localPath(for: next.id)?.path
        orientationForced = false
        lastPosition = 0
        autoRetries = 0
        reconnecting = false
        resumeAt = progress.resumePosition(for: next.id)
        await initialize(refreshSource: true)
    }

    // MARK: Controls visibility

    func scheduleHide() {
        hideTask?.cancel()
        guard let engine, engine.isPlaying else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.controlsTimeout)
            guard let self, !Task.isCancelled, !self.isLeaving, self.showControls,
                  self.engine?.isPlaying == true else { return }
            if self.scrubTarget != nil || self.stalled { self.scheduleHide(); return }
            self.hideControls()
        }
    }

    func hideControls() { if showControls { showControls = false } }

    func revealControls() {
        if !showControls { showControls = true }
        scheduleHide()
    }

    func togglePlayback() {
        guard let engine, engine.isReady, !isLeaving else { return }
        if engine.isPlaying {
            engine.pause()
            hideTask?.cancel()
            showControls = true
        } else {
            engine.play()
            revealControls()
        }
    }

    func replay() async {
        guard let engine, engine.isReady else { await initialize(); return }
        lastPosition = 0
        await engine.seek(to: 0)
        engine.play()
        completed = false
        revealControls()
    }

    // MARK: Scrubbing (_scrubTo / _commitScrub)

    func scrubBySeconds(_ seconds: Int, badge: Bool = true) {
        guard let engine, engine.isReady, !isLeaving else { return }
        scrubTo((scrubTarget ?? engine.position) + Double(seconds), reveal: badge)
    }

    func scrubToFraction(_ fraction: Double) {
        guard let engine, engine.isReady, !isLeaving else { return }
        scrubTo(engine.duration * min(max(fraction, 0), 1))
    }

    private func scrubTo(_ wanted: Double, reveal: Bool = true) {
        guard let engine, engine.isReady, !isLeaving else { return }
        if scrubTarget == nil { scrubOrigin = engine.position }
        var target = max(wanted, 0)
        if engine.duration > 0 { target = min(target, engine.duration) }
        scrubVersion += 1
        scrubBadge = reveal
        scrubTarget = target
        if reveal { revealControls() }
        hideTask?.cancel()
        scrubTask?.cancel()
        scrubTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scrubCommitDelay)
            guard !Task.isCancelled else { return }
            await self?.commitScrub()
        }
    }

    private func commitScrub() async {
        guard let engine, let target = scrubTarget, !isLeaving else { return }
        let version = scrubVersion
        await engine.seek(to: target)
        // A newer scrub restarted the commit timer while we were seeking: keep it.
        guard !isLeaving, version == scrubVersion else { return }
        scrubTarget = nil
        scheduleHide()
    }

    // MARK: Gestures

    /// `_onScreenTap`: left/right 38% zones; a second tap on the same side
    /// within 300 ms skips, otherwise a tap toggles the controls.
    func screenTap(x: CGFloat, width: CGFloat) {
        guard problem == nil, !isLoading, !completed else { return }
        let side: Side? = x < width * 0.38 ? .left : (x > width * 0.62 ? .right : nil)
        let now = Date()
        let isDouble = lastTapAt.map { now.timeIntervalSince($0) < 0.3 } == true
            && side != nil && side == lastTapSide
        lastTapAt = now
        lastTapSide = side
        if isDouble, let side {
            skip(side == .left ? -Self.seekStep : Self.seekStep, side: side)
            return
        }
        showControls ? hideControls() : revealControls()
    }

    private func skip(_ seconds: Int, side: Side) {
        Haptics.play(.selection)
        scrubBySeconds(seconds, badge: false)
        let total = (flash?.side == side) ? (flash?.seconds ?? 0) + abs(seconds) : abs(seconds)
        let value = SeekFlash(side: side, seconds: total)
        lastFlash = value
        flash = value
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    func startBoost() {
        guard let engine, engine.isReady, engine.isPlaying, !boosting, !isLeaving else { return }
        boosting = true
        Haptics.play(.medium)
        engine.setSpeed(2)
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        guard !isLeaving else { return }
        engine?.setSpeed(Float(speed))
    }

    func openSpeedPicker() {
        hideTask?.cancel()
        showSpeedSheet = true
    }

    func setSpeed(_ value: Double) {
        speed = value
        engine?.setSpeed(Float(value))
        scheduleHide()
    }

    // MARK: Leaving / minimize / PiP

    private func saveProgress() {
        guard let engine, engine.isReady else { return }
        progress.save(video.id, position: engine.position, duration: engine.duration)
    }

    private func cancelTimers() {
        hideTask?.cancel(); scrubTask?.cancel(); autoplayTask?.cancel()
    }

    private func beginLeaving() {
        isLeaving = true
        initGeneration += 1
        reloadToken += 1
        cancelTimers()
        flashTask?.cancel()
        monitorTask?.cancel()
        saveProgress()
        progress.flush()
    }

    func leave() async {
        guard !popping else { return }
        popping = true
        beginLeaving()
        if let engine {
            self.engine = nil
            engine.teardown()
        }
        AppOrientation.browse()
        dismiss?()
    }

    /// Swipe down / chevron: hand the live engine to the mini player.
    func minimize() {
        guard let engine, let url = activeURL, engine.isReady, !isLeaving, !popping,
              !isLoading, problem == nil, !isReloading else { return }
        popping = true
        beginLeaving()
        self.engine = nil
        miniPlayer.adopt(MiniSession(video: video, engine: engine, url: url, headers: activeHeaders,
                                     isFile: activeIsFile, speed: Float(speed), queue: queue))
        AppOrientation.browse()
        dismiss?()
    }

    func enterPip() async {
        guard let engine, let url = activeURL, engine.isReady, !isLeaving, !pipBusy, !isReloading,
              let layer = surface.layer else { return }
        pipBusy = true
        defer { pipBusy = false }
        let session = MiniSession(video: video, engine: engine, url: url, headers: activeHeaders,
                                  isFile: activeIsFile, speed: Float(speed), queue: queue)
        engine.play() // PiP needs active playback
        if await PiPCoordinator.shared.start(layer: layer, session: session) {
            popping = true
            beginLeaving()
            self.engine = nil // ownership moved to PiPCoordinator
            AppOrientation.browse()
            dismiss?()
        } else {
            toast = "Picture in Picture isn’t available right now."
        }
    }

    // MARK: App lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard !isLeaving, let engine, engine.isReady else { return }
        if phase == .inactive || phase == .background {
            // PiP keeps playing on its own; otherwise pause like the Dart observer.
            wasPlayingBeforePause = engine.isPlaying
            if wasPlayingBeforePause { engine.pause() }
        } else if phase == .active, wasPlayingBeforePause {
            wasPlayingBeforePause = false
            engine.play()
        }
    }

    /// Called from `onDisappear` as a safety net (Dart `dispose`).
    func teardownIfNeeded() {
        guard !isLeaving else { return }
        beginLeaving()
        engine?.teardown()
        engine = nil
        AppOrientation.browse()
    }
}
