import WidgetKit
import SwiftUI
import ActivityKit

// Widget extension target ("FlowWidgets"). Add: this file + SharedActivityAttributes.swift.
// Enable the same App Group on the app and the extension, and add NSSupportsLiveActivities = YES
// to the APP's Info.plist. The app writes widget.json / resume.jpg (see WidgetSync.swift).

struct ResumeEntry: TimelineEntry {
    let date: Date
    let id: String?
    let title: String?
    let progress: Double?
    let downloadsDone: Int
    let downloadsActive: Int
    let activeProgress: Double
    let thumbnail: UIImage?
}

struct ResumeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ResumeEntry {
        ResumeEntry(date: .now, id: nil, title: "Continue watching", progress: 0.4, downloadsDone: 3, downloadsActive: 0, activeProgress: -1, thumbnail: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (ResumeEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ResumeEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
    private func load() -> ResumeEntry {
        guard let dir = SharedContainer.url,
              let data = try? Data(contentsOf: dir.appendingPathComponent("widget.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ResumeEntry(date: .now, id: nil, title: nil, progress: nil, downloadsDone: 0, downloadsActive: 0, activeProgress: -1, thumbnail: nil)
        }
        return ResumeEntry(
            date: .now,
            id: json["resumeId"] as? String,
            title: json["resumeTitle"] as? String,
            progress: json["resumeProgress"] as? Double,
            downloadsDone: json["downloadsDone"] as? Int ?? 0,
            downloadsActive: json["downloadsActive"] as? Int ?? 0,
            activeProgress: json["activeProgress"] as? Double ?? -1,
            thumbnail: UIImage(contentsOfFile: dir.appendingPathComponent("resume.jpg").path))
    }
}

struct ResumeWidgetView: View {
    let entry: ResumeEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            } else {
                Color(.secondarySystemBackground)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title ?? "Nothing to resume").font(.subheadline.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(entry.thumbnail == nil ? Color.primary : .white)
                if let progress = entry.progress { ProgressView(value: progress).tint(.red) }
                if entry.downloadsActive > 0 {
                    Label("\(entry.downloadsActive) downloading", systemImage: "arrow.down.circle").font(.caption2).foregroundStyle(.white.opacity(0.85))
                } else if entry.downloadsDone > 0 {
                    Label("\(entry.downloadsDone) offline", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
            }.padding(12)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(entry.id.flatMap { URL(string: "watchtube://video?id=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)") })
    }
}

struct ResumeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlowResume", provider: ResumeProvider()) { ResumeWidgetView(entry: $0) }
            .configurationDisplayName("Continue watching")
            .description("Jump back into your last video and see download status.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if context.state.progress >= 0 { ProgressView(value: context.state.progress) } else { ProgressView() }
                }
                if context.state.count > 1 { Text("\(context.state.count)").font(.caption.bold()) }
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "arrow.down.circle.fill") }
                DynamicIslandExpandedRegion(.center) { Text(context.state.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.progress >= 0 { ProgressView(value: context.state.progress) } else { ProgressView() }
                }
            } compactLeading: { Image(systemName: "arrow.down.circle.fill") }
              compactTrailing: { Text(context.state.progress >= 0 ? "\(Int(context.state.progress * 100))%" : "…") }
              minimal: { Image(systemName: "arrow.down.circle.fill") }
        }
    }
}

@main
struct FlowWidgetsBundle: WidgetBundle {
    var body: some Widget { ResumeWidget(); DownloadLiveActivityWidget() }
}
