import Foundation
import Security

/// A *read-only mirror* of the 32-byte master seed, stored in a shared Keychain access
/// group so the Notification Service Extension (a separate process, often running on the
/// lock screen) can decrypt a push payload with `openSealedWithSeed`.
///
/// Why a mirror and not the primary item: `AccountStore` keeps the authoritative seed in
/// the app's own (bundle-id) access group exactly as it always has — touching that item's
/// location risks losing an existing user's identity (see the keychain-locked-read class of
/// bug we already hardened against). So instead the app *additionally* writes a copy here,
/// in `…kith.shared`, which both the app and the extension can read. The extension only ever
/// reads; it never creates or overwrites identity.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly` — the seed is readable once the device
/// has been unlocked at least once (so a push that lands on the lock screen still decrypts),
/// never syncs to iCloud, and never leaves this device.
enum SharedSeed {
    /// Full keychain access group = team prefix (`$(AppIdentifierPrefix)` in the
    /// entitlements) + the shared group id. Both the app and the NSE declare this group.
    private static let accessGroup = "8ZVSPZYSVF.com.blaineam.kith.shared"
    private static let service = "com.blaineam.kith"
    private static let account = "account-master-seed-shared"

    private static func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// App side: mirror the real seed into the shared group. Idempotent (delete-then-add).
    static func write(_ seed: Data) {
        guard seed.count == 32 else { return }
        SecItemDelete(base() as CFDictionary)
        var add = base()
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// NSE side (and app): read the mirrored seed. `nil` if absent or the device hasn't been
    /// unlocked since boot — the NSE then shows a generic alert rather than decrypted text.
    static func read() -> Data? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Remove the mirror (e.g. on identity reset). Safe to call when nothing is stored.
    static func clear() {
        SecItemDelete(base() as CFDictionary)
    }
}
