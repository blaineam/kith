import AppIntents
import UIKit

/// App Intents — drive Haven from Siri, Shortcuts, the Action button, and (iOS 18/26)
/// system surfaces. Each mutating intent loads the existing account + engine so it works
/// without opening the app; if there's no identity yet it fails cleanly.
enum HavenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noAccount, noPost, badImage
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAccount: return "Set up Haven on this device first."
        case .noPost: return "There's no post to reply to yet."
        case .badImage: return "Couldn't read that image."
        }
    }
}

@MainActor
private func ensureEngine() throws {
    guard let seed = AccountStore.storedSeed() else { throw HavenIntentError.noAccount }
    FeedStore.shared.configure(seed: seed)   // no-op if already configured
}

// MARK: - Create a post

struct CreatePostIntent: AppIntent {
    static var title: LocalizedStringResource = "Create a Haven Post"
    static var description = IntentDescription("Share a new post to your active circle.")
    @Parameter(title: "Text") var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ensureEngine()
        FeedStore.shared.post(text)
        return .result(dialog: "Posted to your circle.")
    }
}

// MARK: - Reply to the latest post

struct ReplyToLatestPostIntent: AppIntent {
    static var title: LocalizedStringResource = "Reply to the Latest Haven Post"
    static var description = IntentDescription("Comment on the most recent post in your circle.")
    @Parameter(title: "Comment") var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ensureEngine()
        guard let latest = FeedStore.shared.feedItems.first(where: { !$0.unsent }) else { throw HavenIntentError.noPost }
        FeedStore.shared.comment(latest.id, text)
        return .result(dialog: "Reply sent.")
    }
}

// MARK: - Send a DM

struct HavenContactEntity: AppEntity {
    let id: String      // contact idHex
    let name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = HavenContactQuery()
}

struct HavenContactQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HavenContactEntity] {
        await MainActor.run {
            ContactsStore.shared.contacts
                .filter { identifiers.contains($0.idHex) }
                .map { HavenContactEntity(id: $0.idHex, name: $0.displayName) }
        }
    }
    func suggestedEntities() async throws -> [HavenContactEntity] {
        await MainActor.run {
            ContactsStore.shared.contacts.map { HavenContactEntity(id: $0.idHex, name: $0.displayName) }
        }
    }
}

struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a Haven Message"
    static var description = IntentDescription("Send a direct message to someone in your circle.")
    @Parameter(title: "To") var contact: HavenContactEntity
    @Parameter(title: "Message") var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ensureEngine()
        let dm = FeedStore.shared.startDM(with: contact.id, name: contact.name)
        FeedStore.shared.sendMessage(to: dm, text)
        return .result(dialog: "Message sent to \(contact.name).")
    }
}

// MARK: - Update profile picture

struct UpdateProfilePictureIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Haven Profile Picture"
    static var description = IntentDescription("Set your Haven profile photo.")
    @Parameter(title: "Photo") var photo: IntentFile

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let img = UIImage(data: photo.data) else { throw HavenIntentError.badImage }
        ProfileStore.shared.setAvatar(img)
        return .result(dialog: "Profile picture updated.")
    }
}

// MARK: - Siri / Shortcuts phrases

struct HavenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreatePostIntent(),
                    phrases: ["Post to \(.applicationName)", "Create a \(.applicationName) post"],
                    shortTitle: "New Post", systemImageName: "square.and.pencil")
        AppShortcut(intent: SendMessageIntent(),
                    phrases: ["Send a \(.applicationName) message"],
                    shortTitle: "Send Message", systemImageName: "bubble.left.fill")
        AppShortcut(intent: ReplyToLatestPostIntent(),
                    phrases: ["Reply on \(.applicationName)"],
                    shortTitle: "Reply", systemImageName: "arrowshape.turn.up.left.fill")
        AppShortcut(intent: UpdateProfilePictureIntent(),
                    phrases: ["Update my \(.applicationName) profile picture"],
                    shortTitle: "Profile Picture", systemImageName: "person.crop.circle.fill")
    }
}
