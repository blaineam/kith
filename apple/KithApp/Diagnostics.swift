import SwiftUI

/// A read-only look at the live transports, so a connection problem is diagnosable
/// without guesswork. Reads FeedStore.shared (the single node owner) — it does NOT
/// start its own node.
struct ConnectionView: View {
    @ObservedObject private var store = FeedStore.shared

    var body: some View {
        ZStack {
            KithBackground()
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if let e = store.nodeError { errorCard("Internet node error", e) }
                    if let e = store.lastSendError { errorCard("Last send error", e) }
                    Button("Force reconnect & sync") { store.forceSync() }
                        .buttonStyle(BrandButtonStyle())
                    Text("For the cellular-vs-Wi-Fi test: if “Internet delivered” stays “not yet”, screenshot this and send it over.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Internet node", store.internetReady ? "ready" : "starting…")
            row("Internet delivered", store.internetActive ? "yes ✓" : "not yet")
            row("Nearby (BT/Wi-Fi)", store.nearbyActive ? "connected ✓" : "advertising…")
            row("Your node id", store.myNodeIdShort + "…")
            row("Contacts handshaked", "\(store.handshakedCount) / \(store.contactCount)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    private func errorCard(_ title: String, _ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(msg).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }
}
