//! The desktop counterpart of the iOS `FeedStore` / Android `HavenNet` networking core:
//! owns the [`HavenSocial`] engine and the [`HavenNode`] iroh transport, speaks the
//! byte-exact [`crate::wire`] protocol, drives the Hello/Event handshake, persists state,
//! and runs the circle relay/mailbox so a Windows PC forms circles and exchanges posts
//! with an iPhone or Android phone.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use haven_ffi::{
    parse_link, Account, FeedItemFfi, HavenNode, HavenSocial, InboundListener, RelayClient,
    RelayServerHandle, TrackRefFfi,
};
use haven_s3::{S3Config, S3Mailbox};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex as TokioMutex;

use crate::callwire;
use crate::localmedia::LocalMedia;
use crate::store::{self, Contact, Paths, Prefs, Profile};
use crate::wire;

pub const DEFAULT_CIRCLE: &str = "default";

/// Someone who said hello but we haven't approved yet.
#[derive(Clone)]
pub struct PendingRequest {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
    pub bundle: Vec<u8>,
}

#[derive(Default)]
struct DynState {
    pending: Vec<PendingRequest>,
    /// node ids we initiated a connect to (scanned their QR) → expected verify hash.
    initiated: HashMap<String, String>,
    seen_mailbox: HashSet<String>,
    /// ref -> partial chunks while a media transfer is in flight.
    incoming_media: HashMap<String, IncomingMedia>,
    requested_refs: HashSet<String>,
    internet_active: bool,
    relay_active: bool,
    started: bool,
    hosting: bool,
    foreground: bool,
}

struct IncomingMedia {
    total: u32,
    chunks: HashMap<u32, Vec<u8>>,
}

pub struct Engine {
    seed: [u8; 32],
    social: Arc<HavenSocial>,
    paths: Paths,
    media: LocalMedia,
    app: StdMutex<Option<AppHandle>>,
    node: StdMutex<Option<Arc<HavenNode>>>,
    relay_host: StdMutex<Option<Arc<RelayServerHandle>>>,
    prefs: StdMutex<Prefs>,
    dyn_state: StdMutex<DynState>,
    scheduled: StdMutex<crate::scheduled::ScheduledStore>,
    sched_counter: std::sync::atomic::AtomicU64,
    relay_clients: TokioMutex<HashMap<String, Arc<RelayClient>>>,
    /// Per-relay backoff health, keyed by node hex — drives graceful fallback.
    relay_health: StdMutex<HashMap<String, crate::relayhealth::RelayHealth>>,
    s3: TokioMutex<Option<Arc<S3Mailbox>>>,
}

