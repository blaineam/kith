import SwiftUI

/// Posts the user has chosen to hide from their own feed. Purely local + per-device (it never touches
/// the circle/relay — hiding is a personal view preference, distinct from blocking or removing
/// someone). A "show hidden" toggle reveals them again so a hide is always reversible. Mirrors the
/// Android `HiddenStore`.
final class HiddenStore: ObservableObject {
    static let shared = HiddenStore()

    private let d = UserDefaults.standard
    private let key = "haven.hidden.ids"

    @Published private(set) var hidden: Set<String>
    /// When true, hidden posts are shown again (with an Unhide affordance) instead of filtered out.
    @Published var showHidden = false

    private init() {
        hidden = Set(d.stringArray(forKey: key) ?? [])
    }

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    func hide(_ id: String) {
        guard !hidden.contains(id) else { return }
        hidden.insert(id); persist()
    }

    func unhide(_ id: String) {
        guard hidden.contains(id) else { return }
        hidden.remove(id); persist()
    }

    func toggleShowHidden() { showHidden.toggle() }

    private func persist() { d.set(Array(hidden), forKey: key) }
}
