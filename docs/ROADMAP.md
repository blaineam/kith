# Roadmap

Milestones are ordered so each one proves the hardest unproven thing next, and every
step is verifiable.

## ✅ M1a — Cryptographic spine (DONE)

Real, unit-tested hybrid post-quantum identity, key establishment, and the reach-me
link system, all verifiable on the host with no devices or network.

- On-device identity: Ed25519 + X25519 + ML-KEM-768 (`identity.rs`)
- Hybrid-PQ KEM (X25519 + ML-KEM-768 → HKDF) + AES-256-GCM (`crypto.rs`)
- Reach-me links (`kith://` + `https://`), parse/verify/MITM-check (`link.rs`)
- Transport `Path` ladder + selector seam (`transport.rs`)
- 5 integration tests green (`tests/spine.rs`)

## ⏭️ M1b — Networking spine

Two devices actually exchange an encrypted blob, dial-by-key.

- Integrate **iroh**: dial-by-node-id, mDNS/LAN discovery, relay fallback
- Integrate **iroh-blobs**: content-addressed (BLAKE3) chunked, resumable transfer
- Wrap iroh behind the `Transport` trait; finalize on-wire framing for `Encapsulation`
- **Prereq:** confirm a runnable relay (default or self-hosted) for the relay rung
- *Proof:* host-loopback + (later) two-device send of a sealed photo

## ⏭️ M1c — Hybrid PQ signatures

Add **ML-DSA** (FIPS 204) alongside Ed25519 at the `sign`/`verify` seam in
`identity.rs`. Completes "hybrid PQ everywhere."

## ⏭️ M2 — Groups, posts, comments, reactions

- Integrate **`mls-rs`** with a hybrid-PQ ciphersuite; 1:1 = 2-member group
- Posts/comments/reactions as MLS application messages
- **Edit & unsend** as signed ordered events: edit → "Edited" badge, unsend →
  "Message unsent", both with client-enforced timers (see DECISIONS D11)
- Contact approval + blocking (client-side enforcement)

## ⏭️ M3 — Apple app

- `rustup` + iOS targets, **UniFFI** bindings, build the XCFramework
- SwiftUI app: identity onboarding, QR + link, receive a photo, Secure Enclave keys
- **Prereqs to install:** `rustup` (+ `aarch64-apple-ios`, `aarch64-apple-ios-sim`),
  `uniffi-bindgen`

## ⏭️ M4 — Bluetooth + local-WiFi transport

- `BleTransport` (CoreBluetooth) for the rung-1 path; airplane-mode transfer demo
- Peer-to-peer WiFi for bulk (Network.framework / AWDL)

## ⏭️ M5 — Offline delivery & large files (zero operator cost — D15)

- Fallback chain: sender-online → group-gossip cache → **sender's own iCloud**
  (private CloudKit + `CKShare`) or **BYO bucket**, see `RELAY-AND-DEPLOY.md`
- Apple-first; cross-platform offline via both-online or sender BYO bucket
- Auto-optimize (HEVC/HEIF/AAC) vs. lossless-original toggle; up to ~100 GB
- Opt-in onion/proxy mode for full IP hiding
- *(No quota/blind-token/subscription work — deleted per D15)*

## ⏭️ M5b — `kith-relay` deployment tool (optional / community)

- For volunteers (or the operator later) who want guaranteed relay reliability —
  **never required**, no mandatory monthly cost
- Single static Rust binary + container image for both relay roles
- OpenTofu modules: AWS / GCP / Azure / Hetzner / Fly / DO / Cloudflare-R2 / Oracle /
  bare VPS; `kith-relay deploy --provider … --role connection|storage|both`
- Hardened no-log defaults baked in and hard to disable; self-registers to discovery

## ⏭️ M6 — Web/Android client

- `wasm-pack` build of `p2pcore`; static page; WebCrypto/IndexedDB key storage
- WebRTC transport + relay; **prereq:** `wasm-pack`

## ⏭️ M7 — Music, calls, safety polish

- Apple Music: MusicKit (native) + MusicKit JS (web), share-by-reference
- Calls: WebRTC mesh (≤5)
- On-device `SensitiveContentAnalysis` guards; per-group toggles

## ⏭️ M8 — More clients (all reuse `p2pcore`)

- **Android native** via UniFFI → Kotlin/JNI (until then, the WASM web client covers Android)
- **Windows / Linux desktop** via Tauri (reuses the web UI) + native Rust core
- **macOS** ships alongside iOS from the SwiftUI codebase (near-free)
- **Apple Watch** companion (scoped: messages/photos/reactions/notifications/quick
  replies/audio; *not* bulk video/large files) — see DECISIONS D13

## ⏭️ M9 — Launch surface (pre-submission)

- **Marketing page** at `blaineam.github.io` repo under `/apps/kith/` — only once
  close to App Store submission
- **Screenshot automation**: wire Kith into the shared capture → **Monkr-frame** →
  ASC pipeline in `_shared/` (depends on Monkr `/headless`), via the **rocket** flow,
  matching the existing app-portfolio screenshot style
- CHANGELOG + docs/pages-site + README kept current on every push

## Toolchain prerequisites (this machine)

Installed: Rust 1.95 (Homebrew), cargo, Xcode 26.5, XcodeGen, swift.
Still needed (when their milestone arrives):
- `rustup` + iOS targets — for M3 (Homebrew Rust can't cross-compile to iOS)
- `uniffi-bindgen` — for M3
- `wasm-pack` — for M6
