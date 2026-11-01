import SwiftUI
import AVFoundation

// MARK: - Screen

/// MIGRATION NOTES
/// - Flutter `PageView.builder(scrollDirection: .vertical)` becomes a paging
///   `ScrollView` + `LazyVStack` with `scrollTargetBehavior(.paging)` and
///   `scrollPosition(id:)`: native snapping/bounce at 120 Hz.
/// - The raw-pointer `Listener` state machine (timers for tap / double-tap /
///   long-press) is replaced by SwiftUI gestures: `SpatialTapGesture(count: 2)`
///   exclusive-before `TapGesture`, plus `LongPressGesture` for the 2x hold.
/// - `CupertinoActionSheet` -> `confirmationDialog`; `ValueListenableBuilder`
///   and `ListenableBuilder` -> `@Observable` reads.
/// - The tab bar is hidden for Reels, so a back chevron was added to the top
///   bar (the Flutter app left via its swipe pager, which no longer exists).
struct ReelsView: View {
    @State private var vm: ReelsViewModel
    @State private var controlsHidden = false
    @State private var autoHideTask: Task<Void, Never>?
    let isActive: Bool
    let onExit: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    init(dependencies: AppDependencies, isActive: Bool, onExit: @escaping () -> Void) {
        _vm = State(initialValue: ReelsViewModel(dependencies: dependencies))
        self.isActive = isActive
        self.onExit = onExit
    }

    var body: some View {
        @Bindable var vm = vm

        GeometryReader { root in
            let insets = root.safeAreaInsets
            // The canvas intentionally extends behind system chrome. GeometryReader
            // can therefore report zero insets on some devices; reserve explicit
            // status-bar/home-indicator space so top actions never sit under the notch.
            let top = max(insets.top, 64)
            let bottom = max(insets.bottom, 26) + 6

            ZStack {
                Color.black
                content(topInset: top, bottom: bottom)
                scrims(top: top, bottom: bottom)

                if let message = vm.errorMessage, !vm.items.isEmpty {
                    ReelsErrorCard(message: message) { vm.loadMore() }
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottom + 70)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                ReelsTopBar(clear: vm.isClear, isMuted: vm.isMuted,
                            onBack: onExit, onToggleMute: vm.toggleMute,
                            onToggleClear: vm.toggleClear)
                    .padding(.top, top + 8)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(vm.isClear || controlsHidden ? 0 : 1)
                    .allowsHitTesting(!vm.isClear && !controlsHidden)
                    .animation(.easeOut(duration: 0.22), value: controlsHidden)
                    .zIndex(20)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .toast($vm.toast)
        .confirmationDialog(
            "Save video",
            isPresented: Binding(get: { vm.saveMenuItem != nil },
                                 set: { if !$0 { vm.saveMenuItem = nil } }),
            titleVisibility: .hidden,
            presenting: vm.saveMenuItem
        ) { item in
            Button("Download to app") { vm.download(item) }
            Button("Save to Photos") { Task { await vm.saveToPhotos(item) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { vm.start() }
        .onAppear { vm.setActive(isActive) }
        .onChange(of: isActive) { _, active in vm.setActive(active) }
        .onChange(of: scenePhase) { _, phase in vm.scenePhaseChanged(phase) }
        .onChange(of: vm.currentID) { _, _ in scheduleAutoHide() }
        .onChange(of: currentReelPlaying) { _, playing in if playing { scheduleAutoHide() } else { controlsHidden = false } }
        .onChange(of: vm.isClear) { _, isClear in if !isClear { scheduleAutoHide() } }
        .onDisappear { autoHideTask?.cancel() }
    }

    private var currentReelPlaying: Bool {
        guard let id = vm.currentID else { return false }
        return vm.players[id]?.isPlaying ?? false
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        controlsHidden = false
        guard currentReelPlaying, !vm.isClear else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, currentReelPlaying else { return }
            controlsHidden = true
        }
    }

    private func revealControls() {
        autoHideTask?.cancel()
        controlsHidden = false
        scheduleAutoHide()
    }

    @ViewBuilder
    private func content(topInset: CGFloat, bottom: CGFloat) -> some View {
        @Bindable var vm = vm
        if !vm.items.isEmpty {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(vm.items) { item in
                        ReelPageView(item: item, vm: vm, topInset: topInset, bottomInset: bottom,
                                     onPlaybackTap: revealControls)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $vm.currentID)
            .scrollIndicators(.hidden)
            .onChange(of: vm.currentID) { _, id in vm.pageChanged(to: id) }
            .onScrollPhaseChange { _, phase in if phase == .idle { vm.scrollSettled() } }
        } else if vm.isLoading {
            ProgressView().controlSize(.large).tint(.white.opacity(0.7))
        } else if let message = vm.errorMessage {
            ReelsErrorCard(message: message) { vm.loadMore(first: true) }
                .padding(.horizontal, 16)
        } else {
            Text("No videos right now.").foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Soft top/bottom scrims keep the white UI readable on bright clips.
    private func scrims(top: CGFloat, bottom: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: top + 110)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.clear, .black.opacity(0.70)], startPoint: .top, endPoint: .bottom)
                .frame(height: bottom + 230)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(vm.isClear ? 0 : 1)
        .animation(.easeOut(duration: 0.22), value: vm.isClear)
        .allowsHitTesting(false)
    }
}

// MARK: - Top bar

private struct ReelsTopBar: View {
    let clear: Bool
    let isMuted: Bool
    let onBack: () -> Void
    let onToggleMute: () -> Void
    let onToggleClear: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            topButton("chevron.backward", label: "Back", action: onBack)

            Spacer(minLength: 5)

            HStack(spacing: 7) {
                Circle().fill(Color.white.opacity(0.92)).frame(width: 6, height: 6)
                Text("For You")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(.white.opacity(0.10), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.8))

            Spacer(minLength: 5)

            topButton(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      label: isMuted ? "Unmute" : "Mute", action: onToggleMute)
            topButton(clear ? "eye.slash" : "eye", label: clear ? "Show controls" : "Hide controls",
                      action: onToggleClear)
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.19), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    private func topButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.selection)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.10), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.13), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

