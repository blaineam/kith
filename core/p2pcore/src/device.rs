//! Per-device credentials & signed device lists — the trust foundation for
//! **multi-device** (roadmap D16).
//!
//! The model (see `docs/MULTI-DEVICE.md`): a user is **one account identity** with a
//! set of **authorized devices**, each holding its *own* keypair that never leaves the
//! device. The account identity key (the long-term key contacts pin) **signs**:
//!
//!   * a [`DeviceCredential`] per device — `{account_id, device bundle, name, created_at}`
//!     signed by the account, proving "this device is authorized by this account"; and
//!   * a versioned, signed [`DeviceList`] — the current roster (active + revoked) that
//!     contacts honor so a relay can't inject a rogue device or hide a revocation.
//!
//! This layer is deliberately **independent of MLS** (D3). A device credential is just a
//! signed binding; messages reach a device because its full `HavenId` bundle is published
//! in the credential, so the existing per-recipient hybrid-KEM sealing can encrypt to it.
//! The MLS-specific hardening (forward secrecy + post-compromise rekey on Add/Remove
//! *commits*) layers on top once MLS lands — it does not change these signatures.
//!
//! Everything here is **pure** (no clock, no RNG of its own): `created_at` / `updated_at`
//! / `version` are supplied by the caller, keeping the module deterministic and trivially
//! testable on every platform (incl. WASM).

use crate::identity::{HavenId, Identity};
use crate::{CoreError, Result};

/// Domain-separation tag for the bytes an account signs to issue a device credential.
const CRED_DOMAIN: &[u8] = b"haven-device-cred-v1";
/// Domain-separation tag for the bytes an account signs over a device list.
const LIST_DOMAIN: &[u8] = b"haven-device-list-v1";

/// A device authorized by an account.
///
/// The `sig` is a **hybrid** (Ed25519 + ML-DSA) signature **by the account identity** over
/// the canonical encoding of `{account_id, device, device_name, created_at}`. A contact who
/// has pinned the account's `HavenId` (from the first QR/link verification) can therefore
/// verify that this device legitimately belongs to that account — no relay or third party
/// can forge it.
///
/// (No `PartialEq`/`Debug` derive: it embeds a [`HavenId`], a minimal core type that
/// derives neither. Compare credentials by [`Self::to_bytes`] when needed.)
#[derive(Clone)]
pub struct DeviceCredential {
    /// The account's 32-byte node id (Ed25519 public key) this device belongs to.
    pub account_id: [u8; 32],
    /// The device's full public bundle — peers seal to this so the device can decrypt.
    pub device: HavenId,
    /// Human-readable device label (e.g. "Blaine's iPhone"). Advisory only.
    pub device_name: String,
    /// Unix seconds the credential was issued (caller-supplied; not trusted for security).
    pub created_at: u64,
    /// Hybrid signature by the **account** identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl DeviceCredential {
    /// The canonical bytes the account signs / a verifier re-derives. Stable layout:
    /// `domain ‖ account_id(32) ‖ created_at(8 LE) ‖ name_len(4 LE) ‖ name ‖ device_bundle`.
    fn signing_bytes(account_id: &[u8; 32], device: &HavenId, name: &str, created_at: u64) -> Vec<u8> {
        let dev = device.to_bytes();
        let name_b = name.as_bytes();
        let mut v = Vec::with_capacity(CRED_DOMAIN.len() + 32 + 8 + 4 + name_b.len() + dev.len());
        v.extend_from_slice(CRED_DOMAIN);
        v.extend_from_slice(account_id);
        v.extend_from_slice(&created_at.to_le_bytes());
        v.extend_from_slice(&(name_b.len() as u32).to_le_bytes());
        v.extend_from_slice(name_b);
        v.extend_from_slice(&dev);
        v
    }

    /// Issue a credential: the **account** identity vouches for `device`.
    pub fn issue(account: &Identity, device: &HavenId, name: &str, created_at: u64) -> Self {
        let account_id = account.public().node_id_bytes();
        let msg = Self::signing_bytes(&account_id, device, name, created_at);
        let sig = account.sign(&msg);
        Self { account_id, device: device.clone(), device_name: name.to_string(), created_at, sig }
    }

