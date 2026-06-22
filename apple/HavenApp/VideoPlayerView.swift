import SwiftUI
import AVKit

/// AVPlayerLayer-backed surface with no system chrome. `.resizeAspect` letterboxes — the whole
/// frame is always visible, never cropped.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Inline video with custom, chrome-free controls. This view OWNS every gesture on the
/// video so nothing upstream (the parent post's tap/zoom/contextMenu) can steal them:
///  • **single tap** → `onTap` (the parent uses this to toggle mute)
///  • **double tap** → `onDoubleTap` (the parent uses this to ❤️ the post)
///  • **hold** (long-press) → pause while held, release to resume
///  • **horizontal drag** → scrub (shows a thin progress bar + time)
struct GestureVideoPlayer: View {
    let player: AVPlayer
    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}

    @State private var progress: Double = 0      // 0…1
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var interacting = false
    @State private var wasPlaying = false
    @State private var startProgress: Double = 0
    @State private var dragAxisLocked = false   // committed to horizontal-scrub for this drag
    @State private var observed: (AVPlayer, Any)?

    var body: some View {
        GeometryReader { geo in
            VideoSurface(player: player)
                .overlay(alignment: .bottom) {
                    if scrubbing { scrubBar.padding(8) }
                }
                .contentShape(Rectangle())
                // Tap → mute, double-tap → heart. Double-tap registered first so a genuine
                // double-tap isn't consumed as a single tap.
                .onTapGesture(count: 2) { onDoubleTap() }
                .onTapGesture(count: 1) { onTap() }
                // Hold-to-pause + horizontal-drag-to-scrub, owned here at high priority so the
                // ancestor contextMenu / zoom / feed-scroll can't intercept the long-press or
                // the sideways swipe. Vertical drags fall through (feed keeps scrolling).
                .highPriorityGesture(holdToPause)
                .highPriorityGesture(scrub(width: geo.size.width))
        }
        .onAppear(perform: addObserver)
        .onDisappear(perform: removeObserver)
    }

    private var scrubBar: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 4)
            Text(timeLabel).font(.caption2.monospacedDigit()).foregroundStyle(.white)
        }
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var timeLabel: String {
        func f(_ s: Double) -> String { let v = max(0, s); return String(format: "%d:%02d", Int(v) / 60, Int(v) % 60) }
        return "\(f(progress * duration)) / \(f(duration))"
    }

    /// Press-and-hold pauses the video while held, resumes on release. A 0.2s minimum keeps
    /// it from firing on a quick tap. Because this is attached as a high-priority gesture it
    /// wins the long-press race against any ancestor `.contextMenu`.
    private var holdToPause: some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 10)
            .onEnded { _ in
                // Long-press recognized — pause and hold. The accompanying drag/lift is tracked
                // by the trailing DragGesture so we know when the finger lifts.
                if !scrubbing {
                    wasPlaying = player.timeControlStatus == .playing
                    player.pause()
                    interacting = true
                }
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { _ in
                // Finger lifted after a hold — resume if it had been playing (and we're not
                // mid-scrub, which manages its own resume).
                if interacting && !scrubbing {
                    if wasPlaying { player.play() }
                    interacting = false
                }
            }
    }

    /// A horizontal drag scrubs the timeline. We only engage once the drag is clearly
    /// horizontal so a vertical pan still scrolls the feed; once engaged we keep control for
    /// the rest of the drag (axis lock) so a wiggly finger doesn't drop the scrub.
    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                if !dragAxisLocked {
                    // Decide the axis on first meaningful movement. Vertical-dominant → bail,
                    // let the gesture pass through to the feed scroll.
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    dragAxisLocked = true
                    scrubbing = true
                    wasPlaying = wasPlaying || player.timeControlStatus == .playing
                    startProgress = progress
                    player.pause()
                }
                guard dragAxisLocked, width > 0 else { return }
                let pct = min(1, max(0, startProgress + drag.translation.width / width))
                progress = pct
                seek(to: pct)
            }
            .onEnded { _ in
                guard dragAxisLocked else { return }
                dragAxisLocked = false
                scrubbing = false
                if wasPlaying { player.play() }
                wasPlaying = false
                interacting = false
            }
    }

    private func seek(to pct: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: pct * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addObserver() {
        removeObserver()   // never stack observers / leave a stale one
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            if duration <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
            if !scrubbing, duration > 0 { progress = time.seconds / duration }
        }
        observed = (player, token)   // remember the EXACT player this token belongs to
    }
    private func removeObserver() {
        // Remove from the player the observer was actually added to — SwiftUI can recycle this
        // view onto a different `player`, and removing a token from the wrong player throws
        // (the iPad crash on tab-away). Only ever remove once.
        if let (p, token) = observed { p.removeTimeObserver(token); observed = nil }
    }
}

/// Attaches a single-tap gesture only when `enabled`. Lets the single-video tile drop its
/// tap-to-zoom (so the video's own tap/hold/drag gestures aren't intercepted) while images
/// keep tap-to-zoom.
struct ConditionalTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) }
        else { content }
    }
}
