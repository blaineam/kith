import Foundation

/// One-time carry-over of pre-rename UserDefaults (`kith.*` → `haven.*`). Runs once, copies
/// only when the new key is empty, and never deletes the old values — so it's safe and idempotent.
/// Preserves things that survive an identity reset (the contact list, display name, settings).
enum LegacyMigration {
    private static let doneKey = "haven.migration.kithDefaults.v1"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        for (key, value) in d.dictionaryRepresentation() where key.hasPrefix("kith.") {
            let newKey = "haven." + key.dropFirst("kith.".count)
            if d.object(forKey: newKey) == nil { d.set(value, forKey: newKey) }
        }
        d.set(true, forKey: doneKey)
    }
}
