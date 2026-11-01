import SwiftUI
import AVFoundation
import AVKit
import Observation

// MARK: - Artwork

/// `VideoArtwork`. `AsyncImage` uses URLCache; swap for Nuke/Kingfisher if
/// you need a larger disk cache or downsampling.
struct ArtworkView: View {
    let video: Video

    var body: some View {
        AsyncImage(url: video.thumbnailURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "play.rectangle").font(.title).foregroundStyle(.tertiary) }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Meta line (video_meta.dart)

struct VideoMetaLine: View {
    let video: Video
    var showDuration = false
    var showDate = false
    var showCategory = false
    var fallbackToCategory = true
    var onDark = false

    private struct Item { let systemImage: String?; let text: String; let tinted: Bool }

    private var items: [Item] {
        var out: [Item] = []
        if showDuration, !video.duration.isEmpty { out.append(Item(systemImage: nil, text: video.duration, tinted: false)) }
        if !video.likes.isEmpty { out.append(Item(systemImage: "hand.thumbsup.fill", text: video.likes, tinted: true)) }
        if !video.views.isEmpty { out.append(Item(systemImage: "eye", text: video.views, tinted: false)) }
        if showDate, !video.date.isEmpty { out.append(Item(systemImage: "calendar", text: video.date, tinted: false)) }
        if !video.category.isEmpty, showCategory || (fallbackToCategory && out.isEmpty) {
            out.append(Item(systemImage: nil, text: video.category, tinted: false))
        }
        return out
    }

    var body: some View {
        let items = items
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Text("•").padding(.horizontal, 6).opacity(0.5) }
                HStack(spacing: 4) {
                    if let symbol = item.systemImage {
                        Image(systemName: symbol)
                            .imageScale(.small)
                            .foregroundStyle(item.tinted ? AnyShapeStyle(Color.vxAccent) : AnyShapeStyle(.secondary))
                    }
                    Text(item.text).lineLimit(1)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(onDark ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }
}

// MARK: - Video card (video_card.dart)

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        Rectangle().fill(.black.opacity(0.5))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle().fill(Color.vxAccent)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

struct VideoCard: View {
    let video: Video
    let onTap: () -> Void

    @Environment(PlaybackProgress.self) private var progress
    @Environment(FavoritesStore.self) private var favorites
    @Environment(PreviewManager.self) private var preview

    var body: some View {
        let completed = progress.isCompleted(video.id)
        let fraction = completed ? nil : progress.fraction(for: video.id)

        VStack(alignment: .leading, spacing: Gaps.sm) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { ArtworkView(video: video) }
                .overlay { if preview.activeID == video.id { PlayerLayerView(player: preview.player).transition(.opacity) } }
                .overlay(alignment: .topLeading) {
                    if completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.vxAccent, in: Circle())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !video.duration.isEmpty {
                        Text(video.duration)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(.trailing, 6).padding(.bottom, fraction == nil ? 6 : 9)
                    }
                }
                .overlay(alignment: .bottom) { if let fraction { ProgressBar(fraction: fraction) } }
                .overlay(alignment: .topTrailing) { FavoriteButton(video: video) }
                .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .animation(.easeOut(duration: 0.2), value: preview.activeID)

            Text(video.title)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
            VideoMetaLine(video: video, showDate: true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            preview.stopNow()
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.35) { preview.request(video) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([video.title, completed ? "watched" : nil,
                             video.duration.isEmpty ? nil : video.duration,
                             video.likes.isEmpty ? nil : "\(video.likes) liked",
                             video.views.isEmpty ? nil : video.views].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: favorites.isFavorite(video.id) ? "Remove from favorites" : "Add to favorites") {
            favorites.toggle(video)
        }
    }
}

private struct FavoriteButton: View {
    let video: Video
    @Environment(FavoritesStore.self) private var favorites

