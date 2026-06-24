//! On-device persistence: the master seed in the OS secure store (Windows Credential
//! Manager / macOS Keychain / Linux Secret Service) — keys never leave the device, the
//! same rule the iOS Keychain and Android Keystore enforce — plus a small JSON prefs file
//! and the binary social-state blob on disk in the app data directory.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use serde::{Deserialize, Serialize};

const SERVICE: &str = "com.blaineam.haven";
const SEED_ACCOUNT: &str = "master-seed";
const S3_SECRET_ACCOUNT: &str = "s3-secret-key";

/// Resolved app-data paths. `base` is the global Haven data dir (holds the cross-identity
/// `identities.json`); `root` is the *active identity's* data dir (its state/prefs/media/relay).
/// For the first/legacy identity `root == base` so existing installs keep their files in place;
/// additional identities live under `base/identities/<node_hex>/`.
#[derive(Clone)]
pub struct Paths {
    pub base: PathBuf,
    pub root: PathBuf,
}

impl Paths {
    pub fn resolve() -> Result<Self> {
        Self::resolve_for("")
    }

    /// Resolve paths for a specific identity data subdir (relative to `base`; `""` = legacy root).
    pub fn resolve_for(dir_rel: &str) -> Result<Self> {
        let base = dirs::data_dir().ok_or_else(|| anyhow!("no data dir"))?.join("Haven");
        fs::create_dir_all(&base).with_context(|| format!("create {}", base.display()))?;
        let root = if dir_rel.is_empty() { base.clone() } else { base.join(dir_rel) };
        fs::create_dir_all(&root).with_context(|| format!("create {}", root.display()))?;
        Ok(Self { base, root })
    }

    /// The cross-identity roster file (always at `base`, never per-identity).
    pub fn identities_file(&self) -> PathBuf {
        self.base.join("identities.json")
    }
    pub fn state_file(&self) -> PathBuf {
        self.root.join("haven_social_state.bin")
    }
    pub fn prefs_file(&self) -> PathBuf {
        self.root.join("prefs.json")
    }
    pub fn scheduled_file(&self) -> PathBuf {
        self.root.join("scheduled.json")
    }
    pub fn relay_dir(&self) -> PathBuf {
        self.root.join("relay")
    }
    pub fn media_dir(&self) -> PathBuf {
        self.root.join("media")
    }
}

/// The user's chosen, signed-at-broadcast business card.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Profile {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default)]
    pub link: String,
    #[serde(default)]
    pub emoji: String,
    /// Base64 JPEG/PNG avatar (small), empty if none.
    #[serde(default)]
    pub avatar: String,
}

/// A known contact (their verified identity + display name).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Contact {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
}

/// Non-secret config for a BYO S3/R2/B2 bucket (the secret key lives in the keychain).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct S3Public {
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub access_key: String,
    #[serde(default)]
    pub prefix: String,
}

/// Everything that lives in `prefs.json` (mirrors the Android SharedPreferences set).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Prefs {
    #[serde(default)]
    pub profile: Profile,
    #[serde(default)]
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub blocked: Vec<String>,
    /// Legacy single-relay-per-circle map (migrated into `relays` on load; kept for back-compat).
    #[serde(default)]
    pub relay_nodes: std::collections::HashMap<String, String>,
    /// circleId -> ordered list of relay node hexes. Posts are mirrored to every relay
    /// (redundancy) and read from all of them (graceful fallback if one is down).
    #[serde(default)]
    pub relays: std::collections::HashMap<String, Vec<String>>,
    /// Retention window in seconds for the viewer's own auto-prune (None = keep all).
    #[serde(default)]
    pub retention_secs: Option<u64>,
    /// BYO bucket config (non-secret); `None` until configured.
    #[serde(default)]
    pub s3: Option<S3Public>,
    /// Auto-host the in-process relay on app launch (so launch-on-login = always-on relay).
    #[serde(default)]
    pub host_on_launch: bool,
}

impl Prefs {
    pub fn load(paths: &Paths) -> Self {
        let mut prefs: Prefs = match fs::read(paths.prefs_file()) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Prefs::default(),
        };
        // Migrate the legacy single-relay-per-circle map into the redundant `relays` list.
        // Idempotent: re-runs harmlessly on every load until the next save clears `relay_nodes`.
        for (cid, hex) in std::mem::take(&mut prefs.relay_nodes) {
            let list = prefs.relays.entry(cid).or_default();
            if !list.contains(&hex) {
                list.push(hex);
            }
        }
        prefs
    }
    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(paths.prefs_file(), bytes).context("write prefs")
    }
}

/// Load the 32-byte master seed from the secure store, or `None` if there isn't one yet.
/// Distinguishes "no entry" (new device → caller generates) from a locked/error read, so
/// we never clobber an existing identity by treating a transient failure as "new".
pub fn load_seed() -> Result<Option<[u8; 32]>> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    match entry.get_password() {
        Ok(b64) => {
            let raw = base64::engine::general_purpose::STANDARD
                .decode(b64.trim())
                .context("decode stored seed")?;
            let seed: [u8; 32] = raw
                .try_into()
                .map_err(|_| anyhow!("stored seed is not 32 bytes"))?;
            Ok(Some(seed))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(anyhow!("keyring read failed: {e}")),
    }
}

/// Persist the master seed to the secure store.
pub fn save_seed(seed: &[u8; 32]) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(seed);
    entry.set_password(&b64).context("write seed to keyring")
}

/// Wipe the stored seed (Start Over).
pub fn delete_seed() -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(anyhow!("keyring delete failed: {e}")),
    }
}

// ---- multi-identity roster ------------------------------------------------------------------

