import Foundation
import SwiftSoup

/// Runtime configuration matching the environment-based options in
/// video_repository.dart. Add SwiftSoup through Xcode's Swift Package Manager.
struct CatalogSourceConfiguration: Sendable {
    let baseURL: URL
    let homePath: String
    let pagePathTemplate: String
    let searchPathTemplate: String
    let categoryPathTemplate: String
    let cardSelector: String
    let anchorSelector: String
    let imageSelector: String
    let titleSelector: String
    let durationSelector: String
    let durationIconSelector: String
    let dateIconSelector: String
    let viewsIconSelector: String
    let viewsSelector: String
    let likesSelector: String
    let descriptionSelector: String
    let videoPathPattern: String
    let excludePathPattern: String
    let relatedCardSelector: String
    let streamURLPattern: String
    let detailTitlePattern: String
    let previewPattern: String
    let categories: [String]
    let userAgent: String
    let timeout: TimeInterval

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

    static func fromBundle(_ bundle: Bundle = .main) -> CatalogSourceConfiguration {
        func value(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String) ?? fallback
        }
        let raw = value("VIDEO_SOURCE_BASE_URL", "https://x-fetish.tube")
        let base = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "https://x-fetish.tube")!
        var seenCategories = Set<String>()
        let categories = value("VIDEO_CATEGORIES", "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenCategories.insert($0).inserted }
        return CatalogSourceConfiguration(
            baseURL: base,
            homePath: value("VIDEO_HOME_PATH", "/"),
            pagePathTemplate: value("VIDEO_PAGE_PATH_TEMPLATE", "/video/{page}/"),
            searchPathTemplate: value("VIDEO_SEARCH_PATH_TEMPLATE", "/search/{query}/{page}/"),
            categoryPathTemplate: value("VIDEO_CATEGORY_PATH_TEMPLATE", "/categories/{slug}/{page}/"),
            cardSelector: value("VIDEO_CARD_SELECTOR", ".thumbs__list .item.thumb, .thumb-spot, article[data-video], .video-card, .video-item"),
            anchorSelector: value("VIDEO_ANCHOR_SELECTOR", "a[href]"),
            imageSelector: value("VIDEO_IMAGE_SELECTOR", "img"),
            titleSelector: value("VIDEO_TITLE_SELECTOR", "[itemprop=\"name\"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3"),
            durationSelector: value("VIDEO_DURATION_SELECTOR", ".duration, [data-duration]"),
            durationIconSelector: value("VIDEO_DURATION_ICON_SELECTOR", ".icon-duration"),
            dateIconSelector: value("VIDEO_DATE_ICON_SELECTOR", ".icon-calendar"),
            viewsIconSelector: value("VIDEO_VIEWS_ICON_SELECTOR", ".icon-view"),
            viewsSelector: value("VIDEO_VIEWS_SELECTOR", ".views, [data-views]"),
            likesSelector: value("VIDEO_LIKES_SELECTOR", ".rating, .likes, .thumb-spot__rating, [data-rating], [data-likes]"),
            descriptionSelector: value("VIDEO_DESCRIPTION_SELECTOR", "meta[property=og:description], meta[name=description]"),
            videoPathPattern: value("VIDEO_PATH_PATTERN", #"/video/"#),
            excludePathPattern: value("VIDEO_EXCLUDE_PATH_PATTERN", #"/albums?/|/galleries/|/gallery/|/photos?/|/pictures?/"#),
            relatedCardSelector: value("VIDEO_RELATED_CARD_SELECTOR", ".related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item"),
            streamURLPattern: value("VIDEO_STREAM_URL_PATTERN", #"(?:video_url|file|src)\s*[:=]\s*[\"']([^\"']+)[\"']"#),
            detailTitlePattern: value("VIDEO_DETAIL_TITLE_PATTERN", #"(?:video_title|title)\s*[:=]\s*[\"']([^\"']*)[\"']"#),
            previewPattern: value("VIDEO_PREVIEW_PATTERN", #"(?:preview_url1?|poster)\s*[:=]\s*[\"']([^\"']+)[\"']"#),
            categories: categories,
            userAgent: Self.userAgent,
            timeout: 25
        )
    }

    func url(path: String) -> URL {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: normalized, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    func pageURL(_ page: Int) -> URL {
        url(path: pagePathTemplate.replacingOccurrences(of: "{page}", with: "\(max(1, page + 1))"))
    }

    func searchURL(_ query: String, page: Int, sortBy: String?) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmedQuery.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmedQuery
        var template = searchPathTemplate
        // Match ScraperConfig.searchUri: the first page omits the page segment
        // when the configured template contains "/{page}/".
        if page <= 0, let range = template.range(of: "/{page}/") {
            template.replaceSubrange(range, with: "/")
        }
        var result = url(path: template
            .replacingOccurrences(of: "{query}", with: encoded)
            .replacingOccurrences(of: "{page}", with: "\(max(1, page + 1))"))
        if let sortBy, !sortBy.isEmpty, var components = URLComponents(url: result, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "by", value: sortBy))
            components.queryItems = items
            result = components.url ?? result
        }
        return result
    }

    func categoryURL(_ category: String, page: Int) -> URL {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let slug = normalized.replacingOccurrences(
            of: "[^a-z0-9_-]", with: "", options: .regularExpression
        )
        var template = categoryPathTemplate
        // Match ScraperConfig.categoryUri for page one.
        if page <= 0, let range = template.range(of: "/{page}/") {
            template.replaceSubrange(range, with: "/")
        }
        return url(path: template
            .replacingOccurrences(of: "{slug}", with: String(slug))
            .replacingOccurrences(of: "{page}", with: "\(max(1, page + 1))"))
    }
}

/// HTML-backed native implementation of video_repository.dart + scraper.dart.
/// SwiftSoup is used instead of regex-only HTML parsing so malformed source
/// pages and nested card markup are handled correctly.
final class HtmlScraperVideoRepository: VideoRepository, @unchecked Sendable {
    private let config: CatalogSourceConfiguration
    private let session: URLSession
    private let lock = NSLock()
    private var pageCache: [String: (Date, String)] = [:]
    private var playbackCache: [String: (Date, Video)] = [:]

    init(configuration: CatalogSourceConfiguration = .fromBundle(), session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    var categories: [String] { config.categories }

    func videos(page: Int, pageSize: Int, category: String?) async throws -> [Video] {
        try ensureConfigured()
        let url: URL
        if let category, !category.trimmingCharacters(in: .whitespaces).isEmpty, category != "All" {
            url = config.categoryURL(category, page: page)
        } else if page == 0 {
            url = config.url(path: config.homePath)
        } else {
            url = config.pageURL(page - 1)
        }
        let parsed = try await parseVideos(at: url, selector: config.cardSelector)
        return Array(parsed.prefix(max(1, pageSize)))
    }

    func searchVideos(query: String, page: Int, pageSize: Int, sortBy: String?) async throws -> [Video] {
        try ensureConfigured()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let url = config.searchURL(query, page: page, sortBy: sortBy)
        let parsed = try await parseVideos(at: url, selector: config.cardSelector)
        return Array(parsed.prefix(max(1, pageSize)))
    }

    func searchPeople(_ query: String) async throws -> PeopleSearchResult {
        try ensureConfigured()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return PeopleSearchResult(models: [], albums: []) }

        let searchURL = config.searchURL(term, page: 0, sortBy: nil)
        let html = try await loadHTML(searchURL)
        let document = try SwiftSoup.parse(html, searchURL.absoluteString)
        var modelsByURL: [String: ModelRef] = [:]
        for anchor in try document.select("a[href*=/models/]").array() {
            guard let href = try? anchor.attr("href"), let url = URL(string: href, relativeTo: searchURL)?.absoluteURL,
                  let canonical = modelBaseURL(url) else { continue }
            let image = try? anchor.select("img").first()?.attr("data-src")
            let imageFallback = try? anchor.select("img").first()?.attr("src")
            let name = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty ? (try? anchor.attr("title")) ?? modelName(from: canonical) : name
            modelsByURL[canonical.absoluteString] = ModelRef(name: resolvedName, url: canonical.absoluteString,
                imageURL: absolute(image ?? imageFallback ?? "", relativeTo: searchURL)?.absoluteString)
        }

        // Direct model-slug probes mirror Scraper.searchPeople in Dart.
        let slug = term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        if !slug.isEmpty {
            let candidate = config.url(path: "models/\(slug)/")
            if !modelsByURL.keys.contains(candidate.absoluteString),
               let profile = try? await modelProfile(for: ModelRef(name: term, url: candidate.absoluteString)) {
                modelsByURL[candidate.absoluteString] = ModelRef(name: profile.name, url: candidate.absoluteString, imageURL: profile.imageURL)
            }
        }

        let sorted = modelsByURL.values.sorted { a, b in
            func rank(_ model: ModelRef) -> Int {
                let name = model.name.lowercased(), q = term.lowercased()
                if name == q { return 0 }; if name.hasPrefix(q) { return 1 }; if name.contains(q) { return 2 }; return 3
            }
            return rank(a) < rank(b)
        }
        return PeopleSearchResult(models: Array(sorted.prefix(20)), albums: try parseAlbums(document, baseURL: searchURL))
    }

    func related(to video: Video, fresh: Bool = false) async throws -> [Video] {
        guard let pageURL = video.pageURL else { return [] }
        let list = try await parseVideos(at: pageURL, selector: config.relatedCardSelector, fresh: fresh)
        return Array(list.filter { $0.id != video.id }.prefix(6))
    }

    func models(for video: Video, fresh: Bool = false) async throws -> [ModelRef] {
        guard let pageURL = video.pageURL else { return [] }
        let html = try await loadHTML(pageURL, fresh: fresh)
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        var output: [ModelRef] = []
        var seen = Set<String>()
        for anchor in try document.select(".media-models a[href], .media-info a[href*=/models/], a[href*=/models/]").array() {
            guard let href = try? anchor.attr("href"), let raw = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  let url = modelBaseURL(raw), seen.insert(url.absoluteString).inserted else { continue }
            let text = (try? anchor.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (try? anchor.attr("title")) ?? ""
            let imgSrc = (try? anchor.select("img").first()?.attr("data-src")) ?? (try? anchor.select("img").first()?.attr("src"))
            let name = !text.isEmpty ? text : (!title.isEmpty ? title : modelName(from: url))
            output.append(ModelRef(name: name, url: url.absoluteString, imageURL: absolute(imgSrc ?? "", relativeTo: pageURL)?.absoluteString))
        }
        return output
    }

    func modelProfile(for model: ModelRef) async throws -> ModelProfile {
        guard let url = normalizedModelURL(for: model) else { throw URLError(.badURL) }
        let payload = try await loadHTML(url)
        if let profile = parseJSONModelProfile(payload, fallbackName: model.name) { return profile }
        let document = try SwiftSoup.parse(embeddedHTML(in: payload) ?? payload, url.absoluteString)
        let name = (try? document.select("meta[property=og:title]").first()?.attr("content")) ?? (try? document.select("h1").first()?.text()) ?? model.name
        let image = (try? document.select("meta[property=og:image]").first()?.attr("content")) ?? (try? document.select("meta[name=twitter:image]").first()?.attr("content"))
        return ModelProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model.name : name, imageURL: absolute(image ?? "", relativeTo: url)?.absoluteString)
    }

    func modelPage(_ model: ModelRef, page: Int = 1) async throws -> ModelPageResult {
        guard let base = normalizedModelURL(for: model) else { throw URLError(.badURL) }
        let path = page <= 1 ? "videos/" : "videos/\(page)/"
        let url = base.appending(path: path)
        let payload: String
        do {
            payload = try await loadHTML(url)
        } catch let error as HTTPStatusError where page > 1 && error.code == 404 {
            return ModelPageResult(videos: [], profile: nil)
        }
        let decoded = parseJSONVideos(payload, baseURL: url)
        let list = decoded.isEmpty
            ? try await parseVideos(at: url, selector: config.cardSelector)
            : decoded
        let profile = page <= 1 ? (try? await modelProfile(for: model)) : nil
        return ModelPageResult(videos: list, profile: profile)
    }

    func albums(for model: ModelRef? = nil, page: Int = 1) async throws -> [AlbumRef] {
        let url: URL
        if let model {
            guard let base = normalizedModelURL(for: model) else { throw URLError(.badURL) }
            url = base.appending(path: page <= 1 ? "albums/" : "albums/\(page)/")
        } else {
            url = config.url(path: page <= 1 ? "albums/" : "albums/\(page)/")
        }
        let payload: String
        do {
            payload = try await loadHTML(url)
        } catch let error as HTTPStatusError where page > 1 && error.code == 404 {
            return []
        }
        let decoded = parseJSONAlbums(payload, baseURL: url, modelName: model?.name)
        if !decoded.isEmpty { return decoded }
        let document = try SwiftSoup.parse(embeddedHTML(in: payload) ?? payload, url.absoluteString)
        return try parseAlbums(document, baseURL: url, modelName: model?.name)
    }

    func albumPhotos(_ album: AlbumRef, chunk: Int = 0) async throws -> [AlbumPhoto] {
        guard let base = URL(string: album.url) else { throw URLError(.badURL) }
        var url = base
        if chunk > 0, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "mode", value: "async"),
                URLQueryItem(name: "function", value: "get_block"),
                URLQueryItem(name: "block_id", value: "album_view_album_view"),
                URLQueryItem(name: "load", value: "more"),
                URLQueryItem(name: "from", value: "\(chunk)")
            ]
            url = components.url ?? base
        }
        let extraHeaders: [String: String]? = chunk > 0 ? [
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "*/*",
            "Referer": base.absoluteString
        ] : nil
        let html: String
        do {
            html = try await loadHTML(url, referer: base, extraHeaders: extraHeaders)
        } catch let error as HTTPStatusError where chunk > 0 && (400..<500).contains(error.code) {
            return []
        }
        let decoded = parseJSONPhotos(html, baseURL: url)
        if !decoded.isEmpty { return decoded }
        let document = try SwiftSoup.parse(embeddedHTML(in: html) ?? html, url.absoluteString)
        var output: [AlbumPhoto] = []
        var seen = Set<String>()
        for anchor in try document.select("a.grid-item[href], #albumGallery .item a[href], .album-view .item a[href], .photo-holder .item a[href]").array() {
            guard let href = try? anchor.attr("href"), let full = absolute(href, relativeTo: url),
                  let image = try? anchor.select("img").first() else { continue }
            let dataSrc = (try? image.attr("data-src")) ?? ""
            let plainSrc = (try? image.attr("src")) ?? ""
            let thumbRaw = dataSrc.isEmpty ? plainSrc : dataSrc
            let thumb = absolute(thumbRaw, relativeTo: url) ?? full
            let path = full.path.isEmpty ? full.absoluteString : full.path
            let id = firstMatch(#"/sources/(.+?)/?$"#, in: path) ?? path
            if seen.insert(id).inserted { output.append(AlbumPhoto(id: id, thumbURL: thumb.absoluteString, fullURL: full.absoluteString)) }
        }
        return output
    }

    func resolveForPlayback(_ video: Video, refresh: Bool = false) async throws -> Video {
        try ensureConfigured()
        let supplied = video.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suppliedURL = URL(string: supplied), isPlayable(suppliedURL), !isPreviewURL(suppliedURL),
           supplied != (video.previewURL?.absoluteString ?? "") { return video }
        if !refresh {
            if let cached = cachedPlayback(for: video.id), Date().timeIntervalSince(cached.0) < 8 * 60 { return cached.1 }
        }
        guard let page = video.pageURL else { throw SourceNotConfiguredError(message: "This video has no detail-page URL.") }
        let html = try await loadHTML(page, fresh: refresh)
        let document = try SwiftSoup.parse(html, page.absoluteString)
        let candidates = extractStreams(html, document: document, baseURL: page)
        guard let best = candidates.first else { throw SourceNotConfiguredError(message: "No direct media stream was found on the video page.") }
        let configuredTitle = firstMatch(config.detailTitlePattern, in: html)
        let pageTitle = (try? document.select("h1").first()?.text())
            ?? (try? document.select("meta[property=og:title]").first()?.attr("content"))
            ?? configuredTitle ?? video.title
        let description = (try? document.select(config.descriptionSelector).first()?.attr("content")) ?? video.description
        let configuredPreview = firstMatch(config.previewPattern, in: html)
        let poster = (try? document.select("video[poster]").first()?.attr("poster"))
            ?? (try? document.select("meta[property=og:image]").first()?.attr("content"))
            ?? configuredPreview ?? ""
        let qualities = candidates.compactMap { candidate -> StreamQuality? in
            guard candidate.quality > 0 else { return nil }
            return StreamQuality(height: candidate.quality, url: candidate.url.absoluteString)
        }.reduce(into: [Int: StreamQuality]()) { result, option in result[option.height] = option }
            .values.sorted { $0.height > $1.height }
        var resolved = video
        resolved.title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? video.title : pageTitle
        resolved.streamURL = best.url.absoluteString
        resolved.description = description
        resolved.thumbnailURL = absolute(poster, relativeTo: page) ?? video.thumbnailURL
        resolved.pageURL = page
        resolved.qualities = qualities.count > 1 ? qualities : []
        storePlayback(resolved, for: video.id)
        return resolved
    }

    func playbackHeaders(pageURL: URL?, streamURL: URL, refresh: Bool) async -> [String: String] {
        // Prime the same first-party/detail-page cookie jar before AVFoundation requests media.
        _ = try? await loadHTML(config.baseURL, fresh: refresh)
        if let pageURL {
            _ = try? await loadHTML(pageURL, fresh: refresh, referer: config.baseURL)
        }
        var headers: [String: String] = [
            "User-Agent": config.userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let pageURL {
            headers["Referer"] = pageURL.absoluteString
            headers["Origin"] = pageURL.originString
        }
        let cookieStorage = session.configuration.httpCookieStorage ?? HTTPCookieStorage.shared
        if let cookies = cookieStorage.cookies(for: streamURL), !cookies.isEmpty,
           let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            headers["Cookie"] = cookie
        }
        return headers
    }

    func clearPlaybackCaches() {
        lock.lock(); playbackCache.removeAll(); pageCache.removeAll(); lock.unlock()
        URLCache.shared.removeAllCachedResponses()
    }

    private func cachedPage(for key: String) -> (Date, String)? {
        lock.lock(); defer { lock.unlock() }
        return pageCache[key]
    }

    private func storePage(_ html: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        pageCache[key] = (Date(), html)
    }

    private func cachedPlayback(for key: String) -> (Date, Video)? {
        lock.lock(); defer { lock.unlock() }
        return playbackCache[key]
    }

    private func storePlayback(_ video: Video, for key: String) {
        lock.lock(); defer { lock.unlock() }
        playbackCache[key] = (Date(), video)
    }

    // MARK: JSON / HTML response parsing

    private func jsonValue(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonRecords(in value: Any) -> [[String: Any]] {
        if let array = value as? [Any] { return array.flatMap(jsonRecords(in:)) }
        guard let object = value as? [String: Any] else { return [] }
        let collectionKeys = [
            "videos", "video_list", "model_videos", "albums", "album_list", "photos", "images",
            "gallery", "items", "results", "records", "entries", "list", "data", "result",
            "response", "payload", "content", "model", "profile"
        ]
        for key in collectionKeys {
            guard let actualKey = object.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                  let nested = object[actualKey] else { continue }
            let records = jsonRecords(in: nested)
            if !records.isEmpty { return records }
        }
        return [object]
    }

    private func jsonText(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let actualKey = object.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                  let value = object[actualKey] else { continue }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let number = value as? NSNumber { return number.stringValue }
            if let nested = value as? [String: Any],
               let text = jsonText(nested, keys: ["url", "src", "href", "file", "original"]) {
                return text
            }
        }
        return nil
    }

    private func embeddedHTML(in text: String) -> String? {
        guard let value = jsonValue(from: text) else { return nil }
        func findHTML(_ value: Any) -> String? {
            if let string = value as? String, string.localizedCaseInsensitiveContains("<") { return string }
            if let object = value as? [String: Any] {
                for key in ["html", "block", "content", "response", "data", "result"] {
                    if let child = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
                       let html = findHTML(child) { return html }
                }
            }
            if let values = value as? [Any] {
                for child in values { if let html = findHTML(child) { return html } }
            }
            return nil
        }
        return findHTML(value)
    }

    private func parseJSONVideos(_ text: String, baseURL: URL) -> [Video] {
        guard let root = jsonValue(from: text) else { return [] }
        let rows = jsonRecords(in: root)
        var output: [Video] = []
        var seen = Set<String>()
        for row in rows {
            guard let title = jsonText(row, keys: ["title", "video_title", "name", "label"]),
                  let looseURL = jsonText(row, keys: ["page_url", "detail_url", "permalink", "href", "link", "url", "video_url", "stream_url", "file", "src", "media_url", "play_url"]),
                  let loose = absolute(looseURL, relativeTo: baseURL) else { continue }
            let streamRaw = jsonText(row, keys: ["video_url", "stream_url", "stream", "file", "src", "media_url", "play_url"])
            let stream = streamRaw.flatMap { absolute($0, relativeTo: baseURL) }
            let looseIsMedia = isPlayable(loose)
            let pageRaw = jsonText(row, keys: ["page_url", "detail_url", "permalink", "href", "link"])
            let page = pageRaw.flatMap { absolute($0, relativeTo: baseURL) } ?? (looseIsMedia ? nil : loose)
            let playable = stream ?? (looseIsMedia ? loose : nil)
            let thumbnailRaw = jsonText(row, keys: ["thumbnail_url", "thumbnail", "thumb", "poster", "image", "cover"])
            let thumbnail = thumbnailRaw.flatMap { absolute($0, relativeTo: baseURL) }
            guard page != nil || playable != nil else { continue }
            let id = jsonText(row, keys: ["id", "video_id", "uid", "slug"]) ?? page?.absoluteString ?? playable!.absoluteString
            guard seen.insert(id).inserted else { continue }
            var video = Video(id: id, title: title)
            video.streamURL = playable?.absoluteString ?? ""
            video.pageURL = page
            video.thumbnailURL = thumbnail
            video.duration = jsonText(row, keys: ["duration", "length", "time"]) ?? ""
            video.views = jsonText(row, keys: ["views", "view_count"]) ?? ""
            video.likes = jsonText(row, keys: ["likes", "rating", "like_count"]) ?? ""
            video.category = jsonText(row, keys: ["category", "category_name"]) ?? "Featured"
            let headerFields = (row["headers"] as? [String: String]) ?? (row["http_headers"] as? [String: String])
            video.streamHeaders = headerFields?.map { StreamHeader(name: $0.key, value: $0.value) }
            output.append(video)
        }
        return output
    }

    private func parseJSONAlbums(_ text: String, baseURL: URL, modelName: String?) -> [AlbumRef] {
        guard let root = jsonValue(from: text) else { return [] }
        let rows = jsonRecords(in: root)
        var output: [AlbumRef] = []
        var seen = Set<String>()
        for row in rows {
            guard let title = jsonText(row, keys: ["title", "album_title", "name"]),
                  let rawURL = jsonText(row, keys: ["album_url", "permalink", "href", "link", "url"]),
                  let url = absolute(rawURL, relativeTo: baseURL) else { continue }
            let id = jsonText(row, keys: ["id", "album_id", "uid"]) ?? url.absoluteString
            guard seen.insert(id).inserted else { continue }
            let thumbRaw = jsonText(row, keys: ["thumbnail_url", "thumbnail", "thumb", "cover", "image"])
            output.append(AlbumRef(id: id, title: title, url: url.absoluteString,
                                   thumbnailURL: thumbRaw.flatMap { absolute($0, relativeTo: baseURL)?.absoluteString },
                                   modelName: jsonText(row, keys: ["model_name"]) ?? modelName))
        }
        return output
    }

    private func parseJSONPhotos(_ text: String, baseURL: URL) -> [AlbumPhoto] {
        guard let root = jsonValue(from: text) else { return [] }
        let rows = jsonRecords(in: root)
        var output: [AlbumPhoto] = []
        var seen = Set<String>()
        for row in rows {
            guard let rawFull = jsonText(row, keys: ["full_url", "original", "source", "file", "href", "link", "url", "image"]),
                  let full = absolute(rawFull, relativeTo: baseURL) else { continue }
            let thumbRaw = jsonText(row, keys: ["thumbnail_url", "thumbnail", "thumb", "preview", "src"]) ?? rawFull
            let thumb = absolute(thumbRaw, relativeTo: baseURL) ?? full
            let id = jsonText(row, keys: ["id", "photo_id", "uid"]) ?? full.absoluteString
            if seen.insert(id).inserted {
                output.append(AlbumPhoto(id: id, thumbURL: thumb.absoluteString, fullURL: full.absoluteString))
            }
        }
        return output
    }

    private func parseJSONModelProfile(_ text: String, fallbackName: String) -> ModelProfile? {
        guard let root = jsonValue(from: text) else { return nil }
        for row in jsonRecords(in: root) {
            guard let name = jsonText(row, keys: ["name", "model_name", "title"]) else { continue }
            let imageRaw = jsonText(row, keys: ["image_url", "avatar", "image", "thumbnail", "photo"])
            return ModelProfile(name: name.isEmpty ? fallbackName : name,
                                imageURL: imageRaw.flatMap { absolute($0, relativeTo: URL(string: model.url) ?? config.baseURL)?.absoluteString })
        }
        return nil
    }

    private func normalizedModelURL(for model: ModelRef) -> URL? {
        let raw = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let parsed = URL(string: raw, relativeTo: config.baseURL)?.absoluteURL,
           ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
           parsed.host != nil,
           parsed.path.lowercased().contains("/models/") {
            return modelBaseURL(parsed) ?? parsed
        }
        let candidate = raw.split(separator: "/").last.map(String.init) ?? raw
        guard !candidate.isEmpty, candidate != ".", candidate != "..",
              !candidate.contains("?"), !candidate.contains("#") else { return nil }
        return config.url(path: "models/\(candidate)/")
    }

    // MARK: HTML processing

    private func parseVideos(at url: URL, selector: String, fresh: Bool = false) async throws -> [Video] {
        let html = try await loadHTML(url, fresh: fresh)
        let document = try SwiftSoup.parse(embeddedHTML(in: html) ?? html, url.absoluteString)
        let cards = try document.select(selector).array()
        var videos: [Video] = []
        var seen = Set<String>()
        for card in cards {
            if let video = try parseVideoCard(card, pageURL: url), seen.insert(video.id).inserted { videos.append(video) }
        }
        if videos.isEmpty {
            // Some source templates don't wrap cards in the expected classes.
            for anchor in try document.select("a[href], [data-href], [data-url]").array() {
                guard let video = try parseVideoCard(anchor, pageURL: url), seen.insert(video.id).inserted else { continue }
                videos.append(video)
            }
        }
        return videos
    }

    private func parseVideoCard(_ card: Element, pageURL: URL) throws -> Video? {
        let anchors: [Element] = (card.tagName().lowercased() == "a" ? [card] : [])
            + (try card.select(config.anchorSelector).array())
        var anchor: Element?
        var target: URL?
        for candidate in anchors {
            guard let href = try? candidate.attr("href"), let url = absolute(href, relativeTo: pageURL) else { continue }
            let path = url.path.lowercased()
            guard path.range(of: config.videoPathPattern, options: .regularExpression) != nil,
                  path.range(of: config.excludePathPattern, options: .regularExpression) == nil else { continue }
            anchor = candidate
            target = url
            break
        }
        if target == nil {
            let dataHref = (try? card.attr("data-href")) ?? ""
            let dataURL = (try? card.attr("data-url")) ?? ""
            let raw = !dataHref.isEmpty ? dataHref : dataURL
            if let url = absolute(raw, relativeTo: pageURL) {
                let path = url.path.lowercased()
                if path.range(of: config.videoPathPattern, options: .regularExpression) != nil,
                   path.range(of: config.excludePathPattern, options: .regularExpression) == nil {
                    target = url
                }
            }
        }
        guard let videoPage = target else { return nil }
        let classes = ((try? card.attr("class")) ?? "").lowercased()
        guard !classes.contains("album"), !classes.contains("gallery") else { return nil }

        let image = try card.select(config.imageSelector).first()
        var imageRaw = ""
        for name in ["data-src", "data-original", "data-webp", "data-lazy-src", "src"] {
            let value: String = (try? image?.attr(name)) ?? ""
            if !value.isEmpty { imageRaw = value; break }
        }
        if imageRaw.isEmpty {
            imageRaw = (try? card.select("video[poster]").first()?.attr("poster")) ?? ""
        }
        let thumbnail = absolute(imageRaw, relativeTo: pageURL)
        let anchorText = cleanText((try? anchor?.text()) ?? "")
        let cardText = cleanText(try card.text())
        let titleElement = try card.select(config.titleSelector).first()
        let titleCandidates = [
            (try? anchor?.attr("title")) ?? "",
            (try? card.attr("data-title")) ?? "",
            (try? titleElement?.text()) ?? "",
            (try? image?.attr("alt")) ?? "",
            anchorText,
            cardText
        ]
        var title = titleCandidates.map(cleanText).first(where: { !$0.isEmpty }) ?? ""
        title = cleanVideoTitle(title)
        if title.isEmpty { title = cleanVideoTitle(anchorText) }
        if title.isEmpty { title = cleanVideoTitle(cardText) }
        guard !title.isEmpty else { return nil }

        let durationIcon = iconParentText(in: card, selector: config.durationIconSelector)
        let durationText = selectedMetadataText(
            in: card, selector: config.durationSelector,
            attributes: ["data-duration", "content", "title", "aria-label"]
        )
        let durationPattern = #"\b(\d{1,2}:\d{2}(?::\d{2})?)\b"#
        let duration = firstMatch(durationPattern, in: durationIcon)
            ?? firstMatch(durationPattern, in: durationText)
            ?? firstMatch(durationPattern, in: "\(anchorText) \(cardText)")
            ?? cleanText((try? card.attr("data-duration")) ?? "")

        let viewsIcon = iconParentText(in: card, selector: config.viewsIconSelector)
        let viewsText = selectedMetadataText(
            in: card, selector: config.viewsSelector,
            attributes: ["data-views", "content", "title", "aria-label"]
        ) + " " + cleanText((try? card.attr("data-views")) ?? "")
        let viewsPattern = #"(\d[\d,.]*\s*[KkMmBb]?)\s*views?\b"#
        let iconViews = normalizeViews(viewsIcon)
        let cardViews = firstMatch(viewsPattern, in: "\(anchorText) \(cardText)")
            .map(normalizeViews) ?? ""
        let viewsRaw = firstMatch(#"(\d[\d,.]*\s*[KkMmBb]?)"#, in: viewsText)
        let nodeViews = normalizeViews(viewsRaw ?? viewsText)
        let views = !iconViews.isEmpty ? iconViews
            : (!cardViews.isEmpty ? cardViews : nodeViews)

        let likesText = selectedMetadataText(
            in: card, selector: config.likesSelector,
            attributes: ["data-rating", "data-likes", "content", "title", "aria-label"]
        ) + " " + cleanText((try? card.attr("data-rating")) ?? "")
          + " " + cleanText((try? card.attr("data-likes")) ?? "")
        let likesRaw = firstMatch(#"^\s*(\d{1,3})\s*%"#, in: anchorText)
            ?? firstMatch(#"^\s*(\d{1,3})\s*%"#, in: cardText)
            ?? firstMatch(#"(\d{1,3})\s*%"#, in: likesText)
            ?? firstMatch(#"^\s*(\d{1,3})(?:\.0+)?\s*$"#, in: likesText)
        let likes = likesRaw.map { "\($0)%" } ?? ""
        let date = iconParentText(in: card, selector: config.dateIconSelector)

        let dataID = ((try? card.attr("data-id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var queryPart = ""
        if let query = videoPage.query, !query.isEmpty { queryPart = "?" + query }
        let pageKey: String = (videoPage.host ?? "") + videoPage.path + queryPart
        let id = dataID.isEmpty ? pageKey : dataID
        let directCandidates = [
            (try? card.attr("data-video-url")) ?? "",
            (try? card.attr("data-stream")) ?? "",
            (try? card.select("video source[src]").first()?.attr("src")) ?? "",
            (try? card.select("video[src]").first()?.attr("src")) ?? ""
        ]
        let directURL = directCandidates
            .compactMap { absolute($0, relativeTo: pageURL) }
            .first(where: { isPlayable($0) && !isPreviewURL($0) })
        let directStream = directURL?.absoluteString ?? ""
        let previewCandidates = [
            (try? image?.attr("data-preview")) ?? "",
            (try? card.select("[data-preview]").first()?.attr("data-preview")) ?? ""
        ]
        let previewRaw = previewCandidates.first(where: { !$0.isEmpty }) ?? ""
        let preview = absolute(previewRaw, relativeTo: pageURL)

        return Video(id: id, title: title, streamURL: directStream, description: "", thumbnailURL: thumbnail,
                     duration: duration, views: views, likes: likes, date: date,
                     category: (try? card.attr("data-category")) ?? "Video",
                     pageURL: videoPage, previewURL: preview, qualities: [])
    }

    private func parseAlbums(_ document: Document, baseURL: URL, modelName: String? = nil) throws -> [AlbumRef] {
        var output: [AlbumRef] = []
        var seen = Set<String>()
        let cards = try document.select(".thumb--albums, a[href*=/albums/]").array()
        for card in cards {
            let anchor = try card.tagName().lowercased() == "a" ? card : (card.select("a[href]").first())
            guard let anchor, let href = try? anchor.attr("href"), let url = absolute(href, relativeTo: baseURL),
                  url.path.lowercased().contains("/albums/"), seen.insert(url.absoluteString).inserted else { continue }
            let image = try card.select("img").first()
            let title = cleanText((try? anchor.attr("title")) ?? (try? card.select(".thumb__title, .title").first()?.text()) ?? (try? image?.attr("alt")) ?? "")
            let name = title.isEmpty ? (url.lastPathComponent.replacingOccurrences(of: "-", with: " ")) : title
            output.append(AlbumRef(id: "\(url.host ?? "")\(url.path)", title: name, url: url.absoluteString,
                                   thumbnailURL: absolute((try? image?.attr("data-src")) ?? (try? image?.attr("src")) ?? "", relativeTo: baseURL)?.absoluteString,
                                   modelName: modelName))
        }
        return output
    }

    private struct StreamCandidate {
        let url: URL
        let quality: Int
        let rank: Int
        let order: Int
        let preview: Bool
        var score: Int { max(quality, 1) }
    }

    private func extractStreams(_ html: String, document: Document, baseURL: URL) -> [StreamCandidate] {
        var output: [StreamCandidate] = []
        var seen = Set<String>()
        func add(_ raw: String?, rank: Int, label: String = "") {
            guard let raw else { return }
            let cleaned = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("function/"),
                  let url = absolute(cleaned, relativeTo: baseURL), isPlayable(url),
                  seen.insert(url.absoluteString).inserted else { return }
            let qualityText = label.isEmpty ? url.absoluteString : label
            let lowerQuality = qualityText.lowercased()
            let parsedQuality = Int(firstMatch(#"(\d{3,4})\s*p"#, in: lowerQuality) ?? "")
            let quality = parsedQuality
                ?? (lowerQuality.contains("4k") || lowerQuality.contains("2160") ? 2160 :
                    lowerQuality.contains("fhd") || lowerQuality.contains("1080") ? 1080 :
                    lowerQuality.contains("hd") || lowerQuality.contains("720") ? 720 :
                    lowerQuality.contains("480") ? 480 : lowerQuality.contains("sd") ? 360 : 0)
            output.append(StreamCandidate(url: url, quality: quality, rank: rank,
                                          order: output.count, preview: isPreviewURL(url)))
        }

        // The source's explicit video_url variables are the most reliable full streams.
        let urlPattern = #"(video_(?:alt_)?url\d*)\s*[:=]\s*[\"']([^\"']+)[\"']"#
        let labelPattern = #"(video_(?:alt_)?url\d*)_text\s*[:=]\s*[\"']([^\"']*)[\"']"#
        var labels: [String: String] = [:]
        if let regex = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let keyRange = Range(match.range(at: 1), in: html),
                      let valueRange = Range(match.range(at: 2), in: html) else { continue }
                labels[String(html[keyRange]).lowercased()] = String(html[valueRange])
            }
        }
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let keyRange = Range(match.range(at: 1), in: html),
                      let valueRange = Range(match.range(at: 2), in: html) else { continue }
                let key = String(html[keyRange]).lowercased()
                add(String(html[valueRange]), rank: 0, label: labels[key] ?? "")
            }
        }

        if let sources = try? document.select("video source[src], video[src]").array() {
            for source in sources {
                let label = (try? source.attr("label")) ?? (try? source.attr("title"))
                    ?? (try? source.attr("res")) ?? (try? source.attr("size"))
                    ?? (try? source.attr("data-res")) ?? ""
                add(try? source.attr("src"), rank: 1, label: label)
            }
        }
        if let meta = try? document.select("meta[property=og:video], meta[property=og:video:url], meta[property=og:video:secure_url], meta[name=twitter:player:stream]").array() {
            for node in meta { add(try? node.attr("content"), rank: 2) }
        }
        for value in allMatches(#""contentUrl"\s*:\s*"([^"]+)""#, in: html) {
            add(value, rank: 3)
        }
        for value in allMatches(config.streamURLPattern, in: html) {
            add(value, rank: 4, label: value)
        }
        let plain = html.replacingOccurrences(of: #"\/"#, with: "/")
        for value in allMatches(#"(https?://[^\s\"'<>\\]+?\.(?:mp4|m3u8|m4v|mov)(?:\?[^\s\"'<>\\]*)?)"#, in: plain) {
            add(value, rank: 5, label: value)
        }

        return output.filter { !$0.preview }.sorted { a, b in
            if a.preview != b.preview { return !a.preview }
            if a.score != b.score { return a.score > b.score }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.order < b.order
        }
    }

    // MARK: Networking & URL helpers

    private func ensureConfigured() throws {
        guard ["https", "http"].contains(config.baseURL.scheme?.lowercased() ?? ""), config.baseURL.host != nil,
              !config.baseURL.host!.contains("your-authorized-source") else {
            throw SourceNotConfiguredError(message: "Set VIDEO_SOURCE_BASE_URL in the app Info.plist to a valid video source.")
        }
    }

    private func loadHTML(_ url: URL, fresh: Bool = false, referer: URL? = nil,
                          extraHeaders: [String: String]? = nil) async throws -> String {
        let key = url.absoluteString
        if !fresh {
            if let cached = cachedPage(for: key), Date().timeIntervalSince(cached.0) < 90 { return cached.1 }
        }
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue((referer ?? config.baseURL).absoluteString, forHTTPHeaderField: "Referer")
        extraHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(code: http.statusCode) }
                let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw URLError(.zeroByteResource) }
                storePage(html, for: key)
                return html
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    private func modelBaseURL(_ url: URL) -> URL? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "models" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/models/\(parts[1])/"
        components?.query = nil; components?.fragment = nil
        return components?.url
    }

    private func modelName(from url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
    }

    private func absolute(_ value: String, relativeTo base: URL) -> URL? {
        let cleaned = unescape(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("data:") else { return nil }
        guard let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func isPlayable(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        let nonMedia = #"\.(?:jpe?g|png|gif|webp|svg|ico|css|js|json|vtt|srt|woff2?|ttf|html?)(?:$|[?#])"#
        if path.range(of: nonMedia, options: .regularExpression) != nil { return false }
        let resource = path + (query.isEmpty ? "" : "?\(query)")
        return [".mp4", ".m3u8", ".mov", ".m4v", "/get_file/"]
            .contains(where: { resource.contains($0) })
    }

    /// Read a metadata node's text and common data attributes. Some source
    /// templates place the value in `data-*`, `title`, or `aria-label` instead
    /// of a text node, so support those forms as a fallback.
    private func selectedMetadataText(in element: Element, selector: String, attributes: [String]) -> String {
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selected = try? element.select(selector),
              let node = selected.first() else { return "" }
        var values: [String] = []
        if let text = try? node.text(), !cleanText(text).isEmpty { values.append(cleanText(text)) }
        for attribute in attributes {
            if let value = try? node.attr(attribute), !cleanText(value).isEmpty {
                values.append(cleanText(value))
            }
        }
        if let parent = try? node.parent(), let text = try? parent.text(), !cleanText(text).isEmpty {
            values.append(cleanText(text))
        }
        return cleanText(values.joined(separator: " "))
    }

    private func iconParentText(in element: Element, selector: String) -> String {
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selected = try? element.select(selector),
              let icon = selected.first() else { return "" }
        if let parent = try? icon.parent(),
           let text = try? parent.text(), !cleanText(text).isEmpty {
            return cleanText(text)
        }
        return cleanText((try? icon.text()) ?? "")
    }

    private func normalizeViews(_ raw: String) -> String {
        let text = cleanText(raw)
            .replacingOccurrences(of: "views?", with: "", options: .regularExpression.union(.caseInsensitive))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"^(\d[\d.,\s\x{00a0}]*?)\s*([KkMmBb])?$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text) else { return "" }

        let numberText = String(text[numberRange]).replacingOccurrences(of: #"[\s\x{00a0}]"#, with: "", options: .regularExpression)
        let suffix = match.range(at: 2).location == NSNotFound ? nil : Range(match.range(at: 2), in: text).map { String(text[$0]).uppercased() }
        func compact(_ value: Double) -> String {
            let formatted = value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
            return formatted.replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
        }
        if let suffix {
            guard let value = Double(numberText.replacingOccurrences(of: ",", with: ".")) else { return "" }
            return "\(compact(value))\(suffix) views"
        }
        let digits = numberText.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        guard let count = Double(digits) else { return "" }
        if count >= 1_000_000_000 { return "\(compact(count / 1_000_000_000))B views" }
        if count >= 1_000_000 { return "\(compact(count / 1_000_000))M views" }
        if count >= 1_000 { return "\(compact(count / 1_000))K views" }
        return count == 1 ? "1 view" : "\(Int(count)) views"
    }

    private func cleanVideoTitle(_ raw: String) -> String {
        var text = cleanText(raw)
        text = text.replacingOccurrences(of: #"^\s*\d{1,3}\s*%\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\d,.]+\s*[KkMmBb]?\s*views?\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\b\d+\s+(?:second|minute|hour|day|week|month|year)s?(?:\s+ago)?\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        return cleanText(text)
    }

    private func isPreviewURL(_ url: URL) -> Bool {
        // Test the resource path, not signed query strings that may contain
        // unrelated words such as `thumbnail` in a token parameter.
        url.path.range(of: #"preview|trailer|teaser|sprite|screenshot|thumb"#,
                       options: .regularExpression.union(.caseInsensitive)) != nil
    }

    private func cleanText(_ text: String) -> String {
        let noTags = (try? NSRegularExpression(pattern: "<[^>]+>").stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")) ?? text
        return noTags.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "\\u003a", with: ":")
            .replacingOccurrences(of: "\\u003f", with: "?")
            .replacingOccurrences(of: "\\u002b", with: "+")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let capture = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? 1 : 0
        guard let range = Range(match.range(at: capture), in: text) else { return nil }
        return String(text[range])
    }

    private func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let capture = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? 1 : 0
            guard let range = Range(match.range(at: capture), in: text) else { return nil }
            return String(text[range])
        }
    }
}

/// Native equivalent of stream_resolver.dart / media_headers.dart.
struct NativeStreamResolver: StreamResolver {
    let repository: HtmlScraperVideoRepository

    func resolveForPlayback(_ video: Video, refresh: Bool) async throws -> Video {
        try await repository.resolveForPlayback(video, refresh: refresh)
    }

    func resolveSource(streamURL: URL, pageURL: String?, refresh: Bool, preserveURL: Bool) async throws -> PlaybackSource {
        let page = pageURL.flatMap(URL.init(string:))
        let headers = await repository.playbackHeaders(pageURL: page, streamURL: streamURL, refresh: refresh)
        return PlaybackSource(url: streamURL.absoluteString, headers: headers)
    }
}

private extension URL {
    var originString: String {
        guard let scheme, let host else { return absoluteString }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }
}