    var body: some View {
        let active = favorites.isFavorite(video.id)
        Button {
            let now = favorites.toggle(video)
            Haptics.play(now ? .medium : .light)
        } label: {
            Image(systemName: active ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.vxAccent : Color.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(active ? 0.8 : 0.45), in: Circle())
                .symbolEffect(.bounce, value: active)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true) // exposed as a custom action on the card
    }
}

// MARK: - Category bar (category_bar.dart)

struct CategoryBar: View {
    let categories: [String]
    let selected: String
    let margin: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Gaps.sm) {
                ForEach(categories, id: \.self) { category in
                    let isSelected = category == selected
                    Button { onSelect(category) } label: {
                        Text(category)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(isSelected ? Color.vxAccent : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, margin)
            .padding(.vertical, 7)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Continue watching (continue_row.dart)

struct ContinueRow: View {
    let margin: CGFloat
    let onPlay: (Video) -> Void

    @Environment(HistoryStore.self) private var history
    @Environment(PlaybackProgress.self) private var progress

    private var videos: [Video] {
        var out: [Video] = []
        for entry in history.items {
            if out.count >= 8 { break }
            let id = entry.video.id
            if progress.isCompleted(id) { continue }
            guard let fraction = progress.fraction(for: id), fraction >= 0.01 else { continue }
            out.append(entry.video)
        }
        return out
    }

    var body: some View {
        let videos = videos
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Continue watching")
                    .font(.headline)
                    .padding(.horizontal, margin)
                    .padding(.vertical, Gaps.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Gaps.md) {
                        ForEach(videos) { video in
                            ContinueCard(video: video, fraction: progress.fraction(for: video.id) ?? 0) {
                                onPlay(video)
                            }
                        }
                    }
                    .padding(.horizontal, margin)
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let video: Video
    let fraction: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Gaps.sm) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ArtworkView(video: video) }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .overlay(alignment: .bottom) { ProgressBar(fraction: fraction) }
                    .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                Text(video.title)
                    .font(.subheadline)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: 168)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .accessibilityLabel("Continue \(video.title)")
    }
}

struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Empty / error (state_views.dart)

struct StatusView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionLabel: String
    let action: () -> Void
    var secondaryLabel: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(actionLabel, action: action).buttonStyle(.borderedProminent)
            if let secondaryLabel, let secondaryAction {
                Button(secondaryLabel, action: secondaryAction).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 380)
    }
}

/// Native `.redacted` replaces the hand-built skeleton blocks.
struct SkeletonGrid: View {
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Gaps.lg) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Gaps.sm) {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .fill(.quaternary)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    Text("Placeholder video title\nsecond line").font(.subheadline)
                    Text("1.2M views").font(.caption)
                }
            }
        }
        .redacted(reason: .placeholder)
        .pulsing()
        .accessibilityLabel("Loading videos")
    }
}

extension View {
    /// `SkeletonPulse`.
    func pulsing() -> some View { modifier(PulseModifier()) }

    /// Lightweight toast; SwiftUI has no built-in one.
    func toast(_ message: Binding<String?>) -> some View { modifier(ToastModifier(message: message)) }
}

private struct PulseModifier: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = message {
                    Text(text)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, Gaps.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: text) {
                            try? await Task.sleep(for: .seconds(2.5))
                            if !Task.isCancelled { message = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: message)
            .onChange(of: message) { _, new in
                if let new { AccessibilityNotification.Announcement(new).post() }
            }
    }
}

// MARK: - Hold-to-preview (preview_manager.dart)

/// One shared, muted, looping AVQueuePlayer reused by whichever card is being
/// previewed: a single decoder and a short forward buffer keep scrolling at
/// 60/120 FPS instead of spinning up a player per card.
@MainActor @Observable
final class PreviewManager {
    static let shared = PreviewManager()

    private(set) var activeID: String?
    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?

    private init() {
        player.isMuted = !AppSettings.shared.previewSound
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = false
    }

    func request(_ video: Video) {
        guard let url = video.previewURL else { return }
        stopNow()
        player.isMuted = !AppSettings.shared.previewSound
        Haptics.play(.light)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        looper = AVPlayerLooper(player: player, templateItem: item)
        activeID = video.id
        player.play()
    }

    func stopNow() {
        guard activeID != nil else { return }
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        activeID = nil
    }
}

/// Bare `AVPlayerLayer` host: no transport controls, so it is cheaper than
/// `VideoPlayer` for inline previews inside a scrolling grid.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.playerLayer.videoGravity = gravity
    }
}
