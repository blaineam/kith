import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(macOS) || targetEnvironment(macCatalyst)
import ServiceManagement
#endif

/// Runs this device as the circle's **relay / mailbox** in-process (the `haven-relay` core via
/// FFI): an iroh blob store on local disk that holds sealed (unreadable) circle media + events
/// and re-serves them so the circle has an always-available mailbox. The common, zero-setup path
/// — no S3, no terminal, no cloud — just a toggle.
///
/// Lifetime by platform: on **Mac** it runs as long as the app is open (set-and-forget). On
/// **iPhone/iPad** iOS suspends background apps, so it serves while Haven is foregrounded and
/// awake — we disable auto-lock so a device left on a charger keeps relaying. (Linux/Windows use
/// the standalone binary; Android will use a foreground service.)
@MainActor
final class RelayHost: ObservableObject {
    static let shared = RelayHost()

    @Published private(set) var enabled: Bool
    @Published private(set) var serving = false
    @Published private(set) var nodeId = ""

    private var handle: RelayServerHandle?
    private let d = UserDefaults.standard
    private let enabledKey = "haven.relay.host.enabled"

    private init() { enabled = d.bool(forKey: enabledKey) }

    /// Whether this kind of device makes a good always-on relay (informs the UI copy).
    var isDesktopClass: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var storeDir: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-relay-store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        d.set(on, forKey: enabledKey)
        if on { start() } else { stop() }
    }

    /// Restart the relay at launch if the user had it on.
    func startIfEnabled() { if enabled && handle == nil { start() } }

    private func start() {
        guard handle == nil else { return }
        // The relay now ATTACHES to the messaging node's endpoint (one iroh node, two ALPNs) — running a
        // second in-process iroh node is what made iroh churn paths unboundedly (the tens-of-GB leak).
        guard let node = FeedStore.shared.transportNode else {
            // Node not up yet — retry shortly; the relay can't exist without the node to attach to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.start() }
            return
        }
        // Keep the screen on / device awake while relaying (essential on iOS, harmless on Mac).
        PlatformIdle.disabled = true
        let h = RelayServerHandle.attach(node: node, dir: storeDir)
        handle = h
        nodeId = h.nodeIdHex()   // == the account node id now (the relay shares the node)
        serving = true
        RelayMailboxStore.shared.unforget(nodeId)   // hosting is an explicit adoption of our own relay
        // Lock the mailbox down to circle members before announcing it (audit transport-F4).
        authorizeMembership()
        // Tell my circles to use this device (its account node id) as their mailbox.
        FeedStore.shared.broadcastRelayNode(nodeId)
    }

    /// Store one of OUR OWN sealed events/media into the in-process mailbox directly (no iroh
    /// self-connection). Returns false if we aren't currently hosting.
    func localPut(_ key: String, _ data: Data) -> Bool { handle?.localPut(key: key, data: data) ?? false }
    func localHas(_ key: String) -> Bool { handle?.localHas(key: key) ?? false }

    private func stop() {
        handle?.disable()      // detach the relay from the node's endpoint
        handle = nil           // releases the FFI handle (best-effort; OS reclaims on exit)
        serving = false
        nodeId = ""
        PlatformIdle.disabled = false
    }

    /// Mesh anti-entropy: while we're hosting, pull every sealed blob each SIBLING relay holds that
    /// we lack, so the circle's mailbox self-replicates across relays (any relay can join/leave
    /// without losing data). Health-aware — relays in backoff are skipped, and a successful pull
    /// clears their backoff. Mirrors the desktop `mesh_sync`; driven on FeedStore's sync timer.
    /// Push current circle membership to the in-process relay so each circle's mailbox is served ONLY
    /// to its members (+ sibling relays for mesh sync) — a stranger who learns the relay id gets
    /// nothing (audit transport-F4). Idempotent; safe to call on start and whenever membership or the
    /// relay set changes. The relay stays permissive until the first circle is authorized here.
    func authorizeMembership() {
        guard let handle, serving else { return }
        for (cid, members) in FeedStore.shared.circleMemberships() {
            let relays = RelayMailboxStore.shared.relays(forCircle: cid)
            handle.authorizeCircle(circleId: cid, members: members, relays: relays)
        }
    }

    func meshSyncTick() {
        guard let handle, serving else { return }
        authorizeMembership() // keep the allow-list fresh as membership / relays change
        let myHex = nodeId
        // Every distinct adopted relay (≠ self) that isn't currently backed off.
        let peers = RelayMailboxStore.shared.allRelays()
            .filter { $0 != myHex && RelayHealth.shared.available($0) }
        guard !peers.isEmpty else { return }
        Task {
            for peer in peers {
                let pulled = await handle.syncFrom(peerNodeHex: peer)
                if pulled > 0 {
                    RelayHealth.shared.recordSuccess(peer)
                    FeedStore.shared.markRelay(true)
                    // New blobs landed on our store → ingest anything we hadn't seen.
                    FeedStore.shared.pollMailboxNow()
                }
            }
        }
    }

    /// A stable, relay-specific 32-byte identity (distinct from the messaging account), so the
    /// relay's node id is its own and stable across restarts.
    private static func relaySeed() -> Data {
        if let b64 = Keychain.get("relaySeed"), let s = Data(base64Encoded: b64), s.count == 32 { return s }
        var b = Data(count: 32)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        Keychain.set(b.base64EncodedString(), for: "relaySeed")
        return b
    }

    // MARK: - Start at login (Mac Catalyst only)
    //
    // On the Mac we want the relay to come back automatically after a reboot/logout so the
    // circle's mailbox stays "always-on". `SMAppService.mainApp` registers Haven as a login
    // item, so macOS relaunches it at login; the relay then resumes via `startIfEnabled()`.
    //
    // Catalyst can't run a true windowless/menu-bar agent (see notes in `StorageSettingsView`),
    // so the best achievable is: auto-launch at login + keep relaying for the life of the
    // process (the relay is never torn down on background/window-close — only when the toggle
    // is turned off or the app fully quits).

    /// Whether "start at login" is supported (native macOS + Mac Catalyst).
    var loginItemSupported: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// True when the app is currently registered to launch at login. No-op (false) on iOS.
    var startsAtLogin: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }

    /// Register/unregister Haven as a macOS login item. Throws on failure (e.g. unsigned dev
    /// builds, or when the user has disabled the item in System Settings) so the UI can surface
    /// the error. No-op off Catalyst.
    func setStartAtLogin(_ on: Bool) throws {
        #if targetEnvironment(macCatalyst)
        if on {
            // Already enabled? `register()` is idempotent but throws if the user disabled it in
            // System Settings; treat "already enabled" as success.
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
        #endif
    }
}

