import Foundation
import WidgetKit
import UIKit

/// Port of `widget_sync.dart`: writes `widget.json` + `resume.jpg` into the App Group container
/// for the home-screen widget, debounced by 2 s, and flushed when the app leaves the foreground.
/// The deep-link half (`watchtube://video?id=…`) lives in `DeepLink` below.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()
    private var task: Task<Void, Never>?
    private var thumbURL: URL?
    private weak var history: HistoryStore?
    private weak var progress: PlaybackProgress?
    private weak var downloads: DownloadStore?

    func start(history: HistoryStore, progress: PlaybackProgress, downloads: DownloadStore) {
        self.history = history; self.progress = progress; self.downloads = downloads
        schedule()
    }

    func schedule() {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.write()
        }
    }

    /// Called on scenePhase .inactive/.background.
    func flushNow() {
        task?.cancel()
        task = Task { [weak self] in await self?.write() }
    }

    private func write() async {
        guard let dir = SharedContainer.url, let history, let progress, let downloads else { return }

        var resume: Video?
        var fraction: Double?
        for entry in history.items {
            if let f = progress.fraction(for: entry.video.id) { resume = entry.video; fraction = f; break }
        }
        if resume == nil { resume = history.items.first?.video }

        let thumb = dir.appendingPathComponent("resume.jpg")
        if let wanted = resume?.thumbnailURL, ["http", "https"].contains(wanted.scheme?.lowercased() ?? "") {
            if wanted != thumbURL || !FileManager.default.fileExists(atPath: thumb.path) {
                var request = URLRequest(url: wanted, timeoutInterval: 10)
                request.setValue(CatalogSourceConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                    try? data.write(to: thumb, options: .atomic)
                    thumbURL = wanted
                }
            }
        } else {
            try? FileManager.default.removeItem(at: thumb)
            thumbURL = nil
        }

        var done = 0, active = 0
        var fractions: [Double] = []
        for item in downloads.items.values {
            switch item.status {
            case .done: done += 1
            case .downloading, .queued:
                active += 1
                if let p = item.progress { fractions.append(p) }
            default: break
            }
        }
        let activeProgress = fractions.isEmpty ? -1.0 : min(1, max(0, fractions.reduce(0, +) / Double(fractions.count)))

        let json: [String: Any] = [
            "resumeId": (resume?.id).map { $0 as Any } ?? NSNull(),
            "resumeTitle": (resume?.title).map { $0 as Any } ?? NSNull(),
            "resumeProgress": fraction.map { $0 as Any } ?? NSNull(),
            "downloadsDone": done,
            "downloadsActive": active,
            "activeProgress": activeProgress,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: dir.appendingPathComponent("widget.json"), options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// `watchtube://video?id=<video id>` — resolves the id from history, then downloads (same order as Flutter).
enum DeepLink {
    @MainActor
    static func video(for url: URL, history: HistoryStore, downloads: DownloadStore) -> Video? {
        guard url.scheme == "watchtube", url.host == "video",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        if let entry = history.items.first(where: { $0.video.id == id }) { return entry.video }
        return downloads.item(for: id)?.video
    }
}
