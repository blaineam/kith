//! `haven_ffi` — the UniFFI surface that bridges `p2pcore` to Swift (and Kotlin).
//!
//! Keeps the exposed API tiny and Swift-friendly: an [`Account`] object, a couple of
//! free functions, and plain records. All the security-critical logic stays in
//! `p2pcore`; this is only the boundary.

use std::sync::{Arc, Mutex};

use std::collections::HashSet;

use haven_net::Node;
use p2pcore::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use p2pcore::identity::{Identity, HavenId};
use p2pcore::link::HavenLink;
use p2pcore::social::{
    build_feed, open_bytes, open_event, seal_bytes, seal_event, Event, EventKind, Group,
    SealedEnvelope, TrackRef,
};

uniffi::setup_scaffolding!();

/// Errors crossing the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HavenError {
    #[error("{msg}")]
    Invalid { msg: String },
}

/// A Haven account: a no-PII identity backed by a hybrid post-quantum keypair.
/// Wraps `p2pcore::identity::Identity`.
#[derive(uniffi::Object)]
pub struct Account {
    inner: Identity,
}

#[uniffi::export]
impl Account {
    /// Create a brand-new account (random master seed).
    #[uniffi::constructor]
    pub fn generate() -> Arc<Self> {
        Arc::new(Self { inner: Identity::generate() })
    }

    /// Restore an account from its 32-byte master seed (e.g. read from the Keychain).
    #[uniffi::constructor]
    pub fn from_seed(seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be exactly 32 bytes".into() })?;
        Ok(Arc::new(Self { inner: Identity::from_seed(&seed) }))
    }

    /// The 32-byte master seed — the secret to persist in the Keychain / Secure
    /// Enclave and to back up for recovery. Reconstructs the whole identity.
    pub fn secret_seed(&self) -> Vec<u8> {
        self.inner.secret_seed().to_vec()
    }

    /// The routable node id (Ed25519 public key) as hex.
    pub fn node_id_hex(&self) -> String {
        hex(&self.inner.public().node_id_bytes())
    }

    /// Tamper-check fingerprint of the full hybrid public bundle, as hex.
    pub fn verification_hex(&self) -> String {
        hex(&self.inner.public().verification())
    }

    /// `haven://u/<id>#<verify>` — the deep-link / QR form of the reach-me link.
    pub fn haven_uri(&self) -> String {
        HavenLink::from_identity(&self.inner.public()).to_uri()
    }

    /// `https://<domain>/u/<id>#<verify>` — the website form of the reach-me link.
    pub fn haven_link(&self, domain: String) -> String {
        HavenLink::from_identity(&self.inner.public()).to_web(&domain)
    }

    /// The full public identity bundle (for publishing to discovery).
    pub fn public_bundle(&self) -> Vec<u8> {
        self.inner.public().to_bytes()
    }

    /// Produce a hybrid (Ed25519 + ML-DSA) signature over `msg`.
    pub fn sign(&self, msg: Vec<u8>) -> Vec<u8> {
        self.inner.sign(&msg)
    }
}

/// Parsed contents of a reach-me link.
#[derive(uniffi::Record)]
pub struct LinkInfo {
    pub id_hex: String,
    pub verification_hex: String,
    pub uri: String,
}

/// Parse a `haven://` or `https://…/u/…#…` reach-me link.
#[uniffi::export]
pub fn parse_link(s: String) -> Result<LinkInfo, HavenError> {
    let link = HavenLink::parse(&s).map_err(|e| HavenError::Invalid { msg: format!("{e}") })?;
    Ok(LinkInfo {
        id_hex: hex(&link.id),
        verification_hex: hex(&link.verification),
        uri: link.to_uri(),
    })
}

/// Result of the on-device cryptographic self-test.
#[derive(uniffi::Record)]
pub struct SelfTestReport {
    pub identity_ok: bool,
    pub hybrid_kem_ok: bool,
    pub signature_ok: bool,
    pub link_ok: bool,
    pub all_ok: bool,
    pub node_id_hex: String,
    pub summary: String,
}

