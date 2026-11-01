import SwiftUI
import AVFoundation
import AVKit
import Observation

// MARK: - Playback source / resolver (playback_source.dart)

struct PlaybackSource {
    let url: String
    let headers: [String: String]
}

/// Native seam implemented by NativeStreamResolver in CatalogRepository.swift.
protocol StreamResolver: Sendable {
    /// `resolvePlaybackSource`: headers (and cookie) for a stream URL.
    func resolveSource(streamURL: URL, pageURL: String?,
                       refresh: Bool, preserveURL: Bool) async throws -> PlaybackSource
    /// `videoRepository.resolveForPlayback`.
    func resolveForPlayback(_ video: Video, refresh: Bool) async throws -> Video
}

// MARK: - Settings (app_settings.dart)

enum AppThemeMode: String, CaseIterable, Codable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults: UserDefaults
    private let themeKey = "themeMode"
    private let autoplayKey = "autoplayNext"
    private let qualityKey = "preferredQuality"
    private let previewKey = "previewSound"
    private let hapticsKey = "haptics"

    private(set) var themeMode: AppThemeMode
    private(set) var autoplayNext: Bool
    private(set) var preferredQuality: Int
    private(set) var previewSound: Bool
    private(set) var haptics: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeMode = AppThemeMode(rawValue: defaults.string(forKey: themeKey) ?? "dark") ?? .dark
        autoplayNext = defaults.object(forKey: autoplayKey) as? Bool ?? true
        preferredQuality = defaults.object(forKey: qualityKey) as? Int ?? 0
        previewSound = defaults.object(forKey: previewKey) as? Bool ?? true
        haptics = defaults.object(forKey: hapticsKey) as? Bool ?? true
    }

    func setThemeMode(_ value: AppThemeMode) { themeMode = value; defaults.set(value.rawValue, forKey: themeKey) }
    func setAutoplayNext(_ value: Bool) { autoplayNext = value; defaults.set(value, forKey: autoplayKey) }
    func setPreferredQuality(_ value: Int) { preferredQuality = value; defaults.set(value, forKey: qualityKey) }
    func setPreviewSound(_ value: Bool) { previewSound = value; defaults.set(value, forKey: previewKey) }
    func setHaptics(_ value: Bool) { haptics = value; defaults.set(value, forKey: hapticsKey) }
}

// MARK: - Mini player session (mini_player.dart)

@MainActor
final class MiniSession {
    let video: Video
    let engine: PlayerEngine
    let url: String
    let headers: [String: String]?
    let isFile: Bool
    let speed: Float
    let queue: [Video]?

    init(video: Video, engine: PlayerEngine, url: String, headers: [String: String]?,
         isFile: Bool, speed: Float, queue: [Video]?) {
        self.video = video; self.engine = engine; self.url = url
        self.headers = headers; self.isFile = isFile; self.speed = speed; self.queue = queue
    }
}

@MainActor @Observable
final class MiniPlayer {
    static let shared = MiniPlayer()
    private(set) var session: MiniSession?

    var isActive: Bool { session != nil }

    func adopt(_ new: MiniSession) {
        session?.engine.teardown()
        session = new
    }

    func release() -> MiniSession? {
        defer { session = nil }
        return session
    }

    func close() {
        session?.engine.teardown()
        session = nil
    }

    func disposeSession(_ s: MiniSession) { s.engine.teardown() }
    // Playback state is surfaced by MiniPlayerBar and persisted by PlaybackProgress.
}

// MARK: - Orientation (platform_ui.dart)

/// Add to your App: `@UIApplicationDelegateAdaptor(AppDelegate.self) var delegate`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

enum AppOrientation {
    nonisolated(unsafe) static var mask: UIInterfaceOrientationMask = .portrait

    /// `applyBrowseOrientation` (portrait) / `applyPlayerOrientation` (landscape or portrait).
    @MainActor static func apply(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    @MainActor static func browse() { apply(.portrait) }
    @MainActor static func player(portrait: Bool) { apply(portrait ? .portrait : .landscape) }
}

// MARK: - Video surface (AVPlayerLayer) and Picture in Picture

/// Gives the view model access to the layer PiP needs.
final class PlayerSurface {
    weak var layer: AVPlayerLayer?
}

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer
    let surface: PlayerSurface

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect // BoxFit.contain on black
        view.playerLayer.player = player
        view.isUserInteractionEnabled = false
        surface.layer = view.playerLayer
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        surface.layer = uiView.playerLayer
    }
}

