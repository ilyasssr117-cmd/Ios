import SwiftUI
import ImageIO

// MARK: - Model reference (models.dart: ModelRef)

/// Equality/hash by `url`, like the Dart `==` override.
struct ModelRef: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let url: String
    var imageURL: String?

    var id: String { url }
    static func == (lhs: ModelRef, rhs: ModelRef) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    func withImage(_ image: String?) -> ModelRef { ModelRef(name: name, url: url, imageURL: image ?? imageURL) }
}

// MARK: - Image loading with custom headers

/// `AsyncImage` can't send custom headers (Referer/Origin) and doesn't
/// downsample, which both matter for avatars. This is a small cached loader.
final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 300 }

    func image(url: URL, headers: [String: String]?, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var request = URLRequest(url: url, timeoutInterval: 20)
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct HeaderImage: View {
    let url: URL
    var headers: [String: String]?
    var maxPixel: CGFloat = 256
    var onFailure: (() -> Void)?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.clear }
        }
        .task(id: url) {
            if let loaded = await RemoteImageLoader.shared.image(url: url, headers: headers, maxPixel: maxPixel) {
                image = loaded
            } else {
                onFailure?()
            }
        }
    }
}

/// Source-specific image headers (`imageHeadersFor` in media_headers.dart).
/// Builds source-compatible request headers for remote thumbnails.
func imageHeaders(for pageURL: String) -> [String: String]? {
    guard let url = URL(string: pageURL), let scheme = url.scheme, let host = url.host,
          scheme == "http" || scheme == "https" else { return nil }
    return [
        "User-Agent": CatalogSourceConfiguration.userAgent,
        "Referer": pageURL,
        "Origin": "\(scheme)://\(host)"
    ]
}

// MARK: - Model avatar (model_avatar.dart)

/// Tries page-specific headers + Referer, then headers only, then none,
/// retrying with a short delay; falls back to an initial on accent.
struct ModelAvatar: View {
    let name: String
    let imageURL: String?
    let pageURL: String
    var size: CGFloat = 48

    @State private var attempt = 0
    private static let lastAttempt = 2

    private var headers: [String: String]? {
        switch attempt {
        case 0:
            return imageHeaders(for: pageURL).map { $0.merging(["Referer": pageURL]) { _, new in new } }
        case 1:
            return imageHeaders(for: pageURL)
        default:
            return nil
        }
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let initial = trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()

        ZStack {
            Color.vxAccent.opacity(0.85)
            Text(initial).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            if let imageURL, let url = URL(string: imageURL) {
                HeaderImage(url: url, headers: headers, maxPixel: size * 3, onFailure: scheduleRetry)
                    .id(attempt)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func scheduleRetry() {
        guard attempt < Self.lastAttempt else { return }
        let next = attempt + 1
        Task {
            try? await Task.sleep(for: .milliseconds(800 * next))
            if attempt == next - 1 { attempt = next }
        }
    }
}