/// Run the full hybrid-PQ pipeline **on this device** and report what passed:
/// generate an identity, seal a payload to itself (X25519+ML-KEM-768 → AES-256-GCM)
/// and reopen it, sign+verify (Ed25519+ML-DSA), and round-trip a reach-me link.
#[uniffi::export]
pub fn self_test() -> SelfTestReport {
    let id = Identity::generate();
    let pubid = id.public();
    let payload = b"on-device hybrid post-quantum self-test";

    let identity_ok = pubid.node_id_bytes() != [0u8; 32];

    let hybrid_kem_ok = match encapsulate_to(&pubid) {
        Ok((enc, key)) => {
            let sealed = seal(&key, payload);
            match decapsulate(&id, &enc) {
                Ok(k2) => open(&k2, &sealed).map(|p| p == payload).unwrap_or(false),
                Err(_) => false,
            }
        }
        Err(_) => false,
    };

    let sig = id.sign(payload);
    let signature_ok = pubid.verify(payload, &sig).is_ok()
        && pubid.verify(b"different message", &sig).is_err();

    let link = HavenLink::from_identity(&pubid);
    let link_ok = HavenLink::parse(&link.to_uri()).map(|l| l == link).unwrap_or(false);

    let all_ok = identity_ok && hybrid_kem_ok && signature_ok && link_ok;
    let summary = if all_ok {
        "All hybrid post-quantum checks passed on this device.".to_string()
    } else {
        "One or more on-device checks failed.".to_string()
    };

    SelfTestReport {
        identity_ok,
        hybrid_kem_ok,
        signature_ok,
        link_ok,
        all_ok,
        node_id_hex: hex(&pubid.node_id_bytes()),
        summary,
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ===== Live social demo =====
//
// A local, on-device demonstration of the social engine: every post / comment /
// reaction is really sealed end-to-end to the group and reopened (loopback), then
// reduced into a feed. It pairs your real account with a deterministic "friend"
// identity so you can see two-party interaction. (Networking between real devices
// is the next milestone; the crypto and feed logic here are the real thing.)

const FRIEND_SEED: [u8; 32] = *b"haven-demo-friend-seed-v1-padxxx";

struct DemoState {
    me: Identity,
    friend: Identity,
    group: Group,
    events: Vec<Event>,
}

/// A live local social session over the real hybrid-PQ social engine.
#[derive(uniffi::Object)]
pub struct SocialDemo {
    state: Mutex<DemoState>,
}

#[uniffi::export]
impl SocialDemo {
    /// Start a demo session from your account seed (your real identity) paired with a
    /// stable demo "friend".
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let me = Identity::from_seed(&seed);
        let friend = Identity::from_seed(&FRIEND_SEED);
        let group = Group::new("demo", vec![me.public(), friend.public()]);
        Ok(Arc::new(Self { state: Mutex::new(DemoState { me, friend, group, events: vec![] }) }))
    }

    pub fn my_node_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().node_id_bytes())
    }

    pub fn post(
        &self,
        body: String,
        media: Vec<String>,
        music: Option<TrackRefFfi>,
        retention_secs: Option<u64>,
        created_at: u64,
    ) -> String {
        let music = music.map(|m| m.into_core());
        self.author_event(true, created_at, EventKind::Post { body, media, music, retention_secs, story: false, mute_video: false })
    }
    pub fn friend_post(&self, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Post { body, media: vec![], music: None, retention_secs: None, story: false, mute_video: false })
    }
    pub fn comment(&self, target: String, body: String, media: Vec<String>, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Comment { target, body, media })
    }
    pub fn friend_comment(&self, target: String, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Comment { target, body, media: vec![] })
    }
    pub fn react(&self, target: String, emoji: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn friend_react(&self, target: String, emoji: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn edit(&self, target: String, body: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Edit { target, body, media: vec![], music: None, mute_video: false })
    }
    pub fn unsend(&self, target: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Unsend { target })
    }

    /// The current feed (newest first), with comments and reactions resolved.
    pub fn feed(&self, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        build_feed(st.events.clone(), now_ms, viewer_retention_secs)
            .into_iter()
            .map(|it| FeedItemFfi {
                id: it.id,
                author_short: short(&it.author),
                is_me: it.author == me,
                created_at: it.created_at,
                body: it.body,
                media: it.media,
                music: it.music.map(TrackRefFfi::from_core),
                edited: it.edited,
                unsent: it.unsent,
                story: it.story,
                mute_video: it.mute_video,
                comments: it
                    .comments
                    .into_iter()
                    .map(|c| FeedCommentFfi {
                        id: c.id,
                        author_short: short(&c.author),
                        is_me: c.author == me,
                        created_at: c.created_at,
                        body: c.body,
                        media: c.media,
                        edited: c.edited,
                        unsent: c.unsent,
                        reactions: c.reactions.into_iter().map(|r| ReactionFfi {
                            emoji: r.emoji, count: r.count, mine: r.authors.contains(&me), authors: r.authors,
                        }).collect(),
                    })
                    .collect(),
                reactions: it
                    .reactions
                    .into_iter()
                    .map(|r| ReactionFfi {
                        emoji: r.emoji,
                        count: r.count,
                        mine: r.authors.contains(&me),
                        authors: r.authors,
                    })
                    .collect(),
            })
            .collect()
    }

}

