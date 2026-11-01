import SwiftUI
import Observation

// MARK: - Design tokens (from app_theme.dart)

enum Gaps {
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12
    static let lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}

enum Radii {
    static let card: CGFloat = 22
    static let hero: CGFloat = 28
}

extension Color {
    /// Flutter `AppColors.accent` (0xFF8585FF). Put this in the asset
    /// catalog as "AccentColor" so `.tint` picks it up app-wide.
    static let vxAccent = Color(red: 133.0 / 255.0, green: 133.0 / 255.0, blue: 1.0)
}

// MARK: - Models (from models.dart)

struct StreamQuality: Codable, Hashable, Sendable {
    let height: Int
    let url: String
}

/// Flutter's immutable `Video` + `copyWith` becomes a value-type struct:
/// copy it into a `var` and mutate the field you need.
struct Video: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var streamURL: String = ""
    var description: String = ""
    var thumbnailURL: URL?
    var duration: String = ""
    var views: String = ""
    var likes: String = ""
    var date: String = ""
    var category: String = "Featured"
    var pageURL: URL?
    var previewURL: URL?
    var qualities: [StreamQuality] = []

    var isSavedReel: Bool { id.hasPrefix("reel_") }

    func stream(forQuality preferred: Int) -> String {
        guard preferred > 0, qualities.count >= 2 else { return streamURL }
        return qualities.first { $0.height <= preferred }?.url ?? qualities.last?.url ?? streamURL
    }
}

// MARK: - Errors (from error_text.dart)

struct HTTPStatusError: Error { let code: Int }
struct SourceNotConfiguredError: Error { let message: String }

struct FriendlyError: Equatable {
    var title: String
    var message: String
    var systemImage: String
    var offline = false
}

func describeError(_ error: Error, subject: String = "videos") -> FriendlyError {
    let offline = FriendlyError(
        title: "You’re offline",
        message: "Check your connection and try again.",
        systemImage: "wifi.slash",
        offline: true
    )
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
            return offline
        default: break
        }
    }
    if let http = error as? HTTPStatusError {
        return FriendlyError(
            title: "Unable to load \(subject)",
            message: "The video source returned an error (\(http.code)). Please try again in a moment.",
            systemImage: "icloud.slash"
        )
    }
    if let config = error as? SourceNotConfiguredError {
        return FriendlyError(title: "Video source not configured",
                             message: config.message, systemImage: "gearshape")
    }
    return FriendlyError(
        title: "Unable to load \(subject)",
        message: "Something went wrong while contacting the video source.",
        systemImage: "exclamationmark.triangle"
    )
}

// MARK: - Repository, response models & caches

struct ModelProfile: Codable, Hashable, Sendable {
    var name: String
    var imageURL: String?
}

struct ModelPageResult: Sendable {
    var videos: [Video]
    var profile: ModelProfile?
}

struct AlbumRef: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var url: String
    var thumbnailURL: String?
    var modelName: String?
}

struct AlbumPhoto: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var thumbURL: String
    var fullURL: String
}

struct PeopleSearchResult: Sendable {
    var models: [ModelRef]
    var albums: [AlbumRef]
    var isEmpty: Bool { models.isEmpty && albums.isEmpty }
}

protocol VideoRepository: Sendable {
    var categories: [String] { get }
    func videos(page: Int, pageSize: Int, category: String?) async throws -> [Video]
    func searchVideos(query: String, page: Int, pageSize: Int, sortBy: String?) async throws -> [Video]
    func searchPeople(_ query: String) async throws -> PeopleSearchResult
    func related(to video: Video, fresh: Bool) async throws -> [Video]
    func models(for video: Video, fresh: Bool) async throws -> [ModelRef]
    func resolveForPlayback(_ video: Video, refresh: Bool) async throws -> Video
    func modelPage(_ model: ModelRef, page: Int) async throws -> ModelPageResult
    func albums(for model: ModelRef?, page: Int) async throws -> [AlbumRef]
    func albumPhotos(_ album: AlbumRef, chunk: Int) async throws -> [AlbumPhoto]
    func clearPlaybackCaches()
}

/// Request cache with in-flight de-duplication; mirrors request_cache.dart.
@MainActor
final class RequestCache<Value: Sendable> {
    private var values: [String: Value] = [:]
    private var requests: [String: Task<Value, Error>] = [:]

    func peek(_ key: String) -> Value? { values[key] }

    func fetch(_ key: String, force: Bool = false,
               load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if !force, let value = values[key] { return value }
        if let request = requests[key] { return try await request.value }
        let request = Task { try await load() }
        requests[key] = request
        defer { requests[key] = nil }
        let result = try await request.value
        values[key] = result
        return result
    }

