import Foundation
import Security

/// Owns the user's Haven account. Persists only the 32-byte master seed in the
/// Keychain; the full identity (all hybrid-PQ keys) is derived from it on launch.
///
/// Multi-device: the seed can optionally sync across *your* Apple devices via iCloud
/// Keychain (Apple's E2E sync), and can be moved to any client (web/Android/another
/// phone) with a one-time transfer code / QR. The seed never touches a Haven server.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var account: Account
    /// True when the keychain was unreadable at init (e.g., launched before first unlock):
    /// we use a throwaway identity and DID NOT touch the real seed. `reloadIfTemporary()`
    /// swaps in the real one once the keychain is accessible.
    private(set) var usingTemporaryIdentity = false

    private static let service = "com.blaineam.kith"
    private static let seedKey = "account-master-seed"
    private static let syncDefaultsKey = "haven.icloud.identitySync"

    init() {
        switch Self.loadSeedStatus() {
        case .found(let seed):
            if let restored = try? Account.fromSeed(seed: seed) {
                account = restored
                // Re-store device-local: converts any legacy *synchronizable* seed to
                // device-only so iCloud Keychain can never carry/clobber it again. Also record
                // it in the recoverable identity history.
                Self.saveSeed(seed)
                Self.archive(seed)
            } else {
                // Seed present but un-deriveable — NEVER overwrite it; use a temp identity.
                account = Account.generate(); usingTemporaryIdentity = true
            }
        case .notFound:
            // Genuinely a new install → make + save the first identity. (Only here do we write.)
            let fresh = Account.generate()
            Self.saveSeed(fresh.secretSeed())
            Self.archive(fresh.secretSeed())
            account = fresh
        case .lockedOrError:
            // Keychain not accessible yet (locked). Generating + saving here would DESTROY the
            // real identity — the bug that flipped your old content to "not me". Use a throwaway
            // and reload the real seed once unlocked. Do NOT save.
            account = Account.generate(); usingTemporaryIdentity = true
        }
    }

    /// Re-attempt loading the real seed (call when the app becomes active / keychain unlocks).
    func reloadIfTemporary() {
        guard usingTemporaryIdentity, case .found(let seed) = Self.loadSeedStatus(),
              let restored = try? Account.fromSeed(seed: seed) else { return }
        account = restored
        usingTemporaryIdentity = false
        FeedStore.shared.reconfigure(seed: account.secretSeed())
    }

    /// Wipe the identity and create a new one ("start over"). The old identity is archived to
    /// the history first, so it can still be rolled back to.
    func reset() {
        Self.archive(account.secretSeed())
        Self.deleteSeed()
        let fresh = Account.generate()
        Self.saveSeed(fresh.secretSeed())
        account = fresh
    }

    // MARK: - Multi-device: iCloud Keychain sync

    static var iCloudSyncEnabled: Bool { UserDefaults.standard.bool(forKey: syncDefaultsKey) }

    /// The existing master seed if the user already has an identity — never creates one.
    /// Used by App Intents so they act as *this* account without spinning up a new one.
    static func storedSeed() -> Data? { loadSeed() }

    /// Turn iCloud Keychain identity sync on/off and re-store the seed accordingly.
    func setICloudSync(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.syncDefaultsKey)
        let seed = account.secretSeed()
        Self.deleteSeed()
        Self.saveSeed(seed, synced: on)
    }

    // MARK: - Multi-device: transfer code / QR

    /// A one-time transfer code that encodes the master seed. Anyone holding it can
    /// become this identity — show it only to your own other device.
    func transferCode() -> String {
        "haven-seed:" + Self.base64url(account.secretSeed())
    }

    /// Adopt an identity from a scanned/pasted transfer code. Returns false if invalid.
    @discardableResult
    func restore(fromTransferCode code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = ["haven-seed:"].first(where: { trimmed.hasPrefix($0) }) else { return false }
        let body = String(trimmed.dropFirst(prefix.count))
        guard let seed = Self.base64urlDecode(body), seed.count == 32,
              let restored = try? Account.fromSeed(seed: seed) else { return false }
        Self.deleteSeed()
        Self.saveSeed(seed, synced: Self.iCloudSyncEnabled)
        account = restored
        return true
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: seedKey,
        ]
    }

    /// The seed is ALWAYS stored device-local and NON-synchronizable. iCloud Keychain must never
    /// carry the identity — a syncable seed let a fresh install on one device roll another
    /// device's identity. Cross-device is only ever via an explicit, user-confirmed transfer code.
    private static func saveSeed(_ data: Data, synced: Bool = false) {
        deleteSeed()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadSeed() -> Data? {
        if case .found(let d) = loadSeedStatus() { return d }
        return nil
    }

    /// Distinguishes "no seed exists" from "seed exists but the keychain can't be read right
    /// now" (locked). The init must NEVER treat a locked read as "new user" — that overwrites
    /// a real identity.
    private enum SeedStatus { case found(Data), notFound, lockedOrError }
    private static func loadSeedStatus() -> SeedStatus {
        var query = baseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return (item as? Data).map { .found($0) } ?? .lockedOrError
        case errSecItemNotFound: return .notFound
        default: return .lockedOrError   // errSecInteractionNotAllowed, etc. — don't clobber
        }
    }

    private static func deleteSeed() {
        var query = baseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny   // delete either variant
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Recoverable identity history (for rolling back a changed identity)

    private static let historyKey = "account-identity-history"
    private static func historyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: historyKey]
    }

    /// Append a seed to the identity history (newest first, deduped, capped at 12). The history
    /// is a *recovery archive* and never the active identity, so it's safe to back up to iCloud
    /// when the user opts in (`iCloudSyncEnabled`); the active seed always stays device-local.
    static func archive(_ seed: Data) {
        let b64 = seed.base64EncodedString()
        var hist = previousIdentities()
        hist.removeAll { $0 == b64 }
        hist.insert(b64, at: 0)
        if hist.count > 12 { hist = Array(hist.prefix(12)) }
        guard let data = try? JSONEncoder().encode(hist) else { return }
        var del = historyQuery(); del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(del as CFDictionary)
        let synced = iCloudSyncEnabled
        var add = historyQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = synced ? kSecAttrAccessibleAfterFirstUnlock
                                                   : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = synced ? kCFBooleanTrue! : kCFBooleanFalse!
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Past identities (base64 seeds), newest first.
    static func previousIdentities() -> [String] {
        var q = historyQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let arr = try? JSONDecoder().decode([String].self, from: d)
        else { return [] }
        return arr
    }

    /// Roll back to a previous identity from the history (current one is archived first).
    @discardableResult
    func restoreIdentity(_ b64: String) -> Bool {
        guard let seed = Data(base64Encoded: b64), seed.count == 32,
              let restored = try? Account.fromSeed(seed: seed) else { return false }
        Self.archive(account.secretSeed())
        Self.saveSeed(seed)
        account = restored
        FeedStore.shared.reconfigure(seed: account.secretSeed())
        return true
    }
}