/// Native PiP via `AVPictureInPictureController` (replaces NativeBridge.startPip).
/// Needs the "Audio, AirPlay, and Picture in Picture" background mode.
/// While PiP runs the session (engine + controller) is parked here; tapping
/// the PiP "restore" button calls `onRestore` so the app can re-present the player.
@MainActor
final class PiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPCoordinator()
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var onRestore: ((MiniSession) -> Void)?
    private var controller: AVPictureInPictureController?
    private var session: MiniSession?
    private var startContinuation: CheckedContinuation<Bool, Never>?

    func start(layer: AVPlayerLayer, session: MiniSession) async -> Bool {
        guard Self.isSupported, let pip = AVPictureInPictureController(playerLayer: layer) else { return false }
        pip.delegate = self
        controller = pip
        self.session = session
        return await withCheckedContinuation { continuation in
            startContinuation = continuation
            pip.startPictureInPicture()
            Task { [weak self] in // fail-safe if the system never answers
                try? await Task.sleep(for: .seconds(2))
                self?.finishStart(false)
            }
        }
    }

    private func finishStart(_ started: Bool) {
        startContinuation?.resume(returning: started)
        startContinuation = nil
        if !started, session != nil, controller?.isPictureInPictureActive != true {
            controller = nil
            session = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { finishStart(true) }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { finishStart(false) }
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            if let s = session {
                session = nil // hand ownership back to the restored player
                onRestore?(s)
            }
            completion(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            session?.engine.teardown() // closed from the PiP window: release the player
            session = nil
            controller = nil
        }
    }
}

// MARK: - Launching (playback_launcher.dart)

struct PlaybackLaunchError: LocalizedError {
    let errorDescription: String?
    static let noLink = PlaybackLaunchError(errorDescription: "No playable link was found for this video.")
}

/// MIGRATION NOTE: `launchPlayer` pushed a route and returned an error string.
/// Here it only *prepares* a `PlayerRoute` (stops preview, closes the mini
/// player, resolves the stream); presenting is `fullScreenCover(item:)`.
@MainActor
struct DefaultPlaybackLauncher: PlaybackLauncher {
    let resolver: StreamResolver
    let downloads: DownloadStore

    func prepare(_ video: Video, startAt: TimeInterval?, queue: [Video],
                 source: PlaybackSource?) async throws -> PlayerRoute {
        PreviewManager.shared.stopNow()
        MiniPlayer.shared.close()
        do {
            let local = downloads.localPath(for: video.id)?.path
            var playable = video
            var preparedSource = source

            if local == nil, preparedSource == nil {
                if let directURL = directStreamURL(for: video) {
                    // Preserve a supplied direct stream. AVPlayer receives the
                    // resolved provider headers through PlaybackSource below.
                    var resolved = try await resolver.resolveSource(
                        streamURL: directURL,
                        pageURL: video.pageURL?.absoluteString,
                        refresh: false,
                        preserveURL: true
                    )
                    if let customHeaders = video.streamHeaders, !customHeaders.isEmpty {
                        let fields = customHeaders.reduce(into: [String: String]()) {
                            $0[$1.name] = $1.value
                        }
                        let merged = (resolved.headers ?? [:]).merging(fields) { _, custom in custom }
                        resolved = PlaybackSource(url: resolved.url, headers: merged)
                    }
                    preparedSource = resolved
                } else {
                    // Listing thumbnails and preview clips are never promoted to playback.
                    var bare = video
                    bare.streamURL = ""
                    playable = try await resolver.resolveForPlayback(bare, refresh: false)
                }
            }

            guard local != nil || preparedSource != nil ||
                    !playable.streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlaybackLaunchError.noLink
            }
            return PlayerRoute(video: playable, startAt: startAt, queue: queue,
                               localPath: local, initialSource: local == nil ? preparedSource : nil, adopted: nil)
        } catch let error as PlaybackLaunchError {
            throw error
        } catch {
            let friendly = describeError(error, subject: "this video")
            throw PlaybackLaunchError(errorDescription: friendly.offline
                ? "No connection. Check the network and try again."
                : "Couldn’t prepare this video. Please try again.")
        }
    }

    private func directStreamURL(for video: Video) -> URL? {
        let raw = video.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              raw != video.previewURL?.absoluteString,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              !["jpg", "jpeg", "png", "gif", "webp", "svg", "html", "htm"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    /// Reopening a session from the mini player / PiP.
    static func route(adopting session: MiniSession, queue: [Video]? = nil) -> PlayerRoute {
        PlayerRoute(video: session.video, startAt: nil, queue: queue ?? session.queue,
                    localPath: session.isFile ? session.url : nil, initialSource: nil, adopted: session)
    }
}