// Non-exported helpers (kept out of the UniFFI surface).
impl SocialDemo {
    /// Author an event as me or the friend: really seal it E2E to the group and
    /// reopen it (proving the crypto), then record it. Returns the event id.
    fn author_event(&self, as_me: bool, created_at: u64, kind: EventKind) -> String {
        let mut st = self.state.lock().unwrap();
        let author_pub = if as_me { st.me.public() } else { st.friend.public() };
        let event = Event::new(&author_pub.node_id_bytes(), created_at, kind);
        // Seal to the whole group, then reopen as me — the real E2E round-trip.
        let opened = {
            let author = if as_me { &st.me } else { &st.friend };
            let env = seal_event(author, &st.group, &event).expect("seal");
            open_event(&st.me, &author_pub, &env).expect("open")
        };
        let id = opened.id.clone();
        st.events.push(opened);
        id
    }
}

/// A reaction aggregate for the UI.
#[derive(uniffi::Record)]
pub struct ReactionFfi {
    pub emoji: String,
    pub count: u32,
    pub mine: bool,
    /// Node-id hexes of who reacted with this emoji (so the UI can show names).
    pub authors: Vec<String>,
}

/// A comment for the UI.
#[derive(uniffi::Record)]
pub struct FeedCommentFfi {
    pub id: String,
    pub author_short: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
    pub reactions: Vec<ReactionFfi>,
}

/// An attached Apple Music track (reference only — never audio).
#[derive(uniffi::Record, Clone)]
pub struct TrackRefFfi {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub duration_ms: u64,
}

impl TrackRefFfi {
    fn into_core(self) -> TrackRef {
        TrackRef {
            catalog_id: self.catalog_id,
            title: self.title,
            artist: self.artist,
            artwork_url: self.artwork_url,
            duration_ms: self.duration_ms,
        }
    }
    fn from_core(t: TrackRef) -> Self {
        Self {
            catalog_id: t.catalog_id,
            title: t.title,
            artist: t.artist,
            artwork_url: t.artwork_url,
            duration_ms: t.duration_ms,
        }
    }
}

/// A feed item (post/message) for the UI.
#[derive(uniffi::Record)]
pub struct FeedItemFfi {
    pub id: String,
    pub author_short: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub music: Option<TrackRefFfi>,
    pub edited: bool,
    pub unsent: bool,
    pub story: bool,
    pub mute_video: bool,
    pub comments: Vec<FeedCommentFfi>,
    pub reactions: Vec<ReactionFfi>,
}

fn short(node_hex: &str) -> String {
    node_hex.chars().take(8).collect()
}


// ===== Networking: a live P2P node =====

/// Foreign listener that receives inbound sealed-envelope bytes.
#[uniffi::export(with_foreign)]
pub trait InboundListener: Send + Sync {
    fn on_inbound(&self, payload: Vec<u8>);
}

/// A live peer-to-peer node: listens for inbound sealed posts and dials peers by
/// ticket. The bytes it moves are already E2E-encrypted by `p2pcore`.
#[derive(uniffi::Object)]
pub struct HavenNode {
    node: Node,
}

