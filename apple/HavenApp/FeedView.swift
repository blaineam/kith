import SwiftUI
import AVKit
import AVFoundation

/// Short relative time ("now", "5m", "3h", "2d") from a unix-millis SENT timestamp —
/// so people see when something was sent, not when it reached them.
func relativeTimeShort(_ ms: UInt64) -> String {
    let secs = Date().timeIntervalSince1970 - Double(ms) / 1000
    switch secs {
    case ..<5: return "now"
    case ..<60: return "\(Int(secs))s"
    case ..<3600: return "\(Int(secs / 60))m"
    case ..<86_400: return "\(Int(secs / 3600))h"
    case ..<604_800: return "\(Int(secs / 86_400))d"
    case ..<2_592_000: return "\(Int(secs / 604_800))w"
    default: return "\(Int(secs / 2_592_000))mo"
    }
}

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
    @Published private(set) var unseenCircle = 0      // new circle posts since last viewed
    @Published private(set) var unseenMessages = 0    // new DM messages since last viewed
    @Published private(set) var relayReachable = false  // the circle's relay accepted our last upload
    func markRelay(_ ok: Bool) { if relayReachable != ok { relayReachable = ok } }
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
    /// The circles you belong to, and which one the feed is currently showing.
    @Published private(set) var circles: [CircleInfoFfi] = []
    @Published var activeCircleId = "default"
    static let shared = FeedStore()

    private var social: HavenSocial?
    private var node: HavenNode?
    private var nearby: NearbyTransport?
    private var mailboxTimer: Timer?
    private var listener: InboundBridge?
    private var syncTimer: Timer?

    // Chunked media reassembly: ref → temp file + which chunk indices we've received.
    private static let mediaChunkSize = 512 * 1024
    private struct IncomingMedia { let tempURL: URL; let total: Int; var got: Set<Int> }
    private var incoming: [String: IncomingMedia] = [:]

    private init() {}

    /// Initialize the real networked store once (idempotent) and bring the P2P node
    /// online. The feed works offline too; the node just enables real delivery.
    /// Re-initialize for a different identity (e.g. after restoring from a transfer code).
    /// Tears down the old engine, networking, and on-disk state, then configures fresh.
    func reconfigure(seed: Data) {
        node = nil
        nearby = nil
        social = nil
        items.removeAll()
        circles.removeAll()
        try? FileManager.default.removeItem(at: stateURL)
        configure(seed: seed)
    }

    func configure(seed: Data) {
        guard social == nil else { return }
        social = try? HavenSocial(accountSeed: seed)
        loadPersisted()
        refreshCircles()     // also purges any contaminated DM membership (see refreshCircles)
        refresh()
        guard ProcessInfo.processInfo.environment["HAVEN_NO_NET"] != "1" else { return }
        bringOnline(seed: seed)
        startMailboxPolling()
    }

    private func startMailboxPolling() {
        mailboxTimer?.invalidate()
        pollMailboxNow()
        mailboxTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMailboxNow() }
        }
    }

    // MARK: - Circles

    func refreshCircles() {
        purgeDMIntrudersRaw()           // clean DM membership every time we read circles
        circles = social?.circles() ?? []
    }

    /// Evict anyone who isn't one of a DM's two parties (full-id match). Operates directly
    /// on the engine so it can run inside refreshCircles without recursing.
    @discardableResult
    private func purgeDMIntrudersRaw() -> Bool {
        guard let social else { return false }
        var fixed = false
        for circle in social.circles() where circle.id.hasPrefix("dm:") {
            for nodeHex in social.contactNodeIds(circleId: circle.id) where !dmCircleAllows(circle.id, nodeHex) {
                social.removeFromCircle(circleId: circle.id, nodeHex: nodeHex)
                fixed = true
            }
        }
        if fixed { persist() }
        return fixed
    }

    var activeCircleName: String {
        circles.first { $0.id == activeCircleId }?.name ?? "My Circle"
    }

    func setActiveCircle(_ id: String) {
        guard id != activeCircleId else { return }
        activeCircleId = id
        refresh()
        requestMissingMedia()
    }

    /// Create a circle from scratch and switch to it. Add existing contacts next.
    func createCircle(name: String, memberIds: [String] = []) {
        guard let social else { return }
        let id = UUID().uuidString
        social.createCircle(id: id, name: name)
        for m in memberIds { try? social.addExistingToCircle(circleId: id, nodeHex: m) }
        persist(); refreshCircles()
        activeCircleId = id
        refresh()
        if !memberIds.isEmpty { syncWithContacts() }   // greet + back-fill to the new members
    }

    /// Add a known contact to the active circle, then sync so the circle forms on theirs.
    func addContactToActiveCircle(idHex: String) {
        guard let social else { return }
        try? social.addExistingToCircle(circleId: activeCircleId, nodeHex: idHex)
        persist(); refreshCircles()
        syncWithContacts()
    }

    /// Remove a member from the active (custom) circle only — not a global block.
    func removeFromActiveCircle(_ idHex: String) {
        guard let social, activeCircleId != "default" else { return }
        social.removeFromCircle(circleId: activeCircleId, nodeHex: idHex)
        persist(); refreshCircles(); refresh()
    }

    /// Leave the active circle (you always keep the default one).
    func leaveActiveCircle() {
        guard activeCircleId != "default", let social else { return }
        social.leaveCircle(id: activeCircleId)
        persist(); refreshCircles()
        activeCircleId = "default"
        refresh()
    }

    // MARK: - Direct messages (a DM is a private 2-person circle)

    /// Non-DM circles for the feed's circle switcher.
    var feedCircles: [CircleInfoFfi] { circles.filter { !$0.id.hasPrefix("dm:") } }
    /// DM circles (shown in Messages, hidden from the feed switcher).
    var dmCircles: [CircleInfoFfi] { circles.filter { $0.id.hasPrefix("dm:") } }

    /// Deterministic DM circle id (identical on both sides). Uses the FULL sorted node ids
    /// — never truncated prefixes — so two different people can never collide into one DM.
    func dmCircleId(with idHex: String) -> String {
        let pair = [myNodeHex, idHex].sorted()
        return "dm:" + pair[0] + "-" + pair[1]
    }

    /// True only if `nodeHex` is exactly one of the two full ids encoded in a `dm:` circle
    /// id — the guard that stops a third party from handshaking their way into a private DM.
    /// (Old short-prefix ids fail this and get cleaned out by purge — a fresh DM is made.)
    func dmCircleAllows(_ circleId: String, _ nodeHex: String) -> Bool {
        let parts = circleId.dropFirst(3).split(separator: "-").map(String.init)
        guard parts.count == 2 else { return false }
        return parts.contains(nodeHex)
    }

    /// One-time repair for the old broadcast-Hello bug: drop anyone who wrongly ended up
    /// inside a DM circle, so existing threads stop leaking to non-participants.

    /// Start or open a DM with a known contact; returns the dm circle id.
    @discardableResult
    func startDM(with idHex: String, name: String) -> String {
        let id = dmCircleId(with: idHex)
        guard let social else { return id }
        social.createCircle(id: id, name: name)
        try? social.addExistingToCircle(circleId: id, nodeHex: idHex)
        persist(); refreshCircles(); syncWithContacts()
        return id
    }

    /// The other person in a DM (resolved from the non-me member), for display.
    func dmPartnerName(_ circleId: String) -> String {
        let others = (social?.contactNodeIds(circleId: circleId) ?? []).filter { $0 != myNodeHex }
        if let id = others.first { return ContactsStore.shared.name(forNodePrefix: id) ?? "Direct message" }
        return "Direct message"
    }

    /// The other person's node id in a DM (for placing a call).
    func dmPartnerHex(_ circleId: String) -> String? {
        (social?.contactNodeIds(circleId: circleId) ?? []).first { $0 != myNodeHex }
    }

    // MARK: - Connection approval + block

    /// Approve a pending request: add them as a contact, complete the handshake (add
    /// their bundle, Hello back, back-fill posts), then clear the request.
    func approveConnection(_ req: ConnectionRequest, shareHistory: Bool) {
        guard let social else { return }
        let vhex = try? social.bundleVerificationHex(bundle: req.bundle)
        ContactsStore.shared.add(name: req.name, idHex: req.idHex, verificationHex: vhex)
        social.createCircle(id: "default", name: "Your circle")
        _ = try? social.addContactBundle(circleId: "default", bundle: req.bundle)
        ContactsStore.shared.setAuthoritativeName(idHex: req.idHex, req.name)
        lastHeard[req.idHex] = Date()
        if !shareHistory { ConnectionsStore.shared.setNoHistory(req.idHex) }
        persist(); refreshCircles()
        if let hello = helloPayload(circleId: "default", circleName: "Your circle") {
            sendIroh(0, hello, to: req.idHex); nearbyBroadcast(0, hello)
        }
        if shareHistory {
            // Back-fill your past posts to them (and ensure the shared store has them).
            for env in social.syncEnvelopes(circleId: "default") {
                sendIroh(1, eventPayload("default", env), to: req.idHex)
                Task { await SharedStore.uploadEvent(circleId: "default", env: env) }
            }
        }
        ConnectionsStore.shared.removePending(req.idHex)
        refresh()
    }

    /// Block a node id: remember it, purge them from every circle (engine), drop them
    /// from contacts. Future posts/messages/calls/handshakes from them are dropped.
    func blockConnection(_ idHex: String) {
        ConnectionsStore.shared.block(idHex)
        social?.blockMember(nodeHex: idHex)
        if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == idHex }) {
            ContactsStore.shared.remove(c)
        }
        persist(); refreshCircles(); refresh()
    }

    /// Messages of a circle (for a DM thread) without disturbing the main feed.
    func messages(in circleId: String) -> [FeedItemFfi] {
        social?.feed(circleId: circleId, nowMs: now(), viewerRetentionSecs: SettingsStore.shared.retentionSecs) ?? []
    }

    /// Send a text message into a DM circle + broadcast it.
    func sendMessage(to circleId: String, _ body: String) {
        sendMessage(to: circleId, body, media: [], music: nil)
    }

    /// Send a DM with optional media (photos/videos/audio), a song, and optional
    /// disappearing retention (seconds; the message auto-deletes after that).
    func sendMessage(to circleId: String, _ body: String, media: [String], music: TrackRefFfi?, retentionSecs: UInt64? = nil) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: false, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env)
        postTick += 1
        let circle = circleId
        for ref in media { Task { await SharedStore.backup(ref: ref, circleId: circle, social: social) } }
    }

    /// Edit one of your own messages in a specific (DM) circle.
    func editMessage(in circleId: String, _ id: String, _ body: String) {
        guard let social, let env = try? social.edit(circleId: circleId, target: id, body: body, media: [], music: nil, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1; refresh()
    }

    /// Delete (retract) one of your own messages in a specific (DM) circle.
    func deleteMessage(in circleId: String, _ id: String) {
        guard let social, let env = try? social.unsend(circleId: circleId, target: id, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1; refresh()
    }

    /// Delete a whole DM conversation locally (also clears any old contaminated thread).
    func deleteConversation(_ circleId: String) {
        guard let social, circleId.hasPrefix("dm:") else { return }
        social.leaveCircle(id: circleId)
        persist(); refreshCircles(); refresh()
    }

    /// Node ids in a circle for whom we hold keys (handshake complete).
    func handshaked(in circleId: String) -> [String] {
        social?.contactNodeIds(circleId: circleId) ?? []
    }

    // MARK: - Persistence (so posts + contacts survive restarts and updates)

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-feed.json")
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
                let n = try await HavenNode.start(accountSeed: seed, listener: bridge)
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
    var myNodeHex: String { social?.myNodeHex() ?? "" }
    var contactCount: Int { ContactsStore.shared.contacts.count }
    var handshakedCount: Int { social?.contactNodeIds(circleId: activeCircleId).count ?? 0 }
    /// True once we hold this contact's verified public bundle (handshake complete) —
    /// the point at which we can seal to / open from them.
    func isHandshaked(_ idHex: String) -> Bool {
        social?.contactNodeIds(circleId: activeCircleId).contains(idHex) ?? false
    }
    /// True only if we've actually heard from them recently — a real live link, not
    /// just holding (possibly stale) keys.
    func isConnected(_ idHex: String) -> Bool {
        guard let t = lastHeard[idHex] else { return false }
        return Date().timeIntervalSince(t) < 120
    }
    func forceSync() { syncWithContacts(); pollMailboxNow() }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncWithContacts() }
        }
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    func refresh() {
        items = social?.feed(circleId: activeCircleId, nowMs: now(), viewerRetentionSecs: SettingsStore.shared.retentionSecs) ?? []
        SpotlightIndex.reindexAll()   // no-op unless the user enabled Spotlight indexing
    }

    /// The current user's own posts — their personal archive.
    var myPosts: [FeedItemFfi] { items.filter { $0.isMe && !$0.story } }
    var myStories: [FeedItemFfi] { items.filter { $0.isMe && $0.story && !$0.unsent && !$0.media.isEmpty } }

    // MARK: - Authoring (seal locally, then broadcast to contacts)

    func post(_ body: String, media: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil, story: Bool = false, muteVideo: Bool = false) {
        guard let social, let env = try? social.post(circleId: activeCircleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: story, muteVideo: muteVideo, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); postTick += 1; refresh()
        let circle = activeCircleId
        for ref in media { Task { await SharedStore.backup(ref: ref, circleId: circle, social: social) } }
    }

    /// Post a full-screen story to the active circle — auto-expires after 24h (retention).
    /// Stories can carry a caption (the post body) and a song (played in the viewer).
    func postStory(media: [String], caption: String = "", music: TrackRefFfi? = nil) {
        post(caption, media: media, music: music, retentionSecs: 86_400, story: true)
    }

    /// Stories in the active circle (full-screen, ephemeral), newest first.
    var stories: [FeedItemFfi] { items.filter { $0.story && !$0.unsent && !$0.media.isEmpty } }

    /// Stories grouped by author — each user's stories play together, oldest→newest,
    /// and the groups are ordered by who posted most recently.
    var groupedStories: [(author: String, items: [FeedItemFfi])] {
        Dictionary(grouping: stories) { $0.authorShort }
            .map { (author: $0.key, items: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { ($0.items.last?.createdAt ?? 0) > ($1.items.last?.createdAt ?? 0) }
    }
    /// All stories in grouped order (what the viewer pages through).
    var groupedStoriesFlat: [FeedItemFfi] { groupedStories.flatMap { $0.items } }
    /// The index in the flat list where a given group starts.
    func storyStartIndex(forGroup g: Int) -> Int {
        groupedStories.prefix(g).reduce(0) { $0 + $1.items.count }
    }
    /// The regular feed (stories live in the tray, not the main list).
    var feedItems: [FeedItemFfi] { items.filter { !$0.story } }
    func comment(_ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: activeCircleId, target: id, body: body, media: media, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
    }
    func react(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); reactionTick += 1; refresh()
    }
    /// React to a message in a specific (DM) circle.
    func reactMessage(in circleId: String, _ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: circleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(circleId, env); reactionTick += 1; refresh()
    }
    /// Auto-save freshly-received media to Photos when the user enabled "Save to Photos".
    func autoSaveReceived(_ ref: String) {
        if let item = MediaStore.shared.item(ref) { PhotoSaver.saveIfEnabled(item) }
    }

    /// Whether a DM's partner is currently reachable, and when we last heard from them.
    func dmPresence(_ circleId: String) -> (online: Bool, lastSeen: Date?) {
        guard let hex = dmPartnerHex(circleId) else { return (false, nil) }
        return (isConnected(hex), lastHeard[hex])
    }
    func edit(_ id: String, _ body: String, media: [String] = [], music: TrackRefFfi? = nil, muteVideo: Bool = false) {
        guard let social, let env = try? social.edit(circleId: activeCircleId, target: id, body: body, media: media, music: music, muteVideo: muteVideo, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
        let circle = activeCircleId
        for ref in media { Task { await SharedStore.backup(ref: ref, circleId: circle, social: social) } }
    }
    func unsend(_ id: String) {
        guard let social, let env = try? social.unsend(circleId: activeCircleId, target: id, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
    }

    // MARK: - Wire protocol  [type][payload]: 0 Hello, 1 Event, 3 MediaReq, 5 MediaChunk
    //   Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]
    //   Event payload = [LP circleId][sealed envelope]

    /// On add / online / timer: for every circle, send each member our Hello + that
    /// circle's posts, so the circle forms on their side and back-fills.
    func syncWithContacts() {
        guard let social else { return }
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            let envs = social.syncEnvelopes(circleId: circle.id)
            // The default circle bootstraps with ALL QR contacts (newly-added ones aren't
            // members yet — this is how we get their bundle). Other circles target members.
            var targets = Set(social.contactNodeIds(circleId: circle.id))
            if circle.id == "default" {
                for c in ContactsStore.shared.contacts { targets.insert(c.idHex) }
            }
            for nodeHex in targets {
                sendIroh(0, hello, to: nodeHex)
                // Back-fill history only to people we agreed to share it with.
                if ConnectionsStore.shared.sharesHistory(nodeHex) {
                    for env in envs { sendIroh(1, eventPayload(circle.id, env), to: nodeHex) }
                }
            }
            // Only the OPEN default circle broadcasts its handshake to nearby. Custom + DM
            // circles must NOT — a broadcast Hello let any nearby contact handshake their way
            // into a circle they were never added to (membership contamination).
            if circle.id == "default" { nearbyBroadcast(0, hello) }
            // Sealed events are safe to fan out (non-members can't open them; receive() also
            // gates on membership), so keep nearby delivery for posts — just not DMs.
            if !circle.id.hasPrefix("dm:") {
                for env in envs { nearbyBroadcast(1, eventPayload(circle.id, env)) }
            }
            // Mesh: let a relay carry our handshake to members we can't reach directly.
            originateRelay(dests: Array(targets), inner: frame(0, hello))
        }
        requestMissingMedia()
    }

    /// A nearby peer just connected over Bluetooth/Wi-Fi — say hello + back-fill (all circles).
    private func nearbyPeerConnected() {
        guard let social else { return }
        nearbyActive = true
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            if circle.id == "default" { nearbyBroadcast(0, hello) }   // only the open circle broadcasts handshake
            guard !circle.id.hasPrefix("dm:") else { continue }       // DM events stay point-to-point
            for env in social.syncEnvelopes(circleId: circle.id) { nearbyBroadcast(1, eventPayload(circle.id, env)) }
        }
        refresh()
    }

    private func helloPayload(circleId: String, circleName: String) -> Data? {
        guard let social else { return nil }
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        var p = Data()
        lpAppend(&p, Data(circleId.utf8))
        lpAppend(&p, Data(circleName.utf8))
        lpAppend(&p, social.myBundle())
        p.append(social.mySignedProfile(name: myName))   // rest = profile
        return p
    }

    private func eventPayload(_ circleId: String, _ env: Data) -> Data {
        var p = Data(); lpAppend(&p, Data(circleId.utf8)); p.append(env); return p
    }

    private func broadcastEvent(_ circleId: String, _ env: Data) {
        let payload = eventPayload(circleId, env)
        let members = social?.contactNodeIds(circleId: circleId) ?? []
        for nodeHex in members {
            sendIroh(1, payload, to: nodeHex)
            PushManager.shared.wake(nodeHex)   // push-wake offline members so notifications land
        }
        if !circleId.hasPrefix("dm:") { nearbyBroadcast(1, payload) }   // never broadcast DMs to nearby
        originateRelay(dests: members, inner: frame(1, payload))   // reach members behind a relay
        Task { await SharedStore.uploadEvent(circleId: circleId, env: env) }   // store-and-forward mailbox
        persist()   // we just authored something — save it
    }

    /// Poll the shared mailbox and ingest any envelopes uploaded while we (or the sender)
    /// were offline. This is what delivers posts without both ends being online at once.
    func pollMailboxNow() {
        guard SharedStore.isVolunteering, let social else { return }
        let ids = circles.map { $0.id }
        Task { @MainActor in
            let msgs = await SharedStore.pollMailbox(circleIds: ids)
            var changed = false
            for (cid, env) in msgs {
                if (try? social.receive(circleId: cid, envelope: env)) == true {
                    changed = true
                    notifyNewest(in: cid)
                    bumpUnseen(cid)
                }
            }
            if changed { persist(); refresh(); requestMissingMedia() }
        }
    }

    // Length-prefixed field helpers ([u16 LE len][bytes]).
    private func lpAppend(_ d: inout Data, _ field: Data) {
        let n = UInt16(field.count)
        d.append(UInt8(n & 0xff)); d.append(UInt8(n >> 8)); d.append(field)
    }
    private func lpRead(_ d: Data, _ off: inout Int) -> Data? {
        guard d.count >= off + 2 else { return nil }
        let s = d.startIndex
        let n = Int(UInt16(d[s + off]) | UInt16(d[s + off + 1]) << 8)
        off += 2
        guard d.count >= off + n else { return nil }
        let field = d.subdata(in: (s + off)..<(s + off + n))
        off += n
        return field
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
        // Frames that lead with a 64-char sender id (media req + calls): drop if blocked.
        if [3, 10, 11, 12, 13].contains(type) {
            let head = String(data: payload.prefix(64), encoding: .utf8) ?? ""
            if head.count == 64, ConnectionsStore.shared.isBlocked(head) { return }
        }
        switch type {
        case 0: handleHello(payload)
        case 1: handleEvent(payload)
        case 3: handleMediaRequest(payload)
        case 5: handleMediaChunk(payload)
        case 9: handleRelay(payload)
        case 10: CallManager.shared.handleInvite(payload)
        case 11: CallManager.shared.handleAccept(payload)
        case 12: CallManager.shared.handleHangup(payload)
        case 13: CallManager.shared.handleAudio(payload)
        case 14: handleBucketConfig(payload)
        case 15: CallManager.shared.handleVideo(payload)
        default: break
        }
    }

    /// Share my S3 bucket as the circle's shared relay: seal the config to the circle and
    /// broadcast it. Members adopt it as the shared mailbox. (No Haven server sees it.)
    func shareBucketWithCircle() {
        guard let social, StorageStore.shared.s3Configured else { return }
        let cfg = S3Config(endpoint: StorageStore.shared.s3Endpoint, region: StorageStore.shared.s3Region,
                           bucket: StorageStore.shared.s3Bucket, accessKey: StorageStore.shared.s3AccessKey,
                           secret: StorageStore.shared.s3Secret)
        SharedMailboxStore.shared.set(cfg)   // I use it as the relay too
        guard let data = try? JSONEncoder().encode(cfg),
              let sealed = try? social.sealCircleMedia(circleId: activeCircleId, data: data) else { return }
        var p = Data(); lpAppend(&p, Data(activeCircleId.utf8)); p.append(sealed)
        let members = social.contactNodeIds(circleId: activeCircleId)
        for nodeHex in members { sendIroh(14, p, to: nodeHex) }
        nearbyBroadcast(14, p)
        originateRelay(dests: members, inner: frame(14, p))
    }

    private func handleBucketConfig(_ payload: Data) {
        guard let social else { return }
        var off = 0
        guard let cidData = lpRead(payload, &off) else { return }
        let circleId = String(data: cidData, encoding: .utf8) ?? ""
        let sealed = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !sealed.isEmpty,
              let data = social.openCircleMedia(circleId: circleId, sealed: sealed),
              let cfg = try? JSONDecoder().decode(S3Config.self, from: data) else { return }
        SharedMailboxStore.shared.set(cfg)
        pollMailboxNow()   // immediately pull from the newly-shared bucket
    }

    /// Send a call signaling/audio frame to a peer (direct, over the internet transport).
    func sendCallFrame(_ type: UInt8, _ payload: Data, to nodeHex: String) {
        sendIroh(type, payload, to: nodeHex)
    }

    // MARK: - Mesh relay  [9] payload = [msgId(16)][ttl(1)][destCount(1)][dest×32…][inner frame]
    // Lets an internet-connected nearby peer forward a sealed frame it can't read toward
    // its destination. The routing header is cleartext (dest ids + msg id + ttl); the
    // wrapped payload stays end-to-end encrypted. Relays never decrypt — they just route.

    private static let relayTTL: UInt8 = 4
    private var seenRelay = Set<String>()

    /// Originate a relayable copy of a frame, flooded over the nearby mesh.
    private func originateRelay(dests: [String], inner: Data) {
        var id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        seenRelay.insert(id.map { String(format: "%02x", $0) }.joined())
        emitRelay(msgId: &id, ttl: Self.relayTTL, dests: dests, inner: inner)
    }

    private func emitRelay(msgId: inout Data, ttl: UInt8, dests: [String], inner: Data) {
        let destBytes = dests.compactMap { nodeIdBytes($0) }
        guard !destBytes.isEmpty else { return }
        var p = Data()
        p.append(msgId)
        p.append(ttl)
        p.append(UInt8(min(destBytes.count, 255)))
        for d in destBytes.prefix(255) { p.append(d) }
        p.append(inner)
        nearby?.broadcast(frame(9, p))
    }

    private func handleRelay(_ payload: Data) {
        guard payload.count >= 18 else { return }
        let s = payload.startIndex
        var msgId = payload.subdata(in: s..<(s + 16))
        let key = msgId.map { String(format: "%02x", $0) }.joined()
        guard !seenRelay.contains(key) else { return }   // dedup / loop protection
        seenRelay.insert(key)
        if seenRelay.count > 2000 { seenRelay.removeAll() }
        let ttl = payload[s + 16]
        let destCount = Int(payload[s + 17])
        var off = 18
        guard payload.count >= off + destCount * 32 else { return }
        var dests: [String] = []
        for _ in 0..<destCount {
            dests.append(nodeHex(payload.subdata(in: (s + off)..<(s + off + 32))))
            off += 32
        }
        let inner = payload.subdata(in: (s + off)..<payload.endIndex)
        guard !inner.isEmpty else { return }

        let me = myNodeHex
        // If it's for me, process it as a normal inbound frame.
        if dests.contains(me) {
            handleInbound(inner, viaNearby: true)
        }
        // Forward to any other destinations we can reach, and keep it hopping nearby.
        guard ttl > 0 else { return }
        for dest in dests where dest != me {
            sendRaw(inner, to: dest)            // over the internet, if we can reach them
        }
        emitRelay(msgId: &msgId, ttl: ttl - 1, dests: dests, inner: inner)   // re-flood nearby
    }

    /// Send an already-framed payload as-is (used to forward relayed frames).
    private func sendRaw(_ framed: Data, to nodeHex: String) {
        guard let node else { return }
        Task { [weak self] in
            do { try await node.sendToNode(nodeIdHex: nodeHex, payload: framed) }
            catch { await MainActor.run { self?.lastSendError = error.localizedDescription } }
        }
    }

    private func nodeIdBytes(_ hexStr: String) -> Data? {
        guard hexStr.count == 64 else { return nil }
        var d = Data(); var i = hexStr.startIndex
        while i < hexStr.endIndex {
            let j = hexStr.index(i, offsetBy: 2)
            guard let b = UInt8(hexStr[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }

    // MARK: - Media transfer  [3] request(ref) → [4] sealed media back

    /// Ask contacts for any media our feed references but we don't hold the bytes for.
    /// Actively (re-)request one media ref from every contact, nearby, and the shared
    /// store. Safe to call repeatedly — re-sent chunks just fill the gaps a lossy transfer
    /// left, which is what large videos need (one dropped chunk otherwise hangs forever).
    func requestMedia(_ ref: String) {
        guard let social, !MediaStore.shared.has(ref) else { return }
        let myHex = social.myNodeHex()
        var payload = Data(myHex.utf8); payload.append(Data(ref.utf8))
        for contact in ContactsStore.shared.contacts { sendIroh(3, payload, to: contact.idHex) }
        nearbyBroadcast(3, payload)
        let circleIds = circles.map { $0.id }
        Task { @MainActor in   // also pull from the circle's shared store if one exists
            if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                MediaStore.shared.store(ref, data); autoSaveReceived(ref); refresh()
            }
        }
    }

    private func requestMissingMedia() {
        guard let social, node != nil || nearby != nil else { return }
        let myHex = social.myNodeHex()
        var missing = Set<String>()
        for item in items {
            for ref in item.media where !MediaStore.shared.has(ref) { missing.insert(ref) }
            for c in item.comments { for ref in c.media where !MediaStore.shared.has(ref) { missing.insert(ref) } }
        }
        let circleIds = circles.map { $0.id }
        for ref in missing {
            var payload = Data(myHex.utf8)          // 64-byte requester id
            payload.append(Data(ref.utf8))
            for contact in ContactsStore.shared.contacts { sendIroh(3, payload, to: contact.idHex) }
            nearbyBroadcast(3, payload)
            // Also try restoring it from a shared store (my own bucket), if I run one.
            if SharedStore.isVolunteering {
                Task { @MainActor in
                    if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        MediaStore.shared.store(ref, data); autoSaveReceived(ref); refresh()
                    }
                }
            }
        }
    }

    private func handleMediaRequest(_ payload: Data) {
        guard payload.count > 64 else { return }
        let requesterHex = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let ref = String(data: payload.dropFirst(64), encoding: .utf8) ?? ""
        guard requesterHex.count == 64, !ref.isEmpty else { return }
        if let url = MediaStore.shared.storagePath(for: ref), FileManager.default.fileExists(atPath: url.path) {
            sendMediaChunks(ref: ref, fileURL: url, to: requesterHex)
            return
        }
        // I don't hold it locally — if I'm the circle's backup, restore it and serve.
        guard SharedStore.isVolunteering, let social else { return }
        let circleIds = circles.map { $0.id }
        Task { @MainActor in
            if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                MediaStore.shared.store(ref, data)
                if let url = MediaStore.shared.storagePath(for: ref) {
                    sendMediaChunks(ref: ref, fileURL: url, to: requesterHex)
                }
            }
        }
    }

    /// Stream a media file to the requester as individually-sealed chunks — low memory,
    /// large-file friendly. Chunk N's plaintext goes at offset N*chunkSize on reassembly.
    private func sendMediaChunks(ref: String, fileURL url: URL, to requesterHex: String) {
        guard let social, let handle = try? FileHandle(forReadingFrom: url) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let total = max(1, (size + Self.mediaChunkSize - 1) / Self.mediaChunkSize)
        let refData = Data(ref.utf8)
        Task { @MainActor in
            defer { try? handle.close() }
            var index = 0
            while true {
                let chunk = handle.readData(ofLength: Self.mediaChunkSize)
                if chunk.isEmpty { break }
                guard let sealed = try? social.sealMedia(recipientNodeHex: requesterHex, data: chunk) else { break }
                let out = Data([5]) + Self.chunkFrame(refData: refData, index: index, total: total, sealed: sealed)
                if let node { try? await node.sendToNode(nodeIdHex: requesterHex, payload: out) }
                nearby?.broadcast(out)
                index += 1
            }
        }
    }

    private static func chunkFrame(refData: Data, index: Int, total: Int, sealed: Data) -> Data {
        var f = Data()
        let rl = UInt16(refData.count)
        f.append(UInt8(rl & 0xff)); f.append(UInt8(rl >> 8))
        f.append(refData)
        for v in [UInt32(index), UInt32(total)] {
            f.append(UInt8(v & 0xff)); f.append(UInt8((v >> 8) & 0xff))
            f.append(UInt8((v >> 16) & 0xff)); f.append(UInt8((v >> 24) & 0xff))
        }
        f.append(sealed)
        return f
    }

    private func handleMediaChunk(_ payload: Data) {
        guard let social, payload.count >= 2 else { return }
        let lb = [UInt8](payload.prefix(2))
        let refLen = Int(UInt16(lb[0]) | UInt16(lb[1]) << 8)
        guard payload.count >= 2 + refLen + 8 else { return }
        let ref = String(data: payload.subdata(in: 2..<(2 + refLen)), encoding: .utf8) ?? ""
        var off = 2 + refLen
        let index = Int(Self.readU32(payload, off)); off += 4
        let total = Int(Self.readU32(payload, off)); off += 4
        let sealed = payload.subdata(in: off..<payload.count)
        guard !ref.isEmpty, total > 0, !MediaStore.shared.has(ref),
              let plain = social.openMedia(sealed: sealed) else { return }

        var entry = incoming[ref] ?? IncomingMedia(tempURL: MediaStore.shared.makeTempFile(), total: total, got: [])
        if let fh = try? FileHandle(forWritingTo: entry.tempURL) {
            try? fh.seek(toOffset: UInt64(index) * UInt64(Self.mediaChunkSize))
            fh.write(plain)
            try? fh.close()
        }
        entry.got.insert(index)
        incoming[ref] = entry
        if entry.got.count >= entry.total {
            MediaStore.shared.adopt(ref, from: entry.tempURL)
            autoSaveReceived(ref)
            incoming[ref] = nil
            refresh()   // re-render so the media appears
            // If I'm the circle's backup, cache this received media to my bucket too.
            if SharedStore.isVolunteering {
                let circle = activeCircleId
                Task { await SharedStore.backup(ref: ref, circleId: circle, social: social) }
            }
        }
    }

    private static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        let s = d.startIndex + off
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }

    private func nodeHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func isContact(_ idHex: String) -> Bool {
        ContactsStore.shared.contacts.contains { $0.idHex == idHex }
    }

    private func handleHello(_ payload: Data) {
        guard let social else { return }
        // [LP circleId][LP circleName][LP bundle][signed profile]
        var off = 0
        guard let circleIdData = lpRead(payload, &off),
              let circleNameData = lpRead(payload, &off),
              let bundle = lpRead(payload, &off), bundle.count >= 32 else { return }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let circleName = String(data: circleNameData, encoding: .utf8) ?? "Circle"
        guard !circleId.isEmpty else { return }
        let profileBlob = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        let idHex = nodeHex(bundle.prefix(32))
        // Blocked people get dropped entirely — no add, no re-add.
        if ConnectionsStore.shared.isBlocked(idHex) { return }
        // Someone new reaching us through our invite → hold for approval (don't auto-add).
        // One person scans; the other gets asked, with safety words to verify.
        if !isContact(idHex) {
            let name = social.verifyProfile(bundle: bundle, blob: profileBlob) ?? "Someone"
            let vhex = (try? social.bundleVerificationHex(bundle: bundle)) ?? ""
            let display = name.isEmpty ? "Someone" : name
            ConnectionsStore.shared.addPending(ConnectionRequest(
                idHex: idHex, name: display, bundle: bundle,
                safetyWords: SafetyWords.words(fromHex: vhex)))
            NotificationManager.shared.notify(title: "New connection",
                                              body: "\(display) wants to connect",
                                              dedupeKey: "req-\(idHex)")
            return
        }
        if let expected = ContactsStore.shared.verification(forNodePrefix: idHex),
           let actual = try? social.bundleVerificationHex(bundle: bundle),
           expected != actual {
            return
        }
        // A DM circle is strictly its two encoded parties — never let a third party (e.g. a
        // contact who picked up a broadcast Hello) handshake their way into someone else's DM.
        if circleId.hasPrefix("dm:") && !dmCircleAllows(circleId, idHex) { return }
        // Ensure the circle exists on our side, then add the sender to it.
        let isNewCircle = circleId != "default" && !circles.contains { $0.id == circleId }
        social.createCircle(id: circleId, name: circleName)
        if isNewCircle {
            let who = ContactsStore.shared.name(forNodePrefix: idHex) ?? "Someone"
            NotificationManager.shared.notify(title: "Added to a circle",
                                              body: "\(who) added you to “\(circleName)”",
                                              dedupeKey: "circle-\(circleId)")
        }
        guard (try? social.addContactBundle(circleId: circleId, bundle: bundle)) != nil else { return }
        lastHeard[idHex] = Date()
        persist(); refreshCircles()
        if !profileBlob.isEmpty,
           let authName = social.verifyProfile(bundle: bundle, blob: profileBlob), !authName.isEmpty {
            ContactsStore.shared.setAuthoritativeName(idHex: idHex, authName)
        }
        // Reply so the circle is mutual + back-fill its posts to them. Direct-send to the
        // sender always; only the open default circle's handshake fans out to nearby (a
        // broadcast reply for a custom/DM circle is what contaminated their membership).
        let isDM = circleId.hasPrefix("dm:")
        if let hello = helloPayload(circleId: circleId, circleName: circleName) {
            sendIroh(0, hello, to: idHex)
            if circleId == "default" { nearbyBroadcast(0, hello) }
        }
        for env in social.syncEnvelopes(circleId: circleId) {
            sendIroh(1, eventPayload(circleId, env), to: idHex)
            if !isDM { nearbyBroadcast(1, eventPayload(circleId, env)) }
        }
        refresh()
    }

    private func handleEvent(_ payload: Data) {
        guard let social else { return }
        // [LP circleId][sealed envelope]
        var off = 0
        guard let circleIdData = lpRead(payload, &off) else { return }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let envelope = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !envelope.isEmpty else { return }
        if (try? social.receive(circleId: circleId, envelope: envelope)) == true {
            persist()
            refresh()
            requestMissingMedia()   // pull any photos/videos it references
            notifyNewest(in: circleId)
            bumpUnseen(circleId)
        }
    }

    func markCircleSeen() { unseenCircle = 0 }
    func markMessagesSeen() { unseenMessages = 0 }

    /// Count a fresh inbound item as "unseen" for the badge (ignores historical back-fill).
    private func bumpUnseen(_ circleId: String) {
        let inbound = messages(in: circleId).filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard now() &- newest.createdAt < 5 * 60 * 1000 else { return }   // recent only
        if circleId.hasPrefix("dm:") { unseenMessages += 1 } else { unseenCircle += 1 }
    }

    /// Post a local notification for the newest inbound item in a circle (no server).
    private func notifyNewest(in circleId: String) {
        let inbound = messages(in: circleId).filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        let name = ContactsStore.shared.name(forNodePrefix: newest.authorShort) ?? "Someone"
        let body = newest.story ? "shared a story" : (newest.body.isEmpty ? "sent you media" : newest.body)
        let title = circleId.hasPrefix("dm:") ? name : "\(name) in your circle"
        NotificationManager.shared.notify(title: title, body: body, dedupeKey: newest.id)
    }
}

