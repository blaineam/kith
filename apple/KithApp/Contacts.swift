import Foundation

/// Someone in your circle.
struct Contact: Identifiable, Codable, Equatable {
    var id: String { idHex }
    var name: String
    var idHex: String
}

/// Your circle, persisted locally on this device.
@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var contacts: [Contact] = []
    private let key = "kith.contacts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = list
        }
    }

    func add(name: String, idHex: String) {
        guard !contacts.contains(where: { $0.idHex == idHex }) else { return }
        contacts.append(Contact(name: name, idHex: idHex))
        save()
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
