import Foundation

// Multi-device live sync (roadmap D16, Phase 3 — client wiring).
//
// Makes a user's OWN devices converge: each device writes a self-encrypted snapshot of its
// account state to a per-account mailbox slot it owns, and merges its peers' slots. The merge
// is the CRDT in `p2pcore::selfsync` (last-write-wins per key), exposed through the FFI
// (`AccountStateHandle`, `sealAccountState`/`openAccountState`, `selfSyncSlotKey`). The relay
// only ever holds ciphertext sealed with a key only this account's devices can derive.
//
// v1 scope: the user's PROFILE (name/emoji/bio/link) and GLOBAL SETTINGS. These are scalar
// keys, so applying a merged state needs only `get(key:)` — no key enumeration. Contacts,
// blocked list, and circles (set-like / engine-managed) follow once this round-trips on-device.

/// A stable **per-device** id. All of a user's devices share the account seed (same node id),
/// so each physical device needs its own id to own a sync slot and to break LWW ties. Random
/// 32 bytes, generated once, stored device-local in UserDefaults, never synced.
enum SelfSyncDevice {
    private static let key = "haven.selfsync.deviceId"
    static let id: Data = {
        let d = UserDefaults.standard
        if let hex = d.string(forKey: key), let data = Data(havenHex: hex), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        d.set(data.havenHexString, forKey: key)
        return data
    }()
    static var hex: String { id.havenHexString }
}

@MainActor
final class SelfSyncCoordinator {
    static let shared = SelfSyncCoordinator()
    private init() {}

    private var inFlight = false

    /// Last converged state, persisted so we can detect what changed locally (LWW only advances
    /// a key's stamp when its value actually changes — otherwise two devices would ping-pong).
    private var baseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("haven-selfsync.bin")
    }

    // MARK: state ↔ CRDT mapping (v1: profile + global settings)

    /// The current local state as namespaced key → value bytes (no stamps).
    private func currentLocal() -> [String: Data] {
        var m: [String: Data] = [:]
        let p = ProfileStore.shared
        m["profile:name"] = Data(p.displayName.utf8)
        m["profile:emoji"] = Data(p.emoji.utf8)
        m["profile:bio"] = Data(p.bio.utf8)
        m["profile:link"] = Data(p.link.utf8)
        let s = SettingsStore.shared
        m["setting:saveToPhotos"] = Data([s.saveToPhotos ? 1 : 0])
        m["setting:saveOthersToPhotos"] = Data([s.saveOthersToPhotos ? 1 : 0])
        m["setting:autoOptimize"] = Data([s.autoOptimize ? 1 : 0])
        m["setting:silent"] = Data([s.silent ? 1 : 0])
        m["setting:retentionDays"] = withUnsafeBytes(of: Int32(s.retentionDays).littleEndian) { Data($0) }
        return m
    }

    /// Write a merged state back into the local stores (only when a value actually differs, to
    /// avoid feedback loops through the stores' didSet broadcasts).
    private func applyLocal(_ h: AccountStateHandle) {
        let p = ProfileStore.shared
        if let v = h.get(key: "profile:name"), let s = String(data: v, encoding: .utf8), s != p.displayName { p.displayName = s }
        if let v = h.get(key: "profile:emoji"), let s = String(data: v, encoding: .utf8), s != p.emoji { p.emoji = s }
        if let v = h.get(key: "profile:bio"), let s = String(data: v, encoding: .utf8), s != p.bio { p.bio = s }
        if let v = h.get(key: "profile:link"), let s = String(data: v, encoding: .utf8), s != p.link { p.link = s }

        let s = SettingsStore.shared
        if let b = boolValue(h, "setting:saveToPhotos"), b != s.saveToPhotos { s.saveToPhotos = b }
        if let b = boolValue(h, "setting:saveOthersToPhotos"), b != s.saveOthersToPhotos { s.saveOthersToPhotos = b }
        if let b = boolValue(h, "setting:autoOptimize"), b != s.autoOptimize { s.autoOptimize = b }
        if let b = boolValue(h, "setting:silent"), b != s.silent { s.silent = b }
        if let v = h.get(key: "setting:retentionDays"), v.count == 4 {
            let n = Int(Int32(littleEndian: v.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
            if n != s.retentionDays { s.retentionDays = n }
        }
    }

    private func boolValue(_ h: AccountStateHandle, _ key: String) -> Bool? {
        guard let v = h.get(key: key), let first = v.first else { return nil }
        return first == 1
    }

    // MARK: sync

    /// One full sync pass: fold local changes into the base with fresh stamps, merge every peer
    /// slot, apply the converged result locally, persist, and re-publish our own slot. Safe to
    /// call on a timer; coalesces if already running. No-op without an account or any relay.
    func sync() async {
        guard !inFlight else { return }
        guard let seed = AccountStore.storedSeed() else { return }
        let accountHex = AccountStore.currentNodeHex()
        guard !accountHex.isEmpty else { return }
        let relays = RelayMailboxStore.shared.allRelays()
        guard !relays.isEmpty else { return }   // self-sync needs at least one relay mailbox
        inFlight = true
        defer { inFlight = false }

        // 1. Base = last converged state (or empty).
        let base: AccountStateHandle
        if let data = try? Data(contentsOf: baseURL), let h = try? AccountStateHandle.fromBytes(bytes: data) {
            base = h
        } else {
            base = AccountStateHandle()
        }

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device).
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let device = SelfSyncDevice.id
        for (key, value) in currentLocal() {
            if base.get(key: key) != value {
                _ = try? base.set(key: key, value: value, ts: now, device: device)
            }
        }

        // 3. Pull + merge every peer slot from every relay.
        let prefix = "haven/" + selfSyncSlotPrefix(accountNodeHex: accountHex)
        let ownKey = "haven/" + selfSyncSlotKey(accountNodeHex: accountHex, deviceNodeHex: SelfSyncDevice.hex)
        for node in relays {
            guard let c = await RelayClients.client(node) else { continue }
            let keys = await c.list(prefix: prefix)
            for key in keys where key != ownKey {
                guard let blob = await c.get(key: key) else { continue }
                if let peer = try? openAccountState(accountSeed: seed, sealed: blob) {
                    base.merge(other: peer)
                }
            }
        }

        // 4. Apply the converged state locally + persist the new base.
        applyLocal(base)
        try? base.toBytes().write(to: baseURL, options: .atomic)

        // 5. Re-publish our own slot (sealed) to every relay for redundancy.
        guard let sealed = try? sealAccountState(accountSeed: seed, state: base) else { return }
        for node in relays {
            guard let c = await RelayClients.client(node) else { continue }
            do { try await c.put(key: ownKey, data: sealed); RelayHealth.shared.recordSuccess(node) }
            catch { RelayHealth.shared.recordFailure(node) }
        }
    }
}

private extension Data {
    var havenHexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(havenHex hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self = Data(bytes)
    }
}
