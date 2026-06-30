import Foundation
import MultipeerConnectivity

/// Nearby offline transport over MultipeerConnectivity — spans Bluetooth + peer-to-peer
/// Wi-Fi with no internet or router, and forms a small mesh. It carries the exact same
/// sealed protocol frames ([type][payload]) as the iroh path, so two phones in the same
/// room sync even fully offline. The bytes are already E2E-encrypted by the core; the
/// Multipeer link adds its own transport encryption on top.
final class NearbyTransport: NSObject {
    private let serviceType = "haven-circle"   // 1–15 chars, lowercase + hyphens 
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let onInbound: (Data) -> Void
    private let onPeerConnected: () -> Void
    /// All MCSession reads/writes happen here, never on the main thread. `connectedPeers` and
    /// `send(_:toPeers:)` both dispatch into MultipeerConnectivity's own serial queue; calling them
    /// from `@MainActor` (as every `nearbyBroadcast` caller does) means a backed-up send queue — e.g.
    /// posting a big batch of media, one frame per chunk — blocks the main thread until the 0x8BADF00D
    /// watchdog kills the app. Serializing here keeps frame order while freeing the main thread.
    private let sendQueue = DispatchQueue(label: "haven.nearby.send", qos: .utility)

    /// `displayName` should be our node id hex (truncated to Multipeer's 63-byte limit);
    /// it's only used to deduplicate who-invites-whom. Identity is still proven by the
    /// Hello bundle + verification-hash handshake at the protocol layer.
    init(displayName: String, onInbound: @escaping (Data) -> Void, onPeerConnected: @escaping () -> Void) {
        self.onInbound = onInbound
        self.onPeerConnected = onPeerConnected
        let name = String(displayName.prefix(60))
        peerID = MCPeerID(displayName: name.isEmpty ? "haven" : name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// Whether any nearby peer is currently connected (used to tell the user whether a device-link
    /// request actually has a path to the other device).
    var hasConnectedPeers: Bool { !session.connectedPeers.isEmpty }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// Send a frame to every connected nearby peer (recipients who can't open it ignore it).
    /// Fire-and-forget on a background queue so a slow/jammed Multipeer link never stalls the main
    /// thread (see `sendQueue`).
    func broadcast(_ frame: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            let peers = self.session.connectedPeers
            guard !peers.isEmpty else { return }
            try? self.session.send(frame, toPeers: peers, with: .reliable)
        }
    }
}

extension NearbyTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected { onPeerConnected() }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onInbound(data)
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearbyTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension NearbyTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Only one side initiates, to avoid dueling invitations (the other side accepts).
        if self.peerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
