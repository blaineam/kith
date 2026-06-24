//! Multi-device **self-sync** for the desktop backend (roadmap D16, Phase 3 — client wiring).
//!
//! Direct port of the iOS `SelfSync.swift` coordinator. Makes a user's OWN devices converge:
//! each device writes a self-encrypted snapshot of its account state to a per-account mailbox
//! slot it owns, and merges its peers' slots. The CRDT itself lives in [`p2pcore::selfsync`]
//! (last-write-wins per key); the relay/S3 only ever holds ciphertext sealed with
//! [`p2pcore::identity::Identity::self_sync_key`] — a key only this account's devices can derive.
//!
//! Scope (must match iOS byte-for-byte cross-platform): PROFILE (name/emoji/bio/link), GLOBAL
//! SETTINGS (retention, host-on-launch), CONTACTS, the BLOCKED list, and CIRCLES (name + member
//! bundles + relay nodes). Profile/setting/blocked/circle values are byte-identical to iOS; the
//! `contact:` value is each platform's own (the Contact structs differ) but stable per-platform.
//!
//! This module holds the **pure** pieces — the device-id, the CRDT key/value mapping, and the
//! deterministic circle encoding. The networked coordinator (`Engine::poll_self_sync`) lives in
//! `engine.rs` because it needs the engine's private transport internals.

use std::collections::BTreeMap;

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use crate::store::{Contact, Paths, Prefs};
use haven_ffi::HavenSocial;

/// Load (or first-time generate) this device's stable 32-byte self-sync id. All of a user's
/// devices share the account seed (same node id), so each physical device needs its own id to
/// own a sync slot and to break LWW ties. Random, generated once, stored device-local in the
/// Paths dir (`selfsync-device.bin`), and NEVER synced.
pub fn device_id(paths: &Paths) -> [u8; 32] {
    let path = paths.selfsync_device_file();
    if let Ok(bytes) = std::fs::read(&path) {
        if bytes.len() == 32 {
            let mut id = [0u8; 32];
            id.copy_from_slice(&bytes);
            return id;
        }
    }
    let mut id = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut id);
    let _ = std::fs::write(&path, id);
    id
}

/// A circle's portable structure: its name, every member's public bundle (base64), and the relay
/// nodes that hold its mailbox — enough for another device to reconstruct it and seal to all
/// members. The field names (`members`/`name`/`relays`), base64 member encoding, and sorted vecs
/// MUST match iOS so the encoded bytes are byte-identical cross-platform.
///
/// CRITICAL: iOS encodes this with `JSONEncoder.outputFormatting = [.sortedKeys]`, which emits
/// the keys in ALPHABETICAL order: `members`, `name`, `relays`. serde_json emits struct fields in
/// DECLARATION order, so the fields here are declared alphabetically to reproduce iOS's bytes
/// exactly. Do NOT reorder. The vecs are pre-sorted so equal state encodes identically (otherwise
/// the fold's encoded-bytes diff would re-stamp every sync and the devices would ping-pong).
#[derive(Serialize, Deserialize, PartialEq, Eq)]
struct CircleSync {
    members: Vec<String>,
    name: String,
    relays: Vec<String>,
}

/// Namespaces whose keys are dynamic (set-like) — used to detect LOCAL removals so they
/// propagate as tombstones (unblock, delete contact). Scalar namespaces (`profile:`/`setting:`)
/// are always present, so they're never spuriously removed.
pub const DYNAMIC_PREFIXES: [&str; 2] = ["contact:", "blocked:"];

