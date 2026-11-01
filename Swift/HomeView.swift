import SwiftUI
import Observation

// MARK: - Router

enum AppTab: Hashable { case home, search, reels, library, settings }
enum LibrarySegment: String, Hashable, CaseIterable { case downloads, favorites, history, models, albums }

struct LibraryRequest: Equatable { let segment: LibrarySegment; let token: Int }
struct DetailsRoute: Hashable { let video: Video; let queue: [Video] }

/// Replaces `_section`, `_libraryRequest` and the manual route pushes.
@MainActor @Observable
final class AppRouter {
    var selection: AppTab = .home
    var libraryRequest: LibraryRequest?
    var details: DetailsRoute?
    var selectedModel: ModelRef?
    private var token = 0

    func showDownloads() {
        token += 1
        libraryRequest = LibraryRequest(segment: .downloads, token: token)
        selection = .library
    }
}

// MARK: - Root

/// MIGRATION NOTES (architecture)
/// - Flutter's hand-built section pager (Stack + drag gestures + settle
///   AnimationController + RidingTabBar) is replaced by the native `TabView`,
///   which provides the HIG tab bar, state retention and lazy tab creation.
///   The swipe-between-sections gesture is intentionally dropped (it fights
///   native back-swipe and scroll gestures); the tab bar is the navigation.
/// - The root `NavigationStack` wraps the `TabView`, so pushed details cover
///   the tab bar exactly like `Navigator.push` over HomePage did.
/// - Search is a tab, not an overlay; Android-style PopScope/back handling
///   is gone (iOS back is the edge swipe / nav bar).
struct HomeView: View {
    @State private var vm: HomeViewModel
    @State private var router = AppRouter()
    private let deps: AppDependencies

    init(dependencies: AppDependencies) {
        deps = dependencies
        _vm = State(initialValue: HomeViewModel(dependencies: dependencies))
    }

    var body: some View {
        @Bindable var vm = vm
        @Bindable var router = router

        NavigationStack {
            TabView(selection: $router.selection) {
                HomeScreen(vm: vm, onOpen: openDetails)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(AppTab.home)

                SearchScreen(dependencies: deps, onOpen: openDetails)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)

                ReelsView(dependencies: deps,
                          isActive: router.selection == .reels,
                          onExit: { router.selection = .home })
                    .toolbar(.hidden, for: .tabBar) // full-bleed reels, like the faded dock
                    .tabItem { Label("Reels", systemImage: "play.rectangle.on.rectangle.fill") }
                    .tag(AppTab.reels)

                LibraryView(request: router.libraryRequest, dependencies: deps,
                            onOpen: openDetails,
                            onBrowse: { router.selection = .home })
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                    .tag(AppTab.library)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $router.details) { route in
                VideoDetailsView(video: route.video, queue: route.queue, dependencies: deps, onOpenRelated: openDetails, onOpenModel: { router.selectedModel = $0 }, onPlay: { vm.playerRoute = $0 })
            }
        }
        .fullScreenCover(item: $vm.playerRoute) { PlayerScreen(route: $0, dependencies: deps) }
        .sheet(item: $router.selectedModel) { model in ModelBrowserView(model: model, dependencies: deps, onOpen: openDetails) }
        .overlay(alignment: .bottom) {
            if router.selection != .reels, MiniPlayer.shared.session != nil {
                MiniPlayerBar {
                    if let session = MiniPlayer.shared.release() {
                        vm.playerRoute = DefaultPlaybackLauncher.route(adopting: session)
                    }
                }
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: router.selection) { PreviewManager.shared.stopNow() }
        .onAppear {
            // Tapping "restore" in the PiP window re-presents the live player.
            PiPCoordinator.shared.onRestore = { session in
                vm.playerRoute = DefaultPlaybackLauncher.route(adopting: session)
            }
        }
        .environment(router)
        .environment(deps.progress)
        .environment(deps.favorites)
        .environment(deps.history)
        .environment(deps.downloads)
        .environment(PreviewManager.shared)
    }

