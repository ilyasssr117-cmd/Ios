import Foundation
import Observation

/// Owns everything `_HomePageState` kept in fields: paging, category,
/// loading/error state, stale-while-revalidate and the offline probe.
///
/// MIGRATION NOTES
/// - `setState` + mutable fields  ->  `@Observable` class; SwiftUI re-renders
///   only the views that read a changed property.
/// - Loads run in unstructured `Task`s, NOT `.task {}`. TabView cancels a
///   tab's `.task` when you switch away, which would surface as a bogus
///   "offline" error. The `generation` counter still guards stale results.
/// - Navigation/section state (`_section`, `_dragTarget`, drag animation)
///   moved to `AppRouter` + native `TabView`; it is not data-layer state.
@MainActor @Observable
final class HomeViewModel {
    static let pageSize = 12
    static let maxEmptyPages = 3
    private static let hintsKey = "hints_v1"

    // MARK: State
    private(set) var videos: [Video] = []
    var category = "All"
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: FriendlyError?
    private(set) var isPlayingFeatured = false
    var toast: String?
    var playerRoute: PlayerRoute?

    var featured: Video? { videos.first }
    var gridVideos: [Video] { Array(videos.dropFirst()) }
    var categories: [String] { ["All"] + deps.repository.categories }
    var resumeAvailable: Bool {
        featured.map { deps.progress.resumePosition(for: $0.id) != nil } ?? false
    }
    var hasCompletedDownloads: Bool { deps.downloads.hasCompletedDownloads }

    // MARK: Private
    private var page = 0
    private var generation = 0
    private var emptyPages = 0
    private var didStart = false
    private var offlineTask: Task<Void, Never>?
    private let deps: AppDependencies
    private let defaults: UserDefaults

    init(dependencies: AppDependencies, defaults: UserDefaults = .standard) {
        self.deps = dependencies
        self.defaults = defaults
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        Task { await loadPage(reset: true) }
    }

    // MARK: Loading

    private func key(_ category: String, _ page: Int) -> String { "home|\(category)|\(page)" }

    private func fetch(category: String, page: Int, force: Bool = false) async throws -> [Video] {
        let repository = deps.repository
        let size = Self.pageSize
        let filter = category == "All" ? nil : category
        return try await deps.listingCache.fetch(key(category, page), force: force) {
            try await repository.videos(page: page, pageSize: size, category: filter)
        }
    }

    private func resetPaging() {
        videos = []
        page = 0
        emptyPages = 0
        hasMore = true
    }

    private func apply(_ result: [Video], requestedPage: Int) {
        var seen = Set(videos.map(\.id))
        let fresh = result.filter { seen.insert($0.id).inserted }
        videos.append(contentsOf: fresh)
        page = requestedPage + 1
        emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
        hasMore = !result.isEmpty && emptyPages < Self.maxEmptyPages
        isLoading = false
    }

    func loadPage(reset: Bool = false) async {
        if isLoading && !reset { return }
        if reset { generation += 1 }
        let requestGeneration = generation
        let requestedPage = reset ? 0 : page
        let requestedCategory = category
        let cacheKey = key(requestedCategory, requestedPage)

        // 1. Warm in-memory hit.
        if let cached = deps.listingCache.peek(cacheKey) {
            error = nil
            if reset { resetPaging() }
            apply(cached, requestedPage: requestedPage)
            return
        }

        // 2. Disk hit: show it now, revalidate in the background.
        if let offline = OfflineListingCache.read(cacheKey) {
            error = nil
            if reset { resetPaging() }
            apply(offline, requestedPage: requestedPage)
            isLoading = true // small spinner while the fresh copy loads
            Task {
                await revalidate(category: requestedCategory, page: requestedPage,
                                 generation: requestGeneration)
            }
            return
        }

        // 3. Network.
        isLoading = true
        error = nil
        if reset { resetPaging() }
        do {
            let result = try await fetch(category: requestedCategory, page: requestedPage)
            guard requestGeneration == generation else { return }
            OfflineListingCache.write(cacheKey, result)
            apply(result, requestedPage: requestedPage)
            showPreviewHintIfNeeded()
        } catch {
            guard requestGeneration == generation else { return }
            isLoading = false
            hasMore = false
            self.error = describeError(error)
            if self.error?.offline == true && videos.isEmpty { watchConnection() }
        }
    }

