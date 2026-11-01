import SwiftUI
import AVFoundation

/// MIGRATION NOTES
/// - `Navigator.push(PlayerPage)` becomes `fullScreenCover(item: PlayerRoute)`.
/// - Video is an `AVPlayerLayer` (`.resizeAspect`, black letterbox) so PiP and
///   120 Hz rendering come from AVFoundation; the custom control layer from
///   the Flutter app is kept (skip zones, 2x hold, scrubber, speed, reload).
/// - `showModalBottomSheet` -> `.sheet` with `presentationDetents`;
///   `SystemChrome` immersive mode -> `statusBarHidden` + hidden home indicator.
struct PlayerScreen: View {
    @State private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var pressing = false
    @State private var lastScrubText = ""

    init(route: PlayerRoute, dependencies: AppDependencies) {
        _vm = State(initialValue: PlayerViewModel(route: route, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var vm = vm

        GeometryReader { root in
            let insets = root.safeAreaInsets
            let size = root.size
            let margin: CGFloat = size.width > 700 ? 24 : 16

            ZStack {
                Color.black

                if vm.isLive, let engine = vm.engine {
                    PlayerSurfaceView(player: engine.player, surface: vm.surface)
                        .id(ObjectIdentifier(engine))
                        .modifier(FadeInOnAppear())
                }

                gestureLayer(width: size.width)
                bufferingSpinner
                seekFlash(width: size.width)
                boostBadge(top: insets.top)
                scrubBadge(height: size.height)

                if vm.isLive, let engine = vm.engine {
                    ControlsOverlay(vm: vm, engine: engine, insets: insets, margin: margin)
                }

                loadingOverlay(insets: insets, margin: margin)
                overlay
            }
            .animation(.easeInOut(duration: 0.25), value: vm.problem)
            .animation(.easeInOut(duration: 0.25), value: vm.completed)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toast($vm.toast)
        .sheet(isPresented: $vm.showSpeedSheet, onDismiss: { vm.scheduleHide() }) {
            SpeedSheet(selected: vm.speed) { picked in
                vm.setSpeed(picked)
                vm.showSpeedSheet = false
            }
            .presentationDetents([.height(190)])
            .presentationBackground(Color(white: 0.11))
        }
        .task { vm.start() }
        .onAppear { vm.dismiss = { dismiss() } }
        .onDisappear { vm.teardownIfNeeded() }
        .onChange(of: scenePhase) { _, phase in vm.scenePhaseChanged(phase) }
        .onChange(of: pressing) { _, now in if !now { vm.endBoost() } }
        .onChange(of: vm.scrubTarget) { _, target in
            if let target { lastScrubText = scrubText(for: target) }
        }
    }

    // MARK: Layers

    /// Tap / vertical flick (minimize) / press-and-hold (2x).
    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { vm.screenTap(x: $0.location.x, width: width) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    if value.velocity.height > 700, value.translation.height > abs(value.translation.width) {
                        vm.minimize()
                    }
                }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .updating($pressing) { current, state, _ in state = current }
                    .onEnded { _ in vm.startBoost() }
            )
            .accessibilityHidden(true)
    }

    private var bufferingSpinner: some View {
        ProgressView().controlSize(.large).tint(.white)
            .opacity(vm.spinnerVisible && !vm.completed && !vm.isLoading ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: vm.spinnerVisible)
            .allowsHitTesting(false)
    }

    private func seekFlash(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            flashHalf(.left).frame(width: width * 0.36)
            Spacer(minLength: 0)
            flashHalf(.right).frame(width: width * 0.36)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func flashHalf(_ side: PlayerViewModel.Side) -> some View {
        let active = vm.flash?.side == side
        let seconds = (vm.lastFlash?.side == side ? vm.lastFlash?.seconds : nil) ?? 10
        return VStack(spacing: 2) {
            Image(systemName: side == .left ? "backward.fill" : "forward.fill").font(.system(size: 26))
            Text("\(seconds)s").font(.system(size: 15, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 92, height: 92)
        .background(.white.opacity(0.25), in: Circle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: active)
    }

    private func boostBadge(top: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "forward.fill").font(.system(size: 16))
            Text("2x").font(.system(size: 15, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule())
        .padding(.top, top + 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(vm.boosting ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: vm.boosting)
        .allowsHitTesting(false)
    }

    private func scrubBadge(height: CGFloat) -> some View {
        Text(lastScrubText)
            .font(.system(size: 15, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.top, height * 0.275 - 18)
            .frame(maxHeight: .infinity, alignment: .top)
            .opacity(vm.scrubTarget != nil && vm.scrubBadge ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: vm.scrubTarget != nil && vm.scrubBadge)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func scrubText(for target: Double) -> String {
        let delta = target - vm.scrubOrigin
        let seconds = Int(abs(delta))
        let sign = delta >= 0 ? "+" : "−"
        let deltaText = seconds >= 60 ? formatPlayerTime(Double(seconds)) : "\(seconds)s"
        return "\(sign)\(deltaText)   \(formatPlayerTime(target))"
    }

    private func loadingOverlay(insets: EdgeInsets, margin: CGFloat) -> some View {
        let text = vm.reconnecting
            ? "Reconnecting… (\(vm.autoRetries)/\(PlayerViewModel.maxAutoRetries))"
            : (vm.manualReload ? "Reloading…" : "Preparing video…")
        return ZStack(alignment: .topLeading) {
            Color.black
            VStack(spacing: Gaps.lg) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).font(.body).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlayerIconButton(systemImage: "chevron.backward", label: "Back", iconSize: 19) {
                Task { await vm.leave() }
            }
            .padding(.leading, margin + insets.leading)
            .padding(.top, insets.top + 10)
        }
        .opacity(vm.isLoading ? 1 : 0)
        .allowsHitTesting(vm.isLoading)
        .animation(.easeInOut(duration: 0.25), value: vm.isLoading)
    }

    // MARK: Problem / finished / up next

    @ViewBuilder private var overlay: some View {
        if let problem = vm.problem {
            ZStack {
                Color.black
                StatusView(systemImage: problem.systemImage, title: problem.title, message: problem.message,
                           actionLabel: "Try again", action: vm.reload,
                           secondaryLabel: "Back", secondaryAction: { Task { await vm.leave() } })
            }
            .transition(.opacity)
        } else if vm.engine?.isReady == true, vm.completed {
            if vm.showsUpNext, let next = vm.nextVideo {
                upNext(next).transition(.opacity)
            } else {
                ZStack {
                    Color.black.opacity(0.8)
                    StatusView(systemImage: "checkmark.circle", title: "Finished watching",
                               message: vm.video.title, actionLabel: "Watch again",
                               action: { Task { await vm.replay() } },
                               secondaryLabel: "Back", secondaryAction: { Task { await vm.leave() } })
                }
                .transition(.opacity)
            }
        }
    }

    private func upNext(_ next: Video) -> some View {
        ZStack {
            Color.black.opacity(0.8)
            VStack(spacing: Gaps.sm) {
                Text("UP NEXT").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Color.vxAccent)
                Text(next.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                Text(vm.countdown.map { "Playing in \($0)…" } ?? "Starting…")
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.bottom, Gaps.sm)
                HStack(spacing: Gaps.sm) {
                    Button { vm.cancelAutoplay() } label: { Label("Cancel", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                    Button { Task { await vm.playNext() } } label: { Label("Play now", systemImage: "forward.end.fill") }
                        .buttonStyle(.borderedProminent).tint(.vxAccent)
                }
                .controlSize(.large)
            }
            .padding(Gaps.xl)
            .frame(maxWidth: 420)
        }
    }
}

// MARK: - Controls

private struct ControlsOverlay: View {
    let vm: PlayerViewModel
    let engine: PlayerEngine
    let insets: EdgeInsets
    let margin: CGFloat

    var body: some View {
        let visible = vm.showControls && !vm.completed
        let gap: CGFloat = margin > 16 ? 28 : 18

        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.70), location: 0),
                                   .init(color: .black.opacity(0.08), location: 0.45),
                                   .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            TopBar(vm: vm)
                .padding(.horizontal, margin)
                .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
                .padding(.top, insets.top + 10)
                .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: gap) {
                if vm.previousVideo != nil {
                    PlayerIconButton(systemImage: "backward.end.fill", label: "Previous video", size: 42, iconSize: 22) {
                        Task { await vm.playPrevious() }
                    }
                }
                PlayerIconButton(systemImage: "gobackward.10", label: "Back 10 seconds", size: 48, iconSize: 28,
                                 haptic: .selection) { vm.scrubBySeconds(-PlayerViewModel.seekStep) }

                if vm.isReloading {
                    Button { vm.cancelReload() } label: {
                        ProgressView().tint(.white).controlSize(.large)
                            .frame(width: 64, height: 64)
                            .background(.white.opacity(0.3), in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.9))
                    .accessibilityLabel("Cancel reload")
                } else {
                    PlayerIconButton(systemImage: engine.isPlaying ? "pause.fill" : "play.fill",
                                     label: engine.isPlaying ? "Pause" : "Play",
                                     size: 64, iconSize: 32, background: .white.opacity(0.3)) {
                        vm.togglePlayback()
                    }
                }

                PlayerIconButton(systemImage: "goforward.10", label: "Forward 10 seconds", size: 48, iconSize: 28,
                                 haptic: .selection) { vm.scrubBySeconds(PlayerViewModel.seekStep) }
                if vm.nextVideo != nil {
                    PlayerIconButton(systemImage: "forward.end.fill", label: "Next video", size: 42, iconSize: 22) {
                        Task { await vm.playNext() }
                    }
                }
            }

            ProgressRow(vm: vm, engine: engine)
                .padding(.horizontal, margin)
                .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
                .padding(.bottom, insets.bottom + 12)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: visible ? 0.26 : 0.42), value: visible)
    }
}

private struct TopBar: View {
    let vm: PlayerViewModel

    var body: some View {
        HStack(spacing: 6) {
            PlayerIconButton(systemImage: "chevron.backward", label: "Back", iconSize: 19) {
                Task { await vm.leave() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.video.title).font(.headline).lineLimit(1).foregroundStyle(.white)
                if vm.stalled {
                    Text("Connection is slow – tap reload")
                        .font(.caption).foregroundStyle(.red.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Haptics.play(.selection)
                vm.openSpeedPicker()
            } label: {
                Text(speedLabel(vm.speed))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.9))
            .accessibilityLabel("Playback speed")

            PlayerIconButton(systemImage: "chevron.down", label: "Minimize") { vm.minimize() }
            if vm.pipSupported {
                PlayerIconButton(systemImage: "pip.enter", label: "Picture in Picture") {
                    Task { await vm.enterPip() }
                }
            }
            PlayerIconButton(systemImage: "rotate.right", label: "Rotate") { vm.toggleOrientation() }
            PlayerIconButton(systemImage: "arrow.clockwise", label: "Reload") { vm.reload() }
        }
    }
}

private struct ProgressRow: View {
    let vm: PlayerViewModel
    let engine: PlayerEngine

    var body: some View {
        let total = engine.duration
        let position = vm.scrubTarget ?? engine.position
        let played = total > 0 ? min(max(position / total, 0), 1) : 0
        let buffered = total > 0 ? min(max(engine.bufferedEnd / total, 0), 1) : 0
        let active = vm.dragging
        let track: CGFloat = active ? 6 : 4
        let thumb: CGFloat = active ? 18 : 12

        HStack(spacing: 0) {
            Text(formatPlayerTime(position)).frame(width: 50, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.24)).frame(height: track)
                    Capsule().fill(.white.opacity(0.38)).frame(width: width * buffered, height: track)
                    Capsule().fill(Color.vxAccent).frame(width: width * played, height: track)
                    Circle().fill(.white).frame(width: thumb, height: thumb)
                        .offset(x: min(max(width * played - thumb / 2, -thumb / 2), width - thumb / 2))
                }
                .frame(maxHeight: .infinity)
                .animation(active ? nil : .linear(duration: 0.25), value: played)
                .animation(.easeOut(duration: 0.12), value: active)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !vm.dragging, abs(value.translation.width) > 4 {
                                vm.dragging = true
                                Haptics.play(.selection)
                            }
                            vm.scrubToFraction(width > 0 ? value.location.x / width : 0)
                        }
                        .onEnded { _ in vm.dragging = false }
                )
            }
            .frame(height: 40)