struct FeedView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    let friendName: String
    let seed: Data

    @State private var compose = ""
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var muteVideo = false   // author's audio choice for attached video(s)
    @State private var showMediaPicker = false
    @State private var showCamera = false
    @State private var showSongPicker = false
    @State private var showLocationPicker = false
    @State private var composeRetention: UInt64?
    @State private var showNewCircle = false
    @State private var newCircleName = ""
    @State private var showStoryCamera = false
    @State private var showStories = false
    @State private var storyIndex = 0
    @State private var trimmingRef: TrimTarget?
    @State private var showRequests = false
    @ObservedObject private var connections = ConnectionsStore.shared
    @FocusState private var composeFocused: Bool

    struct TrimTarget: Identifiable { let id = UUID(); let ref: String }

    init(seed: Data, friendName: String) {
        self.seed = seed
        self.friendName = friendName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { composeFocused = false }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        banner
                        if !connections.pending.isEmpty { pendingBanner }
                        storiesTray
                        if store.feedItems.isEmpty {
                            emptyState
                        }
                        ForEach(store.feedItems, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onComment: { b, m in
                                    withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) }
                                    // Reveal the freshly added reply (it lands at the post's bottom).
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(HavenTheme.smooth) { proxy.scrollTo(item.id, anchor: .bottom) }
                                    }
                                },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } }
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
                    .animation(HavenTheme.bouncy, value: store.items.count)
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
                }   // ScrollViewReader
                composerBar
            }
            .navigationTitle(store.activeCircleName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(store.feedCircles, id: \.id) { c in
                            Button { store.setActiveCircle(c.id) } label: {
                                Label(c.name, systemImage: c.id == store.activeCircleId ? "checkmark" : "circle.dashed")
                            }
                        }
                        Divider()
                        Button { newCircleName = ""; showNewCircle = true } label: {
                            Label("New circle…", systemImage: "plus.circle")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.activeCircleName).font(.headline)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings.silent.toggle() } label: {
                        Image(systemName: settings.silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .tint(settings.silent ? .secondary : HavenTheme.pink)
                    .accessibilityLabel(settings.silent ? "Unmute app" : "Mute app")
                }
            }
            .sheet(isPresented: $showNewCircle) {
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }
            }
            .onAppear { store.configure(seed: seed) }
            .sensoryFeedback(.success, trigger: store.postTick)
            .sensoryFeedback(.impact(weight: .light), trigger: store.reactionTick)
            .sheet(isPresented: $showMediaPicker) {
                MediaPicker { refs in attachedMedia.append(contentsOf: refs) }
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPicker { ref in attachedMedia.append(ref) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { refs in attachedMedia.append(contentsOf: refs) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showSongPicker) {
                SongPicker { track in attachedTrack = track }
            }
            .fullScreenCover(isPresented: $showStoryCamera) {
                StoryCameraView { ref, caption, track in
                    Task { @MainActor in
                        // A long video becomes up to 5 consecutive story slides.
                        let refs = await MediaStore.shared.splitStoryVideo(ref)
                        for r in refs { store.postStory(media: [r], caption: caption, music: track) }
                    }
                }
            }
            .sheet(isPresented: $showRequests) { ConnectionRequestsView() }
            .fullScreenCover(isPresented: $showStories) {
                StoryViewer(stories: store.groupedStoriesFlat, index: storyIndex, friendName: friendName)
            }
            .fullScreenCover(item: $trimmingRef) { target in
                if let url = MediaStore.shared.storagePath(for: target.ref) {
                    VideoTrimmer(path: url.path) { trimmed in
                        replaceAttached(target.ref, with: MediaStore.shared.importTrimmed(trimmed))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
            Text("Nothing here yet")
                .font(.headline)
            Text("Share your first moment below. As your circle connects, their posts show up here too.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60).padding(.horizontal, 24)
    }

    private var pendingBanner: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark.fill")
                    .font(.title2).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connections.pending.count == 1 ? "1 connection request" : "\(connections.pending.count) connection requests")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Tap to review who wants to connect").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
            .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var storiesTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { showStoryCamera = true } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2).frame(width: 62, height: 62)
                            Image(systemName: "camera.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                        }
                        Text("Add").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                ForEach(Array(store.groupedStories.enumerated()), id: \.element.author) { gi, group in
                    Button { storyIndex = store.storyStartIndex(forGroup: gi); showStories = true } label: {
                        VStack(spacing: 6) {
                            storyThumb(group.items.last ?? group.items[0])   // latest as the cover
                            Text((group.items.first?.isMe ?? false) ? "You" : (ContactsStore.shared.name(forNodePrefix: group.author) ?? friendName))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
        }
    }

    private func storyThumb(_ s: FeedItemFfi) -> some View {
        let img = s.media.first.flatMap { MediaStore.shared.item($0)?.image }
        return ZStack {
            Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
            if let img {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
            } else {
                Circle().fill(Color(.secondarySystemBackground)).frame(width: 56, height: 56)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
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
                        Button { showLocationPicker = true } label: { Label("Pin a location", systemImage: "mappin.and.ellipse") }
                        Divider()
                        Menu {
                            Button("Off") { composeRetention = nil }
                            Button("1 hour") { composeRetention = 3_600 }
                            Button("1 day") { composeRetention = 86_400 }
                            Button("1 week") { composeRetention = 604_800 }
                        } label: { Label("Disappears after…", systemImage: "timer") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(HavenTheme.pink)
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
                            .padding(13).background(HavenTheme.brand, in: Circle())
                            .shadow(color: HavenTheme.pink.opacity(0.4), radius: 8, y: 4)
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
                                .overlay(alignment: .bottomLeading) {
                                    if m.kind == .video { videoEditMenu(ref) }
                                }
                            removeChip { attachedMedia.removeAll { $0 == ref } }
                        }
                    } else if SharedLocation.parse(ref) != nil {
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                                Text("Location").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 56, height: 56)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
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
                    .background(HavenTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
                // Per-post video audio: only meaningful with a video and no song (a song
                // always plays over a muted video). Toggles between the video's own sound
                // and a silent share.
                if attachedTrack == nil && attachedMedia.contains(where: { MediaStore.shared.item($0)?.kind == .video }) {
                    Button { muteVideo.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: muteVideo ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            Text(muteVideo ? "Video muted" : "Video sound").font(.caption2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(muteVideo ? AnyShapeStyle(.secondary) : AnyShapeStyle(HavenTheme.pink))
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
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

    private func videoEditMenu(_ ref: String) -> some View {
        Menu {
            if MediaStore.shared.canTrim(ref) {
                Button { trimmingRef = TrimTarget(ref: ref) } label: { Label("Trim", systemImage: "scissors") }
            }
            Button { muteVideo.toggle() } label: {
                Label(muteVideo ? "Play video sound" : "Mute video sound",
                      systemImage: muteVideo ? "speaker.wave.2" : "speaker.slash")
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.white)
                .padding(4).background(.black.opacity(0.55), in: Circle())
        }
        .padding(3)
    }

    private func replaceAttached(_ old: String, with new: String) {
        if let i = attachedMedia.firstIndex(of: old) { attachedMedia[i] = new }
    }

    private func send() {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        store.post(text, media: attachedMedia, music: attachedTrack, retentionSecs: composeRetention, muteVideo: muteVideo)
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil; muteVideo = false
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
    @ObservedObject private var feed = FeedStore.shared
    @State private var commentText = ""
    @State private var commentMedia: [String] = []
    @State private var showCommentMediaPicker = false
    @State private var showAudioRecorder = false
    @State private var showEdit = false
    @State private var zoomTarget: ZoomTarget?
    @State private var players: [String: AVPlayer] = [:]
    @State private var showReactionPicker = false
    @State private var editCommentId: String?
    @State private var editCommentText = ""
    @State private var editCommentMedia: [String] = []
    @State private var currentPage = 0
    @State private var showHeart = false
    @State private var showReactionDetail = false

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
    /// A post that is exactly one video — the GestureVideoPlayer owns all of its gestures.
    private var isSingleVideoPost: Bool {
        item.media.count == 1 && (item.media.first.map(isVideo) ?? false)
    }
    private func isVideo(_ ref: String) -> Bool { MediaStore.shared.item(ref)?.kind == .video }

    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    /// Double-tap a post to ❤️ it (with an Instagram-style heart pop).
    private func heartIt() {
        react("❤️")
        withAnimation(HavenTheme.bouncy) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(HavenTheme.smooth) { showHeart = false }
        }
    }

    /// Single-tap a post's media to mute/unmute its sound (video audio or its song).
    private func togglePostMute() {
        if item.media.contains(where: isVideo) {
            if audio.activePostId != item.id {
                audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo)
            }
            audio.toggleVideoAudio()
        } else if item.music != nil {
            audio.toggleMusic(postId: item.id, track: item.music)
        }
    }

    private var heartBurst: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 86)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 10)
            .scaleEffect(showHeart ? 1 : 0.4)
            .opacity(showHeart ? 0.95 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if item.unsent {
                Label("Message unsent", systemImage: "minus.circle")
                    .font(.subheadline).italic().foregroundStyle(.secondary)
            } else {
                if !item.body.isEmpty { Text(item.body).font(.body) }
                if !item.media.isEmpty {
                    // For a single-video post the GestureVideoPlayer owns tap/double-tap/hold/
                    // scrub itself (so its hold-to-pause and drag-to-scrub aren't stolen). For
                    // everything else the post-level tap gestures drive mute + heart.
                    if isSingleVideoPost {
                        mediaView
                            .overlay { if showHeart { heartBurst } }
                    } else {
                        mediaView
                            .overlay { if showHeart { heartBurst } }
                            .onTapGesture(count: 2) { heartIt() }       // double-tap to heart
                            .onTapGesture(count: 1) { togglePostMute() } // tap to mute/unmute
                    }
                }
                if let track = item.music { NowPlayingPill(track: track, animating: true) }
                reactionsRow
                if !item.comments.isEmpty { commentsList }
                commentField
            }
        }
        .havenCard()
        .onAppear { syncPlayback() }
        .onDisappear { pauseVideos() }
        .onChange(of: audio.centeredPostId) { syncPlayback() }
        .onChange(of: currentPage) { if isActive { playVisibleVideo() } }
        .sheet(isPresented: $showEdit) { EditPostSheet(item: item) }
        .fullScreenCover(item: $zoomTarget) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        .alert("Edit comment", isPresented: Binding(get: { editCommentId != nil }, set: { if !$0 { editCommentId = nil } })) {
            TextField("Comment", text: $editCommentText)
            Button("Save") { if let id = editCommentId { feed.edit(id, editCommentText, media: editCommentMedia) }; editCommentId = nil }
            Button("Cancel", role: .cancel) { editCommentId = nil }
        }
    }

    @ViewBuilder private var mediaView: some View {
        if item.media.count == 1, let ref = item.media.first, let loc = SharedLocation.parse(ref) {
            LocationMapView(lat: loc.lat, lon: loc.lon, label: loc.label)
        } else if item.media.count == 1, let ref = item.media.first {
            let video = isVideo(ref)
            ZStack(alignment: .bottomTrailing) {
                mediaPage(ref)
                if video { muteButton }
            }
            // Size to the media's own aspect (capped) so wide AND tall media show in full
            // instead of being cropped to a fixed box.
            .aspectRatio(singleAspect(ref), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Tap-to-zoom only for images. For a video, the player owns the single tap
            // (mute) / hold (pause) / drag (scrub); a zoom tap here would swallow them.
            .modifier(ConditionalTap(enabled: !video) { zoomTarget = ZoomTarget(refs: item.media, index: 0) })
        } else if !item.media.isEmpty {
            masonry   // up to 30 photos/videos in a staggered grid; tap any to zoom
        }
    }

    /// Horizontally-scrolling staggered gallery: items flow across two fixed-height rows and
    /// you swipe sideways through them. Each tile keeps its natural aspect (width = row · aspect).
    private var masonry: some View {
        let rows = 2
        let rowHeight: CGFloat = 150
        let rowItems = (0..<rows).map { ri in
            item.media.enumerated().filter { $0.offset % rows == ri }.map { $0.element }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<rows, id: \.self) { ri in
                    HStack(spacing: 6) {
                        ForEach(rowItems[ri], id: \.self) { ref in masonryTile(ref, height: rowHeight) }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: rowHeight * CGFloat(rows) + 6)
    }

    @ViewBuilder private func masonryTile(_ ref: String, height: CGFloat) -> some View {
        if let m = MediaStore.shared.item(ref), let img = m.image {
            // Aspect width for the fixed row height, clamped so a panorama/portrait stays sane.
            let aspect = min(2.4, max(0.6, img.size.width / max(img.size.height, 1)))
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: height * aspect, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .center) {
                    if m.kind == .video {
                        Image(systemName: "play.circle.fill").font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                    }
                }
                .onTapGesture {
                    if let idx = item.media.firstIndex(of: ref) { zoomTarget = ZoomTarget(refs: item.media, index: idx) }
                }
        }
    }

    @ViewBuilder private func mediaPage(_ ref: String) -> some View {
        if isVideo(ref) {
            // No contextMenu for videos — the long-press is reserved for the player's
            // hold-to-pause. Save/Share live in the mute control's menu instead.
            mediaPageContent(ref)
        } else {
            mediaPageContent(ref)
                .contextMenu {
                    Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    if let url = shareURL(ref) {
                        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                }
        }
    }

    /// The on-disk file to hand to the system share sheet (video file, else the image).
    private func shareURL(_ ref: String) -> URL? {
        guard let m = MediaStore.shared.item(ref) else { return nil }
        return m.kind == .video ? m.videoURL : MediaStore.shared.storagePath(for: ref)
    }

    @ViewBuilder private func mediaPageContent(_ ref: String) -> some View {
        if let m = MediaStore.shared.item(ref) {
            if m.kind == .video, let url = m.videoURL {
                // The player owns its gestures: tap → mute, double-tap → heart,
                // hold → pause, horizontal drag → scrub. Letterboxed, loops continuously.
                GestureVideoPlayer(player: playerFor(ref, url),
                                   onTap: { togglePostMute() },
                                   onDoubleTap: { heartIt() })
            } else if let img = m.image {
                Image(uiImage: img).resizable().scaledToFit()      // show the whole image (no crop)
            }
        }
    }

    /// The single-media tile's aspect ratio, taken from the image (or a video's thumbnail).
    private func singleAspect(_ ref: String) -> CGFloat {
        if let sz = MediaStore.shared.item(ref)?.image?.size, sz.width > 0, sz.height > 0 {
            return sz.width / sz.height
        }
        return 4.0 / 3.0
    }

    @ViewBuilder private var muteButton: some View {
        let ref = item.media.first
        Button {
            if audio.activePostId != item.id { audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo) }
            audio.toggleVideoAudio()
        } label: {
            Image(systemName: audio.activePostId == item.id && audio.videoUnmuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white).padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(10)
        // Save/Share lives here for videos (the player's long-press is hold-to-pause, so the
        // video itself no longer carries a contextMenu).
        .contextMenu {
            if let ref {
                Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                if let url = shareURL(ref) {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }
        }
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
            audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo)
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
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 34)
        } else {
            Circle()
                .fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: 34)
                .overlay(Text(String(authorName.prefix(1))).font(.caption2.bold()).foregroundStyle(.white))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if item.isMe {
                avatar
                Text(authorName).font(.subheadline.weight(.semibold))
            } else {
                NavigationLink {
                    UserProfileView(authorHex: item.authorShort, name: authorName)
                } label: {
                    HStack(spacing: 10) {
                        avatar
                        Text(authorName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(relativeTimeShort(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
            if item.edited {
                Text("edited").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            // Sync state for your own posts, only when a shared store is in play (else
            // posts deliver peer-to-peer and there's no "backed up" notion to show).
            if item.isMe && !item.unsent && SharedStore.isVolunteering {
                Image(systemName: feed.relayReachable ? "cloud.fill" : "cloud")
                    .font(.caption2)
                    .foregroundStyle(feed.relayReachable ? AnyShapeStyle(HavenTheme.pink) : AnyShapeStyle(Color.secondary))
                    .help(feed.relayReachable ? "Backed up to your circle's store" : "Waiting to sync")
            }
            Spacer()
            if item.isMe && !item.unsent {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6) }
            }
        }
    }

    private var reactionsRow: some View {
        HStack(spacing: 8) {
            ForEach(item.reactions, id: \.emoji) { r in
                Button { showReactionDetail = true } label: {
                    Text("\(r.emoji) \(r.count)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(r.mine ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.22)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Capsule())
                        .overlay(Capsule().strokeBorder(r.mine ? HavenTheme.pink.opacity(0.5) : .clear))
                }
                .buttonStyle(.plain)
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
        .animation(HavenTheme.bouncy, value: item.reactions.count)
        .sheet(isPresented: $showReactionPicker) {
            ReactionPicker { e in onReact(e) }
        }
        .sheet(isPresented: $showReactionDetail) {
            ReactionDetailView(reactions: item.reactions)
        }
    }

    private var commentsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.comments, id: \.id) { c in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(commentAuthorName(c)).font(.caption.weight(.semibold))
                            .foregroundStyle(c.isMe ? HavenTheme.pink : .secondary)
                        Text(relativeTimeShort(c.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                        if c.unsent {
                            Text("unsent").font(.caption).italic().foregroundStyle(.secondary)
                        } else if !c.body.isEmpty {
                            Text(c.body).font(.caption)
                            if c.edited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    if !c.unsent && !c.media.isEmpty { commentMediaRow(c.media) }
                    if !c.reactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(c.reactions, id: \.emoji) { r in
                                Text("\(r.emoji)\(r.count > 1 ? " \(r.count)" : "")")
                                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                }
                .contextMenu {
                    if !c.unsent {
                        ControlGroup {
                            ForEach(["❤️", "👍", "😂", "😮", "😢", "🔥"], id: \.self) { e in
                                Button(e) { feed.react(c.id, e) }
                            }
                        }
                        if c.isMe {
                            if !c.body.isEmpty {
                                Button { editCommentId = c.id; editCommentText = c.body; editCommentMedia = c.media } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            }
                            Button(role: .destructive) { feed.unsend(c.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
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
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large).foregroundStyle(HavenTheme.pink)
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
                else { Image(systemName: "waveform").frame(maxWidth: .infinity, maxHeight: .infinity).background(HavenTheme.brandHorizontal.opacity(0.25)) }
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
/// Another person's profile — their posts + a stories ring row. Opened by tapping a
/// name or avatar anywhere.
struct UserProfileView: View {
    let authorHex: String
    let name: String
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var showStories = false
    @State private var showNickname = false
    @State private var nicknameDraft = ""

    /// Reflects a nickname edit live (the passed `name` is a snapshot).
    private var resolvedName: String { contacts.name(forNodePrefix: authorHex) ?? name }

    private var posts: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && !$0.story && !$0.unsent }
    }
    private var userStories: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && $0.story && !$0.unsent && !$0.media.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Circle().fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                            .frame(width: 76, height: 76)
                            .overlay(Text(String(resolvedName.prefix(1))).font(.title.bold()).foregroundStyle(.white))
                        HStack(spacing: 6) {
                            Text(resolvedName).font(.title3.bold())
                            Button { nicknameDraft = contacts.contacts.first { $0.idHex.hasPrefix(authorHex) }?.nickname ?? ""; showNickname = true } label: {
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(posts.count) post\(posts.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                    if !userStories.isEmpty {
                        Button { showStories = true } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 58, height: 58)
                                    if let img = userStories.last?.media.first.flatMap({ MediaStore.shared.item($0)?.image }) {
                                        Image(uiImage: img).resizable().scaledToFill().frame(width: 50, height: 50).clipShape(Circle())
                                    }
                                }
                                Text("\(userStories.count) active stor\(userStories.count == 1 ? "y" : "ies")").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .havenCard()
                        }
                        .buttonStyle(.plain)
                    }
                    if posts.isEmpty {
                        ContentUnavailableView("No posts yet", systemImage: "tray",
                                               description: Text("\(name)'s posts will appear here."))
                            .padding(.top, 30)
                    } else {
                        ForEach(posts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: name,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { _ in },
                                onUnsend: { }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(resolvedName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: userStories, index: 0, friendName: resolvedName)
        }
        .alert("Nickname", isPresented: $showNickname) {
            TextField("Nickname", text: $nicknameDraft)
            Button("Save") { ContactsStore.shared.setNickname(idHex: authorHex, nicknameDraft) }
            Button("Clear", role: .destructive) { ContactsStore.shared.setNickname(idHex: authorHex, "") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Set how \(name) shows up for you.") }
    }
}

/// Create a custom circle and pick which contacts go in it.
struct NewCircleView: View {
    var onCreate: (String, [String]) -> Void
    @ObservedObject private var contacts = ContactsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section("Name") { TextField("Circle name (e.g. Family)", text: $name) }
                    Section("Who's in it") {
                        if contacts.contacts.isEmpty {
                            Text("Add some people first.").foregroundStyle(.secondary)
                        }
                        ForEach(contacts.contacts) { c in
                            Button {
                                if selected.contains(c.idHex) { selected.remove(c.idHex) } else { selected.insert(c.idHex) }
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 34, height: 34)
                                        .overlay(Text(String(c.displayName.prefix(1)).uppercased()).font(.subheadline.bold()).foregroundStyle(.white))
                                    Text(c.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selected.contains(c.idHex) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(c.idHex) ? HavenTheme.pink : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        onCreate(name.trimmingCharacters(in: .whitespaces), Array(selected))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct ProfileView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    let friendName: String
    @State private var showStories = false
    @State private var storyIndex = 0

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if !store.myStories.isEmpty { storiesRow }
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
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Your posts")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: store.myStories, index: storyIndex, friendName: friendName)
        }
    }

    private var storiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your stories").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(store.myStories.enumerated()), id: \.element.id) { idx, s in
                        Button { storyIndex = idx; showStories = true } label: {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 64, height: 64)
                                if let img = s.media.first.flatMap({ MediaStore.shared.item($0)?.image }) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 76)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName).font(.title3.bold())
            Text("\(store.myPosts.count) post\(store.myPosts.count == 1 ? "" : "s") · a copy lives on your device")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
