import SwiftUI

/// Drives the live social demo: every action goes through the real hybrid-PQ
/// social engine (seal → open → feed) in `p2pcore`.
@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var items: [FeedItemFfi] = []
    @Published private(set) var postTick = 0
    @Published private(set) var reactionTick = 0
    private let demo: SocialDemo

    init(seed: Data) {
        demo = (try? SocialDemo(accountSeed: seed)) ?? {
            fatalError("SocialDemo requires a 32-byte seed")
        }()
        seedInitialContent()
        refresh()
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    func refresh() { items = demo.feed() }

    func post(_ body: String) { _ = demo.post(body: body, createdAt: now()); postTick += 1; refresh() }
    func comment(_ id: String, _ body: String) { _ = demo.comment(target: id, body: body, createdAt: now()); refresh() }
    func react(_ id: String, _ emoji: String) { _ = demo.react(target: id, emoji: emoji, createdAt: now()); reactionTick += 1; refresh() }
    func edit(_ id: String, _ body: String) { _ = demo.edit(target: id, body: body, createdAt: now()); refresh() }
    func unsend(_ id: String) { _ = demo.unsend(target: id, createdAt: now()); refresh() }
    func friendReply(_ id: String) { _ = demo.friendComment(target: id, body: "👏 love it", createdAt: now()); refresh() }

    private func seedInitialContent() {
        let t = now()
        let welcome = demo.friendPost(body: "Welcome to Kith 🜂 — just us, no ads, no tracking.", createdAt: t)
        _ = demo.react(target: welcome, emoji: "❤️", createdAt: t + 1)
        let mine = demo.post(body: "First post. Our own little corner of the internet.", createdAt: t + 2)
        _ = demo.friendComment(target: mine, body: "This is so cozy.", createdAt: t + 3)
        _ = demo.friendReact(target: mine, emoji: "🎉", createdAt: t + 4)
    }
}

struct FeedView: View {
    @StateObject private var store: FeedStore
    let friendName: String
    @State private var compose = ""
    @FocusState private var composing: Bool

    init(seed: Data, friendName: String) {
        _store = StateObject(wrappedValue: FeedStore(seed: seed))
        self.friendName = friendName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles").foregroundStyle(KithTheme.pink)
                            Text("Your circle — posts from you and your people live here.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 4)

                        ForEach(store.items, id: \.id) { item in
                            PostCard(
                                item: item,
                                friendName: friendName,
                                onReact: { emoji in withAnimation(KithTheme.bouncy) { store.react(item.id, emoji) } },
                                onComment: { body in withAnimation(KithTheme.smooth) { store.comment(item.id, body) } },
                                onEdit: { body in withAnimation(KithTheme.smooth) { store.edit(item.id, body) } },
                                onUnsend: { withAnimation(KithTheme.smooth) { store.unsend(item.id) } },
                                onFriendReply: { withAnimation(KithTheme.smooth) { store.friendReply(item.id) } }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                removal: .opacity
                            ))
                        }
                    }
                    .animation(KithTheme.bouncy, value: store.items.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 90)
                }
                composerBar
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.large)
            .sensoryFeedback(.success, trigger: store.postTick)
            .sensoryFeedback(.impact(weight: .light), trigger: store.reactionTick)
        }
    }

    private var composerBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                TextField("Share something…", text: $compose, axis: .vertical)
                    .focused($composing)
                    .accessibilityIdentifier("composeField")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                Button {
                    let t = compose.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    store.post(t)
                    compose = ""
                    composing = false
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(KithTheme.brand, in: Circle())
                        .shadow(color: KithTheme.pink.opacity(0.4), radius: 8, y: 4)
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("composeSend")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }
}

private struct PostCard: View {
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    let onComment: (String) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    let onFriendReply: () -> Void

    @State private var commentText = ""
    @State private var showEdit = false
    @State private var editText = ""

    private let quickReactions = ["❤️", "😂", "🎉", "👍"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if item.unsent {
                Label("Message unsent", systemImage: "minus.circle")
                    .font(.subheadline).italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(item.body).font(.body)
                reactionsRow
                if !item.comments.isEmpty { commentsList }
                commentField
            }
        }
        .kithCard()
        .alert("Edit post", isPresented: $showEdit) {
            TextField("New text", text: $editText)
            Button("Save") { if !editText.isEmpty { onEdit(editText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var avatar: some View {
        Circle()
            .fill(item.isMe ? KithTheme.brand
                  : LinearGradient(colors: [KithTheme.amber, KithTheme.pink],
                                   startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: 34)
            .overlay(
                Text(item.isMe ? "You" : "K")
                    .font(.caption2.bold()).foregroundStyle(.white)
            )
    }

    private var header: some View {
        HStack(spacing: 10) {
            avatar
            Text(item.isMe ? "You" : friendName)
                .font(.subheadline.weight(.semibold))
            if item.edited {
                Text("edited")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if item.isMe && !item.unsent {
                    Button { editText = item.body; showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                }
                Button { onFriendReply() } label: { Label("Simulate friend reply", systemImage: "person.fill.badge.plus") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6)
            }
        }
    }

    private var reactionsRow: some View {
        HStack(spacing: 8) {
            ForEach(item.reactions, id: \.emoji) { r in
                Text("\(r.emoji) \(r.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        r.mine ? AnyShapeStyle(KithTheme.brandHorizontal.opacity(0.22))
                               : AnyShapeStyle(Color(.secondarySystemFill)),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(r.mine ? KithTheme.pink.opacity(0.5) : .clear))
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            ForEach(quickReactions, id: \.self) { e in
                Button(e) { onReact(e) }
                    .font(.body)
                    .buttonStyle(PressableStyle())
            }
        }
        .animation(KithTheme.bouncy, value: item.reactions.count)
    }

    private var commentsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(item.comments, id: \.id) { c in
                HStack(alignment: .top, spacing: 6) {
                    Text(c.isMe ? "You" : friendName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(c.isMe ? KithTheme.pink : .secondary)
                    if c.unsent {
                        Text("unsent").font(.caption).italic().foregroundStyle(.secondary)
                    } else {
                        Text(c.body).font(.caption)
                        if c.edited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var commentField: some View {
        HStack(spacing: 8) {
            TextField("Add a comment…", text: $commentText)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Button {
                let t = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                onComment(t)
                commentText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(KithTheme.pink)
            }
            .buttonStyle(PressableStyle())
        }
    }
}