/// The current local state as namespaced key → value bytes (no stamps). `prefs` contributes
/// profile/settings/contacts/blocked; `social` contributes the circle structure (name + member
/// bundles + relay nodes pulled from `prefs.relays`).
pub fn current_local(prefs: &Prefs, social: &HavenSocial) -> BTreeMap<String, Vec<u8>> {
    let mut m: BTreeMap<String, Vec<u8>> = BTreeMap::new();

    // Profile (UTF-8 bytes).
    m.insert("profile:name".into(), prefs.profile.name.clone().into_bytes());
    m.insert("profile:emoji".into(), prefs.profile.emoji.clone().into_bytes());
    m.insert("profile:bio".into(), prefs.profile.bio.clone().into_bytes());
    m.insert("profile:link".into(), prefs.profile.link.clone().into_bytes());

    // Global settings. retention as u64 LE (None = 0 = keep all); host-on-launch as a 1-byte flag.
    let retention = prefs.retention_secs.unwrap_or(0);
    m.insert("setting:retention".into(), retention.to_le_bytes().to_vec());
    m.insert("setting:host_on_launch".into(), vec![if prefs.host_on_launch { 1 } else { 0 }]);

    // Roster: contacts (full card, deterministic serde) + blocked list (marker).
    for c in &prefs.contacts {
        if let Ok(data) = serde_json::to_vec(c) {
            m.insert(format!("contact:{}", c.id_hex), data);
        }
    }
    for hex in &prefs.blocked {
        m.insert(format!("blocked:{hex}"), vec![1]);
    }

    // Circles: name + member bundles + relay nodes, so another device can reconstruct each circle
    // and seal to every member. (Additive — member/circle removal is a follow-up, matching iOS.)
    for ci in social.circles() {
        // Skip DM pseudo-circles — they reconstruct from the contact pair, not from sync.
        if ci.id.starts_with("dm:") {
            continue;
        }
        let mut members: Vec<String> = social
            .circle_member_bundles(ci.id.clone())
            .iter()
            .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
            .collect();
        members.sort();
        let mut relays: Vec<String> = prefs.relays.get(&ci.id).cloned().unwrap_or_default();
        relays.sort();
        relays.dedup();
        let cs = CircleSync { members, name: ci.name.clone(), relays };
        if let Ok(data) = serde_json::to_vec(&cs) {
            m.insert(format!("circle:{}", ci.id), data);
        }
    }

    m
}

/// Decode a stored `setting:host_on_launch` (or any 1-byte bool marker) value.
fn bool_value(v: &[u8]) -> Option<bool> {
    v.first().map(|b| *b == 1)
}

