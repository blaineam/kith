//! Reach-me links & QR tickets.
//!
//! A link is a permanent, server-free pointer to a person. It carries only:
//!   * the 32-byte routable id (Ed25519 public key) — used to *find* the peer's
//!     current network address via decentralized discovery (signed DHT record), and
//!   * a 16-byte verification hash of the peer's full hybrid key bundle, kept in the
//!     URL **fragment** so it is never sent to any web server.
//!
//! The bulky ML-KEM public key is intentionally *not* in the link — it is fetched
//! from discovery, then checked against this verification hash to detect tampering.
//!
//! Two surface forms, same payload:
//!   * `kith://u/<base32-id>#<base32-verify>`            (deep link / QR)
//!   * `https://<domain>/u/<base32-id>#<base32-verify>`  (a link on your website,
//!     opens the app via Universal Link, else the static web client)
//!
//! Security note: a link shared over the internet is a weaker trust anchor than an
//! in-person QR scan, so using one only ever creates a *pending* request that the
//! owner must approve — and the verification hash lets both sides confirm the keys
//! match before trusting them.

use data_encoding::BASE32_NOPAD;

use crate::identity::KithId;
use crate::{CoreError, Result};

/// The decoded contents of a reach-me link.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct KithLink {
    /// 32-byte Ed25519 routable id.
    pub id: [u8; 32],
    /// 16-byte tamper-check over the full hybrid identity bundle.
    pub verification: [u8; 16],
}

impl KithLink {
    /// Build a link from a peer's public identity.
    pub fn from_identity(id: &KithId) -> Self {
        Self {
            id: id.node_id_bytes(),
            verification: id.verification(),
        }
    }

    /// `kith://u/<id>#<verify>` — the deep-link / QR form.
    pub fn to_uri(&self) -> String {
        format!(
            "kith://u/{}#{}",
            BASE32_NOPAD.encode(&self.id),
            BASE32_NOPAD.encode(&self.verification),
        )
    }

    /// `https://<domain>/u/<id>#<verify>` — the website form (Universal Link).
    pub fn to_web(&self, domain: &str) -> String {
        format!(
            "https://{}/u/{}#{}",
            domain.trim_end_matches('/'),
            BASE32_NOPAD.encode(&self.id),
            BASE32_NOPAD.encode(&self.verification),
        )
    }

    /// Parse either form. The fragment (verification) is required — a link without
    /// it can't be checked against discovery, so we reject it rather than trust blindly.
    pub fn parse(s: &str) -> Result<Self> {
        let s = s.trim();
        let idx = s
            .find("/u/")
            .ok_or(CoreError::BadLink("missing /u/ segment"))?;
        let rest = &s[idx + 3..];

        let (id_part, frag) = rest
            .split_once('#')
            .ok_or(CoreError::BadLink("missing #verification fragment"))?;

        // The id ends at any path/query delimiter.
        let id_b32 = id_part.split(['/', '?']).next().unwrap_or(id_part);
        let frag_b32 = frag.split(['/', '?', '&']).next().unwrap_or(frag);

        let id_bytes = BASE32_NOPAD
            .decode(id_b32.as_bytes())
            .map_err(|_| CoreError::BadLink("id is not valid base32"))?;
        if id_bytes.len() != 32 {
            return Err(CoreError::BadLink("id must be 32 bytes"));
        }
        let verify_bytes = BASE32_NOPAD
            .decode(frag_b32.as_bytes())
            .map_err(|_| CoreError::BadLink("verification is not valid base32"))?;
        if verify_bytes.len() != 16 {
            return Err(CoreError::BadLink("verification must be 16 bytes"));
        }

        let mut id = [0u8; 32];
        id.copy_from_slice(&id_bytes);
        let mut verification = [0u8; 16];
        verification.copy_from_slice(&verify_bytes);
        Ok(Self { id, verification })
    }

    /// Confirm a full identity fetched from discovery matches what this link promised.
    /// This is the MITM / tamper check.
    pub fn matches(&self, fetched: &KithId) -> bool {
        fetched.node_id_bytes() == self.id && fetched.verification() == self.verification
    }
}
