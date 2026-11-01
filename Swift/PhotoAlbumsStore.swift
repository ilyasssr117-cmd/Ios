import Foundation
import Observation

// MARK: - Offline photo albums (photo_store.dart)

struct SavedPhotoAsset: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var fileName: String
}

struct SavedPhotoAlbum: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var url: String
    var directoryName: String
    var modelName: String?
    var photos: [SavedPhotoAsset]
    var savedAt: Date
}

struct PhotoAlbumDownloadProgress: Sendable {
    var total: Int
    var completed: Int
    var failed: Int
}

struct PhotoAlbumSaveSummary: Sendable {
    var saved: Int
    var failed: Int
    var requested: Int
}

@MainActor @Observable
final class OfflinePhotoAlbumsStore {
    static let shared = OfflinePhotoAlbumsStore()

    private(set) var albums: [SavedPhotoAlbum] = []
    private(set) var progressByAlbum: [String: PhotoAlbumDownloadProgress] = [:]

    private let defaults = UserDefaults.standard
    private let key = "offline_photo_albums_v1_swift"
    private let root: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = documents.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        restore()
    }

    var totalPhotos: Int { albums.reduce(0) { $0 + $1.photos.count } }

    func album(_ id: String) -> SavedPhotoAlbum? { albums.first { $0.id == id } }

    func fileURL(for photo: SavedPhotoAsset, in album: SavedPhotoAlbum) -> URL {
        root.appendingPathComponent(album.directoryName, isDirectory: true)
            .appendingPathComponent(photo.fileName, isDirectory: false)
    }

    func isSaved(_ albumID: String, photoID: String) -> Bool {
        album(albumID)?.photos.contains(where: { $0.id == photoID }) == true
    }

    func savePhotos(
        _ photos: [AlbumPhoto],
        from source: AlbumRef,
        modelName: String? = nil,
        headers: [String: String]? = nil
    ) async -> PhotoAlbumSaveSummary {
        guard progressByAlbum[source.id] == nil else {
            return PhotoAlbumSaveSummary(saved: 0, failed: 0, requested: 0)
        }

        let existing = album(source.id)
        let alreadySaved = Set(existing?.photos.map(\.id) ?? [])
        let todo = photos.filter { !alreadySaved.contains($0.id) }
        guard !todo.isEmpty else { return PhotoAlbumSaveSummary(saved: 0, failed: 0, requested: 0) }

        let folderName = existing?.directoryName ?? Self.safeName(source.id, fallback: "album")
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return PhotoAlbumSaveSummary(saved: 0, failed: todo.count, requested: todo.count)
        }

        progressByAlbum[source.id] = PhotoAlbumDownloadProgress(total: todo.count, completed: 0, failed: 0)
        let requestHeaders = headers ?? imageHeaders(for: source.url) ?? [
            "User-Agent": CatalogSourceConfiguration.userAgent,
            "Accept": "image/*,*/*;q=0.8"
        ]
        var completedAssets: [SavedPhotoAsset] = []
        var failed = 0

        await withTaskGroup(of: (String, String?).self) { group in
            var iterator = todo.makeIterator()
            for _ in 0..<min(3, todo.count) {
                guard let photo = iterator.next() else { continue }
                group.addTask {
                    (photo.id, await downloadAlbumPhoto(photo, directory: folder, headers: requestHeaders))
                }
            }

            while let (photoID, fileName) = await group.next() {
                if let fileName {
                    completedAssets.append(SavedPhotoAsset(id: photoID, fileName: fileName))
                } else {
                    failed += 1
                }
                let finished = completedAssets.count + failed
                progressByAlbum[source.id] = PhotoAlbumDownloadProgress(
                    total: todo.count,
                    completed: finished,
                    failed: failed
                )
                if let next = iterator.next() {
                    group.addTask {
                        (next.id, await downloadAlbumPhoto(next, directory: folder, headers: requestHeaders))
                    }
                }
            }
        }

        var saved = existing ?? SavedPhotoAlbum(
            id: source.id,
            title: source.title,
            url: source.url,
            directoryName: folderName,
            modelName: modelName,
            photos: [],
            savedAt: .now
        )
        saved.title = source.title
        saved.url = source.url
        if saved.modelName == nil { saved.modelName = modelName }
        var byID = Dictionary(uniqueKeysWithValues: saved.photos.map { ($0.id, $0) })
        for item in completedAssets { byID[item.id] = item }
        saved.photos = byID.values.sorted { Self.photoIDLess($0.id, $1.id) }

        if let index = albums.firstIndex(where: { $0.id == source.id }) {
            albums[index] = saved
        } else if !saved.photos.isEmpty {
            albums.insert(saved, at: 0)
        }
        albums.sort { $0.savedAt > $1.savedAt }
        if saved.photos.isEmpty { try? FileManager.default.removeItem(at: folder) }
        progressByAlbum[source.id] = nil
        persist()
        return PhotoAlbumSaveSummary(saved: completedAssets.count, failed: failed, requested: todo.count)
    }

    func removePhoto(albumID: String, photoID: String) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }),
              let photoIndex = albums[index].photos.firstIndex(where: { $0.id == photoID }) else { return }
        let album = albums[index]
        let photo = album.photos[photoIndex]
        try? FileManager.default.removeItem(at: fileURL(for: photo, in: album))
        albums[index].photos.remove(at: photoIndex)
        if albums[index].photos.isEmpty {
            albums.remove(at: index)
            let folder = root.appendingPathComponent(album.directoryName, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
        }
        persist()
    }

    func removeAlbum(_ albumID: String) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let value = albums.remove(at: index)
        let folder = root.appendingPathComponent(value.directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        persist()
    }

    func clearAll() {
        for album in albums {
            let folder = root.appendingPathComponent(album.directoryName, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
        }
        albums.removeAll()
        persist()
    }

    private func restore() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedPhotoAlbum].self, from: data) else { return }
        albums = decoded.compactMap { album in
            guard !album.directoryName.isEmpty,
                  !album.directoryName.contains("/"),
                  !album.directoryName.contains("..") else { return nil }
            let valid = album.photos.filter { photo in
                !photo.fileName.isEmpty && !photo.fileName.contains("/") &&
                FileManager.default.fileExists(atPath: fileURL(for: photo, in: album).path)
            }
            guard !valid.isEmpty else {
                let folder = root.appendingPathComponent(album.directoryName, isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            var copy = album
            copy.photos = valid
            return copy
        }.sorted { $0.savedAt > $1.savedAt }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        defaults.set(data, forKey: key)
    }

    private static func safeName(_ value: String, fallback: String) -> String {
        var name = value.replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}/?$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "_", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.count > 90 { name = String(name.suffix(90)) }
        return name.isEmpty ? fallback : name
    }

    private static func photoIDLess(_ lhs: String, _ rhs: String) -> Bool {
        let leftDigits = lhs.range(of: #"\d+(?=\.[A-Za-z0-9]+/?$)"#, options: .regularExpression)
            .flatMap { Int(lhs[$0]) }
        let rightDigits = rhs.range(of: #"\d+(?=\.[A-Za-z0-9]+/?$)"#, options: .regularExpression)
            .flatMap { Int(rhs[$0]) }
        if let leftDigits, let rightDigits, leftDigits != rightDigits { return leftDigits < rightDigits }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

private func downloadAlbumPhoto(
    _ photo: AlbumPhoto,
    directory: URL,
    headers: [String: String]
) async -> String? {
    guard let url = URL(string: photo.fullURL),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 40)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let fileExtension = imageFileExtension(data) else { return nil }
        var base = photo.id.replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "_", options: .regularExpression)
        if base.isEmpty { base = UUID().uuidString }
        if base.count > 90 { base = String(base.suffix(90)) }
        let fileName = "\(base).\(fileExtension)"
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    } catch {
        return nil
    }
}

private func imageFileExtension(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    guard bytes.count >= 12 else { return nil }
    if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "jpg" }
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "png" }
    if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return "gif" }
    if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 { return "webp" }
    return nil
}
