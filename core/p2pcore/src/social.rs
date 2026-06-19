//! The social layer: groups, posts, comments, reactions, messages — and edit /
//! unsend — all end-to-end encrypted with the hybrid post-quantum primitives.
//!
//! ## Model
//! A [`Group`] is a set of member public identities. Every social action is an
//! [`Event`] authored and **hybrid-signed** by its sender, then **sealed to the
//! group**: a fresh content key encrypts the event (AES-256-GCM), and that key is
//! wrapped to each member via the hybrid KEM (X25519 + ML-KEM-768). Any member
//! decrypts; nobody else can. The resulting [`SealedEnvelope`] is what travels over
//! the wire or parks in storage — opaque to relays.
//!
//! [`build_feed`] reduces a stream of decrypted events into a timeline: posts with
//! their comments and reactions, edits applied (with an "edited" flag), and unsends
//! marked. This is multi-recipient public-key encryption, not yet MLS — it works and
//! is fully tested; forward-secrecy via MLS (`mls-rs`) is a later hardening (see
//! `docs/DECISIONS.md` D3).

use std::collections::BTreeMap;

use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use crate::identity::{Identity, KithId};
use crate::{CoreError, Result};

/// What a social event *is*. Targets reference another event's id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventKind {
    /// A feed post (optionally with media content-refs).
    Post { body: String, media: Vec<String> },
    /// A direct/group message (rendered as a post in a 1:1 or chat group).
    Message { body: String },
    /// A comment on a post/message.
    Comment { target: String, body: String },
    /// A reaction (emoji) to a post/message.
    Reaction { target: String, emoji: String },
    /// Edit the body of one of *your own* prior events.
    Edit { target: String, body: String },
    /// Retract ("unsend") one of *your own* prior events.
    Unsend { target: String },
}

/// A signed, addressable social action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    /// Stable id = BLAKE3(author ‖ created_at ‖ kind). Used for dedup and as a target.
    pub id: String,
    /// Author's node id (hex).
    pub author: String,
    /// Caller-supplied timestamp (unix millis); the core has no clock.
    pub created_at: u64,
    pub kind: EventKind,
}

impl Event {
    /// Construct an event and compute its content-addressed id.
    pub fn new(author_node_id: &[u8; 32], created_at: u64, kind: EventKind) -> Self {
        let author = hex(author_node_id);
        let kind_bytes = serde_json::to_vec(&kind).expect("event kind serializes");
        let mut h = blake3::Hasher::new();
        h.update(b"kith-event-v1");
        h.update(author.as_bytes());
        h.update(&created_at.to_le_bytes());
        h.update(&kind_bytes);
        let id = hex(&h.finalize().as_bytes()[..16]);
        Self { id, author, created_at, kind }
    }
}

/// A group of members (their public identities). 1:1 is just two members.
#[derive(Clone)]
pub struct Group {
    pub id: String,
    pub members: Vec<KithId>,
}

impl Group {
    pub fn new(id: impl Into<String>, members: Vec<KithId>) -> Self {
        Self { id: id.into(), members }
    }
}

/// The KEM encapsulation, in a serializable wire form.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct EncWire {
    eph_x_pub: Vec<u8>,
    pq_ct: Vec<u8>,
}

/// A content key wrapped to a single recipient.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct RecipientKey {
    member: Vec<u8>, // node id
    enc: EncWire,
    wrapped: Vec<u8>, // AEAD(kek, content_key)
}

/// The opaque, on-wire form of a sealed event. Reveals nothing to a relay.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SealedEnvelope {
    sender: Vec<u8>, // sender node id
    ciphertext: Vec<u8>,
    recipients: Vec<RecipientKey>,
    signature: Vec<u8>, // hybrid signature over the transcript
}

impl SealedEnvelope {
    /// Sender node id (hex) — lets the recipient pick the right verifying key.
    pub fn sender_hex(&self) -> String {
        hex(&self.sender)
    }

