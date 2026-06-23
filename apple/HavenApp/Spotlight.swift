import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Opt-in Spotlight indexing of a circle's posts (on-device search only — CoreSpotlight items
/// live in the device index, never uploaded). This is now a **per-circle** choice
/// (`CircleSettingsStore.spotlightEnabled(circleId)`, default off); a biometric-locked circle
/// is never indexed. Each circle is its own Spotlight domain (`haven.posts.<circleId>`) so it
/// can be re-indexed or cleared independently. Item ids are `post:<id>` so a tap routes back.
@MainActor
enum SpotlightIndex {
    private static func domain(_ circleId: String) -> String { "haven.posts.\(circleId)" }

    /// Re-index every circle that currently opts in (called at launch / on feed refresh).
    static func reindexAll() {
        for circleId in CircleSettingsStore.shared.spotlightCircleIds {
            reindexCircle(circleId)
        }
    }

    /// Re-index one circle's posts.
    static func reindexCircle(_ circleId: String) {
        guard CircleSettingsStore.shared.spotlightEnabled(circleId),
              !CircleSettingsStore.shared.biometricRequired(circleId) else { return }
        let items = FeedStore.shared.messages(in: circleId)
            .filter { !$0.unsent && !$0.body.isEmpty && !$0.story }
            .map { searchable($0, circleId: circleId) }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Index a single post in a circle as it's created/edited.
    static func index(_ item: FeedItemFfi, circleId: String) {
        guard CircleSettingsStore.shared.spotlightEnabled(circleId),
              !CircleSettingsStore.shared.biometricRequired(circleId),
              !item.unsent, !item.body.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems([searchable(item, circleId: circleId)])
    }

    /// Remove one circle's index (toggle off, or it just became biometric-locked).
    static func clearCircle(_ circleId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain(circleId)]) { _ in }
    }

    /// The post id encoded in a Spotlight result's identifier, if it's one of ours.
    static func postId(fromIdentifier id: String) -> String? {
        id.hasPrefix("post:") ? String(id.dropFirst(5)) : nil
    }

    private static func searchable(_ item: FeedItemFfi, circleId: String) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        let author = item.isMe ? "You" : (ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? "Someone")
        attrs.title = "Haven · \(author)"
        attrs.contentDescription = item.body
        return CSSearchableItem(uniqueIdentifier: "post:\(item.id)",
                                domainIdentifier: domain(circleId), attributeSet: attrs)
    }
}
