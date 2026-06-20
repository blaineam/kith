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
    @Published private(set) var online = false
    /// True once we've actually exchanged a frame with a contact over that path —
    /// so the UI can show whether the internet and/or nearby links are really working.
    @Published private(set) var internetActive = false
    @Published private(set) var nearbyActive = false
    // Diagnostics surfaced in Advanced → Connection.
    @Published private(set) var internetReady = false
    @Published private(set) var nodeError: String?
    @Published private(set) var lastSendError: String?
    /// Per-contact time we last received a valid frame from them — the basis for a
    /// truthful "Connected" (a live two-way link), not just "we hold their keys".
    @Published private(set) var lastHeard: [String: Date] = [:]
    static let shared = FeedStore()

    private var social: KithSocial?
    private var node: KithNode?
    private var nearby: NearbyTransport?
    private var listener: InboundBridge?
    private var syncTimer: Timer?
    private init() {}

    /// Initialize the real networked store once (idempotent) and bring the P2P node
    /// online. The feed works offline too; the node just enables real delivery.
    func configure(seed: Data) {
        guard social == nil else { return }
        social = try? KithSocial(accountSeed: seed)
        loadPersisted()
        refresh()
        guard ProcessInfo.processInfo.environment["KITH_NO_NET"] != "1" else { return }
        bringOnline(seed: seed)
    }

    // MARK: - Persistence (so posts + contacts survive restarts and updates)

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kith-feed.json")
    }
    private func loadPersisted() {
        guard let social, let data = try? Data(contentsOf: stateURL) else { return }
        social.importState(data: data)
    }
    private func persist() {
        guard let social else { return }
        try? social.exportState().write(to: stateURL, options: .atomic)
    }

    private func bringOnline(seed: Data) {
        // Nearby Bluetooth / Wi-Fi mesh — works even with no internet at all.
        if let social {
            let nt = NearbyTransport(
                displayName: social.myNodeHex(),
                onInbound: { [weak self] data in Task { @MainActor in self?.handleInbound(data, viaNearby: true) } },
                onPeerConnected: { [weak self] in Task { @MainActor in self?.nearbyPeerConnected() } }
            )
            nt.start()
            nearby = nt
            online = true
        }
        // Internet path (iroh + n0 discovery/relays).
        let bridge = InboundBridge { [weak self] data in
            Task { @MainActor in self?.handleInbound(data, viaNearby: false) }
        }
        listener = bridge
        Task { @MainActor in
            do {
                let n = try await KithNode.start(accountSeed: seed, listener: bridge)
                self.node = n
                self.internetReady = true
                self.online = true
                self.startSyncTimer()
                // Sync soon (discovery needs a moment to resolve), then keep retrying.
                for delay in [1.0, 4.0, 10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.syncWithContacts()
                    }
                }
            } catch {
                self.nodeError = error.localizedDescription
            }
        }
    }

    // Diagnostics accessors.
    var myNodeIdShort: String { social.map { String($0.myNodeHex().prefix(16)) } ?? "—" }
    var contactCount: Int { ContactsStore.shared.contacts.count }
    var handshakedCount: Int { social?.contactNodeIds().count ?? 0 }
    /// True once we hold this contact's verified public bundle (handshake complete) —
    /// the point at which we can seal to / open from them.
    func isHandshaked(_ idHex: String) -> Bool {
        social?.contactNodeIds().contains(idHex) ?? false
    }
    /// True only if we've actually heard from them recently — a real live link, not
    /// just holding (possibly stale) keys.
    func isConnected(_ idHex: String) -> Bool {
        guard let t = lastHeard[idHex] else { return false }
        return Date().timeIntervalSince(t) < 120
    }
    func forceSync() { syncWithContacts() }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncWithContacts() }
        }
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    func refresh() {
        items = social?.feed(nowMs: now(), viewerRetentionSecs: SettingsStore.shared.retentionSecs) ?? []
    }

    /// The current user's own posts — their personal archive.
    var myPosts: [FeedItemFfi] { items.filter(\.isMe) }

    // MARK: - Authoring (seal locally, then broadcast to contacts)

    func post(_ body: String, media: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil) {
        guard let social, let env = try? social.post(body: body, media: media, music: music, retentionSecs: retentionSecs, createdAt: now()) else { return }
        broadcastEvent(env); postTick += 1; refresh()
    }
    func comment(_ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(target: id, body: body, media: media, createdAt: now()) else { return }
        broadcastEvent(env); refresh()
    }
    func react(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(env); reactionTick += 1; refresh()
    }
    func edit(_ id: String, _ body: String) {
        guard let social, let env = try? social.edit(target: id, body: body, createdAt: now()) else { return }
        broadcastEvent(env); refresh()
    }
    func unsend(_ id: String) {
        guard let social, let env = try? social.unsend(target: id, createdAt: now()) else { return }
        broadcastEvent(env); refresh()
    }

    // MARK: - Wire protocol  [type byte][payload]: 0 = Hello(bundle), 1 = Event(envelope)

    /// Called when a contact is added or the node comes online: hand each contact our
    /// bundle (Hello) + our posts, so connections become mutual and back-fill.
    func syncWithContacts() {
        guard let social, let hello = helloPayload() else { return }
        let envs = social.syncEnvelopes()
        for contact in ContactsStore.shared.contacts {
            sendIroh(0, hello, to: contact.idHex)
            for env in envs { sendIroh(1, env, to: contact.idHex) }
        }
        nearbyBroadcast(0, hello)
        for env in envs { nearbyBroadcast(1, env) }
    }

    /// A nearby peer just connected over Bluetooth/Wi-Fi — say hello + back-fill.
    private func nearbyPeerConnected() {
        guard let social, let hello = helloPayload() else { return }
        nearbyActive = true
        nearbyBroadcast(0, hello)
        for env in social.syncEnvelopes() { nearbyBroadcast(1, env) }
        refresh()
    }

    /// Hello payload = [u32 LE bundleLen][public bundle][signed profile (your name)].
    private func helloPayload() -> Data? {
        guard let social else { return nil }
        let bundle = social.myBundle()
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        let profile = social.mySignedProfile(name: myName)
        var p = Data()
        let len = UInt32(bundle.count)
        p.append(UInt8(len & 0xff)); p.append(UInt8((len >> 8) & 0xff))
        p.append(UInt8((len >> 16) & 0xff)); p.append(UInt8((len >> 24) & 0xff))
        p.append(bundle)
        p.append(profile)
        return p
    }

    private func broadcastEvent(_ env: Data) {
        for contact in ContactsStore.shared.contacts { sendIroh(1, env, to: contact.idHex) }
        nearbyBroadcast(1, env)
        persist()   // we just authored something — save it
    }

    private func frame(_ type: UInt8, _ payload: Data) -> Data {
        var f = Data([type]); f.append(payload); return f
    }
    private func sendIroh(_ type: UInt8, _ payload: Data, to nodeHex: String) {
        guard let node else { return }
        let f = frame(type, payload)
        Task { [weak self] in
            do { try await node.sendToNode(nodeIdHex: nodeHex, payload: f) }
            catch { await MainActor.run { self?.lastSendError = error.localizedDescription } }
        }
    }
    private func nearbyBroadcast(_ type: UInt8, _ payload: Data) {
        nearby?.broadcast(frame(type, payload))
    }

    private func handleInbound(_ data: Data, viaNearby: Bool) {
        guard let type = data.first else { return }
        if viaNearby { nearbyActive = true } else { internetActive = true }
        let payload = Data(data.dropFirst())
        switch type {
        case 0: handleHello(payload)
        case 1: handleEvent(payload)
        default: break
        }
    }

    private func nodeHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func isContact(_ idHex: String) -> Bool {
        ContactsStore.shared.contacts.contains { $0.idHex == idHex }
    }

    private func handleHello(_ payload: Data) {
        guard let social else { return }
        // Accept BOTH handshake formats (so a version-skewed pair still connects):
        //   legacy: payload = bundle
        //   current: payload = [u32 bundleLen][bundle][signed profile]
        let bundle: Data
        let profileBlob: Data
        if payload.count >= 32, isContact(nodeHex(payload.prefix(32))) {
            bundle = Data(payload)
            profileBlob = Data()
        } else if payload.count >= 36 {
            let b = [UInt8](payload.prefix(4))
            let n = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            guard n >= 32, payload.count >= 4 + n,
                  isContact(nodeHex(payload.subdata(in: 4..<36))) else { return }
            bundle = payload.subdata(in: 4..<(4 + n))
            profileBlob = payload.subdata(in: (4 + n)..<payload.count)
        } else {
            return
        }

        let idHex = nodeHex(bundle.prefix(32))
        // Verify the bundle against the hash from their reach-me link (MITM guard).
        if let expected = ContactsStore.shared.verification(forNodePrefix: idHex),
           let actual = try? social.bundleVerificationHex(bundle: bundle),
           expected != actual {
            return
        }
        guard (try? social.addContactBundle(bundle: bundle)) != nil else { return }
        lastHeard[idHex] = Date()   // a real, current ping from them
        persist()   // contact's bundle is now known — keep it
        // The name they signed wins over any local nickname (owner has authority).
        if !profileBlob.isEmpty,
           let authName = social.verifyProfile(bundle: bundle, blob: profileBlob), !authName.isEmpty {
            ContactsStore.shared.setAuthoritativeName(idHex: idHex, authName)
        }
        // Reply so the link is mutual + back-fill our posts to them (both transports).
        if let hello = helloPayload() {
            sendIroh(0, hello, to: idHex)
            nearbyBroadcast(0, hello)
        }
        let envs = social.syncEnvelopes()
        for env in envs { sendIroh(1, env, to: idHex); nearbyBroadcast(1, env) }
        refresh()
    }

    private func handleEvent(_ env: Data) {
        guard let social else { return }
        if (try? social.receive(envelope: env)) == true {
            persist()   // a new post arrived — save it
            refresh()
        }
    }
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
        HStack(spacing: 8) {
            Circle().fill(store.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(connectionText)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var connectionText: String {
        guard store.online else { return "Offline — posts sync when you reconnect" }
        var paths: [String] = []
        if store.internetActive { paths.append("internet") }
        if store.nearbyActive { paths.append("nearby") }
        if paths.isEmpty { return "Online — looking for your circle…" }
        return "Connected · " + paths.joined(separator: " + ")
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

    /// Display name for the post's author — resolved from your contacts by node id.
    private var authorName: String {
        if item.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? friendName
    }
    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

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
        // When the clip ends, loop it (muted) and — if we're still on this post —
        // bring the song back, so the music never stays paused under an idle video.
        let postId = item.id
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            if AudioCoordinator.shared.centeredPostId == postId {
                p.play()
                AudioCoordinator.shared.videoFinished()
            }
        }
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
            audio.ensureMusicPlaying()   // resume the song if a video had paused it
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
                .overlay(Text(String(authorName.prefix(1))).font(.caption2.bold()).foregroundStyle(.white))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            avatar
            Text(authorName).font(.subheadline.weight(.semibold))
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
                        Text(commentAuthorName(c)).font(.caption.weight(.semibold))
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
