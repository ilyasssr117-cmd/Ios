import Foundation
import ActivityKit

/// Port of `_syncActivity` in `download_store.dart` + the native `liveUpdate` / `liveEnd` handlers.
/// Updates are throttled to 1/s like Flutter; the activity ends when nothing is queued/downloading.
@MainActor
final class DownloadLiveActivity {
    static let shared = DownloadLiveActivity()
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastTitle = "Downloads"

    func sync(_ store: DownloadStore, force: Bool = false) {
        let active = store.items.values.filter { $0.status == .downloading || $0.status == .queued }
        if active.isEmpty {
            guard let current = activity else { return }
            activity = nil
            let anyDone = store.items.values.contains { $0.status == .done }
            let final = DownloadActivityAttributes.ContentState(title: lastTitle, progress: 1, count: 0, finished: anyDone)
            Task { await current.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 8)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = now

        let fractions = active.compactMap(\.progress)
        let progress = fractions.isEmpty ? -1 : min(1, max(0, fractions.reduce(0, +) / Double(fractions.count)))
        let current = active.first { $0.status == .downloading } ?? active[0]
        lastTitle = current.video.title
        let state = DownloadActivityAttributes.ContentState(title: current.video.title, progress: progress,
                                                            count: active.count, finished: false)
        if let activity {
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        } else {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(),
                                             content: .init(state: state, staleDate: nil))
        }
    }
}