#[uniffi::export(async_runtime = "tokio")]
impl HavenNode {
    /// Start a node bound to this account's identity (so its node id equals the
    /// account's Haven id); inbound payloads are delivered to `listener`.
    #[uniffi::constructor]
    pub async fn start(account_seed: Vec<u8>, listener: Arc<dyn InboundListener>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let identity = Identity::from_seed(&seed);
        let l = listener.clone();
        let handler: haven_net::InboundHandler = Arc::new(move |payload| {
            // Never let a panic cross back into the foreign (Swift) callback and abort.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| l.on_inbound(payload)));
        });
        let node = Node::spawn(identity.node_secret_bytes(), handler)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })?;
        Ok(Arc::new(Self { node }))
    }

    /// This node's id (== the account's Haven id), as hex.
    pub fn node_id_hex(&self) -> String {
        self.node.node_id_hex()
    }

    /// A shareable ticket a peer dials to reach this node (full address form).
    pub async fn ticket(&self) -> Result<String, HavenError> {
        self.node.ticket().await.map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a contact by their hex node id (== their Haven id),
    /// resolving the live address via discovery.
    pub async fn send_to_node(&self, node_id_hex: String, payload: Vec<u8>) -> Result<(), HavenError> {
        self.node
            .send_to_node(&node_id_hex, &payload)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a peer identified by their full-address ticket.
    pub async fn send(&self, ticket: String, payload: Vec<u8>) -> Result<(), HavenError> {
        self.node
            .send_ticket(&ticket, &payload)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }
}

// ===== Real networked social store =====

/// Maps the core feed reducer output into the UI record type.
fn map_feed(events: Vec<Event>, me: &str, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
    build_feed(events, now_ms, viewer_retention_secs)
        .into_iter()
        .map(|it| FeedItemFfi {
            id: it.id,
            author_short: short(&it.author),
            is_me: it.author == me,
            created_at: it.created_at,
            body: it.body,
            media: it.media,
            music: it.music.map(TrackRefFfi::from_core),
            edited: it.edited,
            unsent: it.unsent,
            story: it.story,
            mute_video: it.mute_video,
            comments: it
                .comments
                .into_iter()
                .map(|c| FeedCommentFfi {
                    id: c.id,
                    author_short: short(&c.author),
                    is_me: c.author == me,
                        created_at: c.created_at,
                    body: c.body,
                    media: c.media,
                    edited: c.edited,
                    unsent: c.unsent,
                    reactions: c.reactions.into_iter().map(|r| ReactionFfi {
                        emoji: r.emoji, count: r.count, mine: r.authors.contains(&me.to_string()), authors: r.authors,
                    }).collect(),
                })
                .collect(),
            reactions: it
                .reactions
                .into_iter()
                .map(|r| ReactionFfi {
                    emoji: r.emoji,
                    count: r.count,
                    mine: r.authors.contains(&me.to_string()),
                    authors: r.authors,
                })
                .collect(),
        })
        .collect()
}

/// One circle: its own membership, event log, and dedup set.
struct Circle {
    id: String,
    name: String,
    members: Vec<HavenId>,
    events: Vec<Event>,
    seen: HashSet<String>,
}

struct NetState {
    me: Identity,
    circles: Vec<Circle>,
}

const DEFAULT_CIRCLE: &str = "default";

/// A circle summary for the UI.
#[derive(uniffi::Record)]
pub struct CircleInfoFfi {
    pub id: String,
    pub name: String,
    pub member_count: u32,
}

/// On-disk form, per circle, so circles/posts/contacts survive restarts and updates.
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistCircle {
    id: String,
    name: String,
    /// Members as their public-bundle bytes (HavenId isn't directly Serialize).
    members: Vec<Vec<u8>>,
    events: Vec<Event>,
}
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistState {
    circles: Vec<PersistCircle>,
}
/// Legacy single-circle on-disk form — migrated into the default circle on load.
#[derive(serde::Deserialize)]
struct LegacyPersistState {
    events: Vec<Event>,
    contacts: Vec<Vec<u8>>,
}

/// The real networked social store: your identity + your contacts' public bundles +
/// the event log. Unlike `SocialDemo` it seals to your actual circle and ingests posts
/// received from contacts over the network. Transport-agnostic: the same sealed
/// envelope bytes ride iroh (internet) or MultipeerConnectivity (nearby Bluetooth/Wi-Fi).
#[derive(uniffi::Object)]
pub struct HavenSocial {
    state: Mutex<NetState>,
}

#[uniffi::export]
impl HavenSocial {
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        Ok(Arc::new(Self {
            state: Mutex::new(NetState {
                me: Identity::from_seed(&seed),
                circles: vec![Circle {
                    id: DEFAULT_CIRCLE.to_string(),
                    name: "My Circle".to_string(),
                    members: vec![],
                    events: vec![],
                    seen: HashSet::new(),
                }],
            }),
        }))
    }

    /// All circles (id, name, member count) for the UI switcher.
    pub fn circles(&self) -> Vec<CircleInfoFfi> {
        self.state.lock().unwrap().circles.iter().map(|c| CircleInfoFfi {
            id: c.id.clone(),
            name: c.name.clone(),
            member_count: c.members.len() as u32,
        }).collect()
    }

    /// Create a circle (no-op if the id already exists).
    pub fn create_circle(&self, id: String, name: String) {
        let mut st = self.state.lock().unwrap();
        if !st.circles.iter().any(|c| c.id == id) {
            st.circles.push(Circle { id, name, members: vec![], events: vec![], seen: HashSet::new() });
        }
    }

    pub fn rename_circle(&self, id: String, name: String) {
        if let Some(c) = self.state.lock().unwrap().circles.iter_mut().find(|c| c.id == id) {
            c.name = name;
        }
    }

    /// Leave/delete a circle (you keep the default one).
    pub fn leave_circle(&self, id: String) {
        let mut st = self.state.lock().unwrap();
        st.circles.retain(|c| c.id != id || c.id == DEFAULT_CIRCLE);
    }

    /// Remove a member from ONE circle (their membership + their events there) without
    /// blocking them globally — they stay in your other circles and your default circle.
    pub fn remove_from_circle(&self, circle_id: String, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        if let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) {
            c.members.retain(|m| hex(&m.node_id_bytes()) != node_hex);
            c.events.retain(|e| e.author != node_hex);
        }
    }

    /// Block a node: remove them from every circle (members + their events) so their
    /// posts vanish and they can no longer be a sealed recipient. The caller also keeps
    /// a blocklist that drops their inbound frames and prevents re-add on handshake.
    pub fn block_member(&self, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        for c in st.circles.iter_mut() {
            c.members.retain(|m| hex(&m.node_id_bytes()) != node_hex);
            c.events.retain(|e| e.author != node_hex);
        }
    }

    pub fn my_node_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().node_id_bytes())
    }

    /// Our public bundle to send in the handshake (Hello). Contains the keys a contact
    /// needs to seal posts *to* us — which the reach-me link/QR does not carry.
    pub fn my_bundle(&self) -> Vec<u8> {
        self.state.lock().unwrap().me.public().to_bytes()
    }

    pub fn verification_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().verification())
    }

    /// BLAKE3 verification hex of a received bundle — check it against the link's hash
    /// before trusting it (MITM guard).
    pub fn bundle_verification_hex(&self, bundle: Vec<u8>) -> Result<String, HavenError> {
        let id = HavenId::from_bytes(&bundle)
            .map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })?;
        Ok(hex(&id.verification()))
    }

    /// A signed profile: your chosen name signed by your identity key, so contacts can
    /// display the name **you** chose — you hold authority over it, not a free-text
    /// label they typed. Layout: [u32 sig_len][hybrid signature][name utf8].
    pub fn my_signed_profile(&self, name: String) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let sig = st.me.sign(name.as_bytes());
        let mut out = (sig.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(&sig);
        out.extend_from_slice(name.as_bytes());
        out
    }

    /// Verify a contact's signed profile against their bundle; returns the authoritative
    /// name only if the signature checks out (so a relay can't rename someone).
    pub fn verify_profile(&self, bundle: Vec<u8>, blob: Vec<u8>) -> Option<String> {
        if blob.len() < 4 {
            return None;
        }
        let sig_len = u32::from_le_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        if blob.len() < 4 + sig_len {
            return None;
        }
        let sig = &blob[4..4 + sig_len];
        let name_bytes = &blob[4 + sig_len..];
        let id = HavenId::from_bytes(&bundle).ok()?;
        id.verify(name_bytes, sig).ok()?;
        String::from_utf8(name_bytes.to_vec()).ok()
    }

    /// Add a contact's verified public bundle to a circle. Returns their node id hex.
    pub fn add_contact_bundle(&self, circle_id: String, bundle: Vec<u8>) -> Result<String, HavenError> {
        let id = HavenId::from_bytes(&bundle)
            .map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })?;
        let node_hex = hex(&id.node_id_bytes());
        let mut st = self.state.lock().unwrap();
        let circle = st
            .circles
            .iter_mut()
            .find(|c| c.id == circle_id)
            .ok_or_else(|| HavenError::Invalid { msg: "unknown circle".into() })?;
        if !circle.members.iter().any(|c| c.node_id_bytes() == id.node_id_bytes()) {
            circle.members.push(id);
        }
        Ok(node_hex)
    }

    /// Add an already-known contact (bundle held in some circle) to another circle —
    /// for composing a new circle out of your existing contacts.
    pub fn add_existing_to_circle(&self, circle_id: String, node_hex: String) -> Result<(), HavenError> {
        let mut st = self.state.lock().unwrap();
        let bundle = st
            .circles
            .iter()
            .flat_map(|c| c.members.iter())
            .find(|m| hex(&m.node_id_bytes()) == node_hex)
            .cloned()
            .ok_or_else(|| HavenError::Invalid { msg: "unknown contact".into() })?;
        let circle = st
            .circles
            .iter_mut()
            .find(|c| c.id == circle_id)
            .ok_or_else(|| HavenError::Invalid { msg: "unknown circle".into() })?;
        if !circle.members.iter().any(|m| m.node_id_bytes() == bundle.node_id_bytes()) {
            circle.members.push(bundle);
        }
        Ok(())
    }

    /// Node ids of the members of a circle (who to broadcast that circle's posts to).
    pub fn contact_node_ids(&self, circle_id: String) -> Vec<String> {
        self.state
            .lock()
            .unwrap()
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.members.iter().map(|m| hex(&m.node_id_bytes())).collect())
            .unwrap_or_default()
    }

    pub fn post(
        &self,
        circle_id: String,
        body: String,
        media: Vec<String>,
        music: Option<TrackRefFfi>,
        retention_secs: Option<u64>,
        story: bool,
        mute_video: bool,
        created_at: u64,
    ) -> Result<Vec<u8>, HavenError> {
        let music = music.map(|m| m.into_core());
        self.author(&circle_id, created_at, EventKind::Post { body, media, music, retention_secs, story, mute_video })
    }
    pub fn comment(&self, circle_id: String, target: String, body: String, media: Vec<String>, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Comment { target, body, media })
    }
    pub fn react(&self, circle_id: String, target: String, emoji: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn edit(&self, circle_id: String, target: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool, created_at: u64) -> Result<Vec<u8>, HavenError> {
        let music = music.map(|m| m.into_core());
        self.author(&circle_id, created_at, EventKind::Edit { target, body, media, music, mute_video })
    }
    pub fn unsend(&self, circle_id: String, target: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Unsend { target })
    }

    /// Ingest a sealed envelope received from the network. Opens it against the known
    /// sender contact, dedups by event id, records it. Returns true if it was new.
    pub fn receive(&self, circle_id: String, envelope: Vec<u8>) -> Result<bool, HavenError> {
        let env = SealedEnvelope::from_bytes(&envelope)
            .map_err(|e| HavenError::Invalid { msg: format!("bad envelope: {e}") })?;
        let sender_hex = env.sender_hex();
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return Ok(false) };
        let sender = st.circles[idx]
            .members
            .iter()
            .find(|c| hex(&c.node_id_bytes()) == sender_hex)
            .cloned();
        let Some(sender) = sender else { return Ok(false) };
        let event = open_event(&st.me, &sender, &env)
            .map_err(|e| HavenError::Invalid { msg: format!("open failed: {e}") })?;
        if st.circles[idx].seen.contains(&event.id) {
            return Ok(false);
        }
        st.circles[idx].seen.insert(event.id.clone());
        st.circles[idx].events.push(event);
        Ok(true)
    }

    /// Re-seal everything **I** authored to a circle — to sync a peer that just
    /// connected. Only my own events (relaying others' would forge authorship).
    pub fn sync_envelopes(&self, circle_id: String) -> Vec<Vec<u8>> {
        let st = self.state.lock().unwrap();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let Some(circle) = st.circles.iter().find(|c| c.id == circle_id) else { return vec![] };
        let mut members = vec![st.me.public()];
        members.extend(circle.members.iter().cloned());
        let group = Group::new(circle_id, members);
        circle
            .events
            .iter()
            .filter(|e| e.author == me_hex)
            .filter_map(|e| seal_event(&st.me, &group, e).ok().map(|env| env.to_bytes()))
            .collect()
    }

    pub fn feed(&self, circle_id: String, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        let events = st
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.events.clone())
            .unwrap_or_default();
        map_feed(events, &me, now_ms, viewer_retention_secs)
    }

    /// Seal a media blob to one contact (hybrid KEM → AES-256-GCM). The recipient
    /// opens it with `open_media`. Layout: [32 eph_x_pub][u32 pq_len][pq_ct][ciphertext].
    pub fn seal_media(&self, recipient_node_hex: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        let recipient = st
            .circles
            .iter()
            .flat_map(|c| c.members.iter())
            .find(|m| hex(&m.node_id_bytes()) == recipient_node_hex)
            .ok_or_else(|| HavenError::Invalid { msg: "unknown recipient".into() })?;
        let (enc, key) =
            encapsulate_to(recipient).map_err(|e| HavenError::Invalid { msg: format!("{e}") })?;
        let ct = seal(&key, &data);
        let mut out = Vec::with_capacity(36 + enc.pq_ct.len() + ct.len());
        out.extend_from_slice(&enc.eph_x_pub);
        out.extend_from_slice(&(enc.pq_ct.len() as u32).to_le_bytes());
        out.extend_from_slice(&enc.pq_ct);
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Open a media blob sealed to us by a contact. Returns the plaintext bytes.
    pub fn open_media(&self, sealed: Vec<u8>) -> Option<Vec<u8>> {
        if sealed.len() < 36 {
            return None;
        }
        let eph_x_pub: [u8; 32] = sealed[0..32].try_into().ok()?;
        let pq_len = u32::from_le_bytes(sealed[32..36].try_into().ok()?) as usize;
        if sealed.len() < 36 + pq_len {
            return None;
        }
        let pq_ct = sealed[36..36 + pq_len].to_vec();
        let ct = &sealed[36 + pq_len..];
        let enc = Encapsulation { eph_x_pub, pq_ct };
        let st = self.state.lock().unwrap();
        let key = decapsulate(&st.me, &enc).ok()?;
        open(&key, ct).ok()
    }

    /// Seal a media blob to the WHOLE circle (any member can open it). The shared
    /// store host stores the result opaquely — it can't read it. Returns the sealed
    /// envelope bytes to upload.
    pub fn seal_circle_media(&self, circle_id: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        let Some(circle) = st.circles.iter().find(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        let mut members = vec![st.me.public()];
        members.extend(circle.members.iter().cloned());
        let group = Group::new(circle_id, members);
        seal_bytes(&st.me, &group, &data)
            .map(|env| env.to_bytes())
            .map_err(|e| HavenError::Invalid { msg: format!("{e}") })
    }

    /// Open a circle-sealed media blob fetched from the shared store. Verifies the
    /// sender (read from the envelope) against the circle roster.
    pub fn open_circle_media(&self, circle_id: String, sealed: Vec<u8>) -> Option<Vec<u8>> {
        let st = self.state.lock().unwrap();
        let env = SealedEnvelope::from_bytes(&sealed).ok()?;
        let sender_hex = env.sender_hex();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let circle = st.circles.iter().find(|c| c.id == circle_id)?;
        let sender_pub = if sender_hex == me_hex {
            st.me.public()
        } else {
            circle.members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex)?.clone()
        };
        open_bytes(&st.me, &sender_pub, &env).ok()
    }

    /// Serialize all circles (members + events) for on-disk persistence.
    pub fn export_state(&self) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let ps = PersistState {
            circles: st.circles.iter().map(|c| PersistCircle {
                id: c.id.clone(),
                name: c.name.clone(),
                members: c.members.iter().map(|m| m.to_bytes()).collect(),
                events: c.events.clone(),
            }).collect(),
        };
        serde_json::to_vec(&ps).unwrap_or_default()
    }

    /// Merge a previously-exported store back in (dedup by event id / member node id),
    /// so circles, posts, and connections survive restarts and updates. Migrates the
    /// legacy single-circle format into the default circle.
    pub fn import_state(&self, data: Vec<u8>) {
        let mut st = self.state.lock().unwrap();
        if let Ok(ps) = serde_json::from_slice::<PersistState>(&data) {
            for pc in ps.circles {
                Self::merge_circle(&mut st, pc);
            }
        } else if let Ok(old) = serde_json::from_slice::<LegacyPersistState>(&data) {
            Self::merge_circle(&mut st, PersistCircle {
                id: DEFAULT_CIRCLE.to_string(),
                name: "My Circle".to_string(),
                members: old.contacts,
                events: old.events,
            });
        }
    }
}

