import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if targetEnvironment(macCatalyst)
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
        let seed = Self.relaySeed()
        // Keep the screen on / device awake while relaying (essential on iOS, harmless on Mac).
        PlatformIdle.disabled = true
        Task {
            do {
                let h = try await RelayServerHandle.start(seed: seed, dir: storeDir)
                handle = h
                nodeId = h.nodeIdHex()
                serving = true
                // Tell my circles to use this device as their mailbox.
                FeedStore.shared.broadcastRelayNode(nodeId)
            } catch {
                serving = false
            }
        }
    }

    private func stop() {
        handle = nil           // releases the FFI handle (best-effort; OS reclaims on exit)
        serving = false
        nodeId = ""
        PlatformIdle.disabled = false
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

    /// Whether "start at login" is supported on this build (Mac Catalyst only).
    var loginItemSupported: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// True when the app is currently registered to launch at login. No-op (false) off Catalyst.
    var startsAtLogin: Bool {
        #if targetEnvironment(macCatalyst)
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

/// Per-circle mailbox config: the node id of the Haven relay serving each circle (learned from
/// the relay host's sealed broadcast, or set when this device is the host). When a circle has a
/// relay node id, the app uses it as the mailbox; otherwise it falls back to the S3 option.
@MainActor
final class RelayMailboxStore: ObservableObject {
    static let shared = RelayMailboxStore()
    @Published private(set) var byCircle: [String: String]
    private let key = "haven.relay.byCircle"
    private let defaultKey = "haven.relay.default"
    private init() { byCircle = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }

    /// A relay applied to "all circles (and future ones)": any circle without its own config
    /// uses this. nil = no default (each circle is configured on its own).
    var defaultNodeHex: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey); objectWillChange.send() }
    }

    /// This circle's own relay, else the all-circles default (so new circles inherit it too).
    func nodeId(forCircle circleId: String) -> String? { byCircle[circleId] ?? defaultNodeHex }
    /// The relay set explicitly for this circle (no default fallback) — for the settings UI.
    func explicitNode(forCircle circleId: String) -> String? { byCircle[circleId] }

    func set(circleId: String, nodeHex: String) {
        guard byCircle[circleId] != nodeHex else { return }
        byCircle[circleId] = nodeHex
        UserDefaults.standard.set(byCircle, forKey: key)
    }
    func clear(circleId: String) {
        byCircle[circleId] = nil
        UserDefaults.standard.set(byCircle, forKey: key)
    }
    /// Circles (other than `excluding`) that have an explicit relay — for "copy another circle".
    func circlesWithRelay(excluding: String) -> [String] {
        byCircle.filter { $0.key != excluding && !$0.value.isEmpty }.map(\.key)
    }
}

/// Caches connected `RelayClient`s by relay node id (connecting is async + reusable).
@MainActor
enum RelayClients {
    private static var cache: [String: RelayClient] = [:]
    static func client(_ nodeHex: String) async -> RelayClient? {
        if let c = cache[nodeHex] { return c }
        guard let seed = AccountStore.storedSeed() else { return nil }
        guard let c = try? await RelayClient.connect(seed: seed, relayNodeHex: nodeHex) else { return nil }
        cache[nodeHex] = c
        return c
    }
}
