import Foundation
import Security

/// A tiny queue the Notification Service Extension uses to hand the app **sealed event
/// envelopes that arrived inline in a push** (push-inline sync). The NSE can't ingest a circle
/// event itself (that needs the engine), so it just stashes the raw envelope here; the app
/// drains the queue on next launch/foreground and feeds each one to `HavenSocial.receive`.
///
/// Stored in the shared Keychain group (same one the NSE already reads for the seed), so it
/// needs no extra App-Group provisioning. Capped so it can't grow without bound — push only
/// carries the latest events; the mailbox is the reliable backstop for catch-up.
enum SharedInbox {
    private static let accessGroup = "8ZVSPZYSVF.com.blaineam.kith.shared"
    private static let service = "com.blaineam.kith"
    private static let account = "push-inbox"
    private static let maxItems = 64

    private static func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// NSE side: append a sealed event envelope that arrived in a push (raw, base64-decoded).
    static func append(env: Data) {
        var items = load()
        items.append(env)
        if items.count > maxItems { items.removeFirst(items.count - maxItems) }
        save(items)
    }

    /// App side: take everything queued and clear it.
    static func drain() -> [Data] {
        let items = load()
        if !items.isEmpty { save([]) }
        return items
    }

    private static func load() -> [Data] {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let list = try? JSONDecoder().decode([Data].self, from: data) else { return [] }
        return list
    }

    private static func save(_ items: [Data]) {
        SecItemDelete(base() as CFDictionary)
        guard let data = try? JSONEncoder().encode(items) else { return }
        var add = base()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
