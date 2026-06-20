//! Kith networking — an iroh-backed P2P node that carries opaque payloads (in
//! practice, `p2pcore::social::SealedEnvelope` bytes) between peers over QUIC.
//!
//! A [`Node`] both listens (an accept loop hands each received payload to a callback)
//! and dials. The bytes on the wire are already end-to-end encrypted by `p2pcore`, so
//! the network layer never sees plaintext. Peers exchange a [`Node::ticket`] string
//! (a base32-encoded address) to find each other.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use data_encoding::BASE32_NOPAD;
use iroh::{
    endpoint::{presets::N0, Endpoint},
    EndpointAddr, EndpointId, SecretKey,
};

const ALPN: &[u8] = b"kith/social/0";
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

/// Called for each inbound payload (sealed envelope bytes).
pub type InboundHandler = Arc<dyn Fn(Vec<u8>) + Send + Sync>;

trait IntoAnyhow<T> {
    fn ah(self) -> Result<T>;
}
impl<T, E: std::fmt::Debug> IntoAnyhow<T> for std::result::Result<T, E> {
    fn ah(self) -> Result<T> {
        self.map_err(|e| anyhow!("{e:?}"))
    }
}

/// A peer-to-peer node.
pub struct Node {
    endpoint: Endpoint,
}

impl Node {
    /// Bind a node **using the owning identity's Ed25519 key** (so `node_id_hex()`
    /// equals that identity's `node_id_bytes`), with the n0 preset: free public
    /// discovery (DNS/pkarr) + relays, so a contact can dial you by the id in your
    /// reach-me link, across networks. Starts the accept loop feeding `handler`.
    pub async fn spawn(secret: [u8; 32], handler: InboundHandler) -> Result<Self> {
        let endpoint = Endpoint::builder(N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![ALPN.to_vec()])
            .bind()
            .await
            .ah()?;
        let ep = endpoint.clone();
        tokio::spawn(async move { accept_loop(ep, handler).await });
        Ok(Self { endpoint })
    }

    /// This node's id (== the owning identity's `node_id_bytes`), as hex.
    pub fn node_id_hex(&self) -> String {
        hex(self.endpoint.id().as_bytes())
    }

    /// Send a payload to a contact by their hex node id (== their Kith id). Discovery
    /// resolves the live address; no ticket / IP needed.
    pub async fn send_to_node(&self, node_id_hex: &str, payload: &[u8]) -> Result<()> {
        let bytes = decode_hex32(node_id_hex)?;
        let id = EndpointId::from_bytes(&bytes).map_err(|e| anyhow!("{e:?}"))?;
        self.send(EndpointAddr::new(id), payload).await
    }

    /// A shareable ticket (base32 of this node's address) for a peer to dial.
    pub async fn ticket(&self) -> Result<String> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        let bytes = serde_json::to_vec(&addr).ah()?;
        Ok(BASE32_NOPAD.encode(&bytes))
    }

    /// Send a payload to a peer identified by their [`Node::ticket`].
    pub async fn send_ticket(&self, ticket: &str, payload: &[u8]) -> Result<()> {
        let bytes = BASE32_NOPAD
            .decode(ticket.trim().as_bytes())
            .map_err(|_| anyhow!("bad ticket"))?;
        let addr: EndpointAddr = serde_json::from_slice(&bytes).map_err(|_| anyhow!("bad ticket"))?;
        self.send(addr, payload).await
    }

    /// Same-machine dial address (loopback + this node's port), for local tests.
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        let port = addr
            .ip_addrs()
            .next()
            .map(|a| a.port())
            .ok_or_else(|| anyhow!("no direct port yet"))?;
        Ok(EndpointAddr::new(addr.id).with_ip_addr(SocketAddr::from(([127, 0, 0, 1], port))))
    }

    /// Send a payload to a peer address.
    pub async fn send(&self, to: EndpointAddr, payload: &[u8]) -> Result<()> {
        let conn = self.endpoint.connect(to, ALPN).await.ah()?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        send.write_all(payload).await.ah()?;
        send.finish().ah()?;
        let _ = recv.read_to_end(16).await; // ack
        conn.close(0u32.into(), b"done");
        Ok(())
    }

    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

async fn accept_loop(endpoint: Endpoint, handler: InboundHandler) {
    while let Some(incoming) = endpoint.accept().await {
        let handler = handler.clone();
        tokio::spawn(async move {
            let Ok(connecting) = incoming.accept() else { return };
            let Ok(conn) = connecting.await else { return };
            let Ok((mut send, mut recv)) = conn.accept_bi().await else { return };
            if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                let _ = send.write_all(b"ok").await;
                let _ = send.finish();
                handler(payload);
            }
            let _ = conn.closed().await;
        });
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn decode_hex32(s: &str) -> Result<[u8; 32]> {
    let s = s.trim();
    if s.len() != 64 {
        return Err(anyhow!("node id must be 64 hex chars"));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("bad hex"))?;
    }
    Ok(out)
}

async fn wait_for_direct_addr(endpoint: &Endpoint) -> Result<EndpointAddr> {
    for _ in 0..50 {
        let addr = endpoint.addr();
        if addr.ip_addrs().next().is_some() {
            return Ok(addr);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(anyhow!("no direct addresses discovered within 5s"))
}
