import Foundation
import Security

/// The set of circle ids the user has put behind a biometric lock, mirrored into the shared
/// Keychain group so the Notification Service Extension can **redact** a push for a locked
/// circle (show "New activity" instead of the real sender/text). Biometric lock is meant to
/// gate access; a lock-screen banner that spelled out the content would defeat it.
///
/// The app writes this set whenever a per-circle biometric toggle changes; the extension only
/// reads it. Stored device-local, `AfterFirstUnlockThisDeviceOnly`, never synced.
enum SharedLockedCircles {
    private static let accessGroup = "8ZVSPZYSVF.com.blaineam.kith.shared"
    private static let service = "com.blaineam.kith"
    private static let account = "biometric-locked-circles"

    private static func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// App side: replace the stored set (JSON array of circle ids).
    static func write(_ ids: Set<String>) {
        SecItemDelete(base() as CFDictionary)
        guard let data = try? JSONSerialization.data(withJSONObject: Array(ids)) else { return }
        var add = base()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// App + NSE: read the locked-circle id set (empty if none/locked-out).
    static func read() -> Set<String> {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }
}
