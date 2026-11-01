import SwiftUI
import Observation

func withTimeout<T: Sendable>(_ limit: Duration,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Port of the data/state half of `_VideoDetailsPageState`.
///
/// MIGRATION NOTES
/// - `Future` + `FutureBuilder` becomes an explicit `Related` enum
///   (`loading / loaded / failed`) so SwiftUI renders skeleton, error and grid.
/// - Stale-result protection that Dart did with `identical(request, _modelsFuture)`
///   is a monotonically increasing token.
/// - Navigation (`Navigator.push`, `pushReplacement`) is delegated to closures
///   supplied by `HomeView`, so this model stays UI-framework agnostic.
@MainActor @Observable
final class DetailsViewModel {
    enum Related {
        case loading
        case loaded([Video])
        case failed
    }

    static let detailsLoadLimit: Duration = .seconds(18)
    static let refreshIndicatorLimit: Duration = .seconds(8)

    let video: Video
    let queue: [Video]?

    private(set) var related: Related = .loading
    private(set) var models: [ModelRef] = []
    private(set) var modelsFailed = false
    private(set) var preparing = false
    private(set) var playError: String?
    var toast: String?

    @ObservationIgnored private let repository: VideoRepository
    @ObservationIgnored private let relatedCache: RequestCache<[Video]>
    @ObservationIgnored private let modelsCache: RequestCache<[ModelRef]>
    @ObservationIgnored private let progress: PlaybackProgress
    @ObservationIgnored private let launcher: PlaybackLauncher
    @ObservationIgnored private let onPlayerRoute: (PlayerRoute) -> Void
    @ObservationIgnored private var relatedToken = 0
    @ObservationIgnored private var modelsToken = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var started = false

    init(video: Video, queue: [Video]?, dependencies: AppDependencies,
         onPlayerRoute: @escaping (PlayerRoute) -> Void) {
        self.video = video
        self.queue = queue
        self.repository = dependencies.repository
        self.relatedCache = dependencies.relatedCache
        self.modelsCache = dependencies.modelsCache
        self.progress = dependencies.progress
        self.launcher = dependencies.launcher
        self.onPlayerRoute = onPlayerRoute
    }

    // MARK: Loading

    func start() {
        guard !started else { return }
        started = true
        // Unstructured: leaving and returning to the screen must not cancel the load.
        Task { await loadRelated(force: false, fresh: false) }
        Task { await loadModels(force: false, fresh: false) }
    }

    /// Returns true on success (also true when a newer request superseded this one).
    @discardableResult
    private func loadRelated(force: Bool, fresh: Bool) async -> Bool {
        relatedToken += 1
        let token = relatedToken
        related = .loading
        let cache = relatedCache, repo = repository, video = video
        do {
            let list = try await withTimeout(Self.detailsLoadLimit) {
                try await cache.fetch(video.id, force: force) {
                    try await repo.related(to: video, fresh: fresh)
                }
            }
            guard token == relatedToken else { return true }
            related = .loaded(list)
            return true
        } catch {
            guard token == relatedToken else { return true }
            related = .failed
            return false
        }
    }

    private func loadModels(force: Bool, fresh: Bool) async {
        modelsToken += 1
        let token = modelsToken
        let cache = modelsCache, repo = repository, video = video
        do {
            let list = try await withTimeout(Self.detailsLoadLimit) {
                try await cache.fetch(video.id, force: force) {
                    try await repo.models(for: video, fresh: fresh)
                }
            }
            guard token == modelsToken else { return }
            // Keep the last known profile visible if a refresh comes back empty.
            if !list.isEmpty || models.isEmpty { models = list }
            modelsFailed = false
        } catch {
            guard token == modelsToken else { return }
            // A transient error must not replace an already visible profile row.
            if models.isEmpty { modelsFailed = true }
        }
    }

    func reloadRelated() { Task { await loadRelated(force: true, fresh: true) } }

    func reloadModels() {
        modelsFailed = false
        Task { await loadModels(force: true, fresh: true) }
    }

    /// Pull to refresh: only the recommendations change; the model row stays put.
    func refresh() async {
        guard !refreshing else { return }
        Haptics.play(.light)
        refreshing = true
        defer { refreshing = false }

        // Unstructured so SwiftUI cancelling the refresh task can't abort the request.
        let work = Task { await self.loadRelated(force: true, fresh: true) }
        let outcome: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await work.value }
            group.addTask {
                try? await Task.sleep(for: Self.refreshIndicatorLimit)
                return nil // timed out
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch outcome {
        case .some(false): toast = "Couldn’t refresh. Check your connection and try again."
        case .none: toast = "Refresh is taking longer. Results will update when ready."
        case .some(true): Haptics.play(.selection)
        }
    }

    // MARK: Playback

    var resumePosition: TimeInterval? { progress.resumePosition(for: video.id) }

    func play(fromStart: Bool = false) async {
        guard !preparing else { return }
        let startAt = fromStart ? nil : progress.resumePosition(for: video.id)
        if fromStart { progress.clear(video.id) }
        preparing = true
        playError = nil
        defer { preparing = false }
        do {
            let route = try await launcher.prepare(video, startAt: startAt, queue: queue ?? [], source: nil)
            onPlayerRoute(route)
        } catch {
            playError = error.localizedDescription
        }
    }

    // MARK: Link

    var shareLink: URL? {
        guard let url = video.pageURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, url.user == nil else { return nil }
        return url
    }

    func copyLink() {
        guard let link = shareLink else { return }
        UIPasteboard.general.string = link.absoluteString
        Haptics.play(.light)
        toast = "Link copied"
    }
}
