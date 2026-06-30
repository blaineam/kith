import Foundation
import CryptoKit

/// The "volunteer as tribute" shared circle store. A member who turns this on keeps a
/// sealed copy of the circle's media in their own S3 bucket and re-serves it to anyone
/// who's missing it — so memories survive even when the original sender is offline.
///
/// Security: every blob is sealed to the *circle* (seal_circle_media), so the bucket
/// host stores only opaque bytes it cannot read, and a fetched blob is verified against
/// the circle roster before it's opened. No credentials are ever shared between members
/// — the volunteer simply acts as a durable, always-available media source over the
/// existing P2P media protocol. Keys live only in the device Keychain.
/// The circle's shared relay bucket, received (sealed) from whoever volunteered theirs.
/// Distinct from StorageStore (your *own* bucket). Secret lives only in the Keychain.
@MainActor
final class SharedMailboxStore: ObservableObject {
    static let shared = SharedMailboxStore()
    @Published private(set) var config: S3Config?

    private let d = UserDefaults.standard
    private let key = "haven.sharedMailbox"

    private init() {
        if let data = d.data(forKey: key), var c = try? JSONDecoder().decode(S3Config.self, from: data) {
            c.secret = Keychain.get("sharedMailboxSecret") ?? ""
            config = c
        }
    }

    func set(_ c: S3Config) {
        var stored = c; stored.secret = ""   // keep the secret out of UserDefaults
        d.set(try? JSONEncoder().encode(stored), forKey: key)
        Keychain.set(c.secret, for: "sharedMailboxSecret")
        config = c
    }
    func clear() {
        d.removeObject(forKey: key)
        Keychain.set("", for: "sharedMailboxSecret")
        config = nil
    }
}

@MainActor
enum SharedStore {
    /// The bucket to use for the circle's mailbox: the shared relay if one was set,
    /// otherwise your own bucket *if* you've opted in as the volunteer.
    static func mailboxClient() -> S3Client? {
        if let c = SharedMailboxStore.shared.config, c.isComplete { return S3Client(config: c) }
        if StorageStore.shared.shareCircleMedia { return S3Client(StorageStore.shared) }
        return nil
    }
    /// True when this device participates in a shared mailbox (own volunteer or received relay).
    static var isVolunteering: Bool { mailboxClient() != nil }

    private static func key(_ ref: String) -> String { "haven/media/\(ref)" }

    /// The relay node ids serving a circle (the common path) — posts are mirrored to ALL of them
    /// and read from any (graceful fallback if one is down).
    private static func relayNodes(_ circleId: String) -> [String] {
        RelayMailboxStore.shared.relays(forCircle: circleId)
    }
    /// First configured relay — for "does this circle have a relay at all" checks.
    private static func relayNode(_ circleId: String) -> String? {
        relayNodes(circleId).first
    }
    /// This device's OWN S3 bucket (the owner uses its credentials directly).
    static func ownerS3() -> S3Client? { S3Client(StorageStore.shared) }
    private static func isOwner(_ circleId: String) -> Bool {
        PresignStore.shared.ownedCircles.contains(circleId) && ownerS3() != nil
    }
    /// True when a circle has *some* mailbox — a Haven relay, a pre-signed pool, or raw S3 creds.
    static func hasMailbox(_ circleId: String) -> Bool {
        relayNode(circleId) != nil || isOwner(circleId) || PresignStore.shared.hasPool(circleId) || mailboxClient() != nil
    }