/// One identity the user keeps on this device. The 32-byte seed lives in the OS secure store
/// (keyring account `seed-<node_hex>`); only this non-secret descriptor is on disk.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct IdentityEntry {
    pub node_hex: String,
    pub label: String,
    /// Data subdir relative to `base` (`""` = legacy root, kept for the first identity).
    #[serde(default)]
    pub dir: String,
}

/// The roster of identities + which one is active. Persisted to `identities.json` at `base`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identities {
    #[serde(default)]
    pub active: String,
    #[serde(default)]
    pub items: Vec<IdentityEntry>,
}

impl Identities {
    pub fn load(paths: &Paths) -> Self {
        match fs::read(paths.identities_file()) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Identities::default(),
        }
    }

    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(paths.identities_file(), bytes).context("write identities")
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn find(&self, node_hex: &str) -> Option<&IdentityEntry> {
        self.items.iter().find(|i| i.node_hex == node_hex)
    }

    pub fn active_entry(&self) -> Option<&IdentityEntry> {
        self.find(&self.active)
    }

    /// Add an identity (no-op if its node_hex is already present). The first one added becomes
    /// active and keeps the legacy root (`dir = ""`); later ones get `identities/<hex>`.
    pub fn add(&mut self, node_hex: &str, label: &str) {
        if self.find(node_hex).is_some() {
            return;
        }
        let dir = if self.items.is_empty() { String::new() } else { format!("identities/{node_hex}") };
        let first = self.items.is_empty();
        self.items.push(IdentityEntry { node_hex: node_hex.to_string(), label: label.to_string(), dir });
        if first {
            self.active = node_hex.to_string();
        }
    }

    pub fn set_active(&mut self, node_hex: &str) -> bool {
        if self.find(node_hex).is_some() {
            self.active = node_hex.to_string();
            true
        } else {
            false
        }
    }

    pub fn rename(&mut self, node_hex: &str, label: &str) -> bool {
        if let Some(e) = self.items.iter_mut().find(|i| i.node_hex == node_hex) {
            e.label = label.to_string();
            true
        } else {
            false
        }
    }

    /// Remove an identity (refuses to remove the active one). Returns its data subdir if removed.
    pub fn remove(&mut self, node_hex: &str) -> Option<String> {
        if node_hex == self.active {
            return None;
        }
        let idx = self.items.iter().position(|i| i.node_hex == node_hex)?;
        Some(self.items.remove(idx).dir)
    }
}

/// Per-identity seed in the OS secure store, keyed by node hex (distinct from the legacy
/// `master-seed`, which we keep mirrored to the active identity for the headless relay).
fn id_seed_account(node_hex: &str) -> String {
    format!("seed-{node_hex}")
}

pub fn save_identity_seed(node_hex: &str, seed: &[u8; 32]) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)).context("open id keyring")?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(seed);
    entry.set_password(&b64).context("write id seed")
}

pub fn load_identity_seed(node_hex: &str) -> Result<Option<[u8; 32]>> {
    let entry = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)).context("open id keyring")?;
    match entry.get_password() {
        Ok(b64) => {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64.trim()).context("decode id seed")?;
            let seed: [u8; 32] = raw.try_into().map_err(|_| anyhow!("id seed not 32 bytes"))?;
            Ok(Some(seed))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(anyhow!("id keyring read failed: {e}")),
    }
}

pub fn delete_identity_seed(node_hex: &str) {
    if let Ok(entry) = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)) {
        let _ = entry.delete_credential();
    }
}

/// Store / read / clear the S3 secret access key in the OS secure store (never in prefs.json).
pub fn save_s3_secret(secret: &str) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT).context("open s3 keyring entry")?;
    entry.set_password(secret).context("write s3 secret")
}

pub fn load_s3_secret() -> Option<String> {
    let entry = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT).ok()?;
    entry.get_password().ok()
}

pub fn delete_s3_secret() {
    if let Ok(entry) = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT) {
        let _ = entry.delete_credential();
    }
}

/// Read the persisted social-state blob, if any.
pub fn read_state(paths: &Paths) -> Option<Vec<u8>> {
    fs::read(paths.state_file()).ok()
}

/// Write the social-state blob.
pub fn write_state(paths: &Paths, data: &[u8]) -> Result<()> {
    fs::write(paths.state_file(), data).context("write state")
}

/// Remove a file, ignoring "not found".
pub fn remove_if_exists(p: &Path) {
    let _ = fs::remove_file(p);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_identity_is_active_and_uses_legacy_root() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        assert_eq!(ids.active, "aaaa");
        assert_eq!(ids.active_entry().unwrap().dir, ""); // legacy root, no migration
    }

    #[test]
    fn additional_identities_get_scoped_dirs_and_dont_steal_active() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert_eq!(ids.active, "aaaa"); // adding doesn't switch
        assert_eq!(ids.find("bbbb").unwrap().dir, "identities/bbbb");
    }

    #[test]
    fn add_is_idempotent() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("aaaa", "Me again");
        assert_eq!(ids.items.len(), 1);
    }

    #[test]
    fn set_active_only_for_known() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert!(ids.set_active("bbbb"));
        assert_eq!(ids.active, "bbbb");
        assert!(!ids.set_active("zzzz"));
        assert_eq!(ids.active, "bbbb");
    }

    #[test]
    fn cannot_remove_active_can_remove_others() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert_eq!(ids.remove("aaaa"), None); // active is protected
        assert_eq!(ids.remove("bbbb"), Some("identities/bbbb".to_string()));
        assert!(ids.find("bbbb").is_none());
    }

    #[test]
    fn rename_identity() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        assert!(ids.rename("aaaa", "Work"));
        assert_eq!(ids.find("aaaa").unwrap().label, "Work");
        assert!(!ids.rename("zzzz", "Nope"));
    }
}