private struct ReelsErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Gaps.md) {
            Text(message).font(.body).multilineTextAlignment(.center).lineLimit(2)
            Button(action: onRetry) { Label("Try again", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent)
                .tint(.vxAccent)
        }
        .padding(Gaps.lg)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

// MARK: - One reel

/// Tap = play/pause, double-tap middle = like, double-tap edges (18% each
/// side) = skip 10s, press-and-hold = temporary 2x.
struct ReelPageView: View {
    let item: ReelItem
    let vm: ReelsViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onPlaybackTap: () -> Void

    private static let skipZone: CGFloat = 0.18

    @State private var fast = false
    @State private var holdSuppressesTap = false
    @GestureState private var pressing = false
    @State private var scrubbing = false

    @State private var heartAt: CGPoint = .zero
    @State private var heartTilt: Double = 0
    @State private var heartToken = 0

    @State private var skipDirection = 1
    @State private var skipSeconds = 0
    @State private var skipVisible = false
    @State private var skipPulse = 0
    @State private var skipTask: Task<Void, Never>?

    var body: some View {
        let player = vm.players[item.id]
        let isActive = vm.isActive && vm.currentID == item.id
        let hideUI = vm.isClear || scrubbing

        GeometryReader { geo in
            ZStack {
                Color.black

                // Video, state overlays and all touch gestures live in one layer;
                // the info/rail/scrubber are siblings above it so they take
                // their own touches (like the Positioned widgets in Dart).
                playbackLayer(player: player)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { handleDoubleTap($0.location, width: geo.size.width, player: player, isActive: isActive) }
                            .exclusively(before: TapGesture(count: 1).onEnded { handleSingleTap(player: player, isActive: isActive) })
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.14, maximumDistance: 14)
                            .updating($pressing) { current, state, _ in state = current }
                            .onEnded { _ in beginFast(player: player, isActive: isActive) }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Video player")
                    .accessibilityHint("Tap to pause or play. Double-tap the middle to like. Double-tap the left or right edge to rewind or skip 10 seconds. Press and hold for 2x speed.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { player?.togglePlay() }

                heartBurst
                SkipFeedback(visible: skipVisible, direction: skipDirection, seconds: skipSeconds, pulse: skipPulse)

                InfoBlock(item: item, maxExpandedHeight: geo.size.height * 0.3)
                    .padding(.leading, 16).padding(.trailing, 84)
                    .padding(.bottom, bottomInset + 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .uiFade(hidden: hideUI)

                ActionRail(item: item, vm: vm)
                    .padding(.trailing, 6)
                    .padding(.bottom, bottomInset + 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .uiFade(hidden: hideUI)

                if fast {
                    HStack(spacing: 5) {
                        Image(systemName: "forward.fill").font(.system(size: 14))
                        Text("2x").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, topInset + 58)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                if let player, player.state == .ready {
                    ReelProgressBar(player: player) { scrubbing = $0 }
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomInset + 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .uiFade(hidden: vm.isClear)
                }
            }
            .animation(.spring(duration: 0.22), value: fast)
        }
        .onChange(of: pressing) { _, now in if !now { endFast(player: player) } }
        .onChange(of: isActive) { _, active in if !active { endFast(player: player) } }
    }

    // MARK: Layers

    @ViewBuilder
    private func playbackLayer(player: ReelPlayer?) -> some View {
        ZStack {
            if let player {
                switch player.state {
                case .ready:
                    // .resizeAspect = BoxFit.contain: letterbox on black, never crop.
                    PlayerLayerView(player: player.player, gravity: .resizeAspect)
                    StallSpinner(player: player)
                    PlayIndicator(player: player)
                case .failed:
                    VStack(spacing: Gaps.md) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 40)).foregroundStyle(.white.opacity(0.55))
                        Button { vm.retry(item) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                            .buttonStyle(.bordered).tint(.white)
                    }
                case .loading:
                    ProgressView().controlSize(.regular).tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heartBurst: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 100))
            .foregroundStyle(Color.vxAccent)
            .shadow(color: .black.opacity(0.5), radius: 14)
            .keyframeAnimator(initialValue: HeartValues(), trigger: heartToken) { content, value in
                content
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
                    .rotationEffect(.radians(heartTilt))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.23, spring: .bouncy)
                    LinearKeyframe(1.0, duration: 0.14)
                    LinearKeyframe(1.0, duration: 0.22)
                    LinearKeyframe(1.35, duration: 0.23)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.001)
                    LinearKeyframe(1, duration: 0.589)
                    LinearKeyframe(0, duration: 0.23)
                }
            }
            .position(x: heartAt.x, y: heartAt.y - 20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Gesture handling

    private func handleSingleTap(player: ReelPlayer?, isActive: Bool) {
        onPlaybackTap()
        guard isActive, !holdSuppressesTap, let player, player.state == .ready else { return }
        Haptics.play(.selection)
        player.togglePlay()
    }

    private func handleDoubleTap(_ point: CGPoint, width: CGFloat, player: ReelPlayer?, isActive: Bool) {
        guard isActive else { return }
        if point.x <= width * Self.skipZone {
            skip(-1, player: player)
        } else if point.x >= width * (1 - Self.skipZone) {
            skip(1, player: player)
        } else {
            vm.likeFromDoubleTap(item)
            heartAt = point
            heartTilt = Double((Int(point.x) % 3) - 1) * 0.16
            heartToken += 1
        }
    }

    private func skip(_ direction: Int, player: ReelPlayer?) {
        guard let player, player.state == .ready, player.duration > 0 else { return }
        Task {
            await player.seek(to: player.position + Double(direction) * 10)
            Haptics.play(.selection)
            let chained = skipVisible && skipDirection == direction
            skipSeconds = chained ? skipSeconds + 10 : 10
            skipDirection = direction
            skipVisible = true
            skipPulse += 1
            skipTask?.cancel()
            skipTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { skipVisible = false }
            }
        }
    }