impl HavenSocial {
    fn merge_circle(st: &mut NetState, pc: PersistCircle) {
        let idx = match st.circles.iter().position(|c| c.id == pc.id) {
            Some(i) => i,
            None => {
                st.circles.push(Circle {
                    id: pc.id.clone(),
                    name: pc.name.clone(),
                    members: vec![],
                    events: vec![],
                    seen: HashSet::new(),
                });
                st.circles.len() - 1
            }
        };
        for mb in pc.members {
            if let Ok(id) = HavenId::from_bytes(&mb) {
                if !st.circles[idx].members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes()) {
                    st.circles[idx].members.push(id);
                }
            }
        }
        for e in pc.events {
            if !st.circles[idx].seen.contains(&e.id) {
                st.circles[idx].seen.insert(e.id.clone());
                st.circles[idx].events.push(e);
            }
        }
    }

    fn author(&self, circle_id: &str, created_at: u64, kind: EventKind) -> Result<Vec<u8>, HavenError> {
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        let event = Event::new(&me_pub.node_id_bytes(), created_at, kind);
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        let mut members = vec![me_pub];
        members.extend(st.circles[idx].members.iter().cloned());
        let group = Group::new(circle_id.to_string(), members);
        let env = seal_event(&st.me, &group, &event)
            .map_err(|e| HavenError::Invalid { msg: format!("seal failed: {e}") })?;
        st.circles[idx].seen.insert(event.id.clone());
        st.circles[idx].events.push(event);
        Ok(env.to_bytes())
    }
}

