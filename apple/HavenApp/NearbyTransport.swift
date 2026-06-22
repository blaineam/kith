import Foundation
import MultipeerConnectivity

/// Nearby offline transport over MultipeerConnectivity — spans Bluetooth + peer-to-peer
/// Wi-Fi with no internet or router, and forms a small mesh. It carries the exact same
/// sealed protocol frames ([type][payload]) as the iroh path, so two phones in the same
/// room sync even fully offline. The bytes are already E2E-encrypted by the core; the
/// Multipeer link adds its own transport encryption on top.
final class NearbyTransport: NSObject {
    private let serviceType = "haven-circle"   // 1–15 chars, lowercase + hyphens (was kith-circle)
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let onInbound: (Data) -> Void
    private let onPeerConnected: () -> Void

    /// `displayName` should be our node id hex (truncated to Multipeer's 63-byte limit);
    /// it's only used to deduplicate who-invites-whom. Identity is still proven by the
    /// Hello bundle + verification-hash handshake at the protocol layer.
    init(displayName: String, onInbound: @escaping (Data) -> Void, onPeerConnected: @escaping () -> Void) {
        self.onInbound = onInbound
        self.onPeerConnected = onPeerConnected
        let name = String(displayName.prefix(60))
        peerID = MCPeerID(displayName: name.isEmpty ? "kith" : name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

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
    func broadcast(_ frame: Data) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(frame, toPeers: peers, with: .reliable)
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
