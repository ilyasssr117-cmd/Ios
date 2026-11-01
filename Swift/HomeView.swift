import SwiftUI
import Observation

// MARK: - Router

enum AppTab: Hashable, CaseIterable {
    case home, search, reels, library, settings
}

enum AppSection: Int, Hashable, CaseIterable {
    case home, library, settings
}

enum LibrarySegment: String, Hashable, CaseIterable { case downloads, favorites, history, models, albums }

struct LibraryRequest: Equatable { let segment: LibrarySegment; let token: Int }
struct DetailsRoute: Hashable { let video: Video; let queue: [Video] }

/// Coordinates the three swipeable root sections and the two modal destinations.
@MainActor @Observable
final class AppRouter {
    var selection: AppTab = .home
    var section: AppSection = .home
    var isSearchPresented = false
    var isReelsPresented = false
    var libraryRequest: LibraryRequest?
    var path: [DetailsRoute] = []
    var selectedModel: ModelRef?
    private var token = 0

    func select(_ tab: AppTab) {
        switch tab {
        case .home:
            section = .home
            selection = .home
        case .search:
            selection = .search
            isSearchPresented = true
        case .reels:
            selection = .reels
            isReelsPresented = true
        case .library:
            section = .library
            selection = .library
        case .settings:
            section = .settings
            selection = .settings
        }
    }

    func restoreDockSelection() {
        switch section {
        case .home: selection = .home
        case .library: selection = .library
        case .settings: selection = .settings
        }
    }

    func sectionDidChange(_ section: AppSection) {
        self.section = section
        switch section {
        case .home: selection = .home
        case .library: selection = .library
        case .settings: selection = .settings
        }
    }

    func showDownloads() {
        token += 1
        libraryRequest = LibraryRequest(segment: .downloads, token: token)
        select(.library)
    }
}

// MARK: - Root