    func clear() { values.removeAll(); requests.values.forEach { $0.cancel() }; requests.removeAll() }
}

/// Backwards-compatible listing cache used by HomeViewModel.
@MainActor
final class ListingCache {
    private let cache = RequestCache<[Video]>()
    func peek(_ key: String) -> [Video]? { cache.peek(key) }
    func fetch(_ key: String, force: Bool = false,
               load: @escaping @Sendable () async throws -> [Video]) async throws -> [Video] {
        try await cache.fetch(key, force: force, load: load)
    }
}

enum OfflineListingCache {
    private static let directory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineListings", isDirectory: true)
    }()
    private static func file(for key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
    static func read(_ key: String) -> [Video]? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? JSONDecoder().decode([Video].self, from: data)
    }
    static func write(_ key: String, _ videos: [Video]) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
    }
}

// MARK: - Persistent stores (local_store.dart, favorites_store.dart, history_store.dart)

@MainActor @Observable
final class PlaybackProgress {
    struct Entry: Codable, Sendable { var position: TimeInterval; var duration: TimeInterval }
    private(set) var entries: [String: Entry] = [:]
    private var completed = Set<String>()
    private let defaults: UserDefaults
    private let progressKey = "progress_v1_swift"
    private let completedKey = "completed_v1_swift"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: progressKey),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
        completed = Set(defaults.stringArray(forKey: completedKey) ?? [])
    }

    func resumePosition(for id: String) -> TimeInterval? {
        guard !completed.contains(id), let e = entries[id], e.position >= 15 else { return nil }
        return e.position
    }
    func fraction(for id: String) -> Double? {
        guard let e = entries[id], e.duration > 0 else { return nil }
        return min(1, max(0, e.position / e.duration))
    }
    func isCompleted(_ id: String) -> Bool { completed.contains(id) || (fraction(for: id) ?? 0) >= 0.95 }
    func record(id: String, position: TimeInterval, duration: TimeInterval) { save(id, position: position, duration: duration) }
    func save(_ id: String, position: TimeInterval, duration: TimeInterval) {
        guard duration > 0 else { return }
        if position >= max(0, duration - 20) { markCompleted(id); return }
        guard position >= 15 else { return }
        completed.remove(id)
        entries.removeValue(forKey: id)
        entries[id] = Entry(position: position, duration: duration)
        while entries.count > 200, let first = entries.keys.first { entries.removeValue(forKey: first) }
        persist()
    }
    func clear(_ id: String) { entries.removeValue(forKey: id); completed.remove(id); persist() }
    func markCompleted(_ id: String) {
        entries.removeValue(forKey: id)
        completed.remove(id); completed.insert(id)
        while completed.count > 300, let first = completed.first { completed.remove(first) }
        persist()
    }
    func clearAll() { entries.removeAll(); completed.removeAll(); persist() }
    func flush() { persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: progressKey) }
        defaults.set(Array(completed), forKey: completedKey)
    }
}

@MainActor @Observable
final class FavoritesStore {
    private(set) var favorites: [String: Video] = [:]
    private(set) var orderedIDs: [String] = []
    var items: [Video] { orderedIDs.compactMap { favorites[$0] } }
    private let defaults: UserDefaults
    private let key = "favorites_v1_swift"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Video].self, from: data) {
            for video in saved where favorites[video.id] == nil {
                favorites[video.id] = video; orderedIDs.append(video.id)
            }
        }
    }
    func isFavorite(_ id: String) -> Bool { favorites[id] != nil }
    @discardableResult func toggle(_ video: Video) -> Bool {
        if favorites.removeValue(forKey: video.id) != nil {
            orderedIDs.removeAll { $0 == video.id }; persist(); return false
        }
        add(video); return true
    }
    func add(_ video: Video) {
        favorites[video.id] = video
        orderedIDs.removeAll { $0 == video.id }; orderedIDs.insert(video.id, at: 0)
        if orderedIDs.count > 300 {
            let removed = orderedIDs.suffix(from: 300); removed.forEach { favorites.removeValue(forKey: $0) }
            orderedIDs = Array(orderedIDs.prefix(300))
        }
        persist()
    }
    func remove(_ id: String) { favorites.removeValue(forKey: id); orderedIDs.removeAll { $0 == id }; persist() }
    private func persist() {
        let values = items
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }
}

