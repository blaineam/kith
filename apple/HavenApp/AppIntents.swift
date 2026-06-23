import AppIntents
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// App Intents — drive Haven from Siri, Shortcuts, the Action button, and (iOS 18/26)
/// system surfaces. Each mutating intent loads the existing account + engine so it works
/// without opening the app; if there's no identity yet it fails cleanly.
enum HavenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noAccount, noPost, badImage, circleLocked, noMessages
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAccount: return "Set up Haven on this device first."
        case .noPost: return "There's no post to reply to yet."
        case .badImage: return "Couldn't read that image."
        case .circleLocked: return "That circle is locked with Face ID and can't be used here."
        case .noMessages: return "There are no messages yet."
        }
    }
}

@MainActor
private func ensureEngine() throws {
    guard let seed = AccountStore.storedSeed() else { throw HavenIntentError.noAccount }
    FeedStore.shared.configure(seed: seed)   // no-op if already configured
}

/// Reject a circle that's behind a biometric lock — intents must never read or post into a
/// locked circle without the in-app Face ID gate.
@MainActor
private func assertUnlocked(_ circleId: String) throws {
    if CircleSettingsStore.shared.biometricRequired(circleId) { throw HavenIntentError.circleLocked }
}

// MARK: - Circle filter entity

struct HavenCircleEntity: AppEntity {
    let id: String      // circle id
    let name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Circle"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = HavenCircleQuery()
}

struct HavenCircleQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HavenCircleEntity] {
        await MainActor.run {
            try? ensureEngine()
            return FeedStore.shared.circles
                .filter { identifiers.contains($0.id) && !CircleSettingsStore.shared.biometricRequired($0.id) }
                .map { HavenCircleEntity(id: $0.id, name: $0.name) }
        }
    }
    func suggestedEntities() async throws -> [HavenCircleEntity] {
        await MainActor.run {
            try? ensureEngine()
            // Locked circles are never offered — they can only be opened in-app with Face ID.
            return FeedStore.shared.circles
                .filter { !$0.id.hasPrefix("dm:") && !CircleSettingsStore.shared.biometricRequired($0.id) }
                .map { HavenCircleEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - Create a post

struct CreatePostIntent: AppIntent {
    static var title: LocalizedStringResource = "Create a Haven Post"
    static var description = IntentDescription("Share a new post to one of your circles.")
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Circle") var circle: HavenCircleEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ensureEngine()
        if let circle {
            try assertUnlocked(circle.id)
            FeedStore.shared.post(text, toCircle: circle.id)
            return .result(dialog: "Posted to \(circle.name).")
        }
        FeedStore.shared.post(text)
        return .result(dialog: "Posted to your circle.")
    }
}

// MARK: - Reply to the latest post

struct ReplyToLatestPostIntent: AppIntent {
    static var title: LocalizedStringResource = "Reply to the Latest Haven Post"
    static var description = IntentDescription("Comment on the most recent post in a circle.")
    @Parameter(title: "Comment") var text: String
    @Parameter(title: "Circle") var circle: HavenCircleEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ensureEngine()
        let store = FeedStore.shared
        if let circle {
            try assertUnlocked(circle.id)
            guard let latest = store.messages(in: circle.id)
                .filter({ !$0.unsent && !$0.story })
                .sorted(by: { $0.createdAt > $1.createdAt }).first else { throw HavenIntentError.noPost }
            store.commentMessage(in: circle.id, latest.id, text)
            return .result(dialog: "Reply sent to \(circle.name).")
        }
        guard let latest = store.feedItems.first(where: { !$0.unsent }) else { throw HavenIntentError.noPost }
        store.comment(latest.id, text)
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

// MARK: - Get the latest post

struct GetLatestPostIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Haven Post"
    static var description = IntentDescription("Read the most recent post, optionally from a specific circle or friend.")
    @Parameter(title: "Circle") var circle: HavenCircleEntity?
    @Parameter(title: "From") var contact: HavenContactEntity?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ensureEngine()
        let store = FeedStore.shared
        // Pick the circle to read: the chosen one (must be unlocked), else any unlocked circle.
        let items: [FeedItemFfi]
        if let circle {
            try assertUnlocked(circle.id)
            items = store.messages(in: circle.id)
        } else {
            items = store.circles
                .filter { !CircleSettingsStore.shared.biometricRequired($0.id) }
                .flatMap { store.messages(in: $0.id) }
        }
        let filtered = items
            .filter { !$0.unsent && !$0.story }
            .filter { contact == nil || $0.authorShort == contact!.id || contact!.id.hasPrefix($0.authorShort) }
            .sorted { $0.createdAt > $1.createdAt }
        guard let latest = filtered.first else { throw HavenIntentError.noPost }
        let who = latest.isMe ? "You" : (ContactsStore.shared.name(forNodePrefix: latest.authorShort) ?? "Someone")
        let body = latest.body.isEmpty ? "(media)" : latest.body
        let line = "\(who): \(body)"
        return .result(value: line, dialog: "\(line)")
    }
}

// MARK: - Get the latest message from someone

struct GetMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Haven Message"
    static var description = IntentDescription("Read the most recent direct message from someone in your circle.")
    @Parameter(title: "From") var contact: HavenContactEntity

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ensureEngine()
        let store = FeedStore.shared
        let dm = store.startDM(with: contact.id, name: contact.name)
        try assertUnlocked(dm)   // a DM circle can be biometric-locked too
        guard let latest = store.messages(in: dm)
            .filter({ !$0.unsent })
            .sorted(by: { $0.createdAt > $1.createdAt }).first
        else { throw HavenIntentError.noMessages }
        let who = latest.isMe ? "You" : contact.name
        let body = latest.body.isEmpty ? "(media)" : latest.body
        let line = "\(who): \(body)"
        return .result(value: line, dialog: "\(line)")
    }
}

// MARK: - Update profile picture

struct UpdateProfilePictureIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Haven Profile Picture"
    static var description = IntentDescription("Set your Haven profile photo.")
    @Parameter(title: "Photo") var photo: IntentFile

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let img = PlatformImage(data: photo.data) else { throw HavenIntentError.badImage }
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
        AppShortcut(intent: GetLatestPostIntent(),
                    phrases: ["Get my latest \(.applicationName) post", "What's new on \(.applicationName)"],
                    shortTitle: "Latest Post", systemImageName: "doc.text.magnifyingglass")
        AppShortcut(intent: GetMessagesIntent(),
                    phrases: ["Get my latest \(.applicationName) message"],
                    shortTitle: "Latest Message", systemImageName: "bubble.left.and.text.bubble.right.fill")
        AppShortcut(intent: UpdateProfilePictureIntent(),
                    phrases: ["Update my \(.applicationName) profile picture"],
                    shortTitle: "Profile Picture", systemImageName: "person.crop.circle.fill")
    }
}
