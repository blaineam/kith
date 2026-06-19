//! `kith_ffi` — the UniFFI surface that bridges `p2pcore` to Swift (and Kotlin).
//!
//! Keeps the exposed API tiny and Swift-friendly: an [`Account`] object, a couple of
//! free functions, and plain records. All the security-critical logic stays in
//! `p2pcore`; this is only the boundary.

use std::sync::{Arc, Mutex};

use p2pcore::crypto::{decapsulate, encapsulate_to, open, seal};
use p2pcore::identity::Identity;
use p2pcore::link::KithLink;
use p2pcore::social::{build_feed, open_event, seal_event, Event, EventKind, Group, TrackRef};

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
        created_at: u64,
    ) -> String {
        let music = music.map(|m| m.into_core());
        self.author_event(true, created_at, EventKind::Post { body, media, music })
    }
    pub fn friend_post(&self, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Post { body, media: vec![], music: None })
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
    pub fn feed(&self) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        build_feed(st.events.clone())
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

