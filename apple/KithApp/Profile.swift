import Foundation

/// The user's chosen display name + emoji avatar. Not PII collection — it lives on
/// this device and is only ever shared, end-to-end, with people you connect to.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var displayName: String { didSet { defaults.set(displayName, forKey: nameKey) } }
    @Published var emoji: String { didSet { defaults.set(emoji, forKey: emojiKey) } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: doneKey) } }

    private let defaults = UserDefaults.standard
    private let nameKey = "kith.displayName"
    private let emojiKey = "kith.emoji"
    private let doneKey = "kith.onboarded"

    init() {
        displayName = defaults.string(forKey: nameKey) ?? ""
        emoji = defaults.string(forKey: emojiKey) ?? "🌿"
        onboarded = defaults.bool(forKey: doneKey)

        // Let UI tests skip the onboarding flow.
        if ProcessInfo.processInfo.environment["KITH_SKIP_ONBOARDING"] == "1" {
            if displayName.isEmpty { displayName = "You" }
            onboarded = true
        }
    }

    static let avatarChoices = ["🌿", "🌸", "🔥", "⭐️", "🦊", "🐢", "🌊", "🍯", "🎈", "🪴", "🦋", "🌙"]
}
