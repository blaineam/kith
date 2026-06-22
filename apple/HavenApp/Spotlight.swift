import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Opt-in Spotlight indexing of your circle's posts (on-device search only — CoreSpotlight
/// items live in the device index, never uploaded). Gated by `SettingsStore.spotlightEnabled`
/// (default off). Identifiers are `post:<id>` so a tap can route back to the post.
@MainActor
enum SpotlightIndex {
    static let domain = "haven.posts"

    /// Re-index everything currently in the feed (called when the toggle turns on).
    static func reindexAll() {
        guard SettingsStore.shared.spotlightEnabled else { return }
        let items = FeedStore.shared.feedItems
            .filter { !$0.unsent && !$0.body.isEmpty }
            .map(searchable)
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Index a single post as it's created/edited.
    static func index(_ item: FeedItemFfi) {
        guard SettingsStore.shared.spotlightEnabled, !item.unsent, !item.body.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems([searchable(item)])
    }

    /// Remove the whole index (called when the toggle turns off).
    static func clearAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    /// The post id encoded in a Spotlight result's identifier, if it's one of ours.
    static func postId(fromIdentifier id: String) -> String? {
        id.hasPrefix("post:") ? String(id.dropFirst(5)) : nil
    }

    private static func searchable(_ item: FeedItemFfi) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        let author = item.isMe ? "You" : (ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? "Someone")
        attrs.title = "Haven · \(author)"
        attrs.contentDescription = item.body
        return CSSearchableItem(uniqueIdentifier: "post:\(item.id)", domainIdentifier: domain, attributeSet: attrs)
    }
}
