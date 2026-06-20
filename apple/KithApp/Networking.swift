import SwiftUI
import UIKit

/// Bridges the Rust `KithNode` to Swift. Starts a live P2P node, exposes a ticket for
/// a peer to dial, sends, and receives inbound sealed bytes via the callback listener.
@MainActor
final class NetNode: ObservableObject {
    @Published var status = "Offline"
    @Published var ticket = ""
    @Published var log: [String] = []

    private var node: KithNode?
    private var listener: InboundBridge?

    func start(seed: Data) async {
        guard node == nil else { return }
        status = "Starting…"
        let bridge = InboundBridge { [weak self] data in
            Task { @MainActor in self?.log.insert("⬇︎ received \(data.count) bytes", at: 0) }
        }
        listener = bridge
        do {
            let n = try await KithNode.start(accountSeed: seed, listener: bridge)
            node = n
            ticket = try await n.ticket()
            status = "Online"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    func sendTest(to peerTicket: String) async {
        guard let node else { return }
        let t = peerTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let payload = Data("hello from Kith over QUIC".utf8)
        do {
            try await node.send(ticket: t, payload: payload)
            log.insert("⬆︎ sent \(payload.count) bytes", at: 0)
        } catch {
            log.insert("send failed: \(error.localizedDescription)", at: 0)
        }
    }
}

/// Adapts the Rust callback interface to a Swift closure. Called off the main thread.
final class InboundBridge: InboundListener {
    private let onData: (Data) -> Void
    init(onData: @escaping (Data) -> Void) { self.onData = onData }
    func onInbound(payload: Data) { onData(payload) }
}

/// A minimal, two-device-testable networking screen: go online, share your ticket,
/// paste a peer's, and send bytes over a real QUIC connection.
struct NetworkingView: View {
    let seed: Data
    @StateObject private var net = NetNode()
    @State private var peerTicket = ""
    @State private var copied = false

    var body: some View {
        ZStack {
            KithBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Label(net.status, systemImage: net.status == "Online" ? "wifi" : "wifi.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(net.status == "Online" ? .green : .secondary)

                    if net.ticket.isEmpty {
                        Button("Go online") { Task { await net.start(seed: seed) } }
                            .buttonStyle(BrandButtonStyle())
                        Text("Starts a real peer-to-peer node (QUIC). Two devices on the same network can exchange a sealed message directly — no server.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        myTicketCard
                        sendCard
                    }

                    if !net.log.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(net.log, id: \.self) { Text($0).font(.caption.monospaced()) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kithCard()
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Networking (beta)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var myTicketCard: some View {
        VStack(spacing: 12) {
            if let qr = QRCode.image(from: net.ticket) {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                UIPasteboard.general.string = net.ticket
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied!" : "Copy my ticket", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered).tint(KithTheme.pink)
            Text("Share this with a peer so they can reach you.").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .kithCard()
    }

    private var sendCard: some View {
        VStack(spacing: 10) {
            TextField("Paste a peer's ticket…", text: $peerTicket, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2)
            Button("Send a test message") { Task { await net.sendTest(to: peerTicket) } }
                .buttonStyle(BrandButtonStyle())
                .disabled(peerTicket.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .kithCard()
    }
}