            Text(formatPlayerTime(total)).frame(width: 50, alignment: .trailing).opacity(0.7)
        }
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seek bar")
        .accessibilityValue("\(formatPlayerTime(position)) of \(formatPlayerTime(total))")
        .accessibilityAdjustableAction { direction in
            vm.scrubBySeconds(direction == .increment ? PlayerViewModel.seekStep : -PlayerViewModel.seekStep)
        }
    }
}

// MARK: - Pieces

private struct SpeedSheet: View {
    let selected: Double
    let onPick: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gaps.md) {
            Text("Playback speed").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Gaps.sm)], spacing: Gaps.sm) {
                ForEach(PlayerViewModel.speeds, id: \.self) { speed in
                    let isSelected = speed == selected
                    Button { onPick(speed) } label: {
                        Text(speedLabel(speed))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(isSelected ? Color.vxAccent : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 22
    var background: Color = .black.opacity(0.3)
    var haptic: Haptics.Style?
    let action: () -> Void

    var body: some View {
        Button {
            if let haptic { Haptics.play(haptic) }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

private struct FadeInOnAppear: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { shown = true } }
    }
}

func formatPlayerTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

func speedLabel(_ speed: Double) -> String {
    speed == speed.rounded() ? "\(Int(speed))x" : "\(speed)x"
}
