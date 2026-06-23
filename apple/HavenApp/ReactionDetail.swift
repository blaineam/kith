import SwiftUI

/// "Who reacted with what" — lets the receiver of reactions see exactly who used
/// which emoji on their post.
struct ReactionDetailView: View {
    let reactions: [ReactionFfi]
    /// Remove my own reaction of this emoji (nil = read-only roster).
    var onUnreact: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private func mine(_ r: ReactionFfi) -> Bool { r.mine || r.authors.contains(FeedStore.shared.myNodeHex) }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                List {
                    ForEach(reactions, id: \.emoji) { r in
                        Section {
                            ForEach(r.authors, id: \.self) { hex in
                                HStack(spacing: 10) {
                                    Circle().fill(HavenTheme.brand).frame(width: 30, height: 30)
                                        .overlay(Text(String(name(hex).prefix(1)))
                                            .font(.caption.bold()).foregroundStyle(.white))
                                    Text(name(hex)).font(.subheadline)
                                    Spacer()
                                }
                                .listRowBackground(Color.clear)
                            }
                            if mine(r), let onUnreact {
                                Button(role: .destructive) { onUnreact(r.emoji); dismiss() } label: {
                                    Label("Remove my \(r.emoji)", systemImage: "minus.circle")
                                }
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text("\(r.emoji)   \(r.count)").font(.title3)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Who reacted")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func name(_ hex: String) -> String {
        if hex == FeedStore.shared.myNodeHex { return "You" }
        return ContactsStore.shared.name(forNodePrefix: hex) ?? "Someone in your circle"
    }
}
