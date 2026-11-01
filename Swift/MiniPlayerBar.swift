import SwiftUI

/// Compact native equivalent of mini_player_overlay.dart.
struct MiniPlayerBar: View {
    let onRestore: () -> Void
    @State private var mini = MiniPlayer.shared

    var body: some View {
        if let session = mini.session {
            HStack(spacing: 11) {
                Button(action: onRestore) {
                    HStack(spacing: 11) {
                        ArtworkView(video: session.video)
                            .frame(width: 54, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.video.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Now playing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    if session.engine.isPlaying { session.engine.pause() }
                    else { session.engine.play() }
                } label: {
                    Image(systemName: session.engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Button { mini.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
        }
    }
}
