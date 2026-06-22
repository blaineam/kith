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

    /// Seal a locally-held media blob to the circle and upload it (idempotent).
    static func backup(ref: String, circleId: String, social: HavenSocial) async {
        guard let s3 = mailboxClient(), let raw = MediaStore.shared.rawBytes(ref) else { return }
        if await s3.headObject(key: key(ref)) { return }   // already stored
        guard let sealed = try? social.sealCircleMedia(circleId: circleId, data: raw) else { return }
        try? await s3.putObject(key: key(ref), data: sealed)
    }

    /// Fetch a blob from the bucket and open it for whichever circle it belongs to.
    static func restore(ref: String, circleIds: [String], social: HavenSocial) async -> Data? {
        guard let s3 = mailboxClient() else { return nil }
        guard let sealed = try? await s3.getObject(key: key(ref)) else { return nil }
        for cid in circleIds {
            if let data = social.openCircleMedia(circleId: cid, sealed: sealed) { return data }
        }
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

    /// Drop a sealed event envelope into the circle's mailbox (idempotent).
    static func uploadEvent(circleId: String, env: Data) async {
        guard let s3 = mailboxClient() else { return }
        let key = mailboxKey(circleId, env)
        if seenMailbox.contains(key) { return }
        seenMailbox.insert(key)
        if await s3.headObject(key: key) { FeedStore.shared.markRelay(true); return }
        do { try await s3.putObject(key: key, data: env); FeedStore.shared.markRelay(true) }
        catch { FeedStore.shared.markRelay(false) }
    }

    /// Poll the mailbox for envelopes we haven't seen. Returns (circleId, envelope) pairs.
    static func pollMailbox(circleIds: [String]) async -> [(String, Data)] {
        guard let s3 = mailboxClient() else { return [] }
        var out: [(String, Data)] = []
        for cid in circleIds {
            guard let keys = try? await s3.listKeys(prefix: "haven/mailbox/\(cid)/") else { continue }
            for key in keys where !seenMailbox.contains(key) {
                seenMailbox.insert(key)
                if let data = try? await s3.getObject(key: key) { out.append((cid, data)) }
            }
        }
        return out
    }
}
