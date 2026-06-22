# Architecture

## Layer cake

```
┌─────────────────────────────────────────────────────────────┐
│  UI                                                           │
│   • Apple: SwiftUI app (iOS / macOS)  ── UniFFI ─┐            │
│   • Web/Android: static page          ── WASM ───┤            │
├──────────────────────────────────────────────────┼───────────┤
│  p2pcore  (Rust — ONE implementation for both)   ▼           │
│   identity   hybrid-PQ crypto   links   groups(MLS)   blobs   │
│                         │                                     │
│   transport seam  ──►  path-selector: BLE → localWiFi → relay │
├──────────────────────────────────────────────────────────────┤
│  Network                                                      │
│   BLE (CoreBluetooth) · LAN/p2p WiFi (iroh) · relay (iroh)    │
│   discovery: signed records on the mainline DHT (no directory)│
└──────────────────────────────────────────────────────────────┘
```

**Invariant:** everything above the transport seam deals only in hybrid-PQ
encrypted bytes. The transport is interchangeable; the crypto is transport-blind.

## The core (`core/p2pcore`)

| Module | Responsibility | Status |
|---|---|---|
| `identity` | On-device keypair (Ed25519 + X25519 + ML-KEM-768); public `HavenId`; routable node id; tamper-check hash | ✅ implemented + tested |
| `crypto` | Hybrid-PQ KEM (X25519 + ML-KEM-768 → HKDF) and AES-256-GCM seal/open | ✅ implemented + tested |
| `link` | `haven://` and `https://` reach-me links/QR; parse, verify, MITM check | ✅ implemented + tested |
| `transport` | `Path` ladder + `select()` + `Transport` trait seam | ✅ seam + selector tested |
| `groups` (MLS) | `mls-rs` groups with hybrid-PQ ciphersuite; posts/comments/reactions as group messages | ⏳ next |
| `discovery` | Publish/resolve signed address records on the DHT | ⏳ next |
| `blobs` | Content-addressed (BLAKE3) chunked transfer; resumable, multi-source | ⏳ next |
| FFI | UniFFI (Swift) + wasm-bindgen (web) | ⏳ next |

## How a photo gets from A to B (target flow)

1. **A** has **B**'s `HavenId` (from a prior QR/link approval). A is a member of the
   shared MLS group with B.
2. A optionally **auto-optimizes** the media (HEVC/HEIF/AAC) or sends the original
   losslessly if chosen. The file is chunked and content-addressed (BLAKE3).
3. A derives a content key for B's group via MLS, **seals** the chunks (AES-256-GCM
   under a hybrid-PQ-derived key), and addresses them to B's node id.
4. The **path-selector** picks the route: Bluetooth if nearby and small; local WiFi
   for bulk; relay only if nothing local is reachable. Discovery resolves B's
   current address from the DHT by B's node id.
5. **B** pulls/receives the sealed chunks over whatever path won, verifies each
   chunk hash, decrypts, and (if B was offline) the chunks were held by the fallback
   chain: sender-online → group-gossip cache → B's own storage pin.

## The offline-delivery fallback chain

Because there's no central store, large content for an offline peer falls through:

1. **Sender stays online** — direct, zero cost.
2. **Group-gossip cache** — other online group members opportunistically cache &
   forward the *encrypted* chunks for the offline member.
3. **BYO storage pin** — the recipient optionally points Haven at their *own* iCloud /
   S3 / NAS; encrypted blobs park there until pulled.

## Clients

- **Apple (native):** full transport ladder (BLE + p2p WiFi + relay), Secure Enclave
  key storage, MusicKit, on-device `SensitiveContentAnalysis`.
- **Web / Android-web:** static page, keys in WebCrypto/IndexedDB, same `p2pcore`
  compiled to WASM, transport limited to WebRTC/relay (no BLE/WiFi-direct in
  browsers). MusicKit JS for music.

## Relays (`relay/`)

Two roles, both federated, swappable, and runnable by anyone — never a central
service. Full detail in [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md).

- **Connection relay** — a stateless dumb pipe that forwards encrypted QUIC/WebRTC
  traffic between live peers that can't NAT-punch directly. Never decrypts or stores.
- **Storage relay ("mailbox")** — mostly object storage (S3/R2/B2/GCS) + a thin
  broker, holding E2E-encrypted blobs for offline peers (rung 3 of the fallback
  chain). This is the BYO / quota'd-bucket model — the user's own storage, or any
  community member's, never required to be yours.

Both run with **hardened, no-log, identity-blind defaults**; IPs are never logged or
linked to identities, with an opt-in onion mode for full IP hiding. A
**`haven-relay`** deployment tool stands either role up on most clouds in one command.
