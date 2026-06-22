import SwiftUI

/// "Who reacted with what" — lets the receiver of reactions see exactly who used
/// which emoji on their post.
struct ReactionDetailView: View {
    let reactions: [ReactionFfi]
    @Environment(\.dismiss) private var dismiss

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
                        } header: {
                            Text("\(r.emoji)   \(r.count)").font(.title3)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Who reacted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func name(_ hex: String) -> String {
        if hex == FeedStore.shared.myNodeHex { return "You" }
        return ContactsStore.shared.name(forNodePrefix: hex) ?? "Someone in your circle"
    }
}
