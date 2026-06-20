import SwiftUI
import AVKit

/// Full-screen story viewer: progress bars, auto-advance, tap left/right to navigate,
/// captions, and the song the author attached (played while you watch).
/// Stories are ordinary posts flagged `story` with a 24h retention, so they expire
/// on their own — no special server, just the existing retention rule.
struct StoryViewer: View {
    let stories: [FeedItemFfi]
    @State var index: Int
    let friendName: String
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var player: AVPlayer?
    private let duration = 5.0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if stories.indices.contains(index) {
                content(stories[index]).ignoresSafeArea()
                overlay(stories[index])
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { prev() }
                Color.clear.contentShape(Rectangle()).onTapGesture { next() }
            }
        }
        .statusBarHidden()
        .onAppear { loadCurrent() }
        .onDisappear { teardown() }
        .onReceive(tick) { _ in
            progress += 0.05 / duration
            if progress >= 1 { next() }
        }
    }

    @ViewBuilder private func content(_ s: FeedItemFfi) -> some View {
        if let player {
            VideoPlayer(player: player)
        } else if let ref = s.media.first, let img = MediaStore.shared.item(ref)?.image {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            missing
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            Text("Loading…").foregroundStyle(.white.opacity(0.6)).font(.caption)
        }
    }

    private func overlay(_ s: FeedItemFfi) -> some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(stories.indices, id: \.self) { i in
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : (i == index ? progress : 0)))
                            }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal).padding(.top, 12)
            HStack(spacing: 8) {
                Text(s.isMe ? "Your story" : (ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(relativeTimeShort(s.createdAt)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                }
            }
            .padding(.horizontal).padding(.top, 4)
            Spacer()
            if let m = s.music {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").font(.caption)
                    Text("\(m.title) · \(m.artist)").font(.caption.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.bottom, 8)
            }
            if !s.body.isEmpty {
                Text(s.body)
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24).padding(.bottom, 36)
            }
        }
    }

    // MARK: - Playback per story

    private func loadCurrent() {
        guard stories.indices.contains(index) else { return }
        let s = stories[index]
        // The author's song plays while you watch; the video is muted under it.
        if let m = s.music { MusicPlayback.shared.play(m) } else { MusicPlayback.shared.stop() }
        if let ref = s.media.first, let item = MediaStore.shared.item(ref),
           item.kind == .video, let url = item.videoURL {
            let p = AVPlayer(url: url)
            p.isMuted = (s.music != nil)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            player = p
            p.play()
        } else {
            player = nil
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
        MusicPlayback.shared.stop()
        NotificationCenter.default.removeObserver(self)
    }

    private func next() {
        progress = 0
        if index + 1 < stories.count { index += 1; loadCurrent() } else { dismiss() }
    }
    private func prev() {
        progress = 0
        if index > 0 { index -= 1; loadCurrent() }
    }
}