const MEDIA_CHUNK_SIZE: usize = 512 * 1024;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Engine {
    /// Build the engine for an existing or freshly-created seed. Loads prefs + restores state.
    pub fn new(paths: Paths, seed: [u8; 32]) -> Result<Arc<Self>> {
        let social = HavenSocial::new(seed.to_vec())
            .map_err(|e| anyhow::anyhow!("HavenSocial::new: {e}"))?;
        if let Some(state) = store::read_state(&paths) {
            social.import_state(state);
        }
        let prefs = Prefs::load(&paths);
        let media = LocalMedia::new(paths.media_dir());
        let scheduled = crate::scheduled::ScheduledStore::load(&paths.scheduled_file());
        Ok(Arc::new(Self {
            seed,
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            relay_host: StdMutex::new(None),
            prefs: StdMutex::new(prefs),
            dyn_state: StdMutex::new(DynState::default()),
            scheduled: StdMutex::new(scheduled),
            sched_counter: std::sync::atomic::AtomicU64::new(0),
            relay_clients: TokioMutex::new(HashMap::new()),
            relay_health: StdMutex::new(HashMap::new()),
            s3: TokioMutex::new(None),
        }))
    }

    pub fn set_app(&self, app: AppHandle) {
        *self.app.lock().unwrap() = Some(app);
    }

    pub fn set_foreground(&self, fg: bool) {
        self.dyn_state.lock().unwrap().foreground = fg;
    }

    fn emit_changed(&self) {
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("haven:changed", ());
        }
    }

    fn notify(&self, title: &str, body: &str) {
        if self.dyn_state.lock().unwrap().foreground {
            return;
        }
        if let Some(app) = self.app.lock().unwrap().clone() {
            // Native OS notification (Action Center / toast)…
            use tauri_plugin_notification::NotificationExt;
            let _ = app.notification().builder().title(title).body(body).show();
            // …and an in-app event for a toast if a window is open.
            let _ = app.emit("haven:notify", serde_json::json!({ "title": title, "body": body }));
        }
    }

    // ---- identity / profile -----------------------------------------------------------

    pub fn node_id_hex(&self) -> String {
        self.social.my_node_hex()
    }

    pub fn invite_uri(&self) -> String {
        Account::from_seed(self.seed.to_vec())
            .map(|a| a.haven_uri())
            .unwrap_or_default()
    }

    pub fn invite_link(&self, domain: &str) -> String {
        Account::from_seed(self.seed.to_vec())
            .map(|a| a.haven_link(domain.to_string()))
            .unwrap_or_default()
    }

    pub fn get_profile(&self) -> Profile {
        self.prefs.lock().unwrap().profile.clone()
    }

    pub fn set_profile(self: &Arc<Self>, profile: Profile) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.profile = profile;
            let _ = p.save(&self.paths);
        }
        // Re-greet contacts so the new name/card propagates.
        self.sync_with_contacts();
        self.emit_changed();
    }

    // ---- multi-identity -----------------------------------------------------------------

    /// (node_hex, label, is_active) for every identity on this device.
    pub fn identities(&self) -> Vec<(String, String, bool)> {
        let ids = store::Identities::load(&self.paths);
        ids.items
            .iter()
            .map(|e| (e.node_hex.clone(), e.label.clone(), e.node_hex == ids.active))
            .collect()
    }

    /// Mint a brand-new identity (its seed goes to the secure store). Does not switch to it.
    pub fn add_identity(&self, label: &str) -> Result<String> {
        let acct = Account::generate();
        let seed: [u8; 32] = acct
            .secret_seed()
            .try_into()
            .map_err(|_| anyhow::anyhow!("generated seed not 32 bytes"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    /// Adopt an existing identity from a 32-byte seed (e.g. a transfer from another device).
    pub fn import_identity(&self, label: &str, seed: [u8; 32]) -> Result<String> {
        let acct = Account::from_seed(seed.to_vec()).map_err(|e| anyhow::anyhow!("bad seed: {e}"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    pub fn rename_identity(&self, node_hex: &str, label: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.rename(node_hex, label) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(())
    }

    /// Make `node_hex` the active identity. Mirrors its seed to the legacy `master-seed` so the
    /// headless relay follows it too. The caller must relaunch the app to rebuild the engine.
    pub fn set_active_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.set_active(node_hex) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        if let Some(seed) = store::load_identity_seed(node_hex)? {
            store::save_seed(&seed)?;
        }
        ids.save(&self.paths)?;
        Ok(())
    }

    pub fn remove_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        match ids.remove(node_hex) {
            Some(dir) => {
                ids.save(&self.paths)?;
                store::delete_identity_seed(node_hex);
                if !dir.is_empty() {
                    let _ = std::fs::remove_dir_all(self.paths.base.join(dir));
                }
                self.emit_changed();
                Ok(())
            }
            None => Err(anyhow::anyhow!("cannot remove the active or an unknown identity")),
        }
    }

    // ---- start --------------------------------------------------------------------------

    /// Start the iroh node and begin syncing. Safe to call repeatedly.
    pub async fn start(self: &Arc<Self>) {
        {
            if self.node.lock().unwrap().is_some() {
                return;
            }
        }
        let listener: Arc<dyn InboundListener> = Arc::new(NodeListener {
            engine: Arc::downgrade(self),
        });
        match HavenNode::start(self.seed.to_vec(), listener).await {
            Ok(node) => {
                *self.node.lock().unwrap() = Some(node);
                self.dyn_state.lock().unwrap().started = true;
                self.emit_changed();
                self.sync_with_contacts();
                self.poll_mailbox().await;
                self.request_missing_media();
            }
            Err(e) => {
                log::error!("node start failed: {e}");
            }
        }
        self.fire_due_scheduled(); // flush anything overdue from while the app was closed
        self.start_mailbox_loop();
    }

    fn start_mailbox_loop(self: &Arc<Self>) {
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(15)).await;
                me.poll_mailbox().await;
                me.fire_due_scheduled();
                me.mesh_sync().await;
            }
        });
    }

    /// If we're hosting a relay, pull from every sibling relay so the mailbox self-replicates
    /// across the mesh — any relay can then join/leave freely without losing the circle's data.
    async fn mesh_sync(self: &Arc<Self>) {
        let Some(host) = self.relay_host.lock().unwrap().clone() else { return };
        let my_hex = host.node_id_hex();
        let peers: std::collections::BTreeSet<String> =
            self.prefs.lock().unwrap().relays.values().flatten().cloned().collect();
        for peer in peers {
            if peer == my_hex || !self.relay_available(&peer) {
                continue;
            }
            if host.sync_from(peer.clone()).await > 0 {
                self.mark_relay_ok(&peer);
                self.dyn_state.lock().unwrap().relay_active = true;
                self.emit_changed();
            }
        }
    }

    // ---- scheduled messages -------------------------------------------------------------

    fn persist_scheduled(&self) {
        let snap = self.scheduled.lock().unwrap().clone();
        let _ = snap.save(&self.paths.scheduled_file());
    }

    /// Queue a post or DM to be sent at `send_at_ms`. Returns the generated item id.
    pub fn schedule(
        self: &Arc<Self>,
        kind: crate::scheduled::SchedKind,
        circle_id: String,
        body: String,
        media: Vec<String>,
        music: Option<crate::scheduled::SchedTrack>,
        mute_video: bool,
        send_at_ms: u64,
    ) -> String {
        let n = self.sched_counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("sch-{}-{n}", now_ms());
        let item = crate::scheduled::ScheduledItem {
            id: id.clone(),
            kind,
            circle_id,
            body,
            media,
            music,
            mute_video,
            send_at_ms,
            created_at_ms: now_ms(),
        };
        self.scheduled.lock().unwrap().add(item);
        self.persist_scheduled();
        self.emit_changed();
        id
    }

    pub fn list_scheduled(&self) -> Vec<crate::scheduled::ScheduledItem> {
        self.scheduled.lock().unwrap().items.clone()
    }

    pub fn cancel_scheduled(self: &Arc<Self>, id: &str) {
        let removed = self.scheduled.lock().unwrap().remove(id);
        if removed {
            self.persist_scheduled();
            self.emit_changed();
        }
    }

    /// Send everything whose time has arrived, then persist the remaining queue.
    pub fn fire_due_scheduled(self: &Arc<Self>) {
        let due = self.scheduled.lock().unwrap().take_due(now_ms());
        if due.is_empty() {
            return;
        }
        for it in due {
            let music = it.music.map(|m| TrackRefFfi {
                catalog_id: m.catalog_id,
                title: m.title,
                artist: m.artist,
                artwork_url: m.artwork_url,
                duration_ms: m.duration_ms,
            });
            match it.kind {
                crate::scheduled::SchedKind::Post => {
                    self.post(it.circle_id, it.body, it.media, music, it.mute_video);
                }
                crate::scheduled::SchedKind::Dm => {
                    self.send_dm(it.circle_id, it.body, it.media);
                }
            }
        }
        self.persist_scheduled();
        self.emit_changed();
    }

    pub fn started(&self) -> bool {
        self.dyn_state.lock().unwrap().started
    }

    pub fn host_on_launch(&self) -> bool {
        self.prefs.lock().unwrap().host_on_launch
    }

    pub fn set_host_on_launch(self: &Arc<Self>, on: bool) {
        let mut p = self.prefs.lock().unwrap();
        p.host_on_launch = on;
        let _ = p.save(&self.paths);
    }

    // ---- circles ------------------------------------------------------------------------

    pub fn feed_circles(&self) -> Vec<haven_ffi::CircleInfoFfi> {
        self.social
            .circles()
            .into_iter()
            .filter(|c| !c.id.starts_with("dm:"))
            .collect()
    }

    pub fn create_circle(self: &Arc<Self>, name: String) -> String {
        let id = format!("circle-{}-{}", &self.node_id_hex().chars().take(8).collect::<String>(), now_ms());
        self.social.create_circle(id.clone(), name);
        self.persist();
        self.emit_changed();
        id
    }

    pub fn rename_circle(self: &Arc<Self>, id: String, name: String) {
        self.social.rename_circle(id, name);
        self.persist();
        self.emit_changed();
    }

    pub fn leave_circle(self: &Arc<Self>, id: String) {
        if id == DEFAULT_CIRCLE {
            return;
        }
        self.social.leave_circle(id);
        self.persist();
        self.emit_changed();
    }

    /// Add an existing contact to a circle + greet them there so it forms on their side.
    pub fn add_to_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        let _ = self.social.add_existing_to_circle(circle_id.clone(), contact_id_hex.clone());
        self.persist();
        self.emit_changed();
        self.send_hello(&circle_id, &contact_id_hex);
    }

    // ---- feed / authoring ---------------------------------------------------------------

    pub fn feed(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let retention = self.prefs.lock().unwrap().retention_secs;
        self.social.feed(circle_id.to_string(), now_ms(), retention)
    }

    pub fn post(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool) {
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        match self.social.post(circle_id.clone(), body, media.clone(), music, None, false, mute_video, now_ms()) {
            Ok(env) => {
                self.after_author(&circle_id, &env);
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    for r in media {
                        me.upload_media(&circle_id, &r).await;
                    }
                });
            }
            Err(e) => log::error!("post failed: {e}"),
        }
    }

    pub fn post_story(self: &Arc<Self>, body: String, media: Option<String>, music: Option<TrackRefFfi>) {
        if body.trim().is_empty() && media.is_none() && music.is_none() {
            return;
        }
        let media_vec: Vec<String> = media.iter().cloned().collect();
        match self.social.post(DEFAULT_CIRCLE.to_string(), body, media_vec, music, Some(86_400), true, false, now_ms()) {
            Ok(env) => {
                self.after_author(DEFAULT_CIRCLE, &env);
                if let Some(r) = media {
                    let me = self.clone();
                    tauri::async_runtime::spawn(async move { me.upload_media(DEFAULT_CIRCLE, &r).await; });
                }
            }
            Err(e) => log::error!("post_story failed: {e}"),
        }
    }

    pub fn comment(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if body.trim().is_empty() {
            return;
        }
        if let Ok(env) = self.social.comment(circle_id.clone(), target, body, vec![], now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn react(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.react(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unreact(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.unreact(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn edit_post(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if let Ok(env) = self.social.edit(circle_id.clone(), target, body, vec![], None, false, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unsend_post(self: &Arc<Self>, circle_id: String, target: String) {
        if let Ok(env) = self.social.unsend(circle_id.clone(), target, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    /// Persist, bump the UI, and broadcast a freshly-authored sealed envelope to members.
    fn after_author(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        self.persist();
        self.emit_changed();
        let payload = wire::event_payload(circle_id, env);
        for id_hex in self.social.contact_node_ids(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &payload, &id_hex);
        }
        let me = self.clone();
        let cid = circle_id.to_string();
        let env = env.to_vec();
        tauri::async_runtime::spawn(async move { me.upload_event(&cid, &env).await; });
    }

    // ---- DMs ----------------------------------------------------------------------------

    pub fn dm_circle_id(&self, id_hex: &str) -> String {
        let mut pair = [self.node_id_hex(), id_hex.to_string()];
        pair.sort();
        format!("dm:{}-{}", pair[0], pair[1])
    }

    fn dm_allows(circle_id: &str, node_hex: &str) -> bool {
        let parts: Vec<&str> = circle_id.trim_start_matches("dm:").split('-').collect();
        parts.len() == 2 && parts.contains(&node_hex)
    }

    pub fn start_dm(self: &Arc<Self>, contact_id_hex: String, contact_name: String) -> String {
        let id = self.dm_circle_id(&contact_id_hex);
        self.social.create_circle(id.clone(), contact_name);
        let _ = self.social.add_existing_to_circle(id.clone(), contact_id_hex.clone());
        self.persist();
        self.send_hello(&id, &contact_id_hex);
        id
    }

    pub fn messages(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let mut m = self.social.feed(circle_id.to_string(), now_ms(), None);
        m.sort_by_key(|i| i.created_at);
        m
    }

    pub fn send_dm(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>) {
        if body.trim().is_empty() && media.is_empty() {
            return;
        }
        if let Ok(env) = self.social.post(circle_id.clone(), body, media.clone(), None, None, false, false, now_ms()) {
            self.after_author(&circle_id, &env);
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                for r in media {
                    me.upload_media(&circle_id, &r).await;
                }
            });
        }
    }

    /// DM threads as (circleId, partnerName, lastBody, lastAt).
    pub fn dm_threads(&self) -> Vec<(String, String, String, u64)> {
        let mut out = vec![];
        for c in self.social.circles() {
            if !c.id.starts_with("dm:") {
                continue;
            }
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            let (last_body, last_at) = feed
                .iter()
                .max_by_key(|i| i.created_at)
                .map(|i| (crate::secret::preview(&i.body), i.created_at))
                .unwrap_or_default();
            out.push((c.id.clone(), c.name.clone(), last_body, last_at));
        }
        out.sort_by(|a, b| b.3.cmp(&a.3));
        out
    }

    // ---- connect / handshake ------------------------------------------------------------

    pub fn connect_by_link(self: &Arc<Self>, uri: String) -> bool {
        let info = match parse_link(uri.trim().to_string()) {
            Ok(i) => i,
            Err(_) => return false,
        };
        self.dyn_state
            .lock()
            .unwrap()
            .initiated
            .insert(info.id_hex.clone(), info.verification_hex.clone());
        self.send_hello(DEFAULT_CIRCLE, &info.id_hex);
        true
    }

    pub fn pending(&self) -> Vec<PendingRequest> {
        self.dyn_state.lock().unwrap().pending.clone()
    }

    pub fn approve(self: &Arc<Self>, id_hex: String) {
        let req = {
            let mut st = self.dyn_state.lock().unwrap();
            let idx = st.pending.iter().position(|p| p.id_hex == id_hex);
            idx.map(|i| st.pending.remove(i))
        };
        if let Some(req) = req {
            self.accept_contact(DEFAULT_CIRCLE, &req.bundle, &req.id_hex, &req.name, &req.verify_hex, true);
            self.emit_changed();
        }
    }

    pub fn dismiss(self: &Arc<Self>, id_hex: String) {
        self.dyn_state.lock().unwrap().pending.retain(|p| p.id_hex != id_hex);
        self.emit_changed();
    }

    pub fn contacts(&self) -> Vec<Contact> {
        self.prefs.lock().unwrap().contacts.clone()
    }

    pub fn blocked(&self) -> Vec<String> {
        self.prefs.lock().unwrap().blocked.clone()
    }

    pub fn block(self: &Arc<Self>, id_hex: String) {
        self.social.block_member(id_hex.clone());
        {
            let mut p = self.prefs.lock().unwrap();
            p.contacts.retain(|c| c.id_hex != id_hex);
            if !p.blocked.contains(&id_hex) {
                p.blocked.push(id_hex.clone());
            }
            let _ = p.save(&self.paths);
        }
        self.dyn_state.lock().unwrap().pending.retain(|r| r.id_hex != id_hex);
        self.persist();
        self.emit_changed();
    }

    pub fn unblock(self: &Arc<Self>, id_hex: String) {
        let mut p = self.prefs.lock().unwrap();
        p.blocked.retain(|b| *b != id_hex);
        let _ = p.save(&self.paths);
    }

    fn accept_contact(self: &Arc<Self>, circle_id: &str, bundle: &[u8], id_hex: &str, name: &str, verify_hex: &str, hello_back: bool) {
        let _ = self.social.add_contact_bundle(circle_id.to_string(), bundle.to_vec());
        {
            let mut p = self.prefs.lock().unwrap();
            if !p.contacts.iter().any(|c| c.id_hex == id_hex) {
                p.contacts.push(Contact {
                    id_hex: id_hex.to_string(),
                    name: name.to_string(),
                    verify_hex: verify_hex.to_string(),
                });
            }
            let _ = p.save(&self.paths);
        }
        self.persist();
        if hello_back {
            self.send_hello(circle_id, id_hex);
        }
    }

    /// Resolve a feed item's short author id (8 hex) to a contact's display name.
    pub fn display_name(&self, author_short: &str) -> String {
        let p = self.prefs.lock().unwrap();
        p.contacts
            .iter()
            .find(|c| c.id_hex.starts_with(author_short))
            .map(|c| c.name.clone())
            .unwrap_or_else(|| {
                if author_short.len() >= 6 {
                    format!("Someone ({})", &author_short[..6])
                } else {
                    author_short.to_string()
                }
            })
    }

    // ---- outbound helpers ---------------------------------------------------------------

    fn hello_payload(&self, circle_id: &str) -> Option<Vec<u8>> {
        let profile = self.prefs.lock().unwrap().profile.clone();
        let name = if profile.name.trim().is_empty() { "Someone".to_string() } else { profile.name.clone() };
        let circle_name = self
            .social
            .circles()
            .into_iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.name)
            .unwrap_or_else(|| "My Circle".to_string());
        let bundle = self.social.my_bundle();
        // Avatar is left out of the Hello (keeps it small, matches Android); it travels in-app.
        let signed = self.social.my_signed_profile(name, profile.bio, profile.link, String::new(), profile.emoji);
        Some(wire::hello_payload(circle_id, &circle_name, &bundle, &signed))
    }

    /// Send our Hello + back-fill this circle's events to one node.
    fn send_hello(self: &Arc<Self>, circle_id: &str, to_node_hex: &str) {
        let Some(hello) = self.hello_payload(circle_id) else { return };
        self.send_frame(wire::HELLO, &hello, to_node_hex);
        for env in self.social.sync_envelopes(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &wire::event_payload(circle_id, &env), to_node_hex);
        }
        // Tell this peer about every relay I know for the circle, so we share all mailboxes.
        for node_hex in self.relays_for(circle_id) {
            if let Ok(sealed) = self.social.seal_circle_media(circle_id.to_string(), node_hex.into_bytes()) {
                self.send_frame(wire::RELAY_NODE, &wire::event_payload(circle_id, &sealed), to_node_hex);
            }
        }
    }

    pub fn sync_with_contacts(self: &Arc<Self>) {
        let ids: Vec<String> = self.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
        for id_hex in ids {
            self.send_hello(DEFAULT_CIRCLE, &id_hex);
        }
    }

    fn send_frame(self: &Arc<Self>, t: u8, payload: &[u8], to_node_hex: &str) {
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let frame = wire::frame(t, payload);
        let to = to_node_hex.to_string();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = node.send_to_node(to.clone(), frame).await {
                log::debug!("send type={t} to {} failed: {e}", &to.chars().take(8).collect::<String>());
            }
        });
    }

    // ---- inbound dispatch ---------------------------------------------------------------

    fn dispatch(self: &Arc<Self>, payload: Vec<u8>) {
        if payload.is_empty() {
            return;
        }
        let t = payload[0];
        let body = payload[1..].to_vec();
        // Call/media frames lead with a 64-char sender hex — drop blocked senders early.
        if matches!(t, wire::MEDIA_REQ | wire::CALL_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::GROUP_INVITE) {
            if body.len() >= 64 {
                let head = String::from_utf8_lossy(&body[..64]).into_owned();
                if head.len() == 64 && self.prefs.lock().unwrap().blocked.contains(&head) {
                    return;
                }
            }
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            me.dyn_state.lock().unwrap().internet_active = true;
            match t {
                wire::HELLO => me.handle_hello(&body),
                wire::EVENT => me.handle_event(&body),
                wire::RELAY_NODE => me.handle_relay_node(&body).await,
                wire::MEDIA_REQ => me.handle_media_request(&body).await,
                wire::MEDIA_CHUNK => me.handle_media_chunk(&body),
                wire::CALL_INVITE | wire::GROUP_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP
                | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => me.handle_call(t, &body),
                _ => log::debug!("ignoring frame type {t} (not yet handled)"),
            }
            me.emit_changed();
        });
    }

    fn handle_hello(self: &Arc<Self>, payload: &[u8]) {
        let Some(hello) = wire::parse_hello(payload) else { return };
        let id_hex = wire::node_hex(&hello.bundle);
        if self.prefs.lock().unwrap().blocked.contains(&id_hex) {
            return;
        }
        let Ok(actual_verify) = self.social.bundle_verification_hex(hello.bundle.clone()) else { return };
        let name = self
            .social
            .verify_profile(hello.bundle.clone(), hello.signed_profile.clone())
            .unwrap_or_else(|| "Someone".to_string());

        if hello.circle_id.starts_with("dm:") && !Self::dm_allows(&hello.circle_id, &id_hex) {
            return;
        }
        self.social.create_circle(hello.circle_id.clone(), hello.circle_name.clone());

        let expected = self.dyn_state.lock().unwrap().initiated.get(&id_hex).cloned();
        if let Some(expected) = expected {
            if !expected.is_empty() && expected != actual_verify {
                log::warn!("verify mismatch for {id_hex} — dropping (possible MITM)");
                return;
            }
            self.accept_contact(&hello.circle_id, &hello.bundle, &id_hex, &name, &actual_verify, true);
            self.dyn_state.lock().unwrap().initiated.remove(&id_hex);
            return;
        }
        if self.prefs.lock().unwrap().contacts.iter().any(|c| c.id_hex == id_hex) {
            let _ = self.social.add_contact_bundle(hello.circle_id.clone(), hello.bundle.clone());
            return;
        }
        if !hello.circle_id.starts_with("dm:") {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.pending.iter().any(|p| p.id_hex == id_hex) {
                st.pending.push(PendingRequest { id_hex, name, verify_hex: actual_verify, bundle: hello.bundle });
            }
        }
    }

    fn handle_event(self: &Arc<Self>, payload: &[u8]) {
        let Some(ev) = wire::parse_event(payload) else { return };
        let changed = self.social.receive(ev.circle_id.clone(), ev.envelope).unwrap_or(false);
        if changed {
            self.persist();
            self.emit_changed();
            self.request_missing_media();
            let is_dm = ev.circle_id.starts_with("dm:");
            self.notify(
                if is_dm { "New message" } else { "New in your circle" },
                if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
            );
        }
    }

    // ---- relay / mailbox ----------------------------------------------------------------

    async fn handle_relay_node(self: &Arc<Self>, body: &[u8]) {
        let mut r = wire::Reader::new(body);
        let Some(cid) = r.lp() else { return };
        let circle_id = String::from_utf8_lossy(&cid).into_owned();
        let sealed = r.rest();
        if circle_id.is_empty() || sealed.is_empty() {
            return;
        }
        let Some(open) = self.social.open_circle_media(circle_id.clone(), sealed) else { return };
        let node_hex = String::from_utf8_lossy(&open).trim().to_string();
        if node_hex.len() != 64 {
            return;
        }
        {
            // A contact advertised their circle relay → ADD it to our redundant set for this
            // circle, so members automatically pool relays (more redundancy, no manual setup).
            let mut p = self.prefs.lock().unwrap();
            let list = p.relays.entry(circle_id.clone()).or_default();
            if list.contains(&node_hex) {
                return;
            }
            list.push(node_hex.clone());
            let _ = p.save(&self.paths);
        }
        self.backfill_mailbox(&circle_id).await;
        self.poll_mailbox().await;
    }

    pub fn relay_status(&self) -> (bool, bool, bool, bool, bool) {
        let st = self.dyn_state.lock().unwrap();
        let prefs = self.prefs.lock().unwrap();
        let has_relay = prefs.relays.values().any(|v| !v.is_empty()) || prefs.s3.is_some();
        (st.hosting, has_relay, st.relay_active, st.internet_active, st.started)
    }

    /// The relay's node id (64-hex), which a friend pastes into "Adopt relay" so we share a
    /// mailbox. `None` unless we're currently hosting.
    pub fn relay_link(&self) -> Option<String> {
        self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex())
    }

    /// Start serving the circle's mailbox from this device + adopt it for every circle.
    pub async fn start_hosting(self: &Arc<Self>) -> Result<String> {
        {
            if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                return Ok(h.node_id_hex());
            }
        }
        // A stable relay-specific seed, distinct from the messaging identity.
        let mut hasher = Sha256::new();
        hasher.update(self.seed);
        hasher.update(b"haven-relay");
        let relay_seed: [u8; 32] = hasher.finalize().into();
        let dir = self.paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();
        let handle = RelayServerHandle::start(relay_seed.to_vec(), dir.to_string_lossy().to_string())
            .await
            .map_err(|e| anyhow::anyhow!("relay host start: {e}"))?;
        let node_hex = handle.node_id_hex();
        *self.relay_host.lock().unwrap() = Some(handle);
        self.dyn_state.lock().unwrap().hosting = true;
        self.adopt_relay(node_hex.clone()).await;
        self.emit_changed();
        Ok(node_hex)
    }

    pub fn stop_hosting(self: &Arc<Self>) {
        *self.relay_host.lock().unwrap() = None;
        self.dyn_state.lock().unwrap().hosting = false;
        self.emit_changed();
    }

    /// Adopt a relay node for all circles (ADDED to the redundant set, not replacing existing
    /// relays) + tell contacts via frame 19. Adopt several for redundancy.
    pub async fn adopt_relay(self: &Arc<Self>, node_hex: String) {
        let hex = node_hex.trim().to_lowercase();
        if hex.len() != 64 {
            return;
        }
        for c in self.social.circles() {
            {
                let mut p = self.prefs.lock().unwrap();
                let list = p.relays.entry(c.id.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
                let _ = p.save(&self.paths);
            }
            if let Ok(sealed) = self.social.seal_circle_media(c.id.clone(), hex.clone().into_bytes()) {
                let frame = wire::event_payload(&c.id, &sealed);
                for id_hex in self.social.contact_node_ids(c.id.clone()) {
                    self.send_frame(wire::RELAY_NODE, &frame, &id_hex);
                }
            }
            self.backfill_mailbox(&c.id).await;
        }
        self.poll_mailbox().await;
    }

    /// Drop a relay from every circle (and forget its cached connection + health).
    pub async fn forget_relay(self: &Arc<Self>, node_hex: String) {
        let hex = node_hex.trim().to_lowercase();
        {
            let mut p = self.prefs.lock().unwrap();
            for list in p.relays.values_mut() {
                list.retain(|h| h != &hex);
            }
            let _ = p.save(&self.paths);
        }
        self.relay_clients.lock().await.remove(&hex);
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// (node_hex, reachable, is_hosted_by_us) for every distinct adopted relay — for the UI.
    pub fn relays_detail(&self) -> Vec<(String, bool, bool)> {
        let now = now_ms();
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        let mut seen = std::collections::BTreeSet::new();
        let prefs = self.prefs.lock().unwrap();
        let health = self.relay_health.lock().unwrap();
        let mut out = vec![];
        for list in prefs.relays.values() {
            for hex in list {
                if seen.insert(hex.clone()) {
                    let reachable = health.get(hex).map(|h| h.available(now)).unwrap_or(true);
                    out.push((hex.clone(), reachable, hosted.as_deref() == Some(hex.as_str())));
                }
            }
        }
        out
    }

    /// The redundant relay set for a circle (mirrored writes, fallback reads).
    fn relays_for(&self, circle_id: &str) -> Vec<String> {
        self.prefs.lock().unwrap().relays.get(circle_id).cloned().unwrap_or_default()
    }

    fn relay_available(&self, node_hex: &str) -> bool {
        let now = now_ms();
        self.relay_health.lock().unwrap().get(node_hex).map(|h| h.available(now)).unwrap_or(true)
    }

    fn mark_relay_ok(&self, node_hex: &str) {
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_success();
    }

    fn mark_relay_fail(&self, node_hex: &str) {
        let now = now_ms();
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_failure(now);
    }

    async fn relay_client_for(self: &Arc<Self>, node_hex: &str) -> Option<Arc<RelayClient>> {
        {
            let clients = self.relay_clients.lock().await;
            if let Some(c) = clients.get(node_hex) {
                return Some(c.clone());
            }
        }
        // Skip a relay that's in its backoff window — try the others instead.
        if !self.relay_available(node_hex) {
            return None;
        }
        match RelayClient::connect(self.seed.to_vec(), node_hex.to_string()).await {
            Ok(c) => {
                self.mark_relay_ok(node_hex);
                self.relay_clients.lock().await.insert(node_hex.to_string(), c.clone());
                Some(c)
            }
            Err(e) => {
                log::debug!("relay connect failed ({node_hex}): {e}");
                self.mark_relay_fail(node_hex);
                None
            }
        }
    }

    /// On a put/list/get failure: back the relay off and drop its cached connection.
    async fn relay_failed(self: &Arc<Self>, node_hex: &str) {
        self.mark_relay_fail(node_hex);
        self.relay_clients.lock().await.remove(node_hex);
    }

    fn mailbox_key(circle_id: &str, env: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(env);
        let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        format!("haven/mailbox/{circle_id}/{hex}")
    }

    /// Build (and cache) the BYO S3 mailbox client from prefs + the keychain secret, if configured.
    async fn s3_client(self: &Arc<Self>) -> Option<Arc<S3Mailbox>> {
        if let Some(c) = self.s3.lock().await.as_ref() {
            return Some(c.clone());
        }
        let pub_cfg = self.prefs.lock().unwrap().s3.clone()?;
        let secret = store::load_s3_secret()?;
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint,
            region: pub_cfg.region,
            bucket: pub_cfg.bucket,
            access_key: pub_cfg.access_key,
            secret_key: secret,
            prefix: pub_cfg.prefix,
        };
        let client = Arc::new(S3Mailbox::new(cfg).ok()?);
        *self.s3.lock().await = Some(client.clone());
        Some(client)
    }

    async fn upload_event(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        let key = Self::mailbox_key(circle_id, env);
        // 1) Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        //    re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        for node_hex in self.relays_for(circle_id) {
            if let Some(client) = self.relay_client_for(&node_hex).await {
                match client.put(key.clone(), env.to_vec()).await {
                    Ok(()) => {
                        self.mark_relay_ok(&node_hex);
                        self.dyn_state.lock().unwrap().relay_active = true;
                    }
                    Err(e) => {
                        log::debug!("mailbox put failed ({node_hex}): {e}");
                        self.relay_failed(&node_hex).await;
                    }
                }
            }
        }
        // 2) BYO S3 bucket — an additional, independent mailbox (also idempotent).
        if let Some(s3) = self.s3_client().await {
            if s3.put(&key, env).await.is_ok() {
                self.dyn_state.lock().unwrap().relay_active = true;
            }
        }
    }

    async fn backfill_mailbox(self: &Arc<Self>, circle_id: &str) {
        let has_relay = !self.relays_for(circle_id).is_empty();
        let has_s3 = self.prefs.lock().unwrap().s3.is_some();
        if !has_relay && !has_s3 {
            return;
        }
        for env in self.social.export_my_envelopes(circle_id.to_string()) {
            self.upload_event(circle_id, &env).await;
        }
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        for item in feed {
            if item.is_me {
                for r in item.media {
                    if self.media.has(&r) {
                        self.upload_media(circle_id, &r).await;
                    }
                }
            }
        }
    }

    pub async fn poll_mailbox(self: &Arc<Self>) {
        let mut changed = false;
        // (circle_id, relay_node_hex) for every circle × every configured relay — reading from
        // all of them means a message present on any reachable relay still arrives.
        let relay_targets: Vec<(String, String)> = {
            let prefs = self.prefs.lock().unwrap();
            prefs
                .relays
                .iter()
                .flat_map(|(cid, list)| list.iter().map(move |hex| (cid.clone(), hex.clone())))
                .collect()
        };
        for (circle_id, node_hex) in relay_targets {
            let Some(client) = self.relay_client_for(&node_hex).await else { continue };
            let prefix = format!("haven/mailbox/{circle_id}/");
            let keys = client.list(prefix).await;
            self.mark_relay_ok(&node_hex);
            if !keys.is_empty() {
                self.dyn_state.lock().unwrap().relay_active = true;
            }
            for key in keys {
                // seen_mailbox is keyed by the content-addressed key, so the same envelope
                // mirrored on several relays is ingested exactly once.
                if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                    continue;
                }
                let Some(env) = client.get(key.clone()).await else { continue };
                self.dyn_state.lock().unwrap().seen_mailbox.insert(key);
                if self.social.receive(circle_id.clone(), env).unwrap_or(false) {
                    changed = true;
                    let is_dm = circle_id.starts_with("dm:");
                    self.notify(
                        if is_dm { "New message" } else { "New in your circle" },
                        if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
                    );
                }
            }
        }
        // BYO S3 bucket mailbox (the same circle-sealed envelopes, in the user's own bucket).
        if let Some(s3) = self.s3_client().await {
            for c in self.social.circles() {
                let keys = s3.list(&format!("haven/mailbox/{}", c.id)).await.unwrap_or_default();
                if !keys.is_empty() {
                    self.dyn_state.lock().unwrap().relay_active = true;
                }
                for key in keys {
                    if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                        continue;
                    }
                    let env = match s3.get(&key).await {
                        Ok(Some(e)) => e,
                        _ => continue,
                    };
                    self.dyn_state.lock().unwrap().seen_mailbox.insert(key);
                    if self.social.receive(c.id.clone(), env).unwrap_or(false) {
                        changed = true;
                        let is_dm = c.id.starts_with("dm:");
                        self.notify(
                            if is_dm { "New message" } else { "New in your circle" },
                            if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
                        );
                    }
                }
            }
        }
        if changed {
            self.persist();
            self.emit_changed();
            self.request_missing_media();
        }
    }

    /// Configure (and verify) a BYO S3/R2/B2 bucket. Stores the secret in the keychain, the rest
    /// in prefs, caches the client, and back-fills + polls. Errors if the bucket can't be reached.
    pub async fn s3_configure(self: &Arc<Self>, pub_cfg: store::S3Public, secret_key: String) -> Result<()> {
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint.clone(),
            region: pub_cfg.region.clone(),
            bucket: pub_cfg.bucket.clone(),
            access_key: pub_cfg.access_key.clone(),
            secret_key: secret_key.clone(),
            prefix: pub_cfg.prefix.clone(),
        };
        let client = S3Mailbox::new(cfg)?;
        // Connectivity / auth check.
        client.list("haven/mailbox").await.map_err(|e| anyhow::anyhow!("bucket unreachable: {e}"))?;
        store::save_s3_secret(&secret_key)?;
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = Some(pub_cfg);
            p.save(&self.paths)?;
        }
        *self.s3.lock().await = Some(Arc::new(client));
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            for c in me.social.circles() {
                me.backfill_mailbox(&c.id).await;
            }
            me.poll_mailbox().await;
        });
        Ok(())
    }

    pub async fn s3_clear(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = None;
            let _ = p.save(&self.paths);
        }
        store::delete_s3_secret();
        *self.s3.lock().await = None;
        self.emit_changed();
    }

    pub fn s3_status(&self) -> Option<store::S3Public> {
        self.prefs.lock().unwrap().s3.clone()
    }

    // ---- cross-device media bytes (frame 3 request / frame 5 sealed chunks) -------------

    fn media_key(reference: &str) -> String {
        format!("haven/media/{reference}")
    }

    pub fn request_missing_media(self: &Arc<Self>) {
        let my_hex = self.node_id_hex();
        let mut missing: Vec<(String, String)> = vec![]; // (ref, circleId)
        for c in self.social.circles() {
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            for item in feed {
                for r in item.media {
                    if !self.media.has(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                        missing.push((r, c.id.clone()));
                    }
                }
                for cm in item.comments {
                    for r in cm.media {
                        if !self.media.has(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                            missing.push((r, c.id.clone()));
                        }
                    }
                }
            }
        }
        for (reference, circle_id) in missing {
            let me = self.clone();
            let my_hex = my_hex.clone();
            tauri::async_runtime::spawn(async move {
                if me.fetch_media_from_relay(&circle_id, &reference).await {
                    me.emit_changed();
                    return;
                }
                if !me.dyn_state.lock().unwrap().requested_refs.insert(reference.clone()) {
                    return;
                }
                let mut payload = my_hex.into_bytes();
                payload.extend_from_slice(reference.as_bytes());
                let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
                for id_hex in ids {
                    me.send_frame(wire::MEDIA_REQ, &payload, &id_hex);
                }
            });
        }
    }

    async fn upload_media(self: &Arc<Self>, circle_id: &str, reference: &str) {
        let Some(blob) = self.media.raw_sealed(reference) else { return };
        let key = Self::media_key(reference);
        // Mirror the sealed media blob to every relay (redundancy).
        for node_hex in self.relays_for(circle_id) {
            if let Some(client) = self.relay_client_for(&node_hex).await {
                match client.put(key.clone(), blob.clone()).await {
                    Ok(()) => self.mark_relay_ok(&node_hex),
                    Err(_) => self.relay_failed(&node_hex).await,
                }
            }
        }
        if let Some(s3) = self.s3_client().await {
            let _ = s3.put(&key, &blob).await;
        }
    }

    async fn fetch_media_from_relay(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        let key = Self::media_key(reference);
        // Try each relay in turn; the first that has the blob wins (graceful fallback).
        for node_hex in self.relays_for(circle_id) {
            if let Some(client) = self.relay_client_for(&node_hex).await {
                if let Some(blob) = client.get(key.clone()).await {
                    self.mark_relay_ok(&node_hex);
                    self.media.write_raw_sealed(reference, &blob);
                    return true;
                }
            }
        }
        if let Some(s3) = self.s3_client().await {
            if let Ok(Some(blob)) = s3.get(&key).await {
                self.media.write_raw_sealed(reference, &blob);
                return true;
            }
        }
        false
    }

    async fn handle_media_request(self: &Arc<Self>, body: &[u8]) {
        if body.len() <= 64 {
            return;
        }
        let requester = String::from_utf8_lossy(&body[..64]).into_owned();
        if requester.len() != 64 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[64..]).into_owned();
        if reference.is_empty() || !self.media.has(&reference) {
            return;
        }
        let Some(bytes) = self.media.load_any_circle(&self.social, &reference) else { return };
        self.send_media_chunks(&reference, &bytes, &requester).await;
    }

    async fn send_media_chunks(self: &Arc<Self>, reference: &str, bytes: &[u8], requester_hex: &str) {
        let total = ((bytes.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE).max(1) as u32;
        let ref_bytes = reference.as_bytes();
        let mut index = 0u32;
        let mut offset = 0;
        while offset < bytes.len() {
            let end = (offset + MEDIA_CHUNK_SIZE).min(bytes.len());
            let chunk = &bytes[offset..end];
            let Ok(sealed) = self.social.seal_media(requester_hex.to_string(), chunk.to_vec()) else { return };
            self.send_frame(wire::MEDIA_CHUNK, &wire::chunk_frame(ref_bytes, index, total, &sealed), requester_hex);
            offset = end;
            index += 1;
        }
    }

    fn handle_media_chunk(self: &Arc<Self>, body: &[u8]) {
        if body.len() < 2 {
            return;
        }
        let ref_len = (body[0] as usize) | ((body[1] as usize) << 8);
        if body.len() < 2 + ref_len + 8 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[2..2 + ref_len]).into_owned();
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let sealed = &body[off..];
        if reference.is_empty() || total == 0 || self.media.has(&reference) {
            return;
        }
        let Some(plain) = self.social.open_media(sealed.to_vec()) else { return };
        let mut complete: Option<Vec<u8>> = None;
        {
            let mut st = self.dyn_state.lock().unwrap();
            let entry = st.incoming_media.entry(reference.clone()).or_insert(IncomingMedia { total, chunks: HashMap::new() });
            entry.chunks.insert(index, plain);
            if entry.chunks.len() as u32 >= entry.total {
                let mut full = Vec::new();
                for i in 0..entry.total {
                    if let Some(c) = entry.chunks.get(&i) {
                        full.extend_from_slice(c);
                    }
                }
                complete = Some(full);
                st.incoming_media.remove(&reference);
            }
        }
        if let Some(full) = complete {
            self.media.store_under_ref(&self.social, DEFAULT_CIRCLE, &reference, &full);
            self.emit_changed();
        }
    }

    // ---- local media (attach + display) -------------------------------------------------

    pub fn add_local_media(&self, circle_id: &str, bytes: &[u8], is_video: bool) -> String {
        self.media.store(&self.social, circle_id, bytes, is_video)
    }

    pub fn add_local_audio(&self, circle_id: &str, bytes: &[u8]) -> String {
        self.media.store_kind(&self.social, circle_id, bytes, crate::localmedia::MediaKind::Audio)
    }

    /// Decrypt a stored media ref for display, trying the given circle then any circle.
    pub fn media_bytes(&self, circle_id: &str, reference: &str) -> Option<Vec<u8>> {
        self.media
            .load(&self.social, circle_id, reference)
            .or_else(|| self.media.load_any_circle(&self.social, reference))
    }

    // ---- calls (signaling only; WebRTC media lives in the WebView) ----------------------

    /// Parse an inbound call frame and forward it to the UI's WebRTC mesh via `haven:call`.
    fn handle_call(self: &Arc<Self>, t: u8, body: &[u8]) {
        let Some(app) = self.app.lock().unwrap().clone() else { return };
        let ev = match t {
            wire::CALL_INVITE => callwire::parse_invite_name(body).map(|(from, name)| {
                serde_json::json!({ "kind": "invite", "from": from, "name": name, "sessionId": format!("legacy:{from}"), "roster": [from] })
            }),
            wire::GROUP_INVITE => callwire::parse_group_invite(body).map(|g| {
                serde_json::json!({ "kind": "groupInvite", "from": g.from, "sessionId": g.session_id, "groupName": g.group_name, "roster": g.roster })
            }),
            wire::CALL_ACCEPT => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "accept", "from": a.from, "sessionId": a.session_id })
            }),
            wire::CALL_HANGUP => callwire::parse_hangup(body).map(|from| {
                serde_json::json!({ "kind": "hangup", "from": from })
            }),
            wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => callwire::parse_signal(body, "").map(|s| {
                let kind = match t { wire::SDP_OFFER => "offer", wire::SDP_ANSWER => "answer", _ => "ice" };
                serde_json::json!({ "kind": kind, "from": s.from, "sessionId": s.session_id, "json": String::from_utf8_lossy(&s.json) })
            }),
            _ => None,
        };
        if let Some(ev) = ev {
            // Resolve a friendly name for the caller for the ringing UI.
            let _ = app.emit("haven:call", ev);
        }
    }

    pub fn call_group_invite(self: &Arc<Self>, session_id: String, group_name: String, roster: Vec<String>, to: Vec<String>) {
        let me = self.node_id_hex();
        let frame = callwire::group_invite(&me, &session_id, &group_name, &roster.join(","));
        for t in to {
            self.send_frame(wire::GROUP_INVITE, &frame, &t);
        }
    }

    pub fn call_accept(self: &Arc<Self>, session_id: String, to: Vec<String>) {
        let frame = callwire::accept(&self.node_id_hex(), &session_id);
        for t in to {
            self.send_frame(wire::CALL_ACCEPT, &frame, &t);
        }
    }

    pub fn call_hangup(self: &Arc<Self>, to: Vec<String>) {
        let frame = callwire::hangup(&self.node_id_hex());
        for t in to {
            self.send_frame(wire::CALL_HANGUP, &frame, &t);
        }
    }

    pub fn call_signal(self: &Arc<Self>, kind: String, session_id: String, json: String, to: String) {
        let t = match kind.as_str() {
            "offer" => wire::SDP_OFFER,
            "answer" => wire::SDP_ANSWER,
            _ => wire::ICE,
        };
        let frame = callwire::signal(&self.node_id_hex(), &session_id, json.as_bytes());
        self.send_frame(t, &frame, &to);
    }

    // ---- persistence --------------------------------------------------------------------

    fn persist(&self) {
        if let Err(e) = store::write_state(&self.paths, &self.social.export_state()) {
            log::error!("persist failed: {e}");
        }
    }

    pub fn reset(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            *p = Prefs::default();
            let _ = p.save(&self.paths);
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            *st = DynState::default();
        }
        self.media.clear();
        store::remove_if_exists(&self.paths.state_file());
        store::delete_s3_secret();
        let _ = store::delete_seed();
        self.emit_changed();
    }
}