    /// Seal a locally-held media blob to the circle and store it in the circle's mailbox
    /// (relay if set, else S3) — idempotent.
    static func backup(ref: String, circleId: String, social: HavenSocial) async {
        guard let raw = MediaStore.shared.rawBytes(ref),
              let sealed = try? social.sealCircleMedia(circleId: circleId, data: raw) else { return }
        let nodes = relayNodes(circleId)
        if !nodes.isEmpty {
            // Mirror to EVERY configured relay (redundancy). Content-addressed key → idempotent
            // re-puts, and a relay in backoff is skipped (RelayClients is health-aware).
            for node in nodes {
                // Our OWN hosted relay: store the media directly in the local mailbox (no iroh self-dial).
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    _ = RelayHost.shared.localPut(key(ref), sealed); continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if await c.has(key: key(ref)) { RelayHealth.shared.recordSuccess(node); continue }
                do { try await c.put(key: key(ref), data: sealed); RelayHealth.shared.recordSuccess(node) }
                catch { RelayHealth.shared.recordFailure(node); RelayClients.forget(node) }
            }
            return
        }
        guard let s3 = mailboxClient() else { return }
        if await s3.headObject(key: key(ref)) { return }
        try? await s3.putObject(key: key(ref), data: sealed)
    }

    /// Fetch a media blob from the circle's mailbox and open it for whichever circle it belongs to.
    static func restore(ref: String, circleIds: [String], social: HavenSocial) async -> Data? {
        var sealed: Data?
        var src = "none"
        // Try every relay of every circle first (fallback reads), then the S3 bucket.
        outer: for cid in circleIds {
            for node in relayNodes(cid) {
                // OUR OWN hosted relay: read the media from the local store (a sibling/friend uploaded it
                // to us) — we can't dial ourselves. This is what made a host's media show "all spinners".
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    if let s = RelayHost.shared.localGet(key(ref)) { sealed = s; src = "own:\(node.prefix(8))"; break outer }
                    continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if let s = await c.get(key: key(ref)) { RelayHealth.shared.recordSuccess(node); sealed = s; src = "dial:\(node.prefix(8))"; break outer }
            }
        }
        if sealed == nil, let s3 = mailboxClient() { sealed = try? await s3.getObject(key: key(ref)); if sealed != nil { src = "s3" } }
        guard let blob = sealed else {
            HavenLog.relay("media restore \(ref.prefix(12)): NOT FOUND on any relay/S3")
            return nil
        }
        for cid in circleIds {
            if let data = social.openCircleMedia(circleId: cid, sealed: blob) {
                HavenLog.relay("media restore \(ref.prefix(12)): OK via \(src), \(data.count)B")
                return data
            }
        }
        HavenLog.relay("media restore \(ref.prefix(12)): found via \(src) (\(blob.count)B) but OPEN FAILED for all \(circleIds.count) circles")
        return nil
    }

    // MARK: - Shared mailbox (store-and-forward for ALL events)
    //
    // A sealed event envelope is already encrypted to the whole circle, so we store the
    // envelope itself in the bucket under mailbox/<circle>/<hash>. The sender uploads
    // when they're online; any member polls + downloads when *they're* online — the two
    // never need to overlap. The bucket only ever holds opaque, circle-sealed blobs.

    private static var seenMailbox = Set<String>()

    private static func mailboxKey(_ circleId: String, _ env: Data) -> String {
        let h = SHA256.hash(data: env).map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/\(h)"
    }

