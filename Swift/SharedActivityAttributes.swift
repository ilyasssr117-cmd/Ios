import Foundation
import ActivityKit

/// Shared between the app target and the widget extension (add this file to BOTH targets).
/// Replaces the Flutter `liveUpdate` / `liveEnd` native-channel payloads.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        /// 0...1, or -1 when the total size is unknown (indeterminate).
        var progress: Double
        var count: Int
        var finished: Bool
    }
    var name: String = "Downloads"
}

/// App Group used to hand data to the widget extension (`widgetContainer` in the Flutter bridge).
/// Set `APP_GROUP_ID` in Info.plist, or it falls back to `group.<bundle id>`.
enum SharedContainer {
    static var groupID: String {
        if let id = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_ID") as? String, !id.isEmpty { return id }
        var bundle = Bundle.main.bundleIdentifier ?? "app.flow"
        // The widget extension's id is "<app id>.<suffix>"; strip it so both targets agree.
        if Bundle.main.bundleURL.pathExtension == "appex", let dot = bundle.lastIndex(of: ".") { bundle = String(bundle[..<dot]) }
        return "group.\(bundle)"
    }
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
}
