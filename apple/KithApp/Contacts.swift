import Foundation

/// Someone in your circle.
struct Contact: Identifiable, Codable, Equatable {
    var id: String { idHex }
    /// A local nickname you can give them (free text, your reference).
    var name: String
    var idHex: String
    /// BLAKE3 verification hash from their reach-me link — used to verify the public
    /// bundle they send during the handshake (MITM guard). Optional for older contacts.
    var verificationHex: String?
    /// The name they signed and sent in the handshake — the owner has authority over
    /// this, so it's preferred over the handshake nickname.
    var authoritativeName: String?
    /// A nickname *you* deliberately set for this person. Highest priority — it's how
    /// you've chosen to see them, so it overrides even their signed name.
    var nickname: String?

    /// What to show: your explicit nickname, else the owner's signed name, else the
    /// name from the original handshake.
    var displayName: String {
        if let n = nickname, !n.isEmpty { return n }
        return authoritativeName ?? name
    }
}

/// Your circle, persisted locally on this device.
@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published private(set) var contacts: [Contact] = []
    private let key = "haven.contacts"

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
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.displayName
    }

    /// Record the authoritative (signed) name a contact sent during the handshake.
    func setAuthoritativeName(idHex: String, _ authName: String) {
        guard let i = contacts.firstIndex(where: { $0.idHex == idHex }),
              contacts[i].authoritativeName != authName else { return }
        contacts[i].authoritativeName = authName
        save()
    }

    /// Set (or clear, with "") a nickname you chose for this person.
    func setNickname(idHex: String, _ nickname: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = contacts.firstIndex(where: { $0.idHex == idHex || $0.idHex.hasPrefix(idHex) }) else { return }
        contacts[i].nickname = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// The full node id for a (possibly short) prefix — needed to start a DM from a story.
    func idHex(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.idHex
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