/// Per-circle mailbox config: the node ids of the Haven relays serving each circle (learned from
/// relay-host sealed broadcasts, or set when this device is the host). A circle can have several
/// relays — posts are mirrored to ALL of them (redundancy) and read from any (graceful fallback).
/// When a circle has no relay, the app falls back to the S3 option.
///
/// Mirrors the desktop `prefs.relays: HashMap<String, Vec<String>>`. The legacy single-relay map
/// (`haven.relay.byCircle` as `[String: String]`) is migrated into the list form on first load.
@MainActor
final class RelayMailboxStore: ObservableObject {
    static let shared = RelayMailboxStore()
    /// circleId -> ordered list of relay node hexes (mirrored writes, fallback reads).
    @Published private(set) var relaysByCircle: [String: [String]]
    private let key = "haven.relay.relaysByCircle"
    private let legacyKey = "haven.relay.byCircle"   // old single-relay-per-circle map
    private let defaultKey = "haven.relay.default"
    private let suppressedKey = "haven.relay.suppressed"
    /// Relays the user explicitly FORGOT. Auto-learn paths (frame-19 announce, SelfSync, bootstrap)
    /// must NOT resurrect these, or forgetting a relay looks like a no-op — the peer/your other device
    /// re-announces it within seconds and it pops right back. Cleared when the relay is adopted again
    /// EXPLICITLY (user pasting a link / tapping Connect). This is what makes Forget actually stick, and
    /// lets stale relays (e.g. a device's pre-upgrade relay id) be cleared for good.
    private var suppressed: Set<String>

