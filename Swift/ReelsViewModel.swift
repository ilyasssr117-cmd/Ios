import SwiftUI
import Observation

/// Everything `_ReelsPageState` owned apart from drawing.
///
/// MIGRATION NOTES
/// - Players are keyed by reel **id**, not list index. The Dart code had to
///   re-index its controller map whenever old reels were trimmed
///   (`_trimOldReelsIfNeeded`); with ids that bookkeeping disappears.
/// - The PageView + ScrollNotification plumbing becomes a paging ScrollView
///   with `scrollPosition(id:)`; the view reports `pageChanged` and
///   `scrollSettled` to this model.
/// - Pool rule is unchanged: at most two live players (visible + next).
@MainActor @Observable
final class ReelsViewModel {
    // Tuning (reels_page.dart constants)
    static let firstBatch = 12
    static let nextBatch = 12
    static let preloadAhead = 2
    static let maxBufferedReels = 96
    static let historyKeep = 12
    static let trimTrigger = 48
    private static let neighborPreloadDelay: Duration = .milliseconds(240)
    private static let clearKey = "reels_clear_mode_v1"
    private static let maxSaveBytes: Int64 = 350 * 1024 * 1024

    // Observable state
    private(set) var items: [ReelItem] = []
    var currentID: String?
    private(set) var isLoading = false
    private(set) var isExhausted = false
    private(set) var errorMessage: String?
    private(set) var isMuted = false
    private(set) var isClear: Bool
    private(set) var isActive = false
    private(set) var players: [String: ReelPlayer] = [:]
    private(set) var saving: [String: Double] = [:]   // -1 = indeterminate
    var toast: String?
    var saveMenuItem: ReelItem?

    // Private
    @ObservationIgnored private let repository: ReelsRepository
    @ObservationIgnored private let reelFavorites: ReelFavorites
    @ObservationIgnored private let downloads: DownloadStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var syncPending = false
    @ObservationIgnored private var resumeOnForeground = false
    @ObservationIgnored private var memoryTask: Task<Void, Never>?

    init(dependencies: AppDependencies,
         repository: ReelsRepository = ReelsRepository(),
         defaults: UserDefaults = .standard) {
        self.reelFavorites = dependencies.reelFavorites
        self.downloads = dependencies.downloads
        self.repository = repository
        self.defaults = defaults
        self.isClear = defaults.bool(forKey: Self.clearKey)
    }