    private func openDetails(_ video: Video, queue: [Video]) {
        if video.isSavedReel {
            Task { await vm.openSavedReel(video) }
        } else {
            router.details = DetailsRoute(video: video, queue: queue)
        }
    }
}

// MARK: - Home screen

/// Tracks pull-to-stretch. Kept in its own observable so only `HeroStretch`
/// re-renders while pulling (the ListenableBuilder/RepaintBoundary trick).
@MainActor @Observable
private final class PullState { var amount: CGFloat = 0 }

struct HomeScreen: View {
    @Bindable var vm: HomeViewModel
    let onOpen: (Video, [Video]) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(PreviewManager.self) private var preview
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var pull = PullState()

    private var margin: CGFloat { sizeClass == .regular ? 24 : 16 }
    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2 // videoGridColumns()
        return Array(repeating: GridItem(.flexible(), spacing: Gaps.md, alignment: .top), count: count)
    }

    var body: some View {
        // `CustomScrollView` + slivers -> ScrollView + LazyVStack. The safe-area
        // top/bottom insets (status bar, tab bar) are handled by the system, so
        // the manual `safe.top` / `kBottomBarHeight` paddings are gone.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HeroStretch(pull: pull) {
                    HomeHeroView(
                        video: vm.featured,
                        isLoading: vm.videos.isEmpty && vm.isLoading,
                        playLabel: vm.resumeAvailable ? "Resume" : "Play",
                        playBusy: vm.isPlayingFeatured,
                        margin: margin,
                        onPlay: { Task { await vm.playFeatured() } },
                        onDetails: {
                            if let featured = vm.featured { onOpen(featured, vm.videos) }
                        }
                    )
                }

                ContinueRow(margin: margin) { video in Task { await vm.resume(video) } }

                if vm.categories.count > 1 {
                    CategoryBar(categories: vm.categories, selected: vm.category,
                                margin: margin, onSelect: vm.changeCategory)
                        .padding(.top, Gaps.xs)
                }

                Text(vm.category == "All" ? "Latest videos" : vm.category)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, margin)
                    .padding(.vertical, Gaps.md)

                content
            }
            .padding(.bottom, Gaps.xl)
        }
        .refreshable { await vm.refresh() }          // RefreshIndicator -> native
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            max(0, -(geo.contentOffset.y + geo.contentInsets.top))
        } action: { _, newValue in
            pull.amount = newValue
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { preview.stopNow() }
        }
        .background(Color(.systemBackground))
        .toast($vm.toast)
        .task { vm.startIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.probeConnection() } }
        }
    }

    // MARK: Content states (_contentSlivers)

    @ViewBuilder private var content: some View {
        if vm.videos.isEmpty && vm.isLoading {
            SkeletonGrid(columns: columns).padding(.horizontal, margin)
        } else if vm.videos.isEmpty, let error = vm.error {
            StatusView(
                systemImage: error.systemImage, title: error.title, message: error.message,
                actionLabel: "Retry", action: { Task { await vm.loadPage(reset: true) } },
                secondaryLabel: error.offline && vm.hasCompletedDownloads ? "Open downloads" : nil,
                secondaryAction: router.showDownloads
            )
        } else if vm.videos.isEmpty {
            StatusView(
                systemImage: "video.slash", title: "No videos found",
                message: vm.category == "All"
                    ? "There is nothing to show right now."
                    : "There are no videos in “\(vm.category)” yet.",
                actionLabel: "Refresh", action: { Task { await vm.loadPage(reset: true) } }
            )
        } else {
            LazyVGrid(columns: columns, spacing: Gaps.lg) {
                ForEach(vm.gridVideos) { video in
                    VideoCard(video: video) { onOpen(video, vm.videos) }
                        .onAppear { vm.loadMoreIfNeeded(current: video) }
                }
            }
            .padding(.horizontal, margin)

            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Gaps.lg)
            }
            if vm.error != nil {
                Button {
                    Task { await vm.loadPage() }
                } label: {
                    Label("Couldn’t load more – Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.top, Gaps.lg)
            }
        }
    }
}