    private init() {
        let d = UserDefaults.standard
        var loaded: [String: [String]] = (d.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        // Idempotent migration: fold the legacy single-relay map into the redundant list and drop it.
        if let legacy = d.dictionary(forKey: legacyKey) as? [String: String] {
            for (cid, hex) in legacy where !hex.isEmpty {
                var list = loaded[cid] ?? []
                if !list.contains(hex) { list.append(hex) }
                loaded[cid] = list
            }
            d.removeObject(forKey: legacyKey)
        }
        relaysByCircle = loaded
        suppressed = Set((d.array(forKey: suppressedKey) as? [String]) ?? [])
        if !loaded.isEmpty { d.set(loaded, forKey: key) }
    }

    /// A relay applied to "all circles (and future ones)": any circle inherits it. nil = none.
    var defaultNodeHex: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey); objectWillChange.send() }
    }

    /// Every relay configured for a circle: its own list plus the all-circles default (deduped).
    func relays(forCircle circleId: String) -> [String] {
        var out = relaysByCircle[circleId] ?? []
        if let def = defaultNodeHex, !def.isEmpty, !out.contains(def) { out.append(def) }
        return out
    }
    /// The relays set explicitly for this circle (no default fallback) — for the settings UI.
    func explicitRelays(forCircle circleId: String) -> [String] { relaysByCircle[circleId] ?? [] }

    /// First relay for a circle — back-compat convenience (some callers only need "is there one").
    func nodeId(forCircle circleId: String) -> String? { relays(forCircle: circleId).first }

    /// ADD a relay to a circle (append, don't replace) — mirrors desktop `adopt_relay`. This is the
    /// EXPLICIT path (user adopts / hosts), so it also CLEARS any forgotten-tombstone for the relay —
    /// re-adding a previously-forgotten relay always works. Auto-learn callers must gate on `isForgotten`
    /// BEFORE calling this, so a forgotten relay isn't silently resurrected (that's what makes Forget stick).
    func add(circleId: String, nodeHex: String) {
        let hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64 else { return }
        unforget(hex)
        var list = relaysByCircle[circleId] ?? []
        guard !list.contains(hex) else { return }
        list.append(hex)
        relaysByCircle[circleId] = list
        UserDefaults.standard.set(relaysByCircle, forKey: key)
    }

    /// Whether the user has FORGOTTEN this relay — auto-learn (frame-19 announce / SelfSync / bootstrap)
    /// checks this and skips, so Forget isn't undone within seconds by a re-announce.
    func isForgotten(_ nodeHex: String) -> Bool {
        suppressed.contains(nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Clear a relay's FORGOTTEN tombstone (an explicit adoption overrides a prior Forget).
    func unforget(_ nodeHex: String) {
        let hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard suppressed.remove(hex) != nil else { return }
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
    }
    /// Drop a single relay from a circle.
    func remove(circleId: String, nodeHex: String) {
        guard var list = relaysByCircle[circleId] else { return }
        list.removeAll { $0 == nodeHex }
        if list.isEmpty { relaysByCircle[circleId] = nil } else { relaysByCircle[circleId] = list }
        UserDefaults.standard.set(relaysByCircle, forKey: key)
    }
    /// Forget a relay across EVERY circle (mirrors desktop `forget_relay`); also clears it as the
    /// default and drops its cached connection + health.
    func forget(nodeHex: String) {
        let hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for cid in relaysByCircle.keys {
            relaysByCircle[cid]?.removeAll { $0 == hex }
            if relaysByCircle[cid]?.isEmpty == true { relaysByCircle[cid] = nil }
        }
        if defaultNodeHex == hex { defaultNodeHex = nil }
        // Tombstone it so the frame-19 announce / SelfSync / bootstrap auto-learn can't resurrect it
        // (otherwise Forget is a visible no-op — it reappears within seconds).
        suppressed.insert(hex)
        UserDefaults.standard.set(relaysByCircle, forKey: key)
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        RelayClients.forget(hex)
        RelayHealth.shared.forget(hex)
    }
    /// Remove every relay configured for a circle.
    func clear(circleId: String) {
        relaysByCircle[circleId] = nil
        UserDefaults.standard.set(relaysByCircle, forKey: key)
    }
    /// Circles (other than `excluding`) that have an explicit relay — for "copy another circle".
    func circlesWithRelay(excluding: String) -> [String] {
        relaysByCircle.filter { $0.key != excluding && !$0.value.isEmpty }.map(\.key)
    }
    /// Seed this device's relays from a transfer/link code so a freshly-linked device has a transport
    /// to bootstrap from. Stored under a synthetic circle so `allRelays()` returns them all; the first
    /// SelfSync pull then learns the real circles and registers their relays. (Doesn't appear in the
    /// circles UI — that comes from the social graph, not this store.)
    func adoptBootstrapRelays(_ hexes: [String]) {
        for h in hexes { add(circleId: "__bootstrap__", nodeHex: h) }
        if defaultNodeHex == nil, let first = hexes.first(where: { $0.count == 64 }) { defaultNodeHex = first }
    }

    /// Every distinct relay across all circles — for the settings list / mesh sync.
    func allRelays() -> [String] {
        var seen: [String] = []
        for list in relaysByCircle.values { for h in list where !seen.contains(h) { seen.append(h) } }
        if let def = defaultNodeHex, !def.isEmpty, !seen.contains(def) { seen.append(def) }
        return seen
    }
}

/// Per-relay exponential backoff so a dead relay is skipped and auto-recovers — a 1:1 port of the
/// desktop `RelayHealth` (5s base, ×2 each failure, capped at 5m; success clears it).
@MainActor
final class RelayHealth: ObservableObject {
    static let shared = RelayHealth()
    private init() {}

    private struct Health { var fails: UInt32 = 0; var nextRetryMs: UInt64 = 0 }
    private var byNode: [String: Health] = [:]

    private static let baseBackoffMs: UInt64 = 5_000     // first failure → 5s cool-off
    private static let maxBackoffMs: UInt64 = 300_000    // capped at 5 minutes
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Is the relay usable right now (not inside a backoff window)? Unknown relays are available.
    func available(_ nodeHex: String) -> Bool {
        guard let h = byNode[nodeHex] else { return true }
        return nowMs() >= h.nextRetryMs
    }
    /// A successful op clears the backoff.
    func recordSuccess(_ nodeHex: String) {
        byNode[nodeHex] = Health(fails: 0, nextRetryMs: 0)
        objectWillChange.send()
    }
    /// A failure grows the backoff exponentially (5s, 10s, 20s … capped at 5m).
    func recordFailure(_ nodeHex: String) {
        var h = byNode[nodeHex] ?? Health()
        h.fails = h.fails == UInt32.max ? h.fails : h.fails + 1
        let shift = UInt64(min(h.fails - 1, 6))   // cap the exponent so the shift never overflows
        let backoff = min(Self.baseBackoffMs * (1 << shift), Self.maxBackoffMs)
        h.nextRetryMs = nowMs() + backoff
        byNode[nodeHex] = h
        objectWillChange.send()
    }
    func forget(_ nodeHex: String) { byNode[nodeHex] = nil; objectWillChange.send() }
}

/// Caches connected `RelayClient`s by relay node id (connecting is async + reusable). Skips a relay
/// that's currently in its backoff window (health-aware), and records success/failure so a dead
/// relay backs off and a recovered one is picked up again.
@MainActor
enum RelayClients {
    private static var cache: [String: RelayClient] = [:]
    /// A connected client for a relay, honoring per-relay backoff. nil if in backoff or unreachable.
    static func client(_ nodeHex: String) async -> RelayClient? {
        if let c = cache[nodeHex] { return c }
        // NEVER connect to our OWN hosted relay node. A node dialing itself sends iroh's path discovery
        // into a tight loop (open_path_on_all_conns / normalize_network_path), exploding memory by tens
        // of GB in minutes — THE runaway leak. We already ARE this relay; we never need a client to it.
        if RelayHost.shared.serving, !RelayHost.shared.nodeId.isEmpty, nodeHex == RelayHost.shared.nodeId {
            return nil
        }
        guard RelayHealth.shared.available(nodeHex) else { return nil }   // skip relays in backoff
        guard let seed = AccountStore.storedSeed() else { return nil }
        guard let c = try? await RelayClient.connect(seed: seed, relayNodeHex: nodeHex) else {
            RelayHealth.shared.recordFailure(nodeHex)
            return nil
        }
        RelayHealth.shared.recordSuccess(nodeHex)
        cache[nodeHex] = c
        return c
    }
    /// Drop a relay's cached connection (after a failure, or when forgetting it).
    static func forget(_ nodeHex: String) { cache[nodeHex] = nil }
}