    // MARK: Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        // didHaveMemoryPressure: keep only the visible decoder.
        memoryTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification) {
                self?.evictAllButCurrent()
            }
        }
        loadMore(first: true)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            claimPlayback()
            if !items.isEmpty { syncPlayers() }
        } else {
            pauseForLeaving()
        }
    }

    /// Reels takes over audio/video from the hold-to-preview and mini player.
    private func claimPlayback() {
        PreviewManager.shared.stopNow()
        MiniPlayer.shared.close()
    }

    /// Leaving the Reels tab: silence the reel and free the spare decoder.
    private func pauseForLeaving() {
        for (id, player) in players {
            player.setPlaying(false)
            player.setMuted(true)
            player.setSpeed(1)
            if id != currentID { evict(id) }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let current = currentID.flatMap { players[$0] }
        if phase == .active {
            if resumeOnForeground, isActive { current?.setPlaying(true) }
            resumeOnForeground = false
            if !items.isEmpty { syncPlayers() }
        } else {
            if let current, current.isPlaying {
                resumeOnForeground = true
                current.setPlaying(false)
            }
            evictAllButCurrent()
        }
    }

    private func evictAllButCurrent() {
        for id in Array(players.keys) where id != currentID { evict(id) }
    }

    // MARK: Loading

    func loadMore(first: Bool = false) {
        guard !isLoading, !isExhausted else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let batch = try await repository.nextBatch(first ? Self.firstBatch : Self.nextBatch)
                items.append(contentsOf: batch)
                if batch.isEmpty { isExhausted = true }
                isLoading = false
                guard !items.isEmpty else { return }
                if first, currentID == nil { currentID = items[0].id }
                syncPlayers()
            } catch {
                errorMessage = describeError(error, subject: "reels").message
                isLoading = false
            }
        }
    }

    // MARK: Player pool

    private var currentIndex: Int? {
        guard let id = currentID else { return items.isEmpty ? nil : 0 }
        return items.firstIndex { $0.id == id }
    }

    private func keepIDs(around index: Int) -> Set<String> {
        Set([index, index + 1].filter { items.indices.contains($0) }.map { items[$0].id })
    }

    private func ensurePlayer(for item: ReelItem) {
        guard players[item.id] == nil else { return }
        players[item.id] = ReelPlayer(url: item.videoURL, fallback: item.fallbackURL,
                                      headers: ReelConstants.mediaHeaders)
    }

    private func evict(_ id: String) {
        players.removeValue(forKey: id)?.teardown()
    }

    private func apply(playbackFor id: String, current: String) {
        guard let player = players[id] else { return }
        if id == current {
            player.setMuted(isMuted || !isActive)
            player.setPlaying(isActive)
        } else {
            player.setPlaying(false)
            player.setMuted(true)
            player.setSpeed(1)
        }
    }

    /// `_syncControllers`: evict stale players, start the visible one and
    /// prepare the next after a short head start.
    func syncPlayers() {
        guard let index = currentIndex, items.indices.contains(index) else { return }
        let currentItem = items[index]
        let keep = keepIDs(around: index)
        for id in Array(players.keys) where !keep.contains(id) { evict(id) }

        ensurePlayer(for: currentItem)
        for id in Array(players.keys) { apply(playbackFor: id, current: currentItem.id) }

        if items.indices.contains(index + 1) {
            let nextItem = items[index + 1]
            Task { [weak self] in
                try? await Task.sleep(for: Self.neighborPreloadDelay)
                guard let self, self.currentID == currentItem.id,
                      self.players[currentItem.id] != nil, self.players.count < 2 else { return }
                self.ensurePlayer(for: nextItem)
                self.apply(playbackFor: nextItem.id, current: currentItem.id)
            }
        }
    }

    /// Called by the view when the paging scroll position changes.
    func pageChanged(to id: String?) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        syncPending = true
        // Evict the reel that just left right away so a third decoder never
        // lives through a long swipe.
        let keep = keepIDs(around: index)
        for old in Array(players.keys) where !keep.contains(old) { evict(old) }
        ensurePlayer(for: items[index])
        for key in Array(players.keys) { apply(playbackFor: key, current: id) }
        if index >= items.count - Self.preloadAhead { loadMore() }
    }

    /// Called when the scroll comes to rest (ScrollEndNotification).
    func scrollSettled() {
        if syncPending {
            syncPending = false
            syncPlayers()
        }
        trimOldReelsIfNeeded()
    }

    private func trimOldReelsIfNeeded() {
        guard items.count > Self.maxBufferedReels,
              let index = currentIndex, index >= Self.trimTrigger else { return }
        let shift = index - Self.historyKeep
        guard shift > 0, shift < items.count else { return }
        // Players are keyed by id, so dropping the head needs no re-indexing.
        for dropped in items.prefix(shift) { evict(dropped.id) }
        items.removeFirst(shift)
    }

    func retry(_ item: ReelItem) {
        evict(item.id)
        ensurePlayer(for: item)
        if let current = currentID { apply(playbackFor: item.id, current: current) }
    }

    // MARK: Toggles

    func toggleMute() {
        isMuted.toggle()
        for player in players.values { player.setMuted(isMuted || !isActive) }
    }

    func toggleClear() {
        Haptics.play(.selection)
        isClear.toggle()
        defaults.set(isClear, forKey: Self.clearKey)
    }

    // MARK: Likes

    func isLiked(_ item: ReelItem) -> Bool { reelFavorites.isLiked(item.id) }

    func toggleLike(_ item: ReelItem) {
        let liked = reelFavorites.toggle(item)
        Haptics.play(liked ? .medium : .light)
    }

    /// Double-tap only ever adds (Instagram style). True if newly added.
    @discardableResult
    func likeFromDoubleTap(_ item: ReelItem) -> Bool {
        let added = reelFavorites.like(item)
        if added { Haptics.play(.medium) }
        return added
    }

    // MARK: Downloads / Photos

    func downloadItem(for item: ReelItem) -> DownloadItem? { downloads.item(for: item.downloadID) }

    private func isStream(_ url: URL) -> Bool { url.absoluteString.lowercased().contains(".m3u8") }

    private func enqueue(_ item: ReelItem) -> Bool {
        let url = item.downloadURL ?? item.videoURL
        if isStream(url) {
            toast = "This video is a stream and can’t be downloaded."
            return false
        }
        if let existing = downloads.item(for: item.downloadID) {
            if existing.status == .done { toast = "Already in your downloads."; return false }
            if existing.status == .queued || existing.status == .downloading {
                toast = "Already downloading…"
                return false
            }
        }
        guard downloads.enqueueDirect(ReelFavorites.video(of: item), url: url, headers: ReelConstants.mediaHeaders) else {
            toast = "Download queue is full. Remove an old item first."
            return false
        }
        return true
    }

    func download(_ item: ReelItem) {
        if enqueue(item) { toast = "Downloading…" }
    }

    func saveToPhotos(_ item: ReelItem) async {
        guard saving[item.id] == nil else { return }
        let url = item.downloadURL ?? item.videoURL
        guard !isStream(url) else {
            toast = "This video is a stream and can’t be saved."
            return
        }
        saving[item.id] = -1
        toast = "Saving to Photos…"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel_\(Self.safeToken(item.id)).mp4")
        defer {
            saving[item.id] = nil
            try? FileManager.default.removeItem(at: file)
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            ReelConstants.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let id = item.id
            let downloader = FileDownloader(maxBytes: Self.maxSaveBytes) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.saving[id] != nil else { return }
                    self.saving[id] = progress
                }
            }
            _ = try await downloader.download(request, to: file)
            switch await PhotoSaver.saveVideo(at: file) {
            case .denied: toast = "Allow access to Photos in Settings to save videos."
            case .saved:
                Haptics.play(.medium)
                toast = "Saved to Photos."
            case .failed: toast = "Couldn’t save the video."
            }
        } catch {
            toast = "Couldn’t save the video."
        }
    }

    /// FNV-1a: stable filename without trusting API data as a path.
    private static func safeToken(_ value: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for unit in value.utf16 { hash = (hash ^ UInt32(unit)) &* 0x01000193 }
        return String(format: "%08x", hash)
    }
}