/// Apply a converged `AccountState` back into the local stores. Mutates `prefs` + `social`
/// in place, and ONLY where a value actually differs (avoid churn / feedback loops). Returns
/// `true` if anything local changed (so the caller persists + emits `haven:changed`).
///
/// `entries` is the converged state's live `(key, value)` pairs (already collected so the caller
/// can drop the borrow on the CRDT before locking the prefs/social mutexes).
pub fn apply_local(
    entries: &[(String, Vec<u8>)],
    prefs: &mut Prefs,
    social: &HavenSocial,
) -> bool {
    let mut changed = false;

    // Helper closures over `entries`.
    let get = |key: &str| -> Option<&[u8]> {
        entries.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_slice())
    };

    // Profile (UTF-8).
    macro_rules! apply_str {
        ($key:expr, $field:expr) => {
            if let Some(v) = get($key) {
                if let Ok(s) = std::str::from_utf8(v) {
                    if s != $field {
                        $field = s.to_string();
                        changed = true;
                    }
                }
            }
        };
    }
    apply_str!("profile:name", prefs.profile.name);
    apply_str!("profile:emoji", prefs.profile.emoji);
    apply_str!("profile:bio", prefs.profile.bio);
    apply_str!("profile:link", prefs.profile.link);

    // Settings.
    if let Some(v) = get("setting:retention") {
        if v.len() == 8 {
            let mut a = [0u8; 8];
            a.copy_from_slice(v);
            let n = u64::from_le_bytes(a);
            let want = if n == 0 { None } else { Some(n) };
            if want != prefs.retention_secs {
                prefs.retention_secs = want;
                changed = true;
            }
        }
    }
    if let Some(v) = get("setting:host_on_launch") {
        if let Some(b) = bool_value(v) {
            if b != prefs.host_on_launch {
                prefs.host_on_launch = b;
                changed = true;
            }
        }
    }

    // Contacts: upsert everything present; drop locals the converged state no longer has
    // (a contact deleted on another device propagated as a tombstone).
    let mut want_contacts: BTreeMap<String, Contact> = BTreeMap::new();
    for (k, v) in entries {
        if let Some(_id) = k.strip_prefix("contact:") {
            if let Ok(c) = serde_json::from_slice::<Contact>(v) {
                want_contacts.insert(c.id_hex.clone(), c);
            }
        }
    }
    // Upsert.
    for c in want_contacts.values() {
        match prefs.contacts.iter_mut().find(|x| x.id_hex == c.id_hex) {
            Some(existing) => {
                if existing.name != c.name || existing.verify_hex != c.verify_hex {
                    existing.name = c.name.clone();
                    existing.verify_hex = c.verify_hex.clone();
                    changed = true;
                }
            }
            None => {
                prefs.contacts.push(c.clone());
                changed = true;
            }
        }
    }
    // Drop locals no longer wanted.
    let before = prefs.contacts.len();
    prefs.contacts.retain(|c| want_contacts.contains_key(&c.id_hex));
    if prefs.contacts.len() != before {
        changed = true;
    }

    // Blocked list: reconcile both directions.
    let mut want_blocked: Vec<String> = entries
        .iter()
        .filter_map(|(k, _)| k.strip_prefix("blocked:").map(|h| h.to_string()))
        .collect();
    want_blocked.sort();
    want_blocked.dedup();
    // Add the missing.
    for hex in &want_blocked {
        if !prefs.blocked.contains(hex) {
            prefs.blocked.push(hex.clone());
            changed = true;
        }
    }
    // Remove the extra.
    let before = prefs.blocked.len();
    prefs.blocked.retain(|h| want_blocked.contains(h));
    if prefs.blocked.len() != before {
        changed = true;
    }

    // Circles: reconstruct each synced circle — create it, register every member's bundle (so
    // this device can seal to them), and record its relay mailbox(es). Additive (no removal).
    let existing: Vec<(String, String)> =
        social.circles().into_iter().map(|c| (c.id, c.name)).collect();
    for (k, v) in entries {
        let Some(id) = k.strip_prefix("circle:") else { continue };
        let Ok(cs) = serde_json::from_slice::<CircleSync>(v) else { continue };
        match existing.iter().find(|(cid, _)| cid == id) {
            None => {
                social.create_circle(id.to_string(), cs.name.clone());
                changed = true;
            }
            Some((_, cur_name)) => {
                if *cur_name != cs.name {
                    social.rename_circle(id.to_string(), cs.name.clone());
                    changed = true;
                }
            }
        }
        for b64 in &cs.members {
            if let Ok(bundle) = base64::engine::general_purpose::STANDARD.decode(b64) {
                let _ = social.add_contact_bundle(id.to_string(), bundle);
            }
        }
        if !cs.relays.is_empty() {
            let list = prefs.relays.entry(id.to_string()).or_default();
            for node in &cs.relays {
                if !list.contains(node) {
                    list.push(node.clone());
                    changed = true;
                }
            }
        }
    }

    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circle_sync_encodes_deterministically_and_matches_field_order() {
        // Field order name/members/relays, members & relays sorted ⇒ byte-stable, iOS-compatible.
        let cs = CircleSync {
            members: vec!["AAA".into(), "BBB".into()],
            name: "Home".into(),
            relays: vec!["node1".into()],
        };
        let json = serde_json::to_string(&cs).unwrap();
        // Alphabetical key order, matching iOS `JSONEncoder.outputFormatting = [.sortedKeys]`.
        assert_eq!(json, r#"{"members":["AAA","BBB"],"name":"Home","relays":["node1"]}"#);
    }

    #[test]
    fn dynamic_prefixes_cover_contact_and_blocked() {
        assert!(DYNAMIC_PREFIXES.contains(&"contact:"));
        assert!(DYNAMIC_PREFIXES.contains(&"blocked:"));
    }
}
