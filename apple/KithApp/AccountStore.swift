import Foundation
import Security

/// Owns the user's Kith account. Persists only the 32-byte master seed in the
/// Keychain; the full identity (all hybrid-PQ keys) is derived from it on launch.
///
/// Multi-device: the seed can optionally sync across *your* Apple devices via iCloud
/// Keychain (Apple's E2E sync), and can be moved to any client (web/Android/another
/// phone) with a one-time transfer code / QR. The seed never touches a Kith server.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var account: Account

    private static let service = "com.blaineam.kith"
    private static let seedKey = "account-master-seed"
    private static let syncDefaultsKey = "kith.icloud.identitySync"

    init() {
        if let seed = Self.loadSeed(), let restored = try? Account.fromSeed(seed: seed) {
            account = restored
        } else {
            let fresh = Account.generate()
            Self.saveSeed(fresh.secretSeed(), synced: Self.iCloudSyncEnabled)
            account = fresh
        }
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
        "kith-seed:" + Self.base64url(account.secretSeed())
    }

    /// Adopt an identity from a scanned/pasted transfer code. Returns false if invalid.
    @discardableResult
    func restore(fromTransferCode code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("kith-seed:") else { return false }
        let body = String(trimmed.dropFirst("kith-seed:".count))
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
        var query = baseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny   // match synced or not
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func deleteSeed() {
        var query = baseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny   // delete either variant
        SecItemDelete(query as CFDictionary)
    }
}
