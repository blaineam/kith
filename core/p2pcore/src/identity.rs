//! On-device identity. No phone number, no email, no PII — an account is a keypair.
//!
//! An identity bundles three things:
//!   * an **Ed25519** signing key — long-term identity & message authentication,
//!     and the 32-byte public half doubles as the routable node id ([`KithId`]).
//!   * an **X25519** static secret — the classical half of the hybrid KEM.
//!   * an **ML-KEM-768** decapsulation key — the post-quantum half of the KEM.
//!
//! The Ed25519 key is the stable, compact public address that goes in links/QRs.
//! The bulky ML-KEM public key (1184 B) is *not* shoved into a URL — it travels via
//! discovery (a signed DHT record keyed by the Ed25519 id), and a short hash of the
//! full bundle ([`KithId::verification`]) lets a dialer detect tampering once fetched.
//!
//! NOTE: Ed25519 is the classical signature for now. Hybrid PQ **signatures**
//! (Ed25519 + ML-DSA, FIPS 204) are the next crypto addition; the seam is here
//! (`sign`/`verify` are the only call sites) so adding ML-DSA is local.

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use ml_kem::{Encoded, EncodedSizeUser, KemCore, MlKem768};
use rand::rngs::OsRng;
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret as XStaticSecret};

use crate::{CoreError, Result};

/// Concrete ML-KEM-768 key types (the trait exposes them as associated types).
pub(crate) type EncapKey = <MlKem768 as KemCore>::EncapsulationKey;
pub(crate) type DecapKey = <MlKem768 as KemCore>::DecapsulationKey;

const ED_LEN: usize = 32;
const X_LEN: usize = 32;
const MLKEM_EK_LEN: usize = 1184;

/// The public, shareable identity of a peer.
///
/// `signing` (Ed25519, 32 B) is the compact routable id used in links and as the
/// future iroh `NodeId`. `kem_x` (32 B) and `kem_pq` (1184 B) are the recipient's
/// hybrid-KEM public material, normally delivered via discovery rather than a URL.
#[derive(Clone)]
pub struct KithId {
    pub signing: VerifyingKey,
    pub kem_x: XPublicKey,
    pub kem_pq: EncapKey,
}

impl KithId {
    /// The 32-byte routable id (Ed25519 public key). Stable for the life of the
    /// identity; this is what a `kith://u/<id>` link encodes.
    pub fn node_id_bytes(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }

    /// A short, order-independent fingerprint of the *entire* hybrid public bundle.
    /// Carried in a link's `#fragment` so a dialer can confirm the keys fetched from
    /// discovery match the keys the link's author intended (tamper / MITM check).
    pub fn verification(&self) -> [u8; 16] {
        let ek = self.kem_pq.as_bytes();
        let mut h = blake3::Hasher::new();
        h.update(b"kith-id-v1");
        h.update(&self.signing.to_bytes());
        h.update(self.kem_x.as_bytes());
        h.update(&ek[..]);
        let full = h.finalize();
        let mut out = [0u8; 16];
        out.copy_from_slice(&full.as_bytes()[..16]);
        out
    }

    /// Verify a signature made by this identity's signing key.
    pub fn verify(&self, msg: &[u8], sig: &[u8]) -> Result<()> {
        let sig = ed25519_dalek::Signature::from_slice(sig)
            .map_err(|_| CoreError::Crypto("bad signature length"))?;
        self.signing
            .verify(msg, &sig)
            .map_err(|_| CoreError::Crypto("signature verification failed"))
    }

    /// Serialize the full public bundle (for publishing to discovery).
    /// Layout: ed25519(32) || x25519(32) || ml-kem-ek(1184).
    pub fn to_bytes(&self) -> Vec<u8> {
        let ek = self.kem_pq.as_bytes();
        let mut v = Vec::with_capacity(ED_LEN + X_LEN + MLKEM_EK_LEN);
        v.extend_from_slice(&self.signing.to_bytes());
        v.extend_from_slice(self.kem_x.as_bytes());
        v.extend_from_slice(&ek[..]);
        v
    }

    /// Inverse of [`KithId::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        if b.len() != ED_LEN + X_LEN + MLKEM_EK_LEN {
            return Err(CoreError::Encoding("identity bundle wrong length"));
        }
        let signing = VerifyingKey::from_bytes(b[..ED_LEN].try_into().unwrap())
            .map_err(|_| CoreError::Crypto("bad ed25519 key"))?;
        let kem_x = XPublicKey::from(<[u8; 32]>::try_from(&b[ED_LEN..ED_LEN + X_LEN]).unwrap());
        let ek_encoded = Encoded::<EncapKey>::try_from(&b[ED_LEN + X_LEN..])
            .map_err(|_| CoreError::Crypto("bad ml-kem key length"))?;
        let kem_pq = EncapKey::from_bytes(&ek_encoded);
        Ok(Self { signing, kem_x, kem_pq })
    }
}

/// A full identity including the private keys. Lives in the Secure Enclave /
/// Keychain on Apple platforms; never leaves the device.
pub struct Identity {
    signing: SigningKey,
    kem_x: XStaticSecret,
    kem_pq_dk: DecapKey,
    kem_pq_ek: EncapKey,
}

impl Identity {
    /// Generate a brand-new identity from the OS CSPRNG.
    pub fn generate() -> Self {
        let mut rng = OsRng;
        let signing = SigningKey::generate(&mut rng);
        let kem_x = XStaticSecret::random_from_rng(&mut rng);
        let (kem_pq_dk, kem_pq_ek) = MlKem768::generate(&mut rng);
        Self { signing, kem_x, kem_pq_dk, kem_pq_ek }
    }

    /// The shareable public identity.
    pub fn public(&self) -> KithId {
        KithId {
            signing: self.signing.verifying_key(),
            kem_x: XPublicKey::from(&self.kem_x),
            kem_pq: self.kem_pq_ek.clone(),
        }
    }

    /// Sign a message with the long-term identity key.
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        self.signing.sign(msg).to_bytes().to_vec()
    }

    // --- accessors used by the KEM in `crypto.rs` ---
    pub(crate) fn kem_x_secret(&self) -> &XStaticSecret {
        &self.kem_x
    }
    pub(crate) fn kem_pq_decap(&self) -> &DecapKey {
        &self.kem_pq_dk
    }
}