@MainActor @Observable
final class HistoryStore {
    struct Entry: Identifiable, Codable, Sendable {
        var id: String { video.id }
        let video: Video
        let watchedAt: Date
    }
    private(set) var items: [Entry] = []
    private let defaults: UserDefaults
    private let key = "history_v1_swift"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Entry].self, from: data) { items = saved }
    }
    func record(_ video: Video) {
        items.removeAll { $0.video.id == video.id }
        var safeVideo = video; safeVideo.streamURL = ""
        items.insert(Entry(video: safeVideo, watchedAt: .now), at: 0)
        if items.count > 150 { items = Array(items.prefix(150)) }
        persist()
    }
    func remove(_ id: String) { items.removeAll { $0.video.id == id }; persist() }
    func clear() { items.removeAll(); persist() }
    private func persist() { if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) } }
}

enum DownloadStatus: String, Codable, Sendable { case queued, downloading, paused, failed, done }

struct DownloadItem: Identifiable, Codable, Sendable {
    var id: String { video.id }
    var video: Video
    var status: DownloadStatus
    var progress: Double?
    var localURL: URL?
    var sourceURL: URL?
    var requestHeaders: [String: String]? = nil
    var hasPartial: Bool { status != .done && (progress ?? 0) > 0 }
}

typealias GallerySaveResult = PhotoSaver.Result

@MainActor @Observable
final class DownloadStore {
    private(set) var items: [String: DownloadItem] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolverTasks: [String: Task<Void, Never>] = [:]
    /// Fired on every persisted change and on progress ticks (drives WidgetSync + the Live Activity).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    private let repository: VideoRepository?
    private let resolver: StreamResolver?
    private let defaults: UserDefaults
    private let key = "downloads_v1_swift"
    private let folder: URL

    init(defaults: UserDefaults = .standard, repository: VideoRepository? = nil, resolver: StreamResolver? = nil) {
        self.defaults = defaults
        self.repository = repository
        self.resolver = resolver
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            for var item in saved {
                if item.status == .downloading || item.status == .queued { item.status = .paused }
                if item.status == .done, item.localURL.map({ FileManager.default.fileExists(atPath: $0.path) }) != true { item.status = .failed }
                items[item.video.id] = item
            }
        }
    }

    var hasCompletedDownloads: Bool { items.values.contains { $0.status == .done } }
    var doneCount: Int { items.values.filter { $0.status == .done }.count }
    var totalBytes: Int64 {
        items.values.reduce(Int64(0)) { total, item in
            guard let url = item.localURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let number = attributes[.size] as? NSNumber else { return total }
            return total + number.int64Value
        }
    }
    func item(for id: String) -> DownloadItem? { items[id] }
    func localPath(for id: String) -> URL? {
        guard let item = items[id], item.status == .done, let url = item.localURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @discardableResult func enqueueDirect(_ video: Video, url: URL, headers: [String: String]? = nil) -> Bool {
        if let old = items[video.id], old.status == .queued || old.status == .downloading || old.status == .done { return false }
        var safe = video; safe.streamURL = ""
        items[video.id] = DownloadItem(video: safe, status: .queued, progress: nil, localURL: nil, sourceURL: url, requestHeaders: headers)
        persist(); start(id: video.id)
        return true
    }
    @discardableResult func enqueue(_ video: Video) -> Bool {
        if let old = items[video.id], old.status == .queued || old.status == .downloading || old.status == .done { return false }
        if let url = URL(string: video.streamURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return enqueueDirect(video, url: url)
        }
        guard let repository else { return false }
        var safe = video; safe.streamURL = ""
        items[video.id] = DownloadItem(video: safe, status: .queued, progress: nil, localURL: nil, sourceURL: nil)
        persist()
        resolverTasks[video.id]?.cancel()
        resolverTasks[video.id] = Task { [weak self] in
            do {
                let playable = try await repository.resolveForPlayback(video, refresh: false)
                guard let self, !Task.isCancelled, let url = URL(string: playable.streamURL),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw PlaybackLaunchError.noLink }
                self.items[video.id]?.sourceURL = url
                self.items[video.id]?.video = safe
                self.resolverTasks[video.id] = nil
                self.persist(); self.start(id: video.id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.items[video.id]?.status = .failed
                self.resolverTasks[video.id] = nil
                self.persist()
            }
        }
        return true
    }
    func resume(_ id: String) {
        guard var item = items[id], item.status == .paused || item.status == .failed else { return }
        item.status = .queued; item.progress = nil; items[id] = item; persist()
        if item.sourceURL != nil { start(id: id) }
        else if repository != nil {
            items.removeValue(forKey: id)
            _ = enqueue(item.video)
        }
    }
    func pause(_ id: String) async {
        resolverTasks[id]?.cancel(); resolverTasks[id] = nil
        tasks[id]?.cancel(); tasks[id] = nil
        if var item = items[id], item.status == .downloading || item.status == .queued { item.status = .paused; items[id] = item; persist() }
    }
    func remove(_ id: String) async {
        resolverTasks[id]?.cancel(); resolverTasks[id] = nil
        tasks[id]?.cancel(); tasks[id] = nil
        if let item = items.removeValue(forKey: id), let url = item.localURL { try? FileManager.default.removeItem(at: url) }
        persist()
    }
    func removeAll() async {
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        for task in resolverTasks.values { task.cancel() }; resolverTasks.removeAll()
        for item in items.values { if let url = item.localURL { try? FileManager.default.removeItem(at: url) } }
        items.removeAll(); persist()
    }
    func saveToPhotos(_ id: String) async -> GallerySaveResult {
        guard let url = localPath(for: id) else { return .failed }
        return await PhotoSaver.saveVideo(at: url)
    }
    private func start(id: String) {
        guard let initial = items[id], let source = initial.sourceURL else { return }
        tasks[id]?.cancel()
        let destination = folder.appendingPathComponent("\(safeName(id)).mp4")
        items[id]?.status = .downloading; persist()
        let downloader = FileDownloader(maxBytes: 700 * 1024 * 1024) { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.items[id]?.status == .downloading else { return }
                self.items[id]?.progress = fraction
                self.onChange?()
            }
        }
        let resolver = self.resolver
        let itemHeaders = initial.requestHeaders
        let pageURL = initial.video.pageURL?.absoluteString
        tasks[id] = Task { [weak self] in
            do {
                var request = URLRequest(url: source, timeoutInterval: 45)
                request.setValue(CatalogSourceConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                itemHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                if let resolver,
                   let playback = try? await resolver.resolveSource(streamURL: source, pageURL: pageURL, refresh: false, preserveURL: true),
                   let resolvedURL = URL(string: playback.url) {
                    request.url = resolvedURL
                    playback.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                }
                _ = try await downloader.download(request, to: destination)
                guard let self, !Task.isCancelled, var finished = self.items[id] else { return }
                finished.status = .done; finished.progress = 1; finished.localURL = destination
                self.items[id] = finished; self.tasks[id] = nil; self.persist()
            } catch {
                guard let self, var failed = self.items[id] else { return }
                failed.status = Task.isCancelled ? .paused : .failed
                failed.progress = nil; self.items[id] = failed; self.tasks[id] = nil
                try? FileManager.default.removeItem(at: destination); self.persist()
            }
        }
    }
    private func safeName(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(Array(items.values)) { defaults.set(data, forKey: key) }
        onChange?()
    }
}

