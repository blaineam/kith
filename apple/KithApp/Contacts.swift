import Foundation

/// Someone in your circle.
struct Contact: Identifiable, Codable, Equatable {
    var id: String { idHex }
    var name: String
    var idHex: String
    /// BLAKE3 verification hash from their reach-me link — used to verify the public
    /// bundle they send during the handshake (MITM guard). Optional for older contacts.
    var verificationHex: String?
}

/// Your circle, persisted locally on this device.
@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published private(set) var contacts: [Contact] = []
    private let key = "kith.contacts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = list
        }
    }

    func add(name: String, idHex: String, verificationHex: String? = nil) {
        guard !contacts.contains(where: { $0.idHex == idHex }) else { return }
        contacts.append(Contact(name: name, idHex: idHex, verificationHex: verificationHex))
        save()
    }

    func verification(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.verificationHex
    }

    func name(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.name
    }

    func remove(_ contact: Contact) {
        contacts.removeAll { $0.idHex == contact.idHex }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
