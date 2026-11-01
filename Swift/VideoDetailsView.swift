import SwiftUI

/// MIGRATION NOTES
/// - `CustomScrollView` + `SliverPersistentHeader(pinned:)` becomes a
///   `ScrollView` with `LazyVStack(pinnedViews: .sectionHeaders)`; the models
///   row is the section header, so it pins under the navigation bar for free.
/// - The custom `PageBackButton` is the system back button (transparent bar
///   over the hero, material once scrolled), which keeps the edge-swipe back.
/// - `Navigator.pushReplacement` for related videos is handled by `HomeView`
///   swapping the route (`.id(route)` gives the new page fresh state).
/// - Hero blur: `ImageFiltered` -> `.blur`, the two `ShaderMask`s -> two
///   gradient `.mask`s; the blurred copy is rasterized once (`drawingGroup`).
struct VideoDetailsView: View {
    @State private var vm: DetailsViewModel
    private let onOpenRelated: (Video, [Video]) -> Void
    private let onOpenModel: (ModelRef) -> Void

    @Environment(FavoritesStore.self) private var favorites
    @Environment(DownloadStore.self) private var downloads
    @Environment(PlaybackProgress.self) private var progress
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pull = HeroPull()
    @State private var overHeader = true
    @State private var headerHeight: CGFloat = 320
    @State private var confirmDelete = false
    @State private var shareFile: ShareFile?

    init(video: Video, queue: [Video]?, dependencies: AppDependencies,
         onOpenRelated: @escaping (Video, [Video]) -> Void,
         onOpenModel: @escaping (ModelRef) -> Void,
         onPlay: @escaping (PlayerRoute) -> Void) {
        _vm = State(initialValue: DetailsViewModel(video: video, queue: queue,
                                                   dependencies: dependencies, onPlayerRoute: onPlay))
        self.onOpenRelated = onOpenRelated
        self.onOpenModel = onOpenModel
    }

