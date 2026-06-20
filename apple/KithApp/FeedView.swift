import SwiftUI
import AVKit
import AVFoundation

/// Reports each post card's on-screen vertical center so the feed can pick the one
/// nearest the middle of the screen as the "active" (playing) post.
struct PostCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Drives the live social demo: every action goes through the real hybrid-PQ social
/// engine (seal → open → feed) in `p2pcore`. Posts can carry media + a song.
@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var items: [FeedItemFfi] = []
    @Published private(set) var postTick = 0
    @Published private(set) var reactionTick = 0
    static let shared = FeedStore()
    private var demo: SocialDemo?
    private init() {}

    /// Initialize the local social session once (idempotent).
    func configure(seed: Data) {
        guard demo == nil else { return }
        demo = (try? SocialDemo(accountSeed: seed)) ?? {
            fatalError("SocialDemo requires a 32-byte seed")
        }()
        refresh()
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    func refresh() {
        items = demo?.feed(nowMs: now(), viewerRetentionSecs: SettingsStore.shared.retentionSecs) ?? []
    }

    /// The current user's own posts — their personal archive (a local copy of
    /// everything they've shared).
    var myPosts: [FeedItemFfi] { items.filter(\.isMe) }

    func post(_ body: String, media: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil) {
        guard let demo else { return }
        _ = demo.post(body: body, media: media, music: music, retentionSecs: retentionSecs, createdAt: now())
        postTick += 1
        refresh()
    }
    func comment(_ id: String, _ body: String, _ media: [String] = []) { guard let demo else { return }; _ = demo.comment(target: id, body: body, media: media, createdAt: now()); refresh() }
    func react(_ id: String, _ emoji: String) { guard let demo else { return }; _ = demo.react(target: id, emoji: emoji, createdAt: now()); reactionTick += 1; refresh() }
    func edit(_ id: String, _ body: String) { guard let demo else { return }; _ = demo.edit(target: id, body: body, createdAt: now()); refresh() }
    func unsend(_ id: String) { guard let demo else { return }; _ = demo.unsend(target: id, createdAt: now()); refresh() }
}

struct FeedView: View {
    @ObservedObject private var store = FeedStore.shared
    let friendName: String
    let seed: Data

    @State private var compose = ""
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var showMediaPicker = false
    @State private var showCamera = false
    @State private var showSongPicker = false
    @State private var composeRetention: UInt64?
    @FocusState private var composeFocused: Bool