    private func beginFast(player: ReelPlayer?, isActive: Bool) {
        holdSuppressesTap = true
        guard isActive, let player, player.state == .ready, player.isPlaying, !fast else { return }
        player.setSpeed(2)
        Haptics.play(.medium)
        fast = true
    }

    private func endFast(player: ReelPlayer?) {
        if fast {
            fast = false
            player?.setSpeed(1)
        }
        guard holdSuppressesTap else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            holdSuppressesTap = false
        }
    }
}

private struct HeartValues {
    var scale: Double = 0
    var opacity: Double = 0
}

private extension View {
    /// `_UiFade`.
    func uiFade(hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.easeOut(duration: 0.22), value: hidden)
    }
}

// MARK: - Overlays

private struct PlayIndicator: View {
    let player: ReelPlayer
    var body: some View {
        let paused = !player.isPlaying
        Image(systemName: "play.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white)
            .frame(width: 68, height: 68)
            .background(.black.opacity(0.35), in: Circle())
            .scaleEffect(paused ? 1 : 0.8)
            .opacity(paused ? 1 : 0)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: paused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Shows a spinner only after ~0.7 s of real stalling (AVPlayer reports it).
private struct StallSpinner: View {
    let player: ReelPlayer
    @State private var show = false

    var body: some View {
        ProgressView().controlSize(.large).tint(.white)
            .opacity(show ? 1 : 0)
            .animation(.easeOut(duration: 0.22), value: show)
            .allowsHitTesting(false)
            .task(id: player.isWaiting) {
                if player.isWaiting {
                    try? await Task.sleep(for: .milliseconds(700))
                    show = player.isWaiting
                } else {
                    show = false
                }
            }
    }
}

/// Compact skip badge near the tapped edge (the 78x70 badge from the patch notes).
private struct SkipFeedback: View {
    let visible: Bool
    let direction: Int
    let seconds: Int
    let pulse: Int

    var body: some View {
        let forward = direction >= 0
        VStack(spacing: 1) {
            Image(systemName: forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 26, weight: .regular))
            Text("\(forward ? "+" : "−")\(seconds)s")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 78, height: 70)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous)
            .fill(Color.black.opacity(0.24)))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous)
            .strokeBorder(.white.opacity(0.24), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.2), radius: 7, y: 4)
        .id(pulse) // re-triggers the pop on every chained skip
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .padding(forward ? .trailing : .leading, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: forward ? .trailing : .leading)
        .opacity(visible ? 1 : 0)
        .animation(.spring(duration: 0.26, bounce: 0.3), value: pulse)
        .animation(.easeOut(duration: 0.14), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Info block (author, title, tags, stats)

private struct InfoBlock: View {
    let item: ReelItem
    let maxExpandedHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !item.author.isEmpty {
                HStack(spacing: 9) {
                    Group {
                        if let avatar = item.avatarURL {
                            HeaderImage(url: avatar, headers: ReelConstants.mediaHeaders, maxPixel: 108)
                        } else {
                            Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: 31, height: 31)
                    .background(Color(white: 0.2))
                    .clipShape(Circle())
                    .padding(1.5)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.4))

                    Text("@\(item.author)")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 5)
                }
                .padding(.bottom, 10)
            }

            ExpandableText(text: item.title.isEmpty ? "Untitled" : item.title,
                           collapsedLines: 2, maxExpandedHeight: maxExpandedHeight)

            if !item.tags.isEmpty {
                Text(item.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.86))
                    .shadow(color: .black.opacity(0.6), radius: 5)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 12) {
                Label(reelCompact(item.views), systemImage: "play.fill")
                if item.durationSec > 0 {
                    Label(reelClock(Double(item.durationSec)), systemImage: "clock")
                }
            }
            .labelStyle(CompactIconLabelStyle())
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .shadow(color: .black.opacity(0.6), radius: 5)
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
    }
}

