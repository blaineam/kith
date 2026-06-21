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
                        .swipeActions {
                            Button(role: .destructive) { store.deleteConversation(c.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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
                    Text(last.unsent ? "Message unsent" : (SecretMessages.isSecret(last.body) ? "🔒 Secret message" : last.body))
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
                        HStack(spacing: 12) {
                            Circle()
                                .fill(LinearGradient(colors: [KithTheme.amber, KithTheme.pink], startPoint: .top, endPoint: .bottom))
                                .frame(width: 40, height: 40)
                                .overlay(Text(String(c.displayName.prefix(1)).uppercased())
                                    .font(.headline).foregroundStyle(.white))
                            Text(c.displayName).font(.body).foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
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
    @State private var secret = false
    @State private var editingId: String?      // editing one of my sent messages
    @State private var disappearSecs: UInt64?  // disappearing-message mode (nil = off)
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var showMedia = false
    @State private var showSongs = false
    @State private var showAudio = false
    @State private var zoom: ZoomTarget?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            KithBackground()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ordered, id: \.id) { m in
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
        .fullScreenCover(item: $zoom) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
    }

    @ViewBuilder private func dmMedia(_ m: FeedItemFfi) -> some View {
        let audio = m.media.filter { MediaKind(ref: $0) == .audio }
        let visual = m.media.filter { MediaKind(ref: $0) != .audio }
        VStack(alignment: m.isMe ? .trailing : .leading, spacing: 4) {
            ForEach(audio, id: \.self) { ref in
                if let url = MediaStore.shared.storagePath(for: ref) { AudioPlayerPill(url: url) }
            }
            if !visual.isEmpty { dmVisualMedia(visual) }
        }
    }

    @ViewBuilder private func dmVisualMedia(_ refs: [String]) -> some View {
        if refs.count == 1, let ref = refs.first, let img = MediaStore.shared.item(ref)?.image {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(maxWidth: 220, maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .center) {
                    if MediaStore.shared.item(ref)?.kind == .video {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
                    }
                }
                .onTapGesture { zoom = ZoomTarget(refs: refs, index: 0) }
        } else if !refs.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    if let img = MediaStore.shared.item(ref)?.image {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .center) {
                                if MediaStore.shared.item(ref)?.kind == .video { Image(systemName: "play.circle.fill").foregroundStyle(.white) }
                            }
                            .onTapGesture { zoom = ZoomTarget(refs: refs, index: i) }
                    }
                }
            }
            .frame(width: 216)
        }
    }

    @ViewBuilder private func bubble(_ m: FeedItemFfi) -> some View {
        HStack {
            if m.isMe { Spacer(minLength: 50) }
            VStack(alignment: m.isMe ? .trailing : .leading, spacing: 4) {
                if !m.media.isEmpty { dmMedia(m) }
                if let t = m.music { DMSongChip(track: t, isMe: m.isMe) }
                if m.unsent {
                    Text("Message unsent").italic()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.secondary)
                } else if SecretMessages.isSecret(m.body) {
                    SecretBubble(text: SecretMessages.text(m.body), isMe: m.isMe)
                } else if !m.body.isEmpty {
                    Text(m.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(m.isMe ? AnyShapeStyle(KithTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(m.isMe ? .white : .primary)
                }
                HStack(spacing: 3) {
                    Text(relativeTimeShort(m.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    if m.edited && !m.unsent { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
                    if m.isMe && !m.unsent {
                        // sent → checkmark; on the circle's relay → filled (store-and-forward delivered)
                        Image(systemName: store.relayReachable ? "checkmark.circle.fill" : "checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(store.relayReachable ? KithTheme.pink : Color.secondary)
                    }
                }
            }
            .contextMenu {
                if m.isMe && !m.unsent {
                    if !m.body.isEmpty && !SecretMessages.isSecret(m.body) {
                        Button { beginEdit(m) } label: { Label("Edit", systemImage: "pencil") }
                    }
                    Button(role: .destructive) { store.deleteMessage(in: circleId, m.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            if !m.isMe { Spacer(minLength: 50) }
        }
    }

    private func beginEdit(_ m: FeedItemFfi) {
        editingId = m.id
        text = m.body
        secret = false
        focused = true
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if editingId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil"); Text("Editing message").font(.caption)
                    Spacer()
                    Button("Cancel") { editingId = nil; text = ""; focused = false }.font(.caption)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 6)
            } else if let secs = disappearSecs {
                HStack(spacing: 6) {
                    Image(systemName: "timer"); Text("Disappears after \(Self.disappearLabel(secs))").font(.caption)
                    Spacer()
                    Button("Off") { disappearSecs = nil }.font(.caption)
                }
                .foregroundStyle(KithTheme.pink).padding(.horizontal, 6)
            }
            if !attachedMedia.isEmpty || attachedTrack != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedMedia, id: \.self) { ref in
                            if MediaKind(ref: ref) == .audio {
                                HStack(spacing: 5) {
                                    Image(systemName: "mic.fill"); Text("Voice").font(.caption)
                                    Button { attachedMedia.removeAll { $0 == ref } } label: { Image(systemName: "xmark.circle.fill") }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .background(KithTheme.pink.opacity(0.18), in: Capsule())
                            } else if let img = MediaStore.shared.item(ref)?.image {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Button { attachedMedia.removeAll { $0 == ref } } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
                                    }.padding(2)
                                }
                            }
                        }
                        if let t = attachedTrack {
                            HStack(spacing: 5) {
                                Image(systemName: "music.note")
                                Text(t.title).lineLimit(1)
                                Button { attachedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                            .background(KithTheme.pink.opacity(0.18), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Button { showMedia = true } label: { Label("Photo or video", systemImage: "photo") }
                    Button { showAudio = true } label: { Label("Voice message", systemImage: "mic") }
                    Button { showSongs = true } label: { Label("Song", systemImage: "music.note") }
                    Button { secret.toggle() } label: { Label(secret ? "Secret: on" : "Send secretly", systemImage: secret ? "lock.fill" : "lock") }
                    Menu {
                        Button { disappearSecs = nil } label: { Label("Off", systemImage: disappearSecs == nil ? "checkmark" : "circle") }
                        Button { disappearSecs = 3_600 } label: { Text("After 1 hour") }
                        Button { disappearSecs = 86_400 } label: { Text("After 1 day") }
                        Button { disappearSecs = 604_800 } label: { Text("After 1 week") }
                    } label: { Label("Disappearing", systemImage: "timer") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(KithTheme.pink)
                }
                TextField(secret ? "Secret message…" : "Message…", text: $text, axis: .vertical)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.background, in: Capsule())
                    .overlay(Capsule().strokeBorder(secret ? KithTheme.pink.opacity(0.6) : Color.white.opacity(0.08)))
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(KithTheme.pink)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && attachedMedia.isEmpty && attachedTrack == nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showMedia) { MediaPicker { refs in attachedMedia.append(contentsOf: refs) } }
        .sheet(isPresented: $showSongs) { SongPicker { t in attachedTrack = t } }
        .sheet(isPresented: $showAudio) { AudioRecorderView { ref in attachedMedia.append(ref) } }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingId {   // saving an edit
            guard !t.isEmpty else { return }
            store.editMessage(in: circleId, id, t)
            editingId = nil; text = ""; focused = false
            return
        }
        guard !t.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        let body = secret ? SecretMessages.encode(t) : t
        store.sendMessage(to: circleId, body, media: attachedMedia, music: attachedTrack, retentionSecs: disappearSecs)
        text = ""; secret = false; attachedMedia = []; attachedTrack = nil; focused = false
        // disappearSecs is sticky (stays on for the conversation until you turn it Off).
    }

    static func disappearLabel(_ secs: UInt64) -> String {
        switch secs {
        case ..<3_600: return "\(secs / 60)m"
        case ..<86_400: return "\(secs / 3_600)h"
        case ..<604_800: return "\(secs / 86_400)d"
        default: return "\(secs / 604_800)w"
        }
    }

    /// Oldest → newest, so the newest message sits at the bottom (standard chat order).
    private var ordered: [FeedItemFfi] {
        store.messages(in: circleId).sorted { $0.createdAt < $1.createdAt }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = ordered.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

/// A play/pause song chip for DM messages.
struct DMSongChip: View {
    let track: TrackRefFfi
    let isMe: Bool
    @State private var playing = false
    var body: some View {
        Button {
            if playing { MusicPlayback.shared.stop(); playing = false }
            else { MusicPlayback.shared.play(track); playing = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption2).lineLimit(1).opacity(0.8)
                }
                EqualizerBars(animating: playing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(isMe ? .white : .primary)
            .background(isMe ? AnyShapeStyle(KithTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