    /// Serialize for transport / storage.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("envelope serializes")
    }

    /// Parse from transport / storage.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        serde_json::from_slice(b).map_err(|_| CoreError::Encoding("malformed envelope"))
    }

    /// Transcript that the signature covers (binds ciphertext + all recipient entries).
    fn transcript(&self) -> [u8; 32] {
        let mut h = blake3::Hasher::new();
        h.update(b"kith-envelope-v1");
        h.update(&self.sender);
        h.update(&self.ciphertext);
        for r in &self.recipients {
            h.update(&r.member);
            h.update(&r.enc.eph_x_pub);
            h.update(&r.enc.pq_ct);
            h.update(&r.wrapped);
        }
        *h.finalize().as_bytes()
    }
}

/// Seal an event to every member of a group. Sender side.
pub fn seal_event(sender: &Identity, group: &Group, event: &Event) -> Result<SealedEnvelope> {
    let plaintext = serde_json::to_vec(event).map_err(|_| CoreError::Encoding("event"))?;

    // Fresh symmetric content key; encrypt the event once.
    let mut content_key = [0u8; 32];
    OsRng.fill_bytes(&mut content_key);
    let ciphertext = seal(&content_key, &plaintext);

    // Wrap the content key to each member via the hybrid KEM.
    let mut recipients = Vec::with_capacity(group.members.len());
    for member in &group.members {
        let (enc, kek) = encapsulate_to(member)?;
        recipients.push(RecipientKey {
            member: member.node_id_bytes().to_vec(),
            enc: EncWire { eph_x_pub: enc.eph_x_pub.to_vec(), pq_ct: enc.pq_ct },
            wrapped: seal(&kek, &content_key),
        });
    }

    let mut env = SealedEnvelope {
        sender: sender.public().node_id_bytes().to_vec(),
        ciphertext,
        recipients,
        signature: Vec::new(),
    };
    env.signature = sender.sign(&env.transcript());
    Ok(env)
}

/// Open a sealed envelope addressed to me, verifying the sender's signature. Recipient side.
pub fn open_event(me: &Identity, sender_pub: &KithId, env: &SealedEnvelope) -> Result<Event> {
    // 1. Authenticate the sender over the whole transcript before decrypting.
    sender_pub.verify(&env.transcript(), &env.signature)?;

    // 2. Find my wrapped key.
    let my_id = me.public().node_id_bytes().to_vec();
    let mine = env
        .recipients
        .iter()
        .find(|r| r.member == my_id)
        .ok_or(CoreError::Crypto("not a recipient of this envelope"))?;

    // 3. Unwrap the content key, then decrypt the event.
    let eph: [u8; 32] = mine
        .enc
        .eph_x_pub
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad ephemeral key"))?;
    let enc = Encapsulation { eph_x_pub: eph, pq_ct: mine.enc.pq_ct.clone() };
    let kek = decapsulate(me, &enc)?;
    let content_key_vec = open(&kek, &mine.wrapped)?;
    let content_key: [u8; 32] = content_key_vec
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad content key"))?;
    let plaintext = open(&content_key, &env.ciphertext)?;

    let event: Event =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::Encoding("event decode"))?;

    // 4. The signed sender must match the event's claimed author.
    if event.author != hex(&env.sender) {
        return Err(CoreError::Crypto("author/sender mismatch"));
    }
    Ok(event)
}

// ----- Feed reduction -----

/// A reaction aggregate on a feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactionGroup {
    pub emoji: String,
    pub count: u32,
    pub authors: Vec<String>,
}

/// A comment on a feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedComment {
    pub id: String,
    pub author: String,
    pub created_at: u64,
    pub body: String,
    pub edited: bool,
    pub unsent: bool,
}

/// A post/message with its comments and reactions resolved.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedItem {
    pub id: String,
    pub author: String,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
    pub comments: Vec<FeedComment>,
    pub reactions: Vec<ReactionGroup>,
}