    /// Verify this credential against the **pinned account public key**.
    ///
    /// Fails if the credential names a different account than `account_pub`, or if the
    /// account's hybrid signature does not check out (tamper / forgery).
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("device credential: account id mismatch"));
        }
        let msg = Self::signing_bytes(&self.account_id, &self.device, &self.device_name, self.created_at);
        account_pub.verify(&msg, &self.sig)
    }

    /// The device's 32-byte node id (its routable id / device-list key).
    pub fn device_id(&self) -> [u8; 32] {
        self.device.node_id_bytes()
    }

    /// Wire encoding: `account_id(32) ‖ created_at(8) ‖ name_len(4) ‖ name ‖
    /// dev_len(4) ‖ device_bundle ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let dev = self.device.to_bytes();
        let name_b = self.device_name.as_bytes();
        let mut v = Vec::with_capacity(32 + 8 + 4 + name_b.len() + 4 + dev.len() + self.sig.len());
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.created_at.to_le_bytes());
        v.extend_from_slice(&(name_b.len() as u32).to_le_bytes());
        v.extend_from_slice(name_b);
        v.extend_from_slice(&(dev.len() as u32).to_le_bytes());
        v.extend_from_slice(&dev);
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let account_id = r.array32()?;
        let created_at = r.u64()?;
        let name = r.str_lp()?;
        let dev = r.bytes_lp()?;
        let device = HavenId::from_bytes(dev)?;
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("device credential: missing signature"));
        }
        Ok(Self { account_id, device, device_name: name, created_at, sig })
    }
}

/// The account's **signed, versioned device roster**. Contacts honor the highest `version`
/// they've seen whose signature chains to the pinned account key; this is the anti-rogue /
/// anti-rollback-of-revocation mechanism. A device is trusted iff it is in `devices` and
/// not in `revoked`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceList {
    /// The account this roster belongs to (its 32-byte node id).
    pub account_id: [u8; 32],
    /// Monotonic version — a verifier keeps the highest it has seen (rollback defense).
    pub version: u64,
    /// Unix seconds of this update (caller-supplied; advisory).
    pub updated_at: u64,
    /// Active device node ids.
    pub devices: Vec<[u8; 32]>,
    /// Revoked device node ids (kept so an old credential can't be replayed as live).
    pub revoked: Vec<[u8; 32]>,
    /// Hybrid signature by the **account** identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl DeviceList {
    fn signing_bytes(
        account_id: &[u8; 32],
        version: u64,
        updated_at: u64,
        devices: &[[u8; 32]],
        revoked: &[[u8; 32]],
    ) -> Vec<u8> {
        let mut v = Vec::with_capacity(LIST_DOMAIN.len() + 32 + 8 + 8 + 8 + (devices.len() + revoked.len()) * 32);
        v.extend_from_slice(LIST_DOMAIN);
        v.extend_from_slice(account_id);
        v.extend_from_slice(&version.to_le_bytes());
        v.extend_from_slice(&updated_at.to_le_bytes());
        v.extend_from_slice(&(devices.len() as u64).to_le_bytes());
        for d in devices {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&(revoked.len() as u64).to_le_bytes());
        for d in revoked {
            v.extend_from_slice(d);
        }
        v
    }

    /// Build and sign a device list with the account identity.
    pub fn signed(
        account: &Identity,
        version: u64,
        updated_at: u64,
        devices: Vec<[u8; 32]>,
        revoked: Vec<[u8; 32]>,
    ) -> Self {
        let account_id = account.public().node_id_bytes();
        let msg = Self::signing_bytes(&account_id, version, updated_at, &devices, &revoked);
        let sig = account.sign(&msg);
        Self { account_id, version, updated_at, devices, revoked, sig }
    }

    /// Verify the list against the pinned account key (id match + hybrid signature).
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("device list: account id mismatch"));
        }
        let msg = Self::signing_bytes(&self.account_id, self.version, self.updated_at, &self.devices, &self.revoked);
        account_pub.verify(&msg, &self.sig)
    }

    /// Is `device_id` currently authorized? (present and not revoked).
    pub fn is_authorized(&self, device_id: &[u8; 32]) -> bool {
        !self.revoked.contains(device_id) && self.devices.contains(device_id)
    }

    /// Merge rule across devices/replicas: **higher `version` wins**. Returns `true` if
    /// `other` is newer and was adopted. Both must already be `verify()`-ed by the caller.
    pub fn adopt_if_newer(&mut self, other: &DeviceList) -> bool {
        if other.account_id == self.account_id && other.version > self.version {
            *self = other.clone();
            true
        } else {
            false
        }
    }

    /// Wire encoding: `account_id(32) ‖ version(8) ‖ updated_at(8) ‖ n_dev(4) ‖ dev*32 ‖
    /// n_rev(4) ‖ rev*32 ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(32 + 16 + 8 + (self.devices.len() + self.revoked.len()) * 32 + self.sig.len());
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.updated_at.to_le_bytes());
        v.extend_from_slice(&(self.devices.len() as u32).to_le_bytes());
        for d in &self.devices {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&(self.revoked.len() as u32).to_le_bytes());
        for d in &self.revoked {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let account_id = r.array32()?;
        let version = r.u64()?;
        let updated_at = r.u64()?;
        let n_dev = r.u32()? as usize;
        let mut devices = Vec::with_capacity(n_dev);
        for _ in 0..n_dev {
            devices.push(r.array32()?);
        }
        let n_rev = r.u32()? as usize;
        let mut revoked = Vec::with_capacity(n_rev);
        for _ in 0..n_rev {
            revoked.push(r.array32()?);
        }
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("device list: missing signature"));
        }
        Ok(Self { account_id, version, updated_at, devices, revoked, sig })
    }
}