    /// Refreshes the disk cache only; like the original, the visible list is kept.
    private func revalidate(category: String, page: Int, generation requestGeneration: Int) async {
        do {
            let result = try await fetch(category: category, page: page, force: true)
            OfflineListingCache.write(key(category, page), result)
        } catch {
            // Keep the last successful page visible on a weak connection.
        }
        if requestGeneration == generation { isLoading = false }
    }

    func loadMoreIfNeeded(current video: Video) {
        // Replaces the 800pt scroll-extent check: load when one of the last
        // four grid items scrolls into view.
        guard hasMore, !isLoading, videos.suffix(4).contains(where: { $0.id == video.id }) else { return }
        Task { await loadPage() }
    }

    /// Used by `.refreshable`. Runs unstructured so SwiftUI cancelling the
    /// refresh task mid-pull can't abort the request.
    func refresh() async {
        await Task { await performRefresh() }.value
    }

    private func performRefresh() async {
        Haptics.play(.light)
        generation += 1
        let requestGeneration = generation
        let refreshed = category
        do {
            let result = try await fetch(category: refreshed, page: 0, force: true)
            guard requestGeneration == generation else { return }
            OfflineListingCache.write(key(refreshed, 0), result)
            var seen = Set<String>()
            videos = result.filter { seen.insert($0.id).inserted }
            page = 1
            emptyPages = 0
            hasMore = !result.isEmpty
            isLoading = false
            error = nil
        } catch {
            guard requestGeneration == generation else { return }
            isLoading = false
            showToast("Couldn’t refresh. Check your connection.")
        }
    }

    func changeCategory(_ value: String) {
        guard value != category else { return }
        category = value
        Task { await loadPage(reset: true) }
    }

    // MARK: Connectivity

    private func watchConnection() {
        offlineTask?.cancel()
        offlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.probeConnection()
        }
    }

    func probeConnection() async {
        guard !isLoading, videos.isEmpty, error?.offline == true else { return }
        let probed = category
        do {
            let result = try await fetch(category: probed, page: 0)
            OfflineListingCache.write(key(probed, 0), result)
            guard probed == category, videos.isEmpty else { return }
            await loadPage(reset: true)
        } catch {
            watchConnection()
        }
    }

    // MARK: Playback

    func playFeatured() async {
        guard let video = featured, !isPlayingFeatured else { return }
        isPlayingFeatured = true
        defer { isPlayingFeatured = false }
        await launch(video, startAt: deps.progress.resumePosition(for: video.id), queue: videos)
    }

    func resume(_ video: Video) async {
        await launch(video, startAt: deps.progress.resumePosition(for: video.id), queue: [])
    }

    /// A favorited/downloaded reel has no web page, so it skips the details
    /// screen and plays straight from its saved source.
    func openSavedReel(_ video: Video) async {
        let source = deps.reelFavorites.source(for: video.id)
        guard source != nil || deps.downloads.localPath(for: video.id) != nil else {
            showToast("This reel can’t be opened anymore.")
            return
        }
        let playbackSource = source.map { PlaybackSource(url: $0.url, headers: $0.headers) }
        await launch(video, startAt: nil, queue: [], source: playbackSource)
    }

    private func launch(_ video: Video, startAt: TimeInterval?, queue: [Video],
                        source: PlaybackSource? = nil) async {
        do {
            playerRoute = try await deps.launcher.prepare(video, startAt: startAt, queue: queue, source: source)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: Toast / hints

    func showToast(_ message: String) { toast = message }

    private func showPreviewHintIfNeeded() {
        guard !videos.isEmpty else { return }
        var shown = defaults.stringArray(forKey: Self.hintsKey) ?? []
        guard !shown.contains("preview") else { return }
        shown.append("preview")
        defaults.set(shown, forKey: Self.hintsKey)
        showToast("Tip: press and hold a video to preview it")
    }
}
