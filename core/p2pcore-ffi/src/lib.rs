//! `kith_ffi` — the UniFFI surface that bridges `p2pcore` to Swift (and Kotlin).
//!
//! Keeps the exposed API tiny and Swift-friendly: an [`Account`] object, a couple of
//! free functions, and plain records. All the security-critical logic stays in
//! `p2pcore`; this is only the boundary.

use std::sync::{Arc, Mutex};

use std::collections::HashSet;

use kith_net::Node;
use p2pcore::crypto::{decapsulate, encapsulate_to, open, seal};
use p2pcore::identity::{Identity, KithId};
use p2pcore::link::KithLink;
use p2pcore::social::{
    build_feed, open_event, seal_event, Event, EventKind, Group, SealedEnvelope, TrackRef,
};

uniffi::setup_scaffolding!();

/// Errors crossing the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum KithError {
    #[error("{msg}")]
    Invalid { msg: String },
}

/// A Kith account: a no-PII identity backed by a hybrid post-quantum keypair.
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
    pub fn from_seed(seed: Vec<u8>) -> Result<Arc<Self>, KithError> {
        let seed: [u8; 32] = seed
            .try_into()
            .map_err(|_| KithError::Invalid { msg: "seed must be exactly 32 bytes".into() })?;
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

    /// `kith://u/<id>#<verify>` — the deep-link / QR form of the reach-me link.
    pub fn kith_uri(&self) -> String {
        KithLink::from_identity(&self.inner.public()).to_uri()
    }

    /// `https://<domain>/u/<id>#<verify>` — the website form of the reach-me link.
    pub fn kith_link(&self, domain: String) -> String {
        KithLink::from_identity(&self.inner.public()).to_web(&domain)
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

/// Parse a `kith://` or `https://…/u/…#…` reach-me link.
#[uniffi::export]
pub fn parse_link(s: String) -> Result<LinkInfo, KithError> {
    let link = KithLink::parse(&s).map_err(|e| KithError::Invalid { msg: format!("{e}") })?;
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

    let link = KithLink::from_identity(&pubid);
    let link_ok = KithLink::parse(&link.to_uri()).map(|l| l == link).unwrap_or(false);

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

const FRIEND_SEED: [u8; 32] = *b"kith-demo-friend-seed-v1--padxxx";

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
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, KithError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| KithError::Invalid { msg: "seed must be 32 bytes".into() })?;
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
        self.author_event(true, created_at, EventKind::Post { body, media, music, retention_secs })
    }
    pub fn friend_post(&self, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Post { body, media: vec![], music: None, retention_secs: None })
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
        self.author_event(true, created_at, EventKind::Edit { target, body })
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
                comments: it
                    .comments
                    .into_iter()
                    .map(|c| FeedCommentFfi {
                        id: c.id,
                        author_short: short(&c.author),
                        is_me: c.author == me,
                        body: c.body,
                        media: c.media,
                        edited: c.edited,
                        unsent: c.unsent,
                    })
                    .collect(),
                reactions: it
                    .reactions
                    .into_iter()
                    .map(|r| ReactionFfi {
                        emoji: r.emoji,
                        count: r.count,
                        mine: r.authors.contains(&me),
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
}

/// A comment for the UI.
#[derive(uniffi::Record)]
pub struct FeedCommentFfi {
    pub id: String,
    pub author_short: String,
    pub is_me: bool,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
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
pub struct KithNode {
    node: Node,
}

#[uniffi::export(async_runtime = "tokio")]
impl KithNode {
    /// Start a node bound to this account's identity (so its node id equals the
    /// account's Kith id); inbound payloads are delivered to `listener`.
    #[uniffi::constructor]
    pub async fn start(account_seed: Vec<u8>, listener: Arc<dyn InboundListener>) -> Result<Arc<Self>, KithError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| KithError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let identity = Identity::from_seed(&seed);
        let l = listener.clone();
        let handler: kith_net::InboundHandler = Arc::new(move |payload| l.on_inbound(payload));
        let node = Node::spawn(identity.node_secret_bytes(), handler)
            .await
            .map_err(|e| KithError::Invalid { msg: e.to_string() })?;
        Ok(Arc::new(Self { node }))
    }

    /// This node's id (== the account's Kith id), as hex.
    pub fn node_id_hex(&self) -> String {
        self.node.node_id_hex()
    }

    /// A shareable ticket a peer dials to reach this node (full address form).
    pub async fn ticket(&self) -> Result<String, KithError> {
        self.node.ticket().await.map_err(|e| KithError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a contact by their hex node id (== their Kith id),
    /// resolving the live address via discovery.
    pub async fn send_to_node(&self, node_id_hex: String, payload: Vec<u8>) -> Result<(), KithError> {
        self.node
            .send_to_node(&node_id_hex, &payload)
            .await
            .map_err(|e| KithError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a peer identified by their full-address ticket.
    pub async fn send(&self, ticket: String, payload: Vec<u8>) -> Result<(), KithError> {
        self.node
            .send_ticket(&ticket, &payload)
            .await
            .map_err(|e| KithError::Invalid { msg: e.to_string() })
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
            comments: it
                .comments
                .into_iter()
                .map(|c| FeedCommentFfi {
                    id: c.id,
                    author_short: short(&c.author),
                    is_me: c.author == me,
                    body: c.body,
                    media: c.media,
                    edited: c.edited,
                    unsent: c.unsent,
                })
                .collect(),
            reactions: it
                .reactions
                .into_iter()
                .map(|r| ReactionFfi {
                    emoji: r.emoji,
                    count: r.count,
                    mine: r.authors.contains(&me.to_string()),
                })
                .collect(),
        })
        .collect()
}

struct NetState {
    me: Identity,
    contacts: Vec<KithId>,
    events: Vec<Event>,
    seen: HashSet<String>,
}

/// The real networked social store: your identity + your contacts' public bundles +
/// the event log. Unlike `SocialDemo` it seals to your actual circle and ingests posts
/// received from contacts over the network. Transport-agnostic: the same sealed
/// envelope bytes ride iroh (internet) or MultipeerConnectivity (nearby Bluetooth/Wi-Fi).
#[derive(uniffi::Object)]
pub struct KithSocial {
    state: Mutex<NetState>,
}

#[uniffi::export]
impl KithSocial {
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, KithError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| KithError::Invalid { msg: "seed must be 32 bytes".into() })?;
        Ok(Arc::new(Self {
            state: Mutex::new(NetState {
                me: Identity::from_seed(&seed),
                contacts: vec![],
                events: vec![],
                seen: HashSet::new(),
            }),
        }))
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
    pub fn bundle_verification_hex(&self, bundle: Vec<u8>) -> Result<String, KithError> {
        let id = KithId::from_bytes(&bundle)
            .map_err(|e| KithError::Invalid { msg: format!("bad bundle: {e}") })?;
        Ok(hex(&id.verification()))
    }

    /// Add a contact from their verified public bundle. Returns their node id hex.
    pub fn add_contact_bundle(&self, bundle: Vec<u8>) -> Result<String, KithError> {
        let id = KithId::from_bytes(&bundle)
            .map_err(|e| KithError::Invalid { msg: format!("bad bundle: {e}") })?;
        let node_hex = hex(&id.node_id_bytes());
        let mut st = self.state.lock().unwrap();
        if !st.contacts.iter().any(|c| c.node_id_bytes() == id.node_id_bytes()) {
            st.contacts.push(id);
        }
        Ok(node_hex)
    }

    /// The node ids of all known contacts (who to broadcast to).
    pub fn contact_node_ids(&self) -> Vec<String> {
        self.state
            .lock()
            .unwrap()
            .contacts
            .iter()
            .map(|c| hex(&c.node_id_bytes()))
            .collect()
    }

    pub fn post(
        &self,
        body: String,
        media: Vec<String>,
        music: Option<TrackRefFfi>,
        retention_secs: Option<u64>,
        created_at: u64,
    ) -> Result<Vec<u8>, KithError> {
        let music = music.map(|m| m.into_core());
        self.author(created_at, EventKind::Post { body, media, music, retention_secs })
    }
    pub fn comment(&self, target: String, body: String, media: Vec<String>, created_at: u64) -> Result<Vec<u8>, KithError> {
        self.author(created_at, EventKind::Comment { target, body, media })
    }
    pub fn react(&self, target: String, emoji: String, created_at: u64) -> Result<Vec<u8>, KithError> {
        self.author(created_at, EventKind::Reaction { target, emoji })
    }
    pub fn edit(&self, target: String, body: String, created_at: u64) -> Result<Vec<u8>, KithError> {
        self.author(created_at, EventKind::Edit { target, body })
    }
    pub fn unsend(&self, target: String, created_at: u64) -> Result<Vec<u8>, KithError> {
        self.author(created_at, EventKind::Unsend { target })
    }

    /// Ingest a sealed envelope received from the network. Opens it against the known
    /// sender contact, dedups by event id, records it. Returns true if it was new.
    pub fn receive(&self, envelope: Vec<u8>) -> Result<bool, KithError> {
        let env = SealedEnvelope::from_bytes(&envelope)
            .map_err(|e| KithError::Invalid { msg: format!("bad envelope: {e}") })?;
        let mut st = self.state.lock().unwrap();
        let sender_hex = env.sender_hex();
        let sender = st
            .contacts
            .iter()
            .find(|c| hex(&c.node_id_bytes()) == sender_hex)
            .cloned();
        let Some(sender) = sender else { return Ok(false) };
        let event = open_event(&st.me, &sender, &env)
            .map_err(|e| KithError::Invalid { msg: format!("open failed: {e}") })?;
        if st.seen.contains(&event.id) {
            return Ok(false);
        }
        st.seen.insert(event.id.clone());
        st.events.push(event);
        Ok(true)
    }

    /// Re-seal everything **I** authored to my current circle — to sync a peer that just
    /// connected. Only my own events (relaying others' would forge authorship).
    pub fn sync_envelopes(&self) -> Vec<Vec<u8>> {
        let st = self.state.lock().unwrap();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let mut members = vec![st.me.public()];
        members.extend(st.contacts.iter().cloned());
        let group = Group::new("circle", members);
        st.events
            .iter()
            .filter(|e| e.author == me_hex)
            .filter_map(|e| seal_event(&st.me, &group, e).ok().map(|env| env.to_bytes()))
            .collect()
    }

    pub fn feed(&self, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        map_feed(st.events.clone(), &me, now_ms, viewer_retention_secs)
    }
}

impl KithSocial {
    fn author(&self, created_at: u64, kind: EventKind) -> Result<Vec<u8>, KithError> {
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        let event = Event::new(&me_pub.node_id_bytes(), created_at, kind);
        let mut members = vec![me_pub];
        members.extend(st.contacts.iter().cloned());
        let group = Group::new("circle", members);
        let env = seal_event(&st.me, &group, &event)
            .map_err(|e| KithError::Invalid { msg: format!("seal failed: {e}") })?;
        st.seen.insert(event.id.clone());
        st.events.push(event);
        Ok(env.to_bytes())
    }
}

#[cfg(test)]
mod net_tests {
    use super::*;

    #[test]
    fn two_socials_exchange_a_post() {
        let alice = KithSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = KithSocial::new([2u8; 32].to_vec()).unwrap();

        // Handshake: each adds the other's verified bundle.
        let bob_id = alice.add_contact_bundle(bob.my_bundle()).unwrap();
        let alice_id = bob.add_contact_bundle(alice.my_bundle()).unwrap();
        assert_eq!(bob_id, bob.my_node_hex());
        assert_eq!(alice_id, alice.my_node_hex());

        // Alice posts → envelope → Bob receives and opens it.
        let env = alice.post("hi mom 💜".into(), vec![], None, None, 1_000).unwrap();
        assert!(bob.receive(env.clone()).unwrap(), "new on first receive");
        assert!(!bob.receive(env).unwrap(), "deduped on second receive");

        let feed = bob.feed(2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hi mom 💜");
        assert!(!feed[0].is_me, "the post is from Alice, not Bob");

        // A stranger Bob hasn't added cannot be opened (ignored, not an error).
        let eve = KithSocial::new([9u8; 32].to_vec()).unwrap();
        eve.add_contact_bundle(bob.my_bundle()).unwrap();
        let eve_env = eve.post("spam".into(), vec![], None, None, 1_500).unwrap();
        assert!(!bob.receive(eve_env).unwrap(), "unknown sender is ignored");
        assert_eq!(bob.feed(2_000, None).len(), 1, "stranger's post not in feed");
    }
}
