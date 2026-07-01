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

/// Serializes media backups so they don't all load full files into memory at once. backfillMailboxMedia
/// and the per-post backup sites used to spawn a Task PER media ref concurrently — each loading + sealing a
/// full file (2× in RAM) — which ballooned memory to ~3.4GB and jetsam-killed iOS once a device held a lot
/// of media. Process ONE at a time so peak memory is ~one media file, not the whole library.
@MainActor
final class MediaBackupQueue {
    static let shared = MediaBackupQueue()
    private var pending: [(ref: String, cid: String)] = []
    private var draining = false
    func enqueue(_ ref: String, circleId: String, social: HavenSocial) {
        if pending.contains(where: { $0.ref == ref && $0.cid == circleId }) { return }
        pending.append((ref, circleId))
        if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }   // bound the queue itself
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while !pending.isEmpty {
                let job = pending.removeFirst()
                await SharedStore.backup(ref: job.ref, circleId: job.cid, social: social)
            }
            draining = false
        }
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
    // Chunks live in a SIBLING directory "<ref>.p/", NOT nested under the manifest key. On a hierarchical
    // disk relay (blobstore local_put maps each key segment to a directory) the manifest key "haven/media/<ref>"
    // is a FILE, so chunks under "haven/media/<ref>/<i>" would force "<ref>" to be a directory too — a
    // file-vs-dir collision that fails the manifest write. "<ref>.p" is a distinct name → no collision.
    private static func chunkKey(_ ref: String, _ i: Int) -> String { "haven/media/\(ref).p/\(i)" }

    // MARK: - Chunked media transfer (large-blob fix)
    //
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net blobstore). Large videos
    // (600 MB+) sealed into ONE blob under "haven/media/<ref>" exceed that, so a GET truncates and
    // the receiver can't play them (photos, ~5 MB, worked). Fix: slice the SEALED bytes into 8 MB
    // chunks under "haven/media/<ref>.p/<i>" and store a tiny manifest under "haven/media/<ref>". On
    // download, fetch chunks IN ORDER and APPEND to a file on disk (streaming — never hold the full
    // sealed blob in RAM, which OOM-killed Android before). Small media (<= one chunk) stays a single
    // sealed blob (no manifest) for back-compat. This format is BYTE-IDENTICAL across iOS/macOS,
    // Android and desktop so they interoperate.
    static let mediaChunkBytes = 8 * 1024 * 1024   // 8 MB — well under MAX_BLOB, memory-safe
    /// Magic prefix that marks a manifest blob (a sealed envelope is JSON starting with '{', so it can
    /// never collide). Exactly these 9 bytes, then a JSON body.
    static let manifestMagic = Data("HVCHUNK1\n".utf8)

    /// Build the manifest blob for a sealed media of `sizes` chunk lengths.
    private static func makeManifest(sizes: [Int]) -> Data {
        let total = sizes.reduce(0, +)
        let json: [String: Any] = ["v": 1, "chunks": sizes.count, "total": total, "sizes": sizes]
        var out = manifestMagic
        out.append((try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
        return out
    }
    /// If `blob` is a chunk manifest, return the parsed chunk count; else nil (legacy/small single blob).
    private static func parseManifest(_ blob: Data) -> Int? {
        guard blob.count > manifestMagic.count, blob.prefix(manifestMagic.count) == manifestMagic else { return nil }
        let body = blob.suffix(from: blob.startIndex + manifestMagic.count)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let n = obj["chunks"] as? Int, n > 0 else { return nil }
        return n
    }

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
        // Read the file + seal (encrypt MBs) OFF the main thread — doing it on the main actor janked the UI
        // (the serial backup queue runs these back-to-back). The engine + file read are thread-safe.
        guard let url = MediaStore.shared.storagePath(for: ref) else { return }
        let sealed: Data? = await Task.detached(priority: .utility) { () -> Data? in
            guard let raw = try? Data(contentsOf: url) else { return nil }
            return try? social.sealCircleMedia(circleId: circleId, data: raw)
        }.value
        guard let sealed else { HavenLog.sync("backup SEAL-FAIL ref=\(ref)"); return }
        let nodes = relayNodes(circleId)
        let chunked = sealed.count > mediaChunkBytes
        HavenLog.sync("backup ref=\(ref) size=\(sealed.count) chunked=\(chunked) relays=\(nodes.count) s3=\(mailboxClient() != nil)")
        if !nodes.isEmpty {
            // Mirror to EVERY configured relay (redundancy). Content-addressed key → idempotent
            // re-puts, and a relay in backoff is skipped (RelayClients is health-aware).
            for node in nodes {
                // Our OWN hosted relay: store the media directly in the local mailbox (no iroh self-dial).
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    if chunked {
                        var sizes: [Int] = []
                        var off = 0
                        while off < sealed.count {
                            let end = min(off + mediaChunkBytes, sealed.count)
                            let slice = sealed.subdata(in: off..<end)
                            _ = RelayHost.shared.localPut(chunkKey(ref, sizes.count), slice)
                            sizes.append(slice.count); off = end
                        }
                        _ = RelayHost.shared.localPut(key(ref), makeManifest(sizes: sizes))
                    } else {
                        _ = RelayHost.shared.localPut(key(ref), sealed)
                    }
                    continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if await c.has(key: key(ref)) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); continue }
                do {
                    if chunked {
                        var sizes: [Int] = []
                        var off = 0
                        while off < sealed.count {
                            let end = min(off + mediaChunkBytes, sealed.count)
                            let slice = sealed.subdata(in: off..<end)
                            try await c.put(key: chunkKey(ref, sizes.count), data: slice)
                            sizes.append(slice.count); off = end
                        }
                        try await c.put(key: key(ref), data: makeManifest(sizes: sizes))
                    } else {
                        try await c.put(key: key(ref), data: sealed)
                    }
                    RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                }
                catch { RelayHealth.shared.recordFailure(node); RelayClients.forget(node) }
            }
            return
        }
        guard let s3 = mailboxClient() else { HavenLog.sync("backup NO-DEST ref=\(ref)"); return }
        if await s3.headObject(key: key(ref)) { HavenLog.sync("backup s3-have ref=\(ref)"); return }
        do {
            if chunked {
                var sizes: [Int] = []
                var off = 0
                while off < sealed.count {
                    let end = min(off + mediaChunkBytes, sealed.count)
                    let slice = sealed.subdata(in: off..<end)
                    try await s3.putObject(key: chunkKey(ref, sizes.count), data: slice)
                    sizes.append(slice.count); off = end
                }
                try await s3.putObject(key: key(ref), data: makeManifest(sizes: sizes))
            } else {
                try await s3.putObject(key: key(ref), data: sealed)
            }
            HavenLog.sync("backup s3-put OK ref=\(ref) size=\(sealed.count) chunked=\(chunked)")
        }
        catch { HavenLog.sync("backup s3-put FAIL ref=\(ref): \(error.localizedDescription)") }
    }

    /// A source that can serve the manifest+chunk keys for one media ref.
    private enum MediaSource {
        case ownRelay                              // our own hosted relay (local store)
        case relay(RelayClient, String)            // dialed relay client + node hex
        case s3(S3Client)                          // shared/owner bucket
    }
    /// Fetch one key's bytes from a source (nil = miss).
    private static func fetch(_ src: MediaSource, _ key: String) async -> Data? {
        switch src {
        case .ownRelay: return RelayHost.shared.localGet(key)
        case .relay(let c, _): return await c.get(key: key)
        case .s3(let s3): return try? await s3.getObject(key: key)
        }
    }

    /// Fetch a media blob from the circle's mailbox and open it for whichever circle it belongs to.
    /// If the mailbox holds a chunked manifest (large media), reassemble the sealed bytes by streaming
    /// each 8 MB chunk to a temp file on disk — the full sealed blob is NEVER held in RAM during transfer.
    static func restore(ref: String, circleIds: [String], social: HavenSocial) async -> Data? {
        var chosen: MediaSource?
        var head: Data?
        var src = "none"
        // Try every relay of every circle first (fallback reads), then the S3 bucket. We fetch the
        // manifest key "haven/media/<ref>" first; whichever source serves it also serves the chunks.
        outer: for cid in circleIds {
            for node in relayNodes(cid) {
                // OUR OWN hosted relay: read the media from the local store (a sibling/friend uploaded it
                // to us) — we can't dial ourselves. This is what made a host's media show "all spinners".
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    if let s = RelayHost.shared.localGet(key(ref)) { head = s; chosen = .ownRelay; src = "own:\(node.prefix(8))"; break outer }
                    continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if let s = await c.get(key: key(ref)) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); head = s; chosen = .relay(c, node); src = "dial:\(node.prefix(8))"; break outer }
            }
        }
        if head == nil, let s3 = mailboxClient() {
            if let s = try? await s3.getObject(key: key(ref)) { head = s; chosen = .s3(s3); src = "s3" }
        }
        guard let head, let source = chosen else {
            HavenLog.relay("media restore \(ref.prefix(12)): NOT FOUND on any relay/S3")
            return nil
        }

        // Reassemble the SEALED bytes. If `head` is a manifest, stream each chunk to a temp file on disk
        // (bounded RAM: one 8 MB chunk at a time); otherwise `head` IS the sealed blob (legacy/small).
        let sealed: Data?
        if let chunkCount = parseManifest(head) {
            let temp = MediaStore.shared.makeTempFile()
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                try? FileManager.default.removeItem(at: temp)
                HavenLog.relay("media restore \(ref.prefix(12)): temp-open FAIL"); return nil
            }
            var ok = true
            for i in 0..<chunkCount {
                guard let part = await fetch(source, chunkKey(ref, i)) else { ok = false; break }
                do { try handle.write(contentsOf: part) } catch { ok = false; break }
            }
            try? handle.close()
            guard ok else {
                try? FileManager.default.removeItem(at: temp)
                HavenLog.relay("media restore \(ref.prefix(12)): chunked reassemble FAIL via \(src)"); return nil
            }
            sealed = try? Data(contentsOf: temp)   // read the reassembled sealed blob to open it
            try? FileManager.default.removeItem(at: temp)
        } else {
            sealed = head
        }
        guard let blob = sealed else {
            HavenLog.relay("media restore \(ref.prefix(12)): reassembled read FAIL via \(src)"); return nil
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
                if await c.has(key: key) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true; continue }
                do { try await c.put(key: key, data: env); RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true }
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
                    RelayMailboxStore.shared.markSeen(node)
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