    init(seed: Data, friendName: String) {
        self.seed = seed
        self.friendName = friendName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { composeFocused = false }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        banner
                        if store.items.isEmpty {
                            emptyState
                        }
                        ForEach(store.items, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(KithTheme.bouncy) { store.react(item.id, e) } },
                                onComment: { b, m in withAnimation(KithTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { b in withAnimation(KithTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(KithTheme.smooth) { store.unsend(item.id) } }
                            )
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self,
                                                       value: [item.id: geo.frame(in: .global).midY])
                            })
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                removal: .opacity))
                        }
                    }
                    .animation(KithTheme.bouncy, value: store.items.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 130)
                }
                .scrollDismissesKeyboard(.immediately)
                .onPreferenceChange(PostCenterKey.self) { centers in
                    // The post nearest the vertical center of the screen becomes active.
                    let target = UIScreen.main.bounds.midY
                    let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                    AudioCoordinator.shared.center(nearest?.key)
                }
                composerBar
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { store.configure(seed: seed) }
            .sensoryFeedback(.success, trigger: store.postTick)
            .sensoryFeedback(.impact(weight: .light), trigger: store.reactionTick)
            .sheet(isPresented: $showMediaPicker) {
                MediaPicker { refs in attachedMedia.append(contentsOf: refs) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { refs in attachedMedia.append(contentsOf: refs) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showSongPicker) {
                SongPicker { track in attachedTrack = track }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(KithTheme.pink)
            Text("Nothing here yet")
                .font(.headline)
            Text("Share your first moment below. As your circle connects, their posts show up here too.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60).padding(.horizontal, 24)
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(KithTheme.pink)
            Text("Your circle — posts from you and your people live here.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var composerBar: some View {
        VStack { Spacer()
            VStack(spacing: 8) {
                if !attachedMedia.isEmpty || attachedTrack != nil || composeRetention != nil { attachmentTray }
                HStack(spacing: 10) {
                    Menu {
                        Button { showMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo.on.rectangle") }
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        Button { showSongPicker = true } label: { Label("Add a song", systemImage: "music.note") }
                        Divider()
                        Menu {
                            Button("Off") { composeRetention = nil }
                            Button("1 hour") { composeRetention = 3_600 }
                            Button("1 day") { composeRetention = 86_400 }
                            Button("1 week") { composeRetention = 604_800 }
                        } label: { Label("Disappears after…", systemImage: "timer") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(KithTheme.pink)
                    }
                    .accessibilityIdentifier("attachMenu")

                    TextField("Share something…", text: $compose, axis: .vertical)
                        .accessibilityIdentifier("composeField")
                        .focused($composeFocused)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.background, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))

                    Button { send() } label: {
                        Image(systemName: "paperplane.fill").foregroundStyle(.white)
                            .padding(13).background(KithTheme.brand, in: Circle())
                            .shadow(color: KithTheme.pink.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("composeSend")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedMedia, id: \.self) { ref in
                    if let m = MediaStore.shared.item(ref), let img = m.image {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                            removeChip { attachedMedia.removeAll { $0 == ref } }
                        }
                    }
                }
                if let track = attachedTrack {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                        Text(track.title).font(.caption2).lineLimit(1)
                        Button { attachedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(KithTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
                if let secs = composeRetention {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text("Disappears: \(Self.retentionLabel(secs))").font(.caption2).lineLimit(1)
                        Button { composeRetention = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }

    private static func retentionLabel(_ secs: UInt64) -> String {
        switch secs {
        case ..<3_600: return "\(secs / 60)m"
        case ..<86_400: return "\(secs / 3_600)h"
        case ..<604_800: return "\(secs / 86_400)d"
        default: return "\(secs / 604_800)w"
        }
    }

    private func removeChip(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .padding(3)
    }

    private func send() {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        store.post(text, media: attachedMedia, music: attachedTrack, retentionSecs: composeRetention)
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil
        composeFocused = false
    }
}

private struct PostCard: View {
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void

    @ObservedObject private var audio = AudioCoordinator.shared
    @ObservedObject private var profile = ProfileStore.shared
    @State private var commentText = ""
    @State private var commentMedia: [String] = []
    @State private var showCommentMediaPicker = false
    @State private var showAudioRecorder = false
    @State private var showEdit = false
    @State private var editText = ""
    @State private var players: [String: AVPlayer] = [:]
    @State private var showReactionPicker = false
    @State private var currentPage = 0

    private var isActive: Bool { audio.centeredPostId == item.id }

    private var primaryVideoPlayer: AVPlayer? {
        guard item.media.count == 1, let ref = item.media.first, isVideo(ref) else { return nil }
        return players[ref]
    }
    private func isVideo(_ ref: String) -> Bool { MediaStore.shared.item(ref)?.kind == .video }

    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if item.unsent {
                Label("Message unsent", systemImage: "minus.circle")
                    .font(.subheadline).italic().foregroundStyle(.secondary)
            } else {
                if !item.body.isEmpty { Text(item.body).font(.body) }
                if !item.media.isEmpty { mediaView }
                if let track = item.music { NowPlayingPill(track: track, animating: true) }
                reactionsRow
                if !item.comments.isEmpty { commentsList }
                commentField
            }
        }
        .kithCard()
        .onAppear { syncPlayback() }
        .onDisappear { pauseVideos() }
        .onChange(of: audio.centeredPostId) { syncPlayback() }
        .onChange(of: currentPage) { if isActive { playVisibleVideo() } }
        .alert("Edit post", isPresented: $showEdit) {
            TextField("New text", text: $editText)
            Button("Save") { if !editText.isEmpty { onEdit(editText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var mediaView: some View {
        if item.media.count > 1 {
            // Swipeable carousel for multiple photos/videos, with page dots.
            TabView(selection: $currentPage) {
                ForEach(Array(item.media.enumerated()), id: \.offset) { idx, ref in
                    mediaPage(ref).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else if let ref = item.media.first {
            ZStack(alignment: .bottomTrailing) {
                mediaPage(ref)
                if isVideo(ref) { muteButton }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private func mediaPage(_ ref: String) -> some View {
        if let m = MediaStore.shared.item(ref) {
            if m.kind == .video, let url = m.videoURL {
                VideoPlayer(player: playerFor(ref, url))
            } else if let img = m.image {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
        }
    }

    private var muteButton: some View {
        Button {
            if audio.activePostId != item.id { audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer) }
            audio.toggleVideoAudio()
        } label: {
            Image(systemName: audio.activePostId == item.id && audio.videoUnmuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white).padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(10)
    }

    private func playerFor(_ ref: String, _ url: URL) -> AVPlayer {
        if let p = players[ref] { return p }
        let p = AVPlayer(url: url)
        p.volume = 0
        p.actionAtItemEnd = .none
        DispatchQueue.main.async {
            players[ref] = p
            if isActive { playVisibleVideo() }
        }
        return p
    }

    /// Drive this card's media from whether it's the centered post: the active post
    /// plays its song + the visible carousel video; an inactive post pauses everything.
    private func syncPlayback() {
        if isActive {
            audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer)
            playVisibleVideo()
        } else {
            pauseVideos()
        }
    }

    private func pauseVideos() { players.values.forEach { $0.pause() } }

    private func playVisibleVideo() {
        guard isActive else { return }
        let visibleRef: String? = item.media.isEmpty
            ? nil
            : item.media[min(max(currentPage, 0), item.media.count - 1)]
        for (ref, player) in players {
            if ref == visibleRef && isVideo(ref) {
                player.seek(to: .zero)
                player.play()
            } else {
                player.pause()
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        if item.isMe {
            KithAvatar(image: profile.avatar, emoji: profile.emoji, size: 34)
        } else {
            Circle()
                .fill(LinearGradient(colors: [KithTheme.amber, KithTheme.pink], startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: 34)
                .overlay(Text(String(friendName.prefix(1))).font(.caption2.bold()).foregroundStyle(.white))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            avatar
            Text(item.isMe ? "You" : friendName).font(.subheadline.weight(.semibold))
            if item.edited {
                Text("edited").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isMe && !item.unsent {
                Menu {
                    Button { editText = item.body; showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6) }
            }
        }
    }

    private var reactionsRow: some View {
        HStack(spacing: 8) {
            ForEach(item.reactions, id: \.emoji) { r in
                Text("\(r.emoji) \(r.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(r.mine ? AnyShapeStyle(KithTheme.brandHorizontal.opacity(0.22)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Capsule())
                    .overlay(Capsule().strokeBorder(r.mine ? KithTheme.pink.opacity(0.5) : .clear))
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            ForEach(EmojiStore.shared.frequent(4), id: \.self) { e in
                Button(e) { react(e) }.font(.body).buttonStyle(PressableStyle())
            }
            Button { showReactionPicker = true } label: {
                Image(systemName: "plus.circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(KithTheme.bouncy, value: item.reactions.count)
        .sheet(isPresented: $showReactionPicker) {
            ReactionPicker { e in onReact(e) }
        }
    }

    private var commentsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.comments, id: \.id) { c in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(c.isMe ? "You" : friendName).font(.caption.weight(.semibold))
                            .foregroundStyle(c.isMe ? KithTheme.pink : .secondary)
                        if c.unsent {
                            Text("unsent").font(.caption).italic().foregroundStyle(.secondary)
                        } else if !c.body.isEmpty {
                            Text(c.body).font(.caption)
                            if c.edited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    if !c.unsent && !c.media.isEmpty { commentMediaRow(c.media) }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func commentMediaRow(_ refs: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(refs, id: \.self) { ref in
                if let m = MediaStore.shared.item(ref) {
                    switch m.kind {
                    case .audio:
                        if let u = m.videoURL { AudioPlayerPill(url: u) }
                    case .video:
                        if let img = m.image {
                            thumb(img).overlay(Image(systemName: "play.circle.fill").foregroundStyle(.white).font(.title3))
                        }
                    case .image:
                        if let img = m.image { thumb(img) }
                    }
                }
            }
        }
    }
    private func thumb(_ img: UIImage) -> some View {
        Image(uiImage: img).resizable().scaledToFill()
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var commentField: some View {
        VStack(spacing: 6) {
            if !commentMedia.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(commentMedia, id: \.self) { commentAttachChip($0) } }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Button { showCommentMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                    Button { showAudioRecorder = true } label: { Label("Audio reply", systemImage: "mic") }
                } label: { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                TextField("Add a reply…", text: $commentText)
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                Button { sendComment() } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large).foregroundStyle(KithTheme.pink)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showCommentMediaPicker) { MediaPicker { refs in commentMedia.append(contentsOf: refs) } }
        .sheet(isPresented: $showAudioRecorder) { AudioRecorderView { ref in commentMedia.append(ref) } }
    }

    private func commentAttachChip(_ ref: String) -> some View {
        let m = MediaStore.shared.item(ref)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = m?.image { Image(uiImage: img).resizable().scaledToFill() }
                else { Image(systemName: "waveform").frame(maxWidth: .infinity, maxHeight: .infinity).background(KithTheme.brandHorizontal.opacity(0.25)) }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            Button { commentMedia.removeAll { $0 == ref } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
            }
        }
    }

    private func sendComment() {
        let t = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !commentMedia.isEmpty else { return }
        onComment(t, commentMedia)
        commentText = ""; commentMedia = []
    }
}

/// Your profile / archive: every post you've shared, kept as a copy on your device.
struct ProfileView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    let friendName: String

    var body: some View {
        ZStack {
            KithBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if store.myPosts.isEmpty {
                        ContentUnavailableView(
                            "No posts yet",
                            systemImage: "tray",
                            description: Text("Everything you share lives here — and a copy stays on your device.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(store.myPosts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(KithTheme.bouncy) { store.react(item.id, e) } },
                                onComment: { b, m in withAnimation(KithTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { b in withAnimation(KithTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(KithTheme.smooth) { store.unsend(item.id) } }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Your posts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 8) {
            KithAvatar(image: profile.avatar, emoji: profile.emoji, size: 76)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName).font(.title3.bold())
            Text("\(store.myPosts.count) post\(store.myPosts.count == 1 ? "" : "s") · a copy lives on your device")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
