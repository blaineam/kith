//! Kith engine for the browser. This is the SAME hybrid post-quantum engine the phone
//! runs (`p2pcore`) — identity, sealing, and feed reduction — exposed to JavaScript via
//! wasm-bindgen. No mock data, no separate crypto: a real Kith identity in the browser.
//!
//! Transport (iroh-in-browser) is layered on top in JS; this crate owns the engine:
//! create/restore identity, add contacts, seal posts to the circle, open received
//! envelopes, and reduce everything into a feed.

use std::collections::HashSet;

use wasm_bindgen::prelude::*;

use p2pcore::identity::{Identity, HavenId};
use p2pcore::link::HavenLink;
use p2pcore::social::{
    build_feed, open_event, seal_event, Event, EventKind, Group, SealedEnvelope,
};

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

/// A real Kith engine instance for one identity (default circle = your contacts).
#[wasm_bindgen]
pub struct HavenEngine {
    me: Identity,
    members: Vec<HavenId>,
    events: Vec<Event>,
    seen: HashSet<String>,
}

#[wasm_bindgen]
impl HavenEngine {
    /// Create a fresh identity, or restore one from a 64-char hex seed (e.g. decoded
    /// from a phone's transfer code — same identity across devices).
    #[wasm_bindgen(constructor)]
    pub fn new(seed_hex: Option<String>) -> Result<HavenEngine, JsValue> {
        console_error_panic_hook::set_once();
        let me = match seed_hex.filter(|s| !s.is_empty()) {
            Some(h) => {
                let v = unhex(&h).ok_or_else(|| JsValue::from_str("bad seed hex"))?;
                let seed: [u8; 32] = v
                    .try_into()
                    .map_err(|_| JsValue::from_str("seed must be 32 bytes"))?;
                Identity::from_seed(&seed)
            }
            None => Identity::generate(),
        };
        Ok(HavenEngine { me, members: vec![], events: vec![], seen: HashSet::new() })
    }

    /// The 32-byte master seed as hex — persist this (IndexedDB/localStorage) to stay
    /// the same identity across reloads.
    pub fn seed_hex(&self) -> String {
        hexs(&self.me.secret_seed())
    }
    pub fn node_id_hex(&self) -> String {
        hexs(&self.me.public().node_id_bytes())
    }
    /// The full public bundle (hex) to hand a contact so they can seal to us.
    pub fn bundle_hex(&self) -> String {
        hexs(&self.me.public().to_bytes())
    }
    pub fn invite_link(&self, domain: String) -> String {
        HavenLink::from_identity(&self.me.public()).to_web(&domain)
    }
    pub fn verification_hex(&self) -> String {
        hexs(&self.me.public().verification())
    }

    /// Add a contact from their public bundle (hex); returns their node id (hex).
    pub fn add_contact(&mut self, bundle_hex: String) -> Result<String, JsValue> {
        let bytes = unhex(&bundle_hex).ok_or_else(|| JsValue::from_str("bad bundle hex"))?;
        let kid = HavenId::from_bytes(&bytes).map_err(|_| JsValue::from_str("bad bundle"))?;
        let nh = hexs(&kid.node_id_bytes());
        if !self.members.iter().any(|m| m.node_id_bytes() == kid.node_id_bytes()) {
            self.members.push(kid);
        }
        Ok(nh)
    }

    pub fn contact_count(&self) -> usize {
        self.members.len()
    }

    fn group(&self) -> Group {
        let mut m = vec![self.me.public()];
        m.extend(self.members.iter().cloned());
        Group::new("default", m)
    }

    /// Author a post; returns the sealed envelope bytes to broadcast to the circle.
    pub fn post(&mut self, body: String, created_at: u64) -> Vec<u8> {
        let ev = Event::new(
            &self.me.public().node_id_bytes(),
            created_at,
            EventKind::Post { body, media: vec![], music: None, retention_secs: None, story: false, mute_video: false },
        );
        self.seen.insert(ev.id.clone());
        let bytes = seal_event(&self.me, &self.group(), &ev)
            .map(|env| env.to_bytes())
            .unwrap_or_default();
        self.events.push(ev);
        bytes
    }

    /// Ingest a sealed envelope received from a peer. Returns true if it was new.
    pub fn receive(&mut self, envelope: Vec<u8>) -> bool {
        let Ok(env) = SealedEnvelope::from_bytes(&envelope) else { return false };
        let sender_hex = env.sender_hex();
        let sender = if sender_hex == self.node_id_hex() {
            self.me.public()
        } else {
            match self.members.iter().find(|m| hexs(&m.node_id_bytes()) == sender_hex) {
                Some(s) => s.clone(),
                None => return false,
            }
        };
        let Ok(ev) = open_event(&self.me, &sender, &env) else { return false };
        if self.seen.contains(&ev.id) {
            return false;
        }
        self.seen.insert(ev.id.clone());
        self.events.push(ev);
        true
    }

    /// Our own events, each sealed to the circle, as a JSON array of hex strings — to
    /// back-fill a peer that just connected.
    pub fn sync_envelopes_json(&self) -> String {
        let me = self.node_id_hex();
        let g = self.group();
        let v: Vec<String> = self
            .events
            .iter()
            .filter(|e| e.author == me)
            .filter_map(|e| seal_event(&self.me, &g, e).ok().map(|env| hexs(&env.to_bytes())))
            .collect();
        serde_json::to_string(&v).unwrap_or_else(|_| "[]".into())
    }

    /// The reduced feed as JSON (posts + comments + reactions), newest-first per the engine.
    pub fn feed_json(&self, now_ms: u64) -> String {
        let items = build_feed(self.events.clone(), now_ms, None);
        serde_json::to_string(&items).unwrap_or_else(|_| "[]".into())
    }

    /// A real seal→open round trip with this identity — the browser-side privacy check.
    pub fn self_test(&self) -> bool {
        let ev = Event::new(
            &self.me.public().node_id_bytes(),
            0,
            EventKind::Post { body: "self-test".into(), media: vec![], music: None, retention_secs: None, story: false, mute_video: false },
        );
        let g = Group::new("t", vec![self.me.public()]);
        seal_event(&self.me, &g, &ev)
            .ok()
            .and_then(|env| open_event(&self.me, &self.me.public(), &env).ok())
            .map(|o| o == ev)
            .unwrap_or(false)
    }
}
