import SwiftUI
import UIKit   // UIImage (available on watchOS) — render real post thumbnails

// MARK: - Conversations list

/// Recent DM threads + circle feeds. Tap a row to open the thread.
struct WatchConversationsView: View {
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var path: [WatchThread] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if client.threads.isEmpty {
                    Text(client.reachable ? "No conversations yet." : "Open Haven on your iPhone to sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(client.threads) { thread in
                    NavigationLink(value: thread) { WatchThreadRow(thread: thread) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchBackground())
            .navigationTitle("Haven")
            .navigationDestination(for: WatchThread.self) { thread in
                WatchThreadView(threadId: thread.id, title: thread.title)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { client.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .refreshable { client.refresh() }
        }
        .onAppear {
            // Screenshot harness: jump straight into a thread for the hero shot.
            if ProcessInfo.processInfo.environment["HAVENWATCH_DEMO_SCENE"] == "thread",
               path.isEmpty, let first = client.threads.first {
                path = [first]
            }
        }
    }
}

private struct WatchThreadRow: View {
    let thread: WatchThread

    var body: some View {
        HStack(spacing: 9) {
            WatchAvatar(title: thread.title, isDM: thread.isDM, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(thread.title)
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if thread.timestamp > 0 {
                        Text(watchRelativeTime(thread.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !thread.subtitle.isEmpty {
                    Text(thread.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .watchCard()
    }
}

// MARK: - Thread

/// A thread's recent messages with reply (dictation / canned) + tap-to-react.
struct WatchThreadView: View {
    let threadId: String
    let title: String
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var showReply = false
    @State private var reactingTo: WatchMessage?

    private var messages: [WatchMessage] {
        client.openThread?.threadId == threadId ? (client.openThread?.messages ?? []) : []
    }

    var body: some View {
        List {
            if messages.isEmpty {
                Text(client.loadingThread ? "Loading…" : "No messages yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(messages) { msg in
                WatchMessageRow(message: msg)
                    .onTapGesture { reactingTo = msg }
            }
            Button { showReply = true } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
            }
            .buttonStyle(WatchBrandButton())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 4, trailing: 4))
        }
        .scrollContentBackground(.hidden)
        .background(WatchBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.openThread(threadId) }
        .sheet(isPresented: $showReply) {
            WatchReplyView(threadId: threadId) { showReply = false }
                .environmentObject(client)
        }
        .sheet(item: $reactingTo) { msg in
            WatchReactionPicker { emoji in
                client.react(threadId: threadId, messageId: msg.id, emoji: emoji)
                reactingTo = nil
            }
        }
    }
}

private struct WatchMessageRow: View {
    let message: WatchMessage

    private var bubbleColor: Color {
        message.isMe ? Color.pink.opacity(0.32) : Color.white.opacity(0.12)
    }
    private var hasBubbleContent: Bool {
        !message.body.isEmpty || message.thumbnail != nil || message.hasMedia
    }

    var body: some View {
        VStack(alignment: message.isMe ? .trailing : .leading, spacing: 3) {
            if !message.isMe {
                Text(message.author)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.pink.opacity(0.9))
            }
            if hasBubbleContent {
                VStack(alignment: .leading, spacing: 5) {
                    // Render the ACTUAL media (post photo / video poster), not a generic attachment row.
                    if let data = message.thumbnail, let ui = UIImage(data: data) {
                        ZStack {
                            Image(uiImage: ui)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            if message.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 3)
                            }
                        }
                    } else if message.hasMedia {
                        // Bytes still syncing on the phone — a quiet placeholder, not a scary "Attachment".
                        Label(message.isVideo ? "Video" : "Photo", systemImage: message.isVideo ? "video.fill" : "photo.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if !message.body.isEmpty {
                        Text(message.body).font(.body)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 4) {
                if !message.reactions.isEmpty {
                    Text(message.reactions).font(.caption2)
                }
                Text(watchRelativeTime(message.timestamp))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isMe ? .trailing : .leading)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)   // remove the system row fill → no "double background" behind bubbles
    }
}

// MARK: - Reply (dictation / Scribble via TextField + canned replies)

struct WatchReplyView: View {
    let threadId: String
    var onDone: () -> Void
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // The watchOS keyboard/dictation/Scribble all feed this field.
                TextField("Message", text: $text)
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(WatchBrandButton())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Divider()
                Text("Quick replies").font(.caption2).foregroundStyle(.secondary)
                ForEach(WatchQuickReplies.all, id: \.self) { canned in
                    Button {
                        client.sendReply(threadId: threadId, body: canned)
                        onDone()
                    } label: {
                        Text(canned).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(WatchBackground())
        .navigationTitle("Reply")
    }

    private func send() {
        client.sendReply(threadId: threadId, body: text)
        onDone()
    }
}

// MARK: - Reaction picker

struct WatchReactionPicker: View {
    var onPick: (String) -> Void
    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        ScrollView {
            Text("React").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WatchQuickReplies.reactions, id: \.self) { emoji in
                    Button { onPick(emoji) } label: {
                        Text(emoji).font(.title2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(WatchBackground())
    }
}