/// Adapter so the Rust iroh node can deliver inbound bytes back into the engine without a
/// strong reference cycle (the engine owns the node).
struct NodeListener {
    engine: Weak<Engine>,
}

impl InboundListener for NodeListener {
    fn on_inbound(&self, payload: Vec<u8>) {
        if let Some(engine) = self.engine.upgrade() {
            engine.dispatch(payload);
        }
    }
}

#[cfg(test)]
mod round_trip_tests {
    use crate::wire;
    use haven_ffi::HavenSocial;

    /// Two parties handshake and exchange a post + a sealed media chunk through the exact
    /// `wire` framing the engine moves over iroh — a stand-in for a real cross-device test
    /// (Windows ↔ iPhone ↔ Android) that doesn't need two machines or the network.
    #[test]
    fn two_parties_exchange_post_and_media_over_wire() {
        let alice = HavenSocial::new([11u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let cid = "default".to_string();

        // --- Hello handshake (frame 0) ---
        let hello = wire::hello_payload(
            &cid,
            "My Circle",
            &alice.my_bundle(),
            &alice.my_signed_profile("Alice".into(), String::new(), String::new(), String::new(), String::new()),
        );
        let frame = wire::frame(wire::HELLO, &hello);
        assert_eq!(frame[0], wire::HELLO);
        let parsed = wire::parse_hello(&frame[1..]).expect("hello parses");
        assert_eq!(
            bob.verify_profile(parsed.bundle.clone(), parsed.signed_profile.clone()).as_deref(),
            Some("Alice"),
            "bob reads alice's signed name"
        );
        bob.add_contact_bundle(cid.clone(), parsed.bundle).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        // --- Post (frame 1) ---
        let env = alice.post(cid.clone(), "hello from windows".into(), vec![], None, None, false, false, 1_000).unwrap();
        let ev_frame = wire::frame(wire::EVENT, &wire::event_payload(&cid, &env));
        let ev = wire::parse_event(&ev_frame[1..]).expect("event parses");
        assert!(bob.receive(ev.circle_id, ev.envelope).unwrap(), "new on first receive");
        let feed = bob.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hello from windows");
        assert!(!feed[0].is_me);

        // --- Sealed media chunk (frame 5) ---
        let blob = vec![9u8; 1000];
        let sealed = alice.seal_media(bob.my_node_hex(), blob.clone()).unwrap();
        let chunk = wire::chunk_frame(b"v:abc", 0, 1, &sealed);
        let ref_len = (chunk[0] as usize) | ((chunk[1] as usize) << 8);
        assert_eq!(String::from_utf8_lossy(&chunk[2..2 + ref_len]), "v:abc");
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        assert_eq!((index, total), (0, 1));
        assert_eq!(bob.open_media(chunk[off..].to_vec()), Some(blob), "bob reassembles + decrypts the media");
    }
}
