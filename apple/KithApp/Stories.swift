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
    @State private var slideDuration = 5.0   // photos 5s; videos last their clip (≤15s)
    @State private var profilePeer: StoryProfile?   // tapped a sharer → peek their profile
    @State private var paused = false               // paused while the profile sheet is up
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct StoryProfile: Identifiable { let id = UUID(); let hex: String; let name: String }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if stories.indices.contains(index) {
                content(stories[index]).ignoresSafeArea()
            }
            // Prev/next tap zones — kept BELOW the overlay so the header's tappable
            // name/avatar + buttons receive their taps first.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { prev() }
                Color.clear.contentShape(Rectangle()).onTapGesture { next() }
            }
            if stories.indices.contains(index) {
                overlay(stories[index])
            }
        }
        .statusBarHidden()
        .onAppear { loadCurrent() }
        .onDisappear { teardown() }
        .onReceive(tick) { _ in
            guard !paused else { return }
            progress += 0.05 / slideDuration
            if progress >= 1 { next() }
        }
        .sheet(item: $profilePeer, onDismiss: { paused = false; player?.play() }) { peer in
            NavigationStack { UserProfileView(authorHex: peer.hex, name: peer.name) }
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
                if s.isMe {
                    sharerAvatar(s)
                    Text("Your story").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                } else {
                    let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
                    Button {
                        paused = true
                        player?.pause()
                        profilePeer = StoryProfile(hex: s.authorShort, name: name)
                    } label: {
                        HStack(spacing: 8) {
                            sharerAvatar(s)
                            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text(relativeTimeShort(s.createdAt)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                Spacer()
                if s.isMe {
                    Button {
                        // Convert this story into a permanent (non-expiring) post.
                        FeedStore.shared.post(StoryCaptions.decode(s.body).text,
                                              media: s.media, music: s.music, retentionSecs: nil, story: false)
                        dismiss()
                    } label: {
                        Label("Keep", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                }
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
                let decoded = StoryCaptions.decode(s.body)
                StyledCaption(text: decoded.text, spec: decoded.spec)
                    .padding(.horizontal, 24).padding(.bottom, 36)
            }
        }
    }

    // MARK: - Playback per story

    private func loadCurrent() {
        // Stop the previous slide's audio so it never bleeds into the next.
        player?.pause()
        player = nil
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
            // Let the slide last the clip's length, capped at the per-slide max.
            slideDuration = MediaStore.storySlideMax
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run { slideDuration = min(MediaStore.storySlideMax, max(2, d.seconds)) }
                }
            }
        } else {
            player = nil
            slideDuration = 5
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
        MusicPlayback.shared.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @ViewBuilder private func sharerAvatar(_ s: FeedItemFfi) -> some View {
        if s.isMe {
            KithAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 30)
        } else {
            let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
            Circle().fill(KithTheme.brand).frame(width: 30, height: 30)
                .overlay(Text(String(name.prefix(1))).font(.caption.bold()).foregroundStyle(.white))
        }
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
