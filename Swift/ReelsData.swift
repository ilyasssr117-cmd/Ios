import Foundation
import Photos
import UIKit

// MARK: - Constants (reel_favorites.dart / reels_page.dart)

enum ReelConstants {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"
    static let mediaOrigin = "https://apiv2.tik.porn"
    static let apiURL = URL(string: "https://apiv2.tik.porn/getnextvideos")!
    static let mediaHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Referer": mediaOrigin + "/",
        "Origin": mediaOrigin,
        "Accept": "*/*",
    ]
    static let maxRefetchTries = 4
    static let maxResponseBytes = 6 * 1024 * 1024
}

func reelCompact(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func reelClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Model

struct ReelItem: Identifiable, Codable, Hashable {
    let id: String
    let videoURL: URL
    var fallbackURL: URL?
    var downloadURL: URL?
    var title = ""
    var thumbURL: URL?
    var avatarURL: URL?
    var author = ""
    var views = 0
    var likes = 0
    var durationSec = 0
    var tags: [String] = []

    /// Id used by the download store (matches `ReelFavorites.videoID`).
    var downloadID: String { ReelFavorites.videoID(id) }
}

// MARK: - JSON parsing (parseReels and its helpers)

enum ReelParser {
    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= 8192 else { return nil }
        return s
    }

    static func clip(_ s: String, _ n: Int) -> String { String(s.prefix(n)) }

    static func url(_ value: Any?) -> URL? {
        guard let s = string(value), let u = URL(string: s),
              let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil,
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return u
    }

    static func title(of video: [String: Any]) -> String {
        let parsed = (((video["video_text"] as? [String: Any])?["user_display_video_title"]
            as? [String: Any])?["default"] as? [String: Any])?["parsed_text"]
        if let text = string(parsed) { return clip(text, 240) }
        return clip(string(video["action_name"]) ?? "", 240)
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func clampInt(_ d: Double, max upper: Double) -> Int {
        guard d.isFinite else { return 0 }
        return Int(Swift.min(Swift.max(d, 0), upper))
    }

    static func count(_ value: Any?) -> Int {
        switch value {
        case let n as NSNumber:
            return isBool(n) ? 0 : clampInt(n.doubleValue, max: 2_147_483_647)
        case let dict as [String: Any]:
            for key in ["count", "total", "value", "like_count", "likes_count", "formatted", "display"] {
                guard let inner = dict[key] else { continue }
                let parsed = count(inner)
                if parsed > 0 { return parsed }
            }
            return 0
        case let text as String:
            let cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: ",", with: "")
            guard !cleaned.isEmpty,
                  let regex = try? NSRegularExpression(
                      pattern: #"^(\d+(?:\.\d+)?)\s*([kmb])?\s*(?:likes?)?$"#),
                  let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  let numRange = Range(match.range(at: 1), in: cleaned),
                  let number = Double(cleaned[numRange]), number.isFinite
            else { return 0 }
            var multiplier = 1.0
            if let unitRange = Range(match.range(at: 2), in: cleaned) {
                switch cleaned[unitRange] {
                case "k": multiplier = 1_000
                case "m": multiplier = 1_000_000
                case "b": multiplier = 1_000_000_000
                default: break
                }
            }
            return clampInt((number * multiplier).rounded(), max: 2_147_483_647)
        default:
            return 0
        }
    }

    static func likes(of video: [String: Any]) -> Int {
        let keys = ["like_count", "likes_count", "likeCount", "likesCount", "likes", "like",
                    "total_likes", "totalLikes", "favorite_count", "favorites_count",
                    "favourite_count", "upvote_count", "thumbs_up_count"]
        let sources: [Any?] = [
            video, video["statistics"], video["stats"], video["engagement"], video["counts"],
            video["video_statistics"], video["video_stats"], video["engagement_stats"],
            video["metadata"], video["meta"],
        ]
        for case let source as [String: Any] in sources.compactMap({ $0 }) {
            for key in keys {
                guard let raw = source[key], !(raw is NSNull) else { continue }
                let parsed = count(raw)
                if parsed > 0 { return parsed }
            }
        }
        return 0
    }

    static func tags(of video: [String: Any]) -> [String] {
        guard let raw = video["tags"] as? [Any] else { return [] }
        return raw.prefix(24).compactMap { tag in
            guard let map = tag as? [String: Any], let name = string(map["name"]) else { return nil }
            return clip(name, 64)
        }
    }

    static func parse(_ body: Any) -> [ReelItem] {
        guard let map = body as? [String: Any], let data = map["data"] as? [Any] else { return [] }
        var out: [ReelItem] = []
        for case let raw as [String: Any] in data.prefix(48) {
            let mp4 = url(raw["mp4_url"])
            let hls = url(raw["hls_url"])
            guard let videoURL = mp4 ?? hls else { continue }
            let rawID: String = {
                if let v = raw["video_id"], !(v is NSNull) { return "\(v)" }
                return videoURL.absoluteString
            }()
            let views = (raw["view_count"] as? NSNumber).flatMap { isBool($0) ? nil : clampInt($0.doubleValue, max: 2_147_483_647) } ?? 0
            let duration = (raw["duration"] as? NSNumber).flatMap { isBool($0) ? nil : clampInt($0.doubleValue, max: 86_400) } ?? 0
            out.append(ReelItem(
                id: clip(rawID, 256),
                videoURL: videoURL,
                fallbackURL: mp4 != nil ? hls : nil,
                downloadURL: url(raw["download_url"]),
                title: title(of: raw),
                thumbURL: url(raw["poster_url"]) ?? url(raw["thumbnail_url"]),
                avatarURL: url(raw["user_avatar"]),
                author: clip(string(raw["user_name"]) ?? "", 100),
                views: views,
                likes: likes(of: raw),
                durationSec: duration,
                tags: tags(of: raw)
            ))
        }
        return out
    }
}

// MARK: - Repository (ReelsRepository)

/// `actor` replaces the Dart class + its mutable `_seen` set: access is
/// serialized without locks. Dart's `CupertinoClient` is simply `URLSession`.
/// Deviation: the 6 MB cap is checked after download (`data(for:)`), not
/// while streaming; the payload is a small JSON document.
actor ReelsRepository {
    private struct MethodNotAllowed: Error {}
    private struct HTTPFailure: Error { let status: Int; let retryAfter: TimeInterval? }

    private static let retryable: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    private let session: URLSession
    private var seen = Set<String>()
    private var seenOrder: [String] = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 24
        session = URLSession(configuration: config)
    }

    func nextBatch(_ amount: Int) async throws -> [ReelItem] {
        var fresh: [ReelItem] = []
        var emptyRounds = 0
        var rounds = 0
        while fresh.count < amount, rounds < 4, emptyRounds < ReelConstants.maxRefetchTries {
            rounds += 1
            let fetched = try await fetch(amount - fresh.count)
            var added = 0
            for item in fetched {
                let idKey = "id:\(item.id)"
                let urlKey = "url:\(item.videoURL.absoluteString)"
                if seen.contains(idKey) || seen.contains(urlKey) { continue }
                remember(idKey)
                remember(urlKey)
                fresh.append(item)
                added += 1
            }
            while seenOrder.count > 1200 { seen.remove(seenOrder.removeFirst()) }
            emptyRounds = added == 0 ? emptyRounds + 1 : 0
        }
        return fresh
    }

    private func remember(_ key: String) {
        if seen.insert(key).inserted { seenOrder.append(key) }
    }

    private func fetch(_ amount: Int) async throws -> [ReelItem] {
        for attempt in 0..<2 {
            var retryAfter: TimeInterval?
            do {
                return try await post(amount)
            } catch is MethodNotAllowed {
                // Only fall back to GET when the endpoint explicitly rejects POST.
                return try await getOnce()
            } catch let failure as HTTPFailure {
                if !Self.retryable.contains(failure.status) || attempt == 1 { throw failure }
                retryAfter = failure.retryAfter
            } catch let error as URLError {
                if error.code == .cancelled || attempt == 1 { throw error }
            }
            try await Task.sleep(for: .seconds(retryAfter ?? 0.5 * Double(attempt + 1)))
        }
        return try await post(amount)
    }

    private func post(_ amount: Int) async throws -> [ReelItem] {
        var request = URLRequest(url: ReelConstants.apiURL)
        request.httpMethod = "POST"
        request.setValue(ReelConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "amount": amount, "filter": [Any](), "sfw_mode": 0,
            "forcerand": false, "first_chunk": false,
        ] as [String: Any])
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func getOnce() async throws -> [ReelItem] {
        var request = URLRequest(url: ReelConstants.apiURL)
        request.setValue(ReelConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func decode(_ data: Data, _ response: URLResponse) throws -> [ReelItem] {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 405 || http.statusCode == 501 { throw MethodNotAllowed() }
        guard http.statusCode == 200 else {
            throw HTTPFailure(status: http.statusCode,
                              retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard data.count <= ReelConstants.maxResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let json = try JSONSerialization.jsonObject(with: data)
        if let map = json as? [String: Any], let code = map["code"], !(code is NSNull),
           (code as? NSNumber)?.intValue != 200 {
            throw URLError(.badServerResponse)
        }
        return ReelParser.parse(json)
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Int(text), seconds >= 0 { return TimeInterval(min(seconds, 6)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0), 6)
    }
}

// MARK: - Reel favorites (ReelFavorites)

/// A "like" on a reel is a favorite: the catalogue entry lives in
/// `FavoritesStore` (so it shows in the Library) and the playable data is
/// kept here so it can be reopened later.
@MainActor
final class ReelFavorites {
    struct Source {
        let url: String
        let headers: [String: String]
    }

    private static let key = "reel_favorites_v1"
    private static let maxItems = 300

    private let favorites: FavoritesStore
    private let defaults: UserDefaults
    private var items: [ReelItem] = []
    private var loaded = false

    init(favorites: FavoritesStore, defaults: UserDefaults = .standard) {
        self.favorites = favorites
        self.defaults = defaults
    }

    nonisolated static func videoID(_ reelID: String) -> String { "reel_\(reelID)" }

    static func video(of item: ReelItem) -> Video {
        Video(
            id: videoID(item.id),
            title: item.title.isEmpty
                ? (item.author.isEmpty ? "Reel" : "Reel by @\(item.author)")
                : item.title,
            thumbnailURL: item.thumbURL,
            duration: reelClock(Double(item.durationSec)),
            views: item.views > 0 ? reelCompact(item.views) : "",
            category: "Reels"
        )
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ReelItem].self, from: data) {
            items = Array(decoded.suffix(Self.maxItems))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }

    func isLiked(_ reelID: String) -> Bool { favorites.isFavorite(Self.videoID(reelID)) }

    /// Adds the reel to favorites. Returns false when it was already there.
    @discardableResult
    func like(_ item: ReelItem) -> Bool {
        ensureLoaded()
        guard !isLiked(item.id) else { return false }
        items.removeAll { $0.id == item.id }
        items.append(item)
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        persist()
        favorites.add(Self.video(of: item))
        return true
    }

    func unlike(_ reelID: String) {
        ensureLoaded()
        favorites.remove(Self.videoID(reelID))
        let before = items.count
        items.removeAll { $0.id == reelID }
        if items.count != before { persist() }
    }

    /// Returns the new liked state.
    @discardableResult
    func toggle(_ item: ReelItem) -> Bool {
        if isLiked(item.id) { unlike(item.id); return false }
        like(item)
        return true
    }

    /// Direct playback source for a favorited reel (nil for any other id).
    func source(for videoID: String) -> Source? {
        guard videoID.hasPrefix("reel_") else { return nil }
        ensureLoaded()
        let reelID = String(videoID.dropFirst(5))
        guard let item = items.first(where: { $0.id == reelID }) else { return nil }
        return Source(url: item.videoURL.absoluteString, headers: ReelConstants.mediaHeaders)
    }
}

// MARK: - Save to Photos (photo_saver.dart)

enum PhotoSaver {
    enum Result { case saved, denied, failed }
    enum ImagesResult { case saved(Int), denied, failed(Int) }

    static func saveVideo(at url: URL) async -> Result {
        // Needs NSPhotoLibraryAddUsageDescription in Info.plist.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    static func saveImages(at urls: [URL]) async -> ImagesResult {
        guard !urls.isEmpty else { return .saved(0) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        let images = urls.compactMap { UIImage(contentsOfFile: $0.path) }
        guard !images.isEmpty else { return .failed(urls.count) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images { _ = PHAssetChangeRequest.creationRequestForAsset(from: image) }
            }
            return .saved(images.count)
        } catch {
            return .failed(urls.count)
        }
    }
}

// MARK: - Bounded file download with progress

/// Streams to disk through `URLSessionDownloadDelegate` (no per-byte loops),
/// enforcing the 350 MB cap and reporting progress.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(maxBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                self.continuation = cont
                self.destination = destination
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 35
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        guard let cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > maxBytes || totalBytesWritten > maxBytes {
            downloadTask.cancel()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
              let destination else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