/// Reduce a set of decrypted events into a timeline. Newest posts first; comments
/// oldest-first. Edits/unsends apply only to the original author's own events.
pub fn build_feed(mut events: Vec<Event>) -> Vec<FeedItem> {
    // Deterministic order: by time, then id (dedup identical ids).
    events.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    events.dedup_by(|a, b| a.id == b.id);

    let mut items: BTreeMap<String, FeedItem> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut comments: BTreeMap<String, FeedComment> = BTreeMap::new();
    let mut comment_order: Vec<String> = Vec::new();

    // Pass 1: create posts/messages and comments.
    for e in &events {
        match &e.kind {
            EventKind::Post { body, media } => {
                order.push(e.id.clone());
                items.insert(
                    e.id.clone(),
                    FeedItem {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        media: media.clone(),
                        edited: false,
                        unsent: false,
                        comments: Vec::new(),
                        reactions: Vec::new(),
                    },
                );
            }
            EventKind::Message { body } => {
                order.push(e.id.clone());
                items.insert(
                    e.id.clone(),
                    FeedItem {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        media: Vec::new(),
                        edited: false,
                        unsent: false,
                        comments: Vec::new(),
                        reactions: Vec::new(),
                    },
                );
            }
            EventKind::Comment { target: _, body } => {
                comment_order.push(e.id.clone());
                comments.insert(
                    e.id.clone(),
                    FeedComment {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        edited: false,
                        unsent: false,
                    },
                );
            }
            _ => {}
        }
    }

    // Pass 2: apply edits/unsends (author must match), then reactions.
    for e in &events {
        match &e.kind {
            EventKind::Edit { target, body } => {
                if let Some(it) = items.get_mut(target) {
                    if it.author == e.author && !it.unsent {
                        it.body = body.clone();
                        it.edited = true;
                    }
                } else if let Some(c) = comments.get_mut(target) {
                    if c.author == e.author && !c.unsent {
                        c.body = body.clone();
                        c.edited = true;
                    }
                }
            }
            EventKind::Unsend { target } => {
                if let Some(it) = items.get_mut(target) {
                    if it.author == e.author {
                        it.unsent = true;
                        it.body.clear();
                        it.media.clear();
                    }
                } else if let Some(c) = comments.get_mut(target) {
                    if c.author == e.author {
                        c.unsent = true;
                        c.body.clear();
                    }
                }
            }
            _ => {}
        }
    }

    // Attach comments to their targets (skip unsent comments).
    for cid in &comment_order {
        if let (Some(comment), Some(target)) =
            (comments.get(cid).cloned(), comment_target(&events, cid))
        {
            if let Some(it) = items.get_mut(&target) {
                if !comment.unsent {
                    it.comments.push(comment);
                }
            }
        }
    }

    // Aggregate reactions onto their targets.
    for e in &events {
        if let EventKind::Reaction { target, emoji } = &e.kind {
            if let Some(it) = items.get_mut(target) {
                match it.reactions.iter_mut().find(|r| &r.emoji == emoji) {
                    Some(rg) => {
                        if !rg.authors.contains(&e.author) {
                            rg.authors.push(e.author.clone());
                            rg.count += 1;
                        }
                    }
                    None => it.reactions.push(ReactionGroup {
                        emoji: emoji.clone(),
                        count: 1,
                        authors: vec![e.author.clone()],
                    }),
                }
            }
        }
    }

    // Newest first.
    order
        .iter()
        .rev()
        .filter_map(|id| items.get(id).cloned())
        .collect()
}

/// Find the target post id for a comment event id.
fn comment_target(events: &[Event], comment_id: &str) -> Option<String> {
    events.iter().find_map(|e| match &e.kind {
        EventKind::Comment { target, .. } if e.id == comment_id => Some(target.clone()),
        _ => None,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
