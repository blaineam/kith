//! Kith networking — an iroh-backed P2P node that carries opaque payloads (in
//! practice, `p2pcore::social::SealedEnvelope` bytes) between peers over QUIC.
//!
//! Connections are **kept alive and reused bidirectionally**: each message is a uni
//! stream on a cached connection keyed by the remote's node id. Whoever can reach the
//! other dials once; both then send over that same connection. This is what lets
//! delivery flow both ways even when one peer is behind a NAT that can't be dialed
//! directly. The bytes on the wire are already end-to-end encrypted by `p2pcore`.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Result};
use data_encoding::BASE32_NOPAD;
use iroh::{
    endpoint::{presets::N0, Connection, Endpoint},
    EndpointAddr, EndpointId, SecretKey,
};

const ALPN: &[u8] = b"haven/social/0";
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

/// Called for each inbound payload (sealed envelope / protocol frame bytes).
pub type InboundHandler = Arc<dyn Fn(Vec<u8>) + Send + Sync>;

type Conns = Arc<Mutex<HashMap<EndpointId, Connection>>>;

/// Lock that tolerates poisoning (a panic in one task must not cascade-abort others).
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

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
    conns: Conns,
    handler: InboundHandler,
}

impl Node {
    /// Bind a node using the owning identity's Ed25519 key (so `node_id_hex()` equals
    /// that identity's `node_id_bytes`), with the n0 preset: free public discovery +
    /// relays. Starts an accept loop that keeps each inbound connection alive.
    pub async fn spawn(secret: [u8; 32], handler: InboundHandler) -> Result<Self> {
        let endpoint = Endpoint::builder(N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![ALPN.to_vec()])
            .bind()
            .await
            .ah()?;
        let conns: Conns = Arc::new(Mutex::new(HashMap::new()));
        let ep = endpoint.clone();
        let c = conns.clone();
        let h = handler.clone();
        tokio::spawn(async move { accept_loop(ep, c, h).await });
        Ok(Self { endpoint, conns, handler })
    }

    /// This node's id (== the owning identity's `node_id_bytes`), as hex.
    pub fn node_id_hex(&self) -> String {
        hex(self.endpoint.id().as_bytes())
    }

    /// Send a payload to a contact by their hex node id. Discovery resolves the live
    /// address; an existing (dialed or accepted) connection is reused if present.
    pub async fn send_to_node(&self, node_id_hex: &str, payload: &[u8]) -> Result<()> {
        let bytes = decode_hex32(node_id_hex)?;
        let id = EndpointId::from_bytes(&bytes).map_err(|e| anyhow!("{e:?}"))?;
        self.send(EndpointAddr::new(id), payload).await
    }

    /// Send a payload to a peer address (reusing a live connection if one exists).
    pub async fn send(&self, to: EndpointAddr, payload: &[u8]) -> Result<()> {
        let conn = self.conn_for(to).await?;
        let mut s = conn.open_uni().await.ah()?;
        s.write_all(payload).await.ah()?;
        s.finish().ah()?;
        Ok(())
    }

    /// Reuse a live connection to this peer, or dial a fresh one (and start reading
    /// replies on it).
    async fn conn_for(&self, addr: EndpointAddr) -> Result<Connection> {
        let id = addr.id;
        if let Some(c) = lock(&self.conns).get(&id).cloned() {
            if c.close_reason().is_none() {
                return Ok(c);
            }
        }
        let conn = self.endpoint.connect(addr, ALPN).await.ah()?;
        lock(&self.conns).insert(id, conn.clone());
        let c = self.conns.clone();
        let h = self.handler.clone();
        let cc = conn.clone();
        tokio::spawn(async move { read_loop(cc, c, h).await });
        Ok(conn)
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

    /// A shareable ticket (base32 of this node's address) for a peer to dial.
    pub async fn ticket(&self) -> Result<String> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        Ok(BASE32_NOPAD.encode(&serde_json::to_vec(&addr).ah()?))
    }

    /// Send a payload to a peer identified by their [`Node::ticket`].
    pub async fn send_ticket(&self, ticket: &str, payload: &[u8]) -> Result<()> {
        let bytes = BASE32_NOPAD
            .decode(ticket.trim().as_bytes())
            .map_err(|_| anyhow!("bad ticket"))?;
        let addr: EndpointAddr = serde_json::from_slice(&bytes).map_err(|_| anyhow!("bad ticket"))?;
        self.send(addr, payload).await
    }

    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

async fn accept_loop(endpoint: Endpoint, conns: Conns, handler: InboundHandler) {
    while let Some(incoming) = endpoint.accept().await {
        let conns = conns.clone();
        let handler = handler.clone();
        tokio::spawn(async move {
            let Ok(connecting) = incoming.accept() else { return };
            let Ok(conn) = connecting.await else { return };
            // Keep the inbound connection so we can send back to a peer who dialed us
            // (they may be unreachable for us to dial directly).
            lock(&conns).insert(conn.remote_id(), conn.clone());
            read_loop(conn, conns, handler).await;
        });
    }
}

/// Read every uni stream on a connection as one message, for the connection's life.
async fn read_loop(conn: Connection, conns: Conns, handler: InboundHandler) {
    loop {
        match conn.accept_uni().await {
            Ok(mut recv) => {
                let handler = handler.clone();
                tokio::spawn(async move {
                    if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                        // The handler crosses into a foreign (Swift) callback — a panic
                        // there would abort the whole app, so contain it.
                        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            handler(payload);
                        }));
                    }
                });
            }
            Err(_) => break,
        }
    }
    let id = conn.remote_id();
    let mut map = lock(&conns);
    if map.get(&id).map(|c| c.close_reason().is_some()).unwrap_or(false) {
        map.remove(&id);
    }
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