private struct CompactIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Collapsed to 2 lines; tap to expand into a scrollable block capped at 30%
/// of the screen height (expandable_text.dart).
private struct ExpandableText: View {
    let text: String
    let collapsedLines: Int
    let maxExpandedHeight: CGFloat

    @State private var expanded = false
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var truncated: Bool { fullHeight > limitedHeight + 1 }

    private var label: some View {
        Text(text)
            .font(.system(size: 14.5, weight: .medium))
            .lineSpacing(2)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if expanded {
                ScrollView { label }
                    .frame(height: min(max(fullHeight, 1), maxExpandedHeight))
            } else {
                label
                    .lineLimit(collapsedLines)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
            }
        }
        .background {
            label.fixedSize(horizontal: false, vertical: true).hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard truncated || expanded else { return }
            withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(truncated || expanded ? (expanded ? "Collapse" : "Expand") : "")
    }
}

// MARK: - Action rail

private struct ActionRail: View {
    let item: ReelItem
    let vm: ReelsViewModel

    var body: some View {
        let liked = vm.isLiked(item)
        VStack(spacing: 18) {
            RailButton(systemImage: liked ? "heart.fill" : "heart",
                       tint: liked ? .vxAccent : .white, size: 24,
                       label: reelCompact(item.likes), popTrigger: liked, haptic: nil) {
                vm.toggleLike(item)
            }
            saveButton
            RailButton(systemImage: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: vm.isMuted ? "Muted" : "Sound") { vm.toggleMute() }
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let open = { vm.saveMenuItem = item }
        if let progress = vm.saving[item.id] {
            RailButton(systemImage: "arrow.down.to.line", label: "Saving", progress: progress, action: open)
        } else if let entry = vm.downloadItem(for: item) {
            switch entry.status {
            case .done:
                RailButton(systemImage: "checkmark.circle", tint: .vxAccent, label: "Saved", action: open)
            case .failed, .paused:
                RailButton(systemImage: "arrow.clockwise", label: "Retry", action: open)
            case .queued, .downloading:
                RailButton(systemImage: "arrow.down.to.line",
                           label: entry.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Queued",
                           progress: entry.progress ?? -1, action: open)
            }
        } else {
            RailButton(systemImage: "arrow.down.to.line", label: "Save", action: open)
        }
    }
}

/// Bare glyph with soft shadow and a label (Instagram-style rail action).
private struct RailButton: View {
    let systemImage: String
    var tint: Color = .white
    var size: CGFloat = 23
    let label: String
    var progress: Double?
    var popTrigger: Bool?
    var haptic: Haptics.Style? = .light
    let action: () -> Void