// MARK: - Playback launching (playback_launcher.dart)

/// What `fullScreenCover(item:)` presents (Flutter: the PlayerPage constructor args).
struct PlayerRoute: Identifiable {
    let id = UUID()
    var video: Video
    var startAt: TimeInterval?
    var queue: [Video]?
    var localPath: String?
    var initialSource: PlaybackSource?
    var adopted: MiniSession?   // live session handed back from the mini player / PiP
}

protocol PlaybackLauncher {
    /// Prepares playback (stops preview, resolves the stream) or throws a
    /// user-presentable error. See `DefaultPlaybackLauncher`.
    func prepare(_ video: Video, startAt: TimeInterval?, queue: [Video],
                 source: PlaybackSource?) async throws -> PlayerRoute
}

extension PlaybackLauncher {
    func prepare(_ video: Video, startAt: TimeInterval?, queue: [Video]) async throws -> PlayerRoute {
        try await prepare(video, startAt: startAt, queue: queue, source: nil)
    }
}

// MARK: - Haptics (touch.dart)

enum Haptics {
    enum Style { case light, medium, selection }
    @MainActor static func play(_ style: Style) {
        guard AppSettings.shared.haptics else { return }
        switch style {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

// MARK: - Dependencies

@MainActor
struct AppDependencies {
    var repository: VideoRepository
    var resolver: StreamResolver
    var launcher: PlaybackLauncher
    var listingCache = ListingCache()
    var relatedCache = RequestCache<[Video]>()
    var modelsCache = RequestCache<[ModelRef]>()
    var progress = PlaybackProgress()
    var favorites: FavoritesStore
    var history = HistoryStore()
    var downloads = DownloadStore()
    var reelFavorites: ReelFavorites

    init(repository: VideoRepository, resolver: StreamResolver, launcher: PlaybackLauncher? = nil) {
        let favorites = FavoritesStore()
        let downloads = DownloadStore(repository: repository, resolver: resolver)
        self.repository = repository
        self.resolver = resolver
        self.favorites = favorites
        self.downloads = downloads
        self.reelFavorites = ReelFavorites(favorites: favorites)
        self.launcher = launcher ?? DefaultPlaybackLauncher(resolver: resolver, downloads: downloads)
    }
}