/// Minimal length-prefixed byte reader for the wire formats above.
struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Reader<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, i: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.i + n > self.b.len() {
            return Err(CoreError::Encoding("device wire: unexpected end of input"));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn array32(&mut self) -> Result<[u8; 32]> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn str_lp(&mut self) -> Result<String> {
        let b = self.bytes_lp()?;
        String::from_utf8(b.to_vec()).map_err(|_| CoreError::Encoding("device wire: invalid utf-8 name"))
    }
    fn rest(&self) -> &'a [u8] {
        &self.b[self.i..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn id(seed: u8) -> Identity {
        Identity::from_seed(&[seed; 32])
    }

    #[test]
    fn issue_then_verify_against_pinned_account() {
        let account = id(1);
        let device = id(2);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1_700_000_000);
        // A contact who pinned the account key trusts the device.
        cred.verify(&account.public()).expect("valid credential must verify");
        assert_eq!(cred.device_id(), device.public().node_id_bytes());
    }

    #[test]
    fn credential_rejected_for_wrong_account() {
        let account = id(1);
        let imposter = id(9);
        let device = id(2);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1);
        // Pinning a different account key must reject it (id mismatch / bad sig).
        assert!(cred.verify(&imposter.public()).is_err());
    }

    #[test]
    fn credential_tamper_is_detected() {
        let account = id(1);
        let device = id(2);
        let mut cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1);
        cred.device_name = "Attacker's laptop".into(); // forge the label
        assert!(cred.verify(&account.public()).is_err());
    }

    #[test]
    fn credential_roundtrips_through_wire() {
        let account = id(7);
        let device = id(8);
        let cred = DeviceCredential::issue(&account, &device.public(), "MacBook Pro", 42);
        let back = DeviceCredential::from_bytes(&cred.to_bytes()).expect("decode");
        assert_eq!(cred.to_bytes(), back.to_bytes(), "wire round-trip must be stable");
        assert_eq!(cred.device_name, back.device_name);
        assert_eq!(cred.created_at, back.created_at);
        back.verify(&account.public()).expect("decoded credential still verifies");
    }

    #[test]
    fn device_list_signs_verifies_and_gates_authorization() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let lost = id(4).public().node_id_bytes();

        let list = DeviceList::signed(&account, 2, 100, vec![phone, mac], vec![lost]);
        list.verify(&account.public()).expect("valid list verifies");
        assert!(list.is_authorized(&phone));
        assert!(list.is_authorized(&mac));
        assert!(!list.is_authorized(&lost), "revoked device must not be authorized");
        let unknown = id(5).public().node_id_bytes();
        assert!(!list.is_authorized(&unknown), "unlisted device must not be authorized");
    }

    #[test]
    fn device_list_rejects_foreign_signer_and_tamper() {
        let account = id(1);
        let imposter = id(9);
        let phone = id(2).public().node_id_bytes();
        let mut list = DeviceList::signed(&account, 1, 0, vec![phone], vec![]);
        assert!(list.verify(&imposter.public()).is_err(), "foreign account must not verify");
        // Splice in an extra device without re-signing → must fail.
        list.devices.push(id(6).public().node_id_bytes());
        assert!(list.verify(&account.public()).is_err(), "tampered roster must not verify");
    }

    #[test]
    fn device_list_roundtrips_through_wire() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let lost = id(4).public().node_id_bytes();
        let list = DeviceList::signed(&account, 5, 999, vec![phone, mac], vec![lost]);
        let back = DeviceList::from_bytes(&list.to_bytes()).expect("decode");
        assert_eq!(list, back);
        back.verify(&account.public()).expect("decoded list still verifies");
    }

    #[test]
    fn higher_version_wins_on_merge() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let mut v1 = DeviceList::signed(&account, 1, 0, vec![phone], vec![]);
        let v3 = DeviceList::signed(&account, 3, 10, vec![phone, mac], vec![]);
        assert!(v1.adopt_if_newer(&v3), "newer version must be adopted");
        assert_eq!(v1.version, 3);
        assert!(v1.is_authorized(&mac));
        // An older replay must NOT be adopted (rollback defense).
        let stale = DeviceList::signed(&account, 2, 5, vec![phone], vec![mac]);
        assert!(!v1.adopt_if_newer(&stale));
        assert_eq!(v1.version, 3);
    }
}
