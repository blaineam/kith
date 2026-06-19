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

## ✅ M1b — Networking spine (first transfer working)

A real photo moves peer-to-peer as hybrid-PQ ciphertext over QUIC, verified
byte-identical. Runnable: `cargo run -p kith-demo` (see `core/demo/`).

- **iroh 1.0** integrated: two endpoints, dial-by-address, real QUIC streams,
  relays disabled (runs fully offline/local)
- `p2pcore` crypto carried over the wire end-to-end (X25519+ML-KEM-768 → AES-256-GCM);
  the QUIC stream only ever holds ciphertext, verified by BLAKE3 match on both ends
- On-wire framing for `Encapsulation` (eph ‖ pq_ct ‖ sealed)
- Bonus: iroh 1.0 ships `X25519MLKEM768` PQ-transport examples → confirms D4's
  PQ transport is available to switch on later

### Remaining for M1b polish
- Integrate **iroh-blobs** for content-addressed (BLAKE3) chunked, **resumable**,
  multi-source transfer (replaces the one-shot read for large/100 GB files)
- Wrap iroh behind the `Transport` trait + path-selector
- mDNS/LAN discovery + relay fallback (currently dials an explicit address)
- True two-device run (currently two endpoints on one host over loopback)

## ✅ M1c — Hybrid PQ signatures (DONE)

**ML-DSA-65** (FIPS 204) added alongside Ed25519 in `identity.rs`. Signatures are
now `ed25519(64) ‖ ml-dsa(rest)`; both halves must verify. Tests prove each half is
enforced (corrupting either fails). "Hybrid PQ everywhere" is complete — KEM *and*
signatures. 6 core tests green.

## ⏭️ M2 — Groups, posts, comments, reactions

- Integrate **`mls-rs`** with a hybrid-PQ ciphersuite; 1:1 = 2-member group
- Posts/comments/reactions as MLS application messages
- **Edit & unsend** as signed ordered events: edit → "Edited" badge, unsend →
  "Message unsent", both with client-enforced timers (see DECISIONS D11)
- **Scheduled "send later"** (D17, `SCHEDULED-MESSAGES.md`): queue plaintext, seal+send
  at T from an awake device (always-on device = primary firer); send-time + optional
  display-time modes; editable/cancelable until fired *(exact-time relies on M2b)*
- Contact approval + blocking (client-side enforcement)

## ⏭️ M2b — Multi-device (one account, many devices)

- Account identity key + per-device keys + signed **device credentials** (D16)
- Device linking: QR/code + short-verification-phrase + add device as MLS leaf
- Receive on all devices (each device = a leaf); revoke a device via Remove commit
- **Always-on device as personal store-and-forward** (ordered MLS backlog cache)
- Signed device-list + "new device linked" transparency notices
- See `MULTI-DEVICE.md`

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
