# Haven — security model & threat model

Haven is a peer-to-peer, end-to-end-encrypted, post-quantum social network. **Nothing is sent to the
developer; nothing is logged.** Content travels only between the people in a user's circles — directly
over Bluetooth/Wi-Fi/iroh P2P, or store-and-forwarded through a relay/S3 mailbox that one of the
circle's own members runs. Every relay and server is **blind**: it holds only ciphertext.

This document records what Haven protects, how, and the limits — including the two features that are
**privacy deterrents, not cryptographic guarantees**. It reflects the post-audit state (2026-06).

## Cryptography

- **Hybrid post-quantum** throughout: key establishment is X25519 + ML-KEM-768 (FIPS 203), signatures
  are Ed25519 + ML-DSA-65, AEAD is AES-256-GCM, KDF is HKDF-SHA256. Both halves must break to lose
  security, so Haven is never weaker than classical and resists "harvest-now-decrypt-later". The KEM
  derivation binds the full transcript (ephemeral key, ciphertext, recipient keys).
- **Group keying (sender keys + epochs)** — see `GROUP-KEYING.md`. Each member seals their posts under
  a rotating epoch key distributed to the current members via the hybrid KEM. Removing/blocking a
  member rotates the epoch so the removed node **cannot decrypt content posted afterward** —
  cryptographic revocation, not advisory. Old epoch keys are pruned, giving **bounded forward
  secrecy**: a later key compromise can't decrypt older wire/relay ciphertext.
- **Authentication**: every event is signed and the signer is bound to the event author and circle
  epoch; push notifications are signed (the receiver verifies the sender); push registration is signed
  (the worker verifies the device belongs to the identity). Signatures are domain-separated; there is
  no general signing oracle.
- **At rest**: the master seed is wrapped by the Secure Enclave; the decrypted social state, media, and
  scheduled queue use file-protection so they're unreadable on a locked/forensic device.

## What a relay / server can and cannot do

- **Cannot** read content, contacts, keys, or notification text — everything it stores or forwards is
  sealed; the push worker only forwards opaque ciphertext.
- **Cannot be enumerated by strangers**: the relay enforces **circle-membership authorization** — a
  circle's mailbox (read, write, and list) is served only to that circle's members (and its sibling
  relays, for replication). A node that merely learns the relay's id can no longer fetch or enumerate a
  circle's blobs. Self-sync slots are likewise access-controlled to their owning account. (Standalone
  self-host relays stay permissive until configured; the apps configure membership automatically.)
- **Can** see **limited metadata**: connection timing, IP↔node-id mappings (via the iroh/n0 public
  discovery the app uses for NAT traversal), and — for a member-run relay, which knows its own circle's
  config anyway — the random circle UUIDs in key paths. Content, contacts, and keys remain sealed. A
  user with a stricter threat model can run their own relay/discovery. *(Core groundwork also exists for
  opaque/HMAC'd per-member key prefixes, for the case of a non-member-operated relay.)*

## Identity & control

- The user can **roll their identity** at any time (a true reset that abandons the old social graph),
  **remove** any member from a circle, or **block** them. Block/remove are now cryptographically
  enforced going forward (epoch rotation), not just local filtering.
- There is **no content moderation or reporting** by design, and it is not possible: content is E2EE
  between community members, the developer has no access to it and logs nothing, so there is nothing
  to moderate or report to. Users curate their own circles (who they approve, remove, and block).

## Deterrents, not guarantees (do not over-rely)

- **Secret messages** (screenshot-protected): the recipient is handed the plaintext like any message;
  the "secret" rendering is a same-device, same-client UX deterrent against shoulder-surfing and
  casual screenshots. A determined recipient (or a modified client) can read it normally. It is **not**
  protection *against the recipient*.
- **Biometric circle locks**: gate the in-app UI for a circle. They are a privacy convenience, not an
  access-control boundary for a fully-compromised, unlocked device.

## Third-party services

- **Apple Push Notification service (APNs)** via a self-hosted **Cloudflare Worker** push server — the
  worker is blind (encrypted payload; the on-device Notification Service Extension decrypts).
- **iroh / number0 (n0)** public discovery + relay infrastructure for P2P NAT traversal (metadata only;
  no content).
- **The user's own** relay binary and/or S3-compatible bucket (their infrastructure, blind storage).
- **WebRTC** (DTLS-SRTP) for calls; STUN for connectivity. No analytics, telemetry, crash reporters,
  or ad SDKs — verified by audit.

## Export compliance

Standard, published algorithms only; `ITSAppUsesNonExemptEncryption = NO`. The app is submitted to the
relevant export bureaus; no proprietary cryptography.
