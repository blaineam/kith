//! The run loop: start the connection relay, optionally the media store (local-disk,
//! rclone, or S3-over-iroh), print the link/QR, then idle until Ctrl-C.

use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};

use anyhow::{anyhow, Result};
use haven_net::blobstore::BlobServer;
use haven_net::s3tunnel::S3Server;
use haven_net::RelayNode;
use p2pcore::identity::Identity;

use crate::config::{Config, StoreBackend};

/// A guard that kills the rclone child on drop.
struct RcloneChild(Child);
impl Drop for RcloneChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

pub async fn run(cfg: Config) -> Result<()> {
    let id = Identity::from_seed(&cfg.seed);
    let my_hex = hex32(&id.public().node_id_bytes());

    println!("▸ Haven relay starting (no logs are written).");
    println!("  circle tag : {}", cfg.link.circle);
    println!("  members    : {}", cfg.link.members.len());
    println!("  data dir   : {}", cfg.data_dir.display());
    println!("  relay node : {my_hex}");

    // --- Connection relay (always on) ---------------------------------------------
    // Pure forwarder: no member handler, so it can never deliver content to itself.
    let relay = RelayNode::spawn(id.node_secret_bytes(), None)
        .await
        .map_err(|e| anyhow!("start relay: {e}"))?;
    let _ = cfg.link.member_bytes(); // (warmup hook; reverse paths form when members dial in)
    println!("✓ connection relay live — forwarding sealed frames toward circle members.");

    // --- Media store-and-forward --------------------------------------------------
    // Keep the started servers/guards alive for the process lifetime.
    let mut _blob_guard: Option<std::sync::Arc<BlobServer>> = None;
    let mut _s3_guard: Option<std::sync::Arc<S3Server>> = None;
    let mut _rclone_guard: Option<RcloneChild> = None;

    match &cfg.backend {
        StoreBackend::Local => {
            // Default: serve sealed blobs straight off local disk over haven/blob/1.
            let store = cfg.data_dir.join("store");
            let blob = BlobServer::spawn(id.node_secret_bytes(), store.clone())
                .await
                .map_err(|e| anyhow!("start local-disk blob store: {e}"))?;
            println!(
                "✓ media store live — local-disk blob mailbox at {} over Haven Net (haven/blob/1).",
                store.display()
            );
            println!("  storage node id (volunteer_node_id): {}", blob.node_id_hex());

            // Mesh replication: pull from each sibling relay every 30s so the mailbox
            // self-heals across the mesh (peers do the same in reverse → eventual set-union).
            if !cfg.peers.is_empty() {
                println!("  meshing with {} sibling relay(s) — mailbox self-replicates.", cfg.peers.len());
                let blob_mesh = blob.clone();
                let peers = cfg.peers.clone();
                tokio::spawn(async move {
                    loop {
                        for peer in &peers {
                            let _ = blob_mesh.sync_pull_from(peer).await;
                        }
                        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                    }
                });
            }
            _blob_guard = Some(blob);
        }
        StoreBackend::S3 | StoreBackend::Rclone { .. } => {
            // Opt-in: rclone serve s3 (local dir or a named remote) over haven/s3/1.
            let s3_local: SocketAddr = SocketAddr::from(([127, 0, 0, 1], cfg.s3_port));
            match start_rclone(&cfg, s3_local) {
                Ok(child) => {
                    _rclone_guard = Some(child);
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    let s3 = S3Server::spawn(id.node_secret_bytes(), s3_local)
                        .await
                        .map_err(|e| anyhow!("start s3-over-iroh: {e}"))?;
                    match &cfg.backend {
                        StoreBackend::Rclone { remote } => println!(
                            "✓ media store live — rclone serve s3 of remote '{}' on 127.0.0.1:{} over iroh (haven/s3/1).",
                            remote, cfg.s3_port
                        ),
                        _ => println!(
                            "✓ media store live — rclone serve s3 on 127.0.0.1:{} over iroh (haven/s3/1).",
                            cfg.s3_port
                        ),
                    }
                    println!("  storage node id (volunteer_node_id): {}", s3.node_id_hex());
                    _s3_guard = Some(s3);
                }
                Err(e) => {
                    eprintln!("⚠ media store disabled: {e}");
                    eprintln!("  (install rclone, or drop the --s3/--rclone-remote flag to use the local-disk store.)");
                }
            }
        }
        StoreBackend::None => {
            println!("• media store-and-forward disabled (--no-storage).");
        }
    }

    println!("\n═══════════════════════════════════════════════════════════════");
    println!("✓ Relay online. The Haven app already knows this relay from the link;");
    println!("  if it asks, the relay's node id (public routing data, not a secret) is:");
    println!("     {my_hex}");
    println!("  The relay only ever moves ciphertext. Stop with Ctrl-C.");
    println!("═══════════════════════════════════════════════════════════════\n");

    // Idle until Ctrl-C; the relay's accept/forward loops run in the background.
    let _ = &relay;
    tokio::signal::ctrl_c().await.ok();
    println!("▸ shutting down.");
    Ok(())
}

/// Launch `rclone serve s3` bound to loopback only (never a public interface), with
/// hardened, low-noise flags. The source is either a named rclone remote (so rclone owns
/// the provider auth — Haven holds no OAuth) or a plain local data dir. Returns a
/// kill-on-drop guard.
fn start_rclone(cfg: &Config, addr: SocketAddr) -> Result<RcloneChild> {
    let bin = cfg.rclone_bin.clone().unwrap_or_else(|| "rclone".to_string());

    // Source path: a remote (`remote:path`) for the rclone backend, else a local dir.
    let source = match &cfg.backend {
        StoreBackend::Rclone { remote } => remote.clone(),
        _ => {
            let data = cfg.data_dir.join("store");
            std::fs::create_dir_all(&data).map_err(|e| anyhow!("create store dir: {e}"))?;
            data.to_string_lossy().to_string()
        }
    };

    // Stable per-relay S3 creds (the tunnel is the real auth; these just satisfy rclone).
    let key = format!("haven{}", &hex32(&cfg.seed)[..18]);
    let secret = hex32(&cfg.seed)[18..50].to_string();

    let mut cmd = Command::new(&bin);
    cmd.arg("serve")
        .arg("s3")
        .arg(&source)
        .arg("--addr")
        .arg(addr.to_string()) // loopback only
        .arg("--auth-key")
        .arg(format!("{key},{secret}"))
        // Hardened / quiet: no request log, no transaction log.
        .arg("--log-level")
        .arg("ERROR")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(conf) = &cfg.rclone_config {
        cmd.arg("--config").arg(conf);
    }

    let child = cmd.spawn().map_err(|e| anyhow!("spawn rclone ({bin}): {e}"))?;
    Ok(RcloneChild(child))
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
