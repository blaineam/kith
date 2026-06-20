import SwiftUI

/// Direct messages. Each DM is a private 2-person circle, so it rides the same E2E
/// engine, delivery, mesh relay, and persistence as everything else.
struct MessagesView: View {
    let account: Account
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var showPicker = false

    var body: some View {
        ZStack {
            KithBackground()
            List {
                if store.dmCircles.isEmpty {
                    Text("No messages yet. Tap the pencil to start one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(store.dmCircles, id: \.id) { c in
                    NavigationLink { DMThreadView(circleId: c.id) } label: { rowLabel(c.id) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showPicker = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showPicker) { DMContactPicker() }
    }

    private func rowLabel(_ circleId: String) -> some View {
        let name = store.dmPartnerName(circleId)
        return HStack(spacing: 12) {
            Circle().fill(KithTheme.brand).frame(width: 40, height: 40)
                .overlay(Text(String(name.prefix(1))).font(.headline).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium))
                if let last = store.messages(in: circleId).last {
                    Text(last.unsent ? "Message unsent" : last.body)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Pick a contact to start a DM with.
struct DMContactPicker: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var openId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                List(contacts.contacts) { c in
                    Button { openId = store.startDM(with: c.idHex, name: c.displayName) } label: {
                        Text(c.displayName).foregroundStyle(.primary)
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $openId) { id in DMThreadView(circleId: id) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A chat thread for one DM.
struct DMThreadView: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            KithBackground()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.messages(in: circleId), id: \.id) { m in
                                bubble(m).id(m.id)
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.postTick) { scrollToBottom(proxy) }
                    .onChange(of: store.items.count) { scrollToBottom(proxy) }
                    .onAppear { scrollToBottom(proxy) }
                }
                composer
            }
        }
        .navigationTitle(store.dmPartnerName(circleId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let hex = store.dmPartnerHex(circleId) {
                        CallManager.shared.startCall(peerHex: hex, name: store.dmPartnerName(circleId))
                    }
                } label: { Image(systemName: "phone.fill") }
                .disabled(store.dmPartnerHex(circleId) == nil)
            }
        }
        .onAppear { store.forceSync() }
    }

    private func bubble(_ m: FeedItemFfi) -> some View {
        HStack {
            if m.isMe { Spacer(minLength: 50) }
            VStack(alignment: m.isMe ? .trailing : .leading, spacing: 2) {
                Text(m.unsent ? "Message unsent" : m.body)
                    .italic(m.unsent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(m.isMe ? AnyShapeStyle(KithTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(m.isMe ? .white : .primary)
                Text(relativeTimeShort(m.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            if !m.isMe { Spacer(minLength: 50) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message…", text: $text, axis: .vertical)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(KithTheme.pink)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.sendMessage(to: circleId, t)
        text = ""; focused = false
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = store.messages(in: circleId).last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
