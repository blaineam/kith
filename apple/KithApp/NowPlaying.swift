import SwiftUI

/// The little "now playing" pill shown near a post with attached music: artist + song
/// title and a live audio-playing animation.
struct NowPlayingPill: View {
    let track: TrackRefFfi
    var animating: Bool

    var body: some View {
        HStack(spacing: 8) {
            EqualizerBars(animating: animating)
            Text("\(track.title) · \(track.artist)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(KithTheme.pink.opacity(0.35)))
    }
}

/// Four little bars that bob up and down while audio plays.
struct EqualizerBars: View {
    var animating: Bool
    @State private var on = false

    private let durations: [Double] = [0.42, 0.55, 0.36, 0.48]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(KithTheme.brandHorizontal)
                    .frame(width: 3, height: 15)
                    .scaleEffect(y: scale(i), anchor: .bottom)
                    .animation(
                        animating
                            ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true)
                            : .default,
                        value: on
                    )
            }
        }
        .frame(width: 22, height: 16, alignment: .bottom)
        .onAppear { on = true }
    }

    private func scale(_ i: Int) -> CGFloat {
        guard animating else { return 0.4 }
        let lows: [CGFloat] = [0.35, 0.5, 0.3, 0.45]
        return on ? 1.0 : lows[i]
    }
}
