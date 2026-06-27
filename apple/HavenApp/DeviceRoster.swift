import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// This device's OWN keypair — distinct from the account master seed, never synced, never leaves the
/// device. Multi-device (D16): a linked device acts under this key plus an account-signed credential,
/// so the account can authorize it and **revoke it individually** without touching the master seed.
///
/// This is the foundation; the enrollment flow (the primary issues a credential for this key on link,
/// the engine runs under it instead of the copied seed) + the Authorized-Devices UI build on top.
enum DeviceKeyStore {
    private static let service = "com.blaineam.kith"
    private static let accountKey = "haven.device-key-seed"

    /// This device's stable device Account — created once (32-byte seed in the data-protection keychain,
    /// device-local, never iCloud-synced).
    static func deviceAccount() -> Account {
        if let seed = loadSeed(), let acct = try? Account.fromSeed(seed: seed) { return acct }
        let fresh = Account.generate()
        saveSeed(fresh.secretSeed())
        return fresh
    }
    static func deviceNodeHex() -> String { deviceAccount().nodeIdHex() }
    static func deviceBundle() -> Data { deviceAccount().publicBundle() }

    /// A friendly label for this device (shown in "Authorized devices").
    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: accountKey, kSecUseDataProtectionKeychain as String: true]
    }
    private static func loadSeed() -> Data? {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }
    private static func saveSeed(_ seed: Data) {
        SecItemDelete(query() as CFDictionary)
        var add = query()
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