    private var margin: CGFloat { sizeClass == .regular ? 24 : 16 }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Gaps.md, alignment: .top), count: sizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        @Bindable var vm = vm

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                DetailsHeroStretch(pull: pull) { header }

                Section {
                    relatedTitle
                    relatedContent
                } header: {
                    if !vm.models.isEmpty || vm.modelsFailed { modelsBar }
                }
            }
            .padding(.bottom, Gaps.xl)
        }
        .ignoresSafeArea(edges: .top) // hero artwork runs under the status bar
        .background(Color(.systemBackground))
        .refreshable { await vm.refresh() }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pull.amount = max(0, -offset)
            let over = offset < headerHeight - 60
            if over != overHeader { overHeader = over }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(overHeader ? .hidden : .automatic, for: .navigationBar)
        .toolbarColorScheme(overHeader ? .dark : nil, for: .navigationBar)
        .toast($vm.toast)
        .confirmationDialog("Delete this download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await downloads.remove(vm.video.id) } }
        } message: {
            Text("The video will be removed from your phone.")
        }
        .sheet(item: $shareFile) { file in
            ActivityShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .task { vm.start() }
    }

    // MARK: Header

    private var header: some View {
        let video = vm.video
        let resume = vm.resumePosition

        return VStack(alignment: .leading, spacing: 0) {
            if !video.category.isEmpty {
                Text(video.category.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .padding(.bottom, 6)
            }

            ExpandableTitle(text: video.title)

            if hasMeta(video) {
                VideoMetaLine(video: video, showDuration: true, showDate: true,
                              fallbackToCategory: false, onDark: true)
                    .padding(.top, Gaps.sm)
            }

            if !video.description.isEmpty {
                Text(video.description)
                    .font(.footnote)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .foregroundStyle(Color(red: 0.84, green: 0.85, blue: 0.89))
                    .padding(.top, Gaps.sm)
            }

            FlowLayout(spacing: Gaps.sm) {
                Button {
                    Task { await vm.play() }
                } label: {
                    if vm.preparing {
                        ProgressView().tint(.white)
                    } else {
                        Label(resume.map { "Resume \(formatPlayerTime($0))" } ?? "Play", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent).tint(.vxAccent)
                .disabled(vm.preparing)

                if resume != nil {
                    Button { Task { await vm.play(fromStart: true) } } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered).tint(.white)
                }

                favoriteButton
                downloadButtons

                if vm.shareLink != nil {
                    Button { vm.copyLink() } label: { Label("Copy link", systemImage: "link") }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .padding(.top, Gaps.md)

            if let error = vm.playError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                    .padding(.top, Gaps.sm)
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, margin)
        .padding(.top, Gaps.xxl + Gaps.lg)
        .padding(.bottom, Gaps.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: headerHeight, alignment: .bottomLeading)
        .background { heroArtwork(video).ignoresSafeArea(edges: .top) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Radii.hero, bottomTrailingRadius: Radii.hero,
                                          style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = max($0, 200) }
    }

    private func hasMeta(_ v: Video) -> Bool {
        !v.duration.isEmpty || !v.likes.isEmpty || !v.views.isEmpty || !v.date.isEmpty
    }

    /// Blurred copy fills the panel; the sharp copy fades into it at the
    /// sides and toward the bottom (the two ShaderMasks), under a dark scrim.
    private func heroArtwork(_ video: Video) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            ArtworkView(video: video)
                .blur(radius: 30)
                .drawingGroup()
            ArtworkView(video: video)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.075),
                                             .init(color: .black, location: 0.925),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: 0.44),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            LinearGradient(stops: [
                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.24), location: 0),
                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.15), location: 0.24),
                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.54), location: 0.58),
                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.95), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    // MARK: Actions

    private var favoriteButton: some View {
        let active = favorites.isFavorite(vm.video.id)
        return Button {
            let now = favorites.toggle(vm.video)
            Haptics.play(now ? .medium : .light)
        } label: {
            Label(active ? "Favorited" : "Favorite", systemImage: active ? "star.fill" : "star")
                .symbolRenderingMode(.palette)
                .foregroundStyle(active ? Color.yellow : Color.white, .white)
        }
        .buttonStyle(.bordered).tint(.white)
        .sensoryFeedback(.selection, trigger: active)
    }

    @ViewBuilder private var downloadButtons: some View {
        let id = vm.video.id
        if let item = downloads.item(for: id) {
            switch item.status {
            case .done:
                Button { confirmDelete = true } label: {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.vxAccent)
                }
                .buttonStyle(.bordered).tint(.white)
                Button {
                    Task { await saveToPhotos(id) }
                } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.bordered).tint(.white)
            case .downloading, .queued:
                let fraction = item.progress
                Button { Task { await downloads.pause(id) } } label: {
                    Label(item.status == .queued ? "Waiting…" : (fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Downloading…"),
                          systemImage: "pause.fill")
                }
                .buttonStyle(.bordered).tint(.white)
            case .paused, .failed:
                let percent = item.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                Button { downloads.resume(id) } label: {
                    Label(item.hasPartial ? "Resume\(percent)" : "Retry download", systemImage: "play.fill")
                }
                .buttonStyle(.bordered).tint(.white)
            }
        } else {
            Button {
                _ = downloads.enqueue(vm.video)
                vm.toast = "Download started"
            } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).tint(.white)
        }
    }

    /// save_video_to_photos.dart: Photos first, share sheet as fallback.
    private func saveToPhotos(_ id: String) async {
        vm.toast = "Saving to Photos…"
        switch await downloads.saveToPhotos(id) {
        case .denied: vm.toast = "Allow access to Photos in Settings to save videos."
        case .saved: vm.toast = "Saved to Photos."
        case .failed:
            if let file = downloads.localPath(for: id) {
                shareFile = ShareFile(url: file)
                vm.toast = "Choose an app to share the downloaded video."
            } else {
                vm.toast = "Couldn’t save or share the video."
            }
        }
    }

    // MARK: Models bar (pinned)

    private var modelsBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !vm.models.isEmpty {
                if overHeader {
                    Text(vm.models.count == 1 ? "MODEL" : "MODELS")
                        .font(.caption2.weight(.semibold)).tracking(0.7)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Gaps.sm) {
                        ForEach(vm.models) { model in
                            ModelChip(model: model) { onOpenModel(model) }
                        }
                    }
                }
                .frame(height: 36)
            } else {
                HStack {
                    Text("Couldn’t load model information.").font(.subheadline)
                    Spacer()
                    Button { vm.reloadModels() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, margin)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    // MARK: Related

    @ViewBuilder private var relatedTitle: some View {
        switch vm.related {
        case .loaded(let list) where list.isEmpty:
            EmptyView()
        default:
            Text("More like this")
                .font(.headline)
                .padding(.horizontal, margin)
                .padding(.vertical, Gaps.md)
        }
    }

    @ViewBuilder private var relatedContent: some View {
        switch vm.related {
        case .loading:
            SkeletonGrid(columns: columns).padding(.horizontal, margin)
        case .failed:
            HStack {
                Text("Couldn’t load related videos.").font(.body)
                Spacer()
                Button { vm.reloadRelated() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, margin)
        case .loaded(let list):
            LazyVGrid(columns: columns, spacing: Gaps.lg) {
                ForEach(list) { video in
                    VideoCard(video: video) { onOpenRelated(video, list) }
                }
            }
            .padding(.horizontal, margin)
        }
    }
}

// MARK: - Pieces

@MainActor @Observable
private final class HeroPull { var amount: CGFloat = 0 }

/// Scale-on-pull; only this wrapper re-renders while pulling.
private struct DetailsHeroStretch<Content: View>: View {
    let pull: HeroPull
    @ViewBuilder let content: Content
    var body: some View {
        content.scaleEffect(1 + min(pull.amount, 120) / 2400, anchor: .bottom)
    }
}

/// Collapsed to 3 lines; tap to expand (expandable_text.dart).
private struct ExpandableTitle: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.system(size: 23, weight: .semibold))
            .lineSpacing(1)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 6)
            .lineLimit(expanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Collapse title" : "Expand title")
    }
}

private struct ModelChip: View {
    let model: ModelRef
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.selection)
            action()
        } label: {
            HStack(spacing: 8) {
                ModelAvatar(name: model.name, imageURL: model.imageURL, pageURL: model.url, size: 25)
                Text(model.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: 36)
            .background(Color(.secondarySystemFill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator)))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .accessibilityLabel("Model \(model.name)")
    }
}

/// `Wrap(spacing:runSpacing:)`: lays children out left-to-right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
