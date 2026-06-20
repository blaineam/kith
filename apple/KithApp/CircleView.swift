import SwiftUI

/// Manage who's in your circle: see each person's real (signed) name + whether the
/// secure handshake has completed, remove people, or invite someone new. "Waiting"
/// means you don't yet hold their keys — usually because you haven't both added each
/// other, you're on different app versions, or one of you started a new identity.
struct CircleView: View {
    let account: Account
    @ObservedObject private var contacts = ContactsStore.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var showInvite = false

    var body: some View {
        ZStack {
            KithBackground()
            List {
                Section {
                    if contacts.contacts.isEmpty {
                        Text("No one yet. Tap the + to invite someone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(contacts.contacts) { c in
                        row(c)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) {
                                Button { store.forceSync() } label: {
                                    Label("Reconnect", systemImage: "arrow.clockwise")
                                }.tint(KithTheme.pink)
                            }
                    }
                    .onDelete { offsets in
                        offsets.map { contacts.contacts[$0] }.forEach(contacts.remove)
                    }
                } header: {
                    Text("People in your circle")
                } footer: {
                    Text("Swipe left to remove someone. “Waiting” means the secure handshake hasn't completed — make sure you've **both** added each other and are on the **same app version**. If either of you started a new identity, re-scan each other's QR codes.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Your circle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
            }
        }
        .sheet(isPresented: $showInvite) { ConnectView(account: account, contacts: contacts) }
    }

    private func row(_ c: Contact) -> some View {
        let connected = store.isConnected(c.idHex)
        return HStack(spacing: 12) {
            Circle().fill(KithTheme.brand).frame(width: 38, height: 38)
                .overlay(Text(String(c.displayName.prefix(1))).font(.subheadline.bold()).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName).font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? "Connected" : "Waiting to connect")
                        .font(.caption2).foregroundStyle(connected ? .green : .secondary)
                }
            }
            Spacer()
            Text(String(c.idHex.prefix(6))).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
