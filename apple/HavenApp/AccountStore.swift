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
            } else {
                // Seed present but un-deriveable — NEVER overwrite it; use a temp identity.
                account = Account.generate(); usingTemporaryIdentity = true
            }
        case .notFound:
            // Genuinely a new install → make + save the first identity. (Only here do we write.)
            let fresh = Account.generate()
            Self.saveSeed(fresh.secretSeed(), synced: Self.iCloudSyncEnabled)
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

    /// Wipe the identity and create a new one ("start over").
    func reset() {
        Self.deleteSeed()
        let fresh = Account.generate()
        Self.saveSeed(fresh.secretSeed(), synced: Self.iCloudSyncEnabled)
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

    private static func saveSeed(_ data: Data, synced: Bool) {
        deleteSeed()
        var query = baseQuery()
        query[kSecValueData as String] = data
        // Synchronizable items can't be "ThisDeviceOnly"; use AfterFirstUnlock so iCloud
        // Keychain can carry them. Non-synced stays device-only (the conservative default).
        query[kSecAttrAccessible as String] = synced
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = synced ? kCFBooleanTrue! : kCFBooleanFalse!
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
}