#[cfg(test)]
mod net_tests {
    use super::*;

    #[test]
    fn two_socials_exchange_a_post() {
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();

        let cid = DEFAULT_CIRCLE.to_string();

        // Handshake: each adds the other's verified bundle to their default circle.
        let bob_id = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        let alice_id = bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        assert_eq!(bob_id, bob.my_node_hex());
        assert_eq!(alice_id, alice.my_node_hex());

        // Alice posts → envelope → Bob receives and opens it.
        let env = alice.post(cid.clone(), "hi mom 💜".into(), vec![], None, None, false, 1_000).unwrap();
        assert!(bob.receive(cid.clone(), env.clone()).unwrap(), "new on first receive");
        assert!(!bob.receive(cid.clone(), env).unwrap(), "deduped on second receive");

        let feed = bob.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hi mom 💜");
        assert!(!feed[0].is_me, "the post is from Alice, not Bob");

        // A stranger Bob hasn't added cannot be opened (ignored, not an error).
        let eve = HavenSocial::new([9u8; 32].to_vec()).unwrap();
        eve.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        let eve_env = eve.post(cid.clone(), "spam".into(), vec![], None, None, false, 1_500).unwrap();
        assert!(!bob.receive(cid.clone(), eve_env).unwrap(), "unknown sender is ignored");
        assert_eq!(bob.feed(cid.clone(), 2_000, None).len(), 1, "stranger's post not in feed");

        // Signed profile: Bob reads Alice's authoritative name; a tampered name is rejected.
        let prof = alice.my_signed_profile("Alice".into());
        assert_eq!(bob.verify_profile(alice.my_bundle(), prof.clone()).as_deref(), Some("Alice"));
        let mut forged = prof;
        let last = forged.len() - 1;
        forged[last] ^= 0xff;
        assert!(bob.verify_profile(alice.my_bundle(), forged).is_none(), "tampered name rejected");

        // Media blob: Alice seals a photo to Bob; Bob opens it; a stranger can't.
        let photo = vec![7u8; 5000];
        let sealed = alice.seal_media(bob.my_node_hex(), photo.clone()).unwrap();
        assert_eq!(bob.open_media(sealed.clone()), Some(photo.clone()));
        assert!(eve.open_media(sealed).is_none(), "non-recipient can't open media");

        // Persistence: export Bob's store, reload into a fresh instance → posts survive.
        let saved = bob.export_state();
        let bob2 = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        bob2.import_state(saved);
        assert_eq!(bob2.feed(cid.clone(), 2_000, None).len(), 1, "posts survive a restart");
        assert_eq!(bob2.contact_node_ids(cid.clone()), bob.contact_node_ids(cid.clone()), "contacts survive too");

        // Multi-circle isolation: a post in a new circle stays out of the default circle.
        alice.create_circle("fam".into(), "Family".into());
        alice.add_contact_bundle("fam".into(), bob.my_bundle()).unwrap();
        bob.create_circle("fam".into(), "Family".into());
        bob.add_contact_bundle("fam".into(), alice.my_bundle()).unwrap();
        let fam_env = alice.post("fam".into(), "just family".into(), vec![], None, None, false, 3_000).unwrap();
        assert!(bob.receive("fam".into(), fam_env).unwrap());
        assert_eq!(bob.feed("fam".into(), 4_000, None).len(), 1, "fam post lands in fam circle");
        assert_eq!(bob.feed(cid, 4_000, None).len(), 1, "default circle is unchanged");
        assert_eq!(alice.circles().len(), 2, "alice now has two circles");
    }
}
