//! Kith networking — an iroh-backed P2P node that carries opaque payloads (in
//! practice, `p2pcore::social::SealedEnvelope` bytes) between peers over QUIC.
//!
//! A [`Node`] both listens (an accept loop pushes received payloads to a queue) and
//! dials. The bytes on the wire are already end-to-end encrypted by `p2pcore`, so the
//! network layer never sees plaintext. This is the transport the app uses to turn
//! "waiting to connect" into a real connection.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iroh::{
    endpoint::{presets::Empty, Endpoint},
    EndpointAddr, RelayMode,
};
use tokio::sync::mpsc;

/// Application protocol id.
const ALPN: &[u8] = b"kith/social/0";
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

trait IntoAnyhow<T> {
    fn ah(self) -> Result<T>;
}
impl<T, E: std::fmt::Debug> IntoAnyhow<T> for std::result::Result<T, E> {
    fn ah(self) -> Result<T> {
        self.map_err(|e| anyhow!("{e:?}"))
    }
}

/// A peer-to-peer node: listens for inbound sealed payloads and dials out to send.
pub struct Node {
    endpoint: Endpoint,
    inbound: mpsc::UnboundedReceiver<Vec<u8>>,
}

impl Node {
    /// Bind a node with relays disabled (direct / LAN). Spawns the accept loop.
    pub async fn spawn() -> Result<Self> {
        let endpoint = Endpoint::builder(Empty)
            .crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .alpns(vec![ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .ah()?;

        let (tx, rx) = mpsc::unbounded_channel();
        let accept_ep = endpoint.clone();
        tokio::spawn(async move { accept_loop(accept_ep, tx).await });

        Ok(Self { endpoint, inbound: rx })
    }

    /// A same-machine dial address (loopback + this node's port), for tests and
    /// local development. Real peers dial the full advertised address / via discovery.
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        let port = addr
            .ip_addrs()
            .next()
            .map(|a| a.port())
            .ok_or_else(|| anyhow!("no direct port yet"))?;
        Ok(EndpointAddr::new(addr.id).with_ip_addr(SocketAddr::from(([127, 0, 0, 1], port))))
    }

    /// Send a payload (a sealed envelope) to a peer.
    pub async fn send(&self, to: EndpointAddr, payload: &[u8]) -> Result<()> {
        let conn = self.endpoint.connect(to, ALPN).await.ah()?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        send.write_all(payload).await.ah()?;
        send.finish().ah()?;
        let _ = recv.read_to_end(16).await; // wait for ack
        conn.close(0u32.into(), b"done");
        Ok(())
    }

    /// Await the next inbound payload (sealed envelope bytes). `None` once closed.
    pub async fn recv(&mut self) -> Option<Vec<u8>> {
        self.inbound.recv().await
    }

    /// Gracefully close the node.
    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

async fn accept_loop(endpoint: Endpoint, tx: mpsc::UnboundedSender<Vec<u8>>) {
    while let Some(incoming) = endpoint.accept().await {
        let tx = tx.clone();
        tokio::spawn(async move {
            let connecting = match incoming.accept() {
                Ok(c) => c,
                Err(_) => return,
            };
            let conn = match connecting.await {
                Ok(c) => c,
                Err(_) => return,
            };
            let (mut send, mut recv) = match conn.accept_bi().await {
                Ok(x) => x,
                Err(_) => return,
            };
            if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                let _ = send.write_all(b"ok").await;
                let _ = send.finish();
                let _ = tx.send(payload);
            }
            let _ = conn.closed().await;
        });
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