    var body: some View {
        Button {
            if let haptic { Haptics.play(haptic) }
            action()
        } label: {
            VStack(spacing: 1) {
                ZStack {
                    if let progress { ProgressRing(value: progress) }
                    Image(systemName: systemImage)
                        .font(.system(size: size))
                        .foregroundStyle(tint)
                        .shadow(color: .black.opacity(0.5), radius: 7)
                        .symbolEffect(.bounce, value: popTrigger ?? false)
                }
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().fill(Color.black.opacity(0.13)))
                .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.8))

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 5)
            }
            .frame(width: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.86))
        .accessibilityLabel(label)
    }
}

private struct ProgressRing: View {
    let value: Double // < 0 = indeterminate
    var body: some View {
        Group {
            if value < 0 {
                ProgressView().tint(.white).controlSize(.large)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 2.4)
                    Circle().trim(from: 0, to: min(max(value, 0), 1))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Scrubber

/// iOS-style scrubber with elapsed/total labels. Tap seeks; horizontal drag
/// scrubs (pausing while dragging, then resuming).
private struct ReelProgressBar: View {
    let player: ReelPlayer
    let onScrub: (Bool) -> Void

    @State private var dragging = false
    @State private var fraction: Double = 0
    @State private var wasPlaying = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = player.duration
            let played = total > 0 ? min(max(player.position / total, 0), 1) : 0
            let shown = dragging ? fraction : played
            let elapsed = dragging ? total * fraction : player.position
            let barHeight: CGFloat = dragging ? 7 : 4
            let thumb: CGFloat = 15

            ZStack(alignment: .bottomLeading) {
                HStack {
                    Text(reelClock(elapsed))
                    Spacer()
                    Text(reelClock(total))
                }
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 1)

                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.4))
                    Rectangle().fill(.white.opacity(0.6)).frame(width: width * player.buffered)
                    Rectangle().fill(Color.vxAccent).frame(width: width * shown)
                        .animation(dragging ? nil : .linear(duration: 0.28), value: shown)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                .padding(.bottom, 7)
                .animation(.easeOut(duration: 0.12), value: dragging)

                if dragging {
                    Circle().fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: Color.vxAccent.opacity(0.65), radius: 6)
                        .offset(x: min(max(width * shown - thumb / 2, 0), width - thumb), y: -1.5)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging, abs(value.translation.width) > 4 {
                            wasPlaying = player.isPlaying
                            player.setPlaying(false)
                            Haptics.play(.selection)
                            dragging = true
                            onScrub(true)
                        }
                        if dragging { fraction = clamp(value.location.x / width) }
                    }
                    .onEnded { value in
                        if dragging {
                            let target = fraction
                            let resume = wasPlaying
                            dragging = false
                            onScrub(false)
                            Task {
                                await player.seek(toFraction: target)
                                if resume { player.setPlaying(true) }
                            }
                        } else {
                            let target = clamp(value.location.x / width)
                            Task { await player.seek(toFraction: target) }
                        }
                    }
            )
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(reelClock(player.position)) of \(reelClock(player.duration))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10.0 : -10.0
            Task { await player.seek(to: player.position + step) }
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