/// Scales the featured card slightly while pulled past the top.
private struct HeroStretch<Content: View>: View {
    let pull: PullState
    @ViewBuilder let content: Content

    var body: some View {
        content.scaleEffect(1 + min(pull.amount, 120) / 2400, anchor: .bottom)
    }
}

// MARK: - Hero (home_hero.dart)

struct HomeHeroView: View {
    let video: Video?
    let isLoading: Bool
    let playLabel: String
    let playBusy: Bool
    let margin: CGFloat
    let onPlay: () -> Void
    let onDetails: () -> Void

    var body: some View {
        Group {
            if video == nil && !isLoading {
                HeroTopBar().padding(.horizontal, margin).padding(.bottom, Gaps.md)
            } else {
                hero.padding(.horizontal, margin).padding(.bottom, Gaps.sm)
            }
        }
        .padding(.top, Gaps.sm)
    }

    private var hero: some View {
        Color.clear
            .containerRelativeFrame(.vertical) { height, _ in min(height * 0.48, 450) }
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if let video {
                        ArtworkView(video: video)
                    } else {
                        LinearGradient(colors: [Color(red: 0.19, green: 0.18, blue: 0.44),
                                                Color(red: 0.05, green: 0.06, blue: 0.13)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    LinearGradient(
                        stops: [.init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.30), location: 0),
                                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.03), location: 0.35),
                                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.95), location: 1)],
                        startPoint: .top, endPoint: .bottom)

                    HeroTopBar()
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Group {
                        if let video {
                            HeroDetails(video: video, playLabel: playLabel, playBusy: playBusy,
                                        onPlay: onPlay, onDetails: onDetails)
                                .id(video.id)
                        } else {
                            HeroSkeleton()
                        }
                    }
                    .padding(18)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.32), value: video?.id)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radii.hero, style: .continuous))
            .environment(\.colorScheme, .dark) // hero is always on a dark scrim
    }
}

private struct HeroTopBar: View {
    var body: some View {
        // Plain translucent pill (no blur) as in the original, to keep
        // scrolling and pull-to-refresh cheap over the hero image.
        HStack(spacing: 9) {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(colors: [.vxAccent, Color(red: 0.41, green: 0.46, blue: 0.96)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text("VXTUBE")
                .font(.footnote.weight(.black))
                .tracking(1.8)
                .foregroundStyle(.white)
            Circle().fill(Color.vxAccent).frame(width: 5, height: 5)
        }
        .padding(.leading, 7).padding(.trailing, 13).padding(.vertical, 7)
        .background(Color(red: 0.08, green: 0.10, blue: 0.19).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.white.opacity(0.16)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VXTUBE")
    }
}

private struct HeroDetails: View {
    let video: Video
    let playLabel: String
    let playBusy: Bool
    let onPlay: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gaps.sm) {
            HStack(spacing: 7) {
                Circle().fill(Color.vxAccent).frame(width: 6, height: 6)
                Text("FEATURED")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(Color.vxAccent)
            }
            Text(video.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 9, y: 3)
            VideoMetaLine(video: video, showDuration: true, showCategory: true, onDark: true)
                .padding(.bottom, Gaps.sm)

            HStack(spacing: Gaps.sm) {
                Button(action: onPlay) {
                    if playBusy { ProgressView().tint(.white) }
                    else { Label(playLabel, systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.vxAccent)
                .disabled(playBusy)

                Button(action: onDetails) { Label("Details", systemImage: "info.circle") }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 16))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeroSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gaps.sm) {
            Text("FEATURED").font(.caption2)
            Text("Loading the featured video title here").font(.title2.weight(.semibold))
            Text("Play")
                .font(.headline).padding(.horizontal, 28).padding(.vertical, 12)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
        }
        .foregroundStyle(.white)
        .redacted(reason: .placeholder)
        .pulsing()
        .accessibilityLabel("Loading featured video")
    }
}