/// Keeps the original Flutter information architecture:
/// - Home, Library and Settings are horizontally swipeable root sections.
/// - Search is presented as a large draggable sheet; Reels remains an immersive full-screen destination.
/// - The compact floating glass bar uses native-feeling selection indicators and haptics.
/// Native TabView paging replaces the manually animated Flutter section stack.
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

        NavigationStack(path: $router.path) {
            TabView(selection: $router.section) {
                HomeScreen(vm: vm, onOpen: openDetails)
                    .tag(AppSection.home)

                LibraryView(request: router.libraryRequest, dependencies: deps,
                            onOpen: openDetails,
                            onBrowse: { router.select(.home) })
                    .tag(AppSection.library)

                SettingsView()
                    .tag(AppSection.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Keeps scroll content clear of the floating glass dock.
                Color.clear.frame(height: 78).accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                GlassTabBar(selection: $router.selection, onSelect: { tab in
                    PreviewManager.shared.stopNow()
                    router.select(tab)
                })
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .opacity(router.isSearchPresented || router.isReelsPresented ? 0 : 1)
                .allowsHitTesting(!router.isSearchPresented && !router.isReelsPresented)
                .animation(.spring(response: 0.34, dampingFraction: 0.84),
                           value: router.selection)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DetailsRoute.self) { route in
                VideoDetailsView(video: route.video, queue: route.queue,
                                 dependencies: deps, onOpenRelated: openDetails,
                                 onOpenModel: { router.selectedModel = $0 },
                                 onPlay: { vm.playerRoute = $0 })
            }
        }
        // Search uses a native draggable sheet instead of a rigid full-screen route.
        .sheet(isPresented: $router.isSearchPresented, onDismiss: {
            router.restoreDockSelection()
        }) {
            NavigationStack {
                SearchScreen(dependencies: deps, onOpen: openDetailsFromSearch, onClose: {
                    router.isSearchPresented = false
                })
                .toolbar(.hidden, for: .navigationBar)
            }
            .tint(.vxAccent)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
            .presentationContentInteraction(.scrolls)
        }
        .fullScreenCover(isPresented: $router.isReelsPresented, onDismiss: {
            router.restoreDockSelection()
        }) {
            ReelsView(dependencies: deps, isActive: true, onExit: {
                router.isReelsPresented = false
            })
        }
        .fullScreenCover(item: $vm.playerRoute) { PlayerScreen(route: $0, dependencies: deps) }
        .sheet(item: $router.selectedModel) { model in
            ModelBrowserView(model: model, dependencies: deps, onOpen: openDetails)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationContentInteraction(.scrolls)
        }
        .overlay(alignment: .bottom) {
            if !router.isSearchPresented, !router.isReelsPresented,
               MiniPlayer.shared.session != nil {
                MiniPlayerBar {
                    if let session = MiniPlayer.shared.release() {
                        vm.playerRoute = DefaultPlaybackLauncher.route(adopting: session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: router.section) { _, section in
            PreviewManager.shared.stopNow()
            router.sectionDidChange(section)
        }
        .onAppear {
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
            PreviewManager.shared.stopNow()
            router.path.append(DetailsRoute(video: video, queue: queue))
        }
    }

    private func openDetailsFromSearch(_ video: Video, queue: [Video]) {
        router.isSearchPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            if video.isSavedReel {
                await vm.openSavedReel(video)
            } else {
                router.path.append(DetailsRoute(video: video, queue: queue))
            }
        }
    }
}

// MARK: - Floating glass navigation

private struct GlassTabBar: View {
    @Binding var selection: AppTab
    let onSelect: (AppTab) -> Void
    @Namespace private var selectionMotion

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        let symbol: String
        var id: AppTab { tab }
    }

    private let items: [Item] = [
        Item(tab: .home, title: "Home", symbol: "house"),
        Item(tab: .search, title: "Search", symbol: "magnifyingglass"),
        Item(tab: .reels, title: "Reels", symbol: "play.rectangle"),
        Item(tab: .library, title: "Library", symbol: "square.stack"),
        Item(tab: .settings, title: "Settings", symbol: "slider.horizontal.3")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let active = selection == item.tab
                Button {
                    Haptics.play(.selection)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selection = item.tab
                    }
                    onSelect(item.tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(active ? Color.vxAccent : Color.secondary)
                            .frame(height: 22)
                        Circle()
                            .fill(active ? Color.vxAccent : Color.clear)
                            .frame(width: 4, height: 4)
                        Text(item.title)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 25, style: .continuous)
                                .fill(.white.opacity(0.13))
                                .matchedGeometryEffect(id: "telegram-tab-selection", in: selectionMotion)
                                .padding(.horizontal, 2)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 31, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 9)
        .frame(height: 76)
        .accessibilityElement(children: .contain)
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
            .containerRelativeFrame(.vertical) { height, _ in min(height * 0.44, 410) }
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
                                .init(color: Color(red: 0.05, green: 0.06, blue: 0.13).opacity(0.88), location: 1)],
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
        // Native material keeps the brand mark legible while preserving the
        // live artwork underneath, instead of using a flat translucent fill.
        HStack(spacing: 9) {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Color.vxSocialGradient,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text("VXTUBE")
                .font(.footnote.weight(.black))
                .tracking(1.8)
                .foregroundStyle(.white)
            Circle().fill(Color.vxAccent).frame(width: 5, height: 5)
        }
        .padding(.leading, 7).padding(.trailing, 13).padding(.vertical, 7)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(Color.black.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
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
                .font(.system(.title2, design: .rounded).weight(.bold))
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
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 17).frame(height: 44)
                .background(Color.vxSocialGradient, in: Capsule(style: .continuous))
                .shadow(color: Color.vxAccent.opacity(0.28), radius: 12, y: 5)
                .disabled(playBusy)

                Button(action: onDetails) { Label("Details", systemImage: "arrow.up.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.8) )
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 16))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
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