    /// Drop a sealed event envelope into the circle's mailbox (idempotent). Returns whether it
    /// is now safely in the mailbox (already present or just uploaded) — the background uploader
    /// uses this to know when to stop retrying. We only mark a key "seen" on success, so a
    /// failed upload is retried rather than silently dropped.
    @discardableResult
    static func uploadEvent(circleId: String, env: Data) async -> Bool {
        let key = mailboxKey(circleId, env)
        if seenMailbox.contains(key) { return true }
        // Relay (common path) → owner's own bucket → member's pre-signed pool → legacy creds.
        let nodes = relayNodes(circleId)
        if !nodes.isEmpty {
            // Mirror to EVERY configured relay (redundancy). Content-addressed key → idempotent;
            // a relay in backoff is skipped. Success on ANY relay means it's safely in a mailbox.
            var landed = false
            for node in nodes {
                // Our OWN hosted relay: store directly into the local mailbox (no iroh self-connection,
                // which blows up iroh's path machinery) so offline members can still pull our posts.
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    _ = RelayHost.shared.localPut(key, env)
                    landed = true; continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if await c.has(key: key) { RelayHealth.shared.recordSuccess(node); landed = true; continue }
                do { try await c.put(key: key, data: env); RelayHealth.shared.recordSuccess(node); landed = true }
                catch { RelayHealth.shared.recordFailure(node); RelayClients.forget(node) }
            }
            if landed { seenMailbox.insert(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        if PresignStore.shared.hasPool(circleId) && !isOwner(circleId) {
            // Member: write to one of our pre-signed PUT slots (no credentials).
            guard let put = await PresignStore.shared.nextPutURL(circleId: circleId, myHex: FeedStore.shared.myNodeHex) else {
                FeedStore.shared.markRelay(false); return false
            }
            if await S3Client.putURL(put, data: env) { seenMailbox.insert(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        guard let s3 = isOwner(circleId) ? ownerS3() : mailboxClient() else { return false }
        if await s3.headObject(key: key) { seenMailbox.insert(key); FeedStore.shared.markRelay(true); return true }
        do {
            try await s3.putObject(key: key, data: env)
            seenMailbox.insert(key); FeedStore.shared.markRelay(true); return true
        } catch {
            FeedStore.shared.markRelay(false); return false
        }
    }

    /// Poll the mailbox for envelopes we haven't seen. Returns (circleId, envelope) pairs.
    static func pollMailbox(circleIds: [String]) async -> [(String, Data)] {
        var out: [(String, Data)] = []
        for cid in circleIds {
            let prefix = "haven/mailbox/\(cid)/"
            let nodes = relayNodes(cid)
            if !nodes.isEmpty {
                // Read from ALL relays; seenMailbox is keyed by the content-addressed key, so the
                // same envelope mirrored on several relays is ingested exactly once (dedup).
                for node in nodes {
                    // OUR OWN hosted relay: read the local store directly — we can't dial ourselves
                    // (self-dial guard), so this is how the host ingests what a sibling device or a
                    // friend uploaded to it (the previously-missing read-own-relay path).
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                        let localKeys = RelayHost.shared.localList(prefix)
                        let fresh = localKeys.filter { !seenMailbox.contains($0) }
                        HavenLog.relay("poll OWN relay \(cid): \(localKeys.count) keys, \(fresh.count) new")
                        for key in fresh {
                            seenMailbox.insert(key)
                            if let data = RelayHost.shared.localGet(key) { out.append((cid, data)) }
                        }
                        continue
                    }
                    guard let c = await RelayClients.client(node) else { continue }
                    let keys = await c.list(prefix: prefix)
                    RelayHealth.shared.recordSuccess(node)
                    for key in keys where !seenMailbox.contains(key) {
                        seenMailbox.insert(key)
                        if let data = await c.get(key: key) { out.append((cid, data)) }
                    }
                }
            } else if PresignStore.shared.hasPool(cid) && !isOwner(cid) {
                // Member: LIST + GET via the pre-signed pool URLs (no credentials).
                if let listURL = await PresignStore.shared.listURL(cid), let xml = await S3Client.getURL(listURL) {
                    for key in S3Client.parseListKeys(xml) where !seenMailbox.contains(key) {
                        seenMailbox.insert(key)
                        if let g = await PresignStore.shared.getURL(circleId: cid, key: key), let data = await S3Client.getURL(g) {
                            out.append((cid, data))
                        }
                    }
                }
            } else if let s3 = isOwner(cid) ? ownerS3() : mailboxClient(), let s3keys = try? await s3.listKeys(prefix: prefix) {
                for key in s3keys where !seenMailbox.contains(key) {
                    seenMailbox.insert(key)
                    if let data = try? await s3.getObject(key: key) { out.append((cid, data)) }
                }
            }
        }
        return out
    }
}
