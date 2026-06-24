# Roadmap

Milestones are ordered so each one proves the hardest unproven thing next, and every
step is verifiable.

## ✅ M1a — Cryptographic spine (DONE)

Real, unit-tested hybrid post-quantum identity, key establishment, and the reach-me
link system, all verifiable on the host with no devices or network.

- On-device identity: Ed25519 + X25519 + ML-KEM-768 (`identity.rs`)
- Hybrid-PQ KEM (X25519 + ML-KEM-768 → HKDF) + AES-256-GCM (`crypto.rs`)
- Reach-me links (`haven://` + `https://`), parse/verify/MITM-check (`link.rs`)
- Transport `Path` ladder + selector seam (`transport.rs`)
- 5 integration tests green (`tests/spine.rs`)

## ✅ M1b — Networking spine (first transfer working)

A real photo moves peer-to-peer as hybrid-PQ ciphertext over QUIC, verified
byte-identical. Runnable: `cargo run -p haven-demo` (see `core/demo/`).

- **iroh 1.0** integrated: two endpoints, dial-by-address, real QUIC streams,
  relays disabled (runs fully offline/local)
- `p2pcore` crypto carried over the wire end-to-end (X25519+ML-KEM-768 → AES-256-GCM);
  the QUIC stream only ever holds ciphertext, verified by BLAKE3 match on both ends
- On-wire framing for `Encapsulation` (eph ‖ pq_ct ‖ sealed)
- Bonus: iroh 1.0 ships `X25519MLKEM768` PQ-transport examples → confirms D4's
  PQ transport is available to switch on later

### Reusable networking node ✅
- **`haven-net`** crate: a `Node` (iroh) that listens + dials and exchanges opaque
  payloads. Test: two nodes exchange a real `p2pcore::social::SealedEnvelope` over
  QUIC and the recipient opens the post with their own keys.

### Remaining for M1b polish
- **Async FFI** so the iOS app drives a `Node` (connect, send, receive callbacks)
- **Discovery** (iroh n0 / DHT) so an invite link's node id resolves to a live
  address over the internet (currently direct/LAN address)
- Integrate **iroh-blobs** for content-addressed, **resumable**, multi-source
  transfer (large/100 GB files)
- Wrap behind the `Transport` trait + path-selector; relay fallback
- True two-device run (currently two nodes on one host)

## ✅ M1c — Hybrid PQ signatures (DONE)

**ML-DSA-65** (FIPS 204) added alongside Ed25519 in `identity.rs`. Signatures are
now `ed25519(64) ‖ ml-dsa(rest)`; both halves must verify. Tests prove each half is
enforced (corrupting either fails). "Hybrid PQ everywhere" is complete — KEM *and*
signatures. 6 core tests green.

## ✅ M2 — Groups, posts, comments, reactions (DONE)

- ✅ **Social engine** (`p2pcore::social`): circles, posts, stories, messages, comments,
  reactions, edit, unsend, DMs, media + music refs — events sealed E2E to all members
  (fresh content key + per-member hybrid-KEM wrap), hybrid-signed; `build_feed` timeline
  reducer with author-authorized edit/unsend.
- ✅ **Multi-circle feed in the app**, networked between real devices: compose, react,
  comment, edit, unsend flow peer-to-peer (verified device-to-device).
- ✅ **Edit & unsend** as signed ordered events: edit → "Edited" badge, unsend →
  "Message unsent" (see DECISIONS D11).
- ✅ Contact approval + blocking (client-side enforcement); per-circle privacy
  (Spotlight + Face ID lock).
- ⏭️ Harden to **`mls-rs`** with a hybrid-PQ ciphersuite (forward secrecy / efficient
  membership) — the current layer is multi-recipient PKE, not yet MLS.
- ⏭️ **Scheduled "send later"** (D17, `SCHEDULED-MESSAGES.md`): queue plaintext, seal+send
  at T from an awake device (always-on device = primary firer); send-time + optional
  display-time modes; editable/cancelable until fired *(designed; relies on M2b)*.

## 🟡 M2b — Multi-device & multi-identity

- ✅ **Multi-identity switcher**: keep a roster of every identity you've used and jump
  between them; **per-identity profiles** (name/photo/emoji/bio/link) namespaced by
  node-id (`AccountStore.roster()`, `Profile.swift`).
- ✅ **Move-to-device**: transfer code + QR (`haven-seed:…`) to adopt an identity on a
  new device; **iCloud-Keychain backup/restore** of identity history (active seed stays
  device-only; history is synced + recoverable).
- ✅ **Multi-token push**: the relay holds multiple device tokens per identity, so every
  linked device gets pushes; authored events self-sync via a silent push to your own
  devices.
- 🟡 **Per-device keys + signed device credentials (D16)** — building in phases:
  - ✅ **Phase 1: trust layer** in core (`p2pcore::device`): per-device keypair,
    account-signed `DeviceCredential`, versioned signed `DeviceList` (add/revoke,
    higher-version-wins, rollback-defended), verified against the pinned account key —
    MLS-independent, unit-tested.
  - 🟡 **Phase 3: convergence engine** in core (`p2pcore::selfsync`): an `AccountState`
    CRDT (LWW roster/contacts/profile/settings/blocked + grow-only read cursors) with a
    commutative/associative/idempotent merge, self-encrypted via a seed-derived key only
    the user's devices can derive — concurrent edits provably converge. Unit-tested.
    Remaining: mailbox channel + sync loop + FFI + client wiring.
  - ⏭️ Phase 2 enrollment + UI · Phase 4 live device-to-device delivery ·
    Phase 5 MLS leaf/commit hardening (forward + post-compromise secrecy; gated on MLS).
  - See `MULTI-DEVICE.md` → *Implementation phases*.
- ⏭️ **Always-on device as personal store-and-forward** (ordered backlog cache; Phase 4).
- See `MULTI-DEVICE.md`

## ✅ M3 — Apple app (DONE, on TestFlight)

iOS + macOS (Mac Catalyst) SwiftUI app on the real Rust core via a UniFFI XCFramework.
On TestFlight and used device-to-device over the internet.

- ✅ `rustup` + iOS targets, **UniFFI** crate `haven_ffi`, `HavenFFI.xcframework`
  (device + sim + Mac Catalyst + native-macOS slices), `build-rust-xcframework.sh`
- ✅ On-device identity, `haven://` QR + reach-me link, Keychain-persisted master seed,
  on-device hybrid-PQ self-test (covered by `HavenUITests`)
- ✅ Networked feed/DMs/media over iroh on real devices; circles; stories; calls
- ⏭️ Secure Enclave-backed key storage (currently Keychain)

## ✅ M4 — Nearby (Bluetooth + local-WiFi) transport (DONE)

- ✅ Nearby offline transport via **MultipeerConnectivity** (Bluetooth + local Wi-Fi):
  posts, DMs, and handshakes flow over a nearby mesh when peers are off-internet.
- ✅ **Mesh relay** (frame type 9): an internet-connected nearby phone forwards a sealed
  frame it can't read toward its destination (cleartext routing header, E2E payload,
  ttl-bounded, msg-id dedup).

## 🟡 M5 — Offline delivery & large files (zero operator cost — D15)

- ✅ **Store-and-forward mailbox**: circle-sealed blobs to an S3-compatible bucket; a
  **pre-signed-URL** model (`PresignStore`) so members never hold bucket credentials;
  per-circle mailbox config (frame 14). "Volunteer as tribute" — a member re-serves
  circle-sealed media P2P.
- ✅ **Chunked media transfer** (512 KB sealed chunks) — large videos send with flat
  memory; auto-optimize (1080p video / ≤2560px photos) vs. lossless toggle.
- ⏭️ Fallback chain polish: group-gossip cache; **Haven relay mailbox** (in-app relay
  or `haven-relay` daemon) or the user's **own S3-compatible bucket** for offline
  delivery, see `RELAY-AND-DEPLOY.md`.
- ⏭️ Opt-in onion/proxy mode for full IP hiding.
- *(No quota/blind-token/subscription work — deleted per D15.)*

## 🟡 M5b — `haven-relay` easy circle relay (optional / community)

- For volunteers (or the operator later) who want guaranteed relay reliability —
  **never required**, no mandatory monthly cost
- ✅ **Single static Rust binary** (`core/haven-relay`) composing `haven-net` +
  `p2pcore` — reinvents no crypto/transport. `haven-relay run --link <code>` links to a
  circle and serves **both** roles while online:
  - ✅ **Connection relay**: forwards mesh-relay frames (cleartext routing header —
    dest node ids + ttl + random msg-id; opaque sealed payload) toward circle members it
    can reach; RAM-only bounded de-dup; **non-key-holder** (can't open the payload).
    Proven by `relay_forward.rs` (Alice→relay→Bob, indirect peers; relay can't decrypt).
  - ✅ **Media store-and-forward**: runs `rclone serve s3` on loopback + S3-over-iroh
    tunnel (`haven/s3/1`, HAVEN-NET-RELAY.md Design A) — no public host/port/domain.
    Proven by `s3_tunnel.rs` (consumer ↔ iroh ↔ store byte round-trip).
  - ✅ **Relay link** = public routing data only (`circle tag` + member node ids) — no
    content/KEM key, so linking can't make it a content reader or bypass target.
  - ✅ Hardened no-log defaults: RAM-only de-dup, rclone `--log-level ERROR` on loopback,
    persisted seed (`0600`) so the relay's node id is stable.
- ✅ App-side hooks: an **in-app RelayHost** (`RelayHost.swift`, FFI) runs the relay
  in-process; per-circle relay node id is stored + broadcast (frames 19/20); the
  **Mac runs it as an invisible background relay** (accessory activation policy — close
  the window, no dock icon, keeps relaying). Standalone `haven-relay` packaging ships
  for **macOS launchd** and **Linux systemd** (`relay/`).
- ⏭️ OpenTofu modules: AWS / GCP / Azure / Hetzner / Fly / DO / Cloudflare-R2 / Oracle /
  bare VPS; `haven-relay deploy --provider … --role connection|storage|both`
- ⏭️ Self-register to discovery; true two-machine field run

## ❌ M6 — Web client — ABANDONED (native-only focus)

A browser can't be a peer on Haven's network: no raw UDP / NAT hole-punching, so it can
never join the iroh mesh directly. The only way a web client could work is as a thin
client of a **publicly-hosted relay** (WSS/WebRTC bridge → iroh) — which means every circle
would need a public relay just for web to function. Not worth the complexity or the
half-broken UX. **Decision (2026-06-22): drop the web client.** The web page (`web/`) is now
just a clean **invite-landing / app-promo** (parses `haven://` invites → opens the native
app); the WASM client and `web/engine/` were removed.

- **Android** is still planned, but as a **native** UniFFI → Kotlin/JNI client (see M8), not
  WASM — so it's a real iroh peer like iOS/macOS.

## 🟡 M7 — Media, music, calls, safety (security-audited — D18, `MEDIA-AND-MUSIC.md`)

- ✅ **In-app camera** (photos+video): seal E2E before send, sandbox-only; **camera
  filters** (9 Apple-style variants + Kodak Gold).
- ✅ **Apple Music on posts**: attach a song (reference only — `TrackRef`), artist+title
  pill + playing animation; video muted while music plays; unmute → clean audio
  crossfade (`AudioCoordinator`). Real MusicKit catalog + library picker.
- ✅ **Calls**: WebRTC **1:1 and full-mesh group** calls (audio+video, E2EE DTLS-SRTP),
  signaling over the sealed iroh channel; **VoIP PushKit** ring-from-killed; **CallKit**
  on iOS, in-app on native macOS; echo cancellation; **screen share** (macOS
  ScreenCaptureKit, iOS ReplayKit broadcast extension → App Group `group.com.blaineam.kith`).
- ✅ **MusicKit entitlement** on the App ID — granted; live Apple Music attach + playback
  shipped (see `MEDIA-AND-MUSIC.md`).
- ⏭️ **EXIF/GPS stripping** at the seal-and-send boundary.
- ⏭️ On-device `SensitiveContentAnalysis` guards; per-circle toggles.

## ⏭️ M10 — CI & launch tooling

- ✅ Marketing page live: https://wemiller.com/apps/haven/ (registered in projects.json)
- ⏭️ **Monkr ASC screenshot pipeline** (`.local-screenshots.conf` + `rocket shots Haven`)
  — device-framed App Store screenshots
- ⏭️ **Xcode Cloud CI** (eventually; local rocket CI is fine for the early phase)

## 🟡 M8 — More clients (all reuse `p2pcore`)

- 🟡 **Android native** via UniFFI → Kotlin/JNI — **in progress** (`android/`, Jetpack
  Compose + Material 3, minSdk 29). Identity, circles, feed, DMs, reactions/comments,
  stories, QR handshake working and on-device verified; cross-device media bytes,
  mailbox, calls, and notifications remain. (No WASM — the web client was abandoned.)
- ✅ **macOS** ships today via **Mac Catalyst** from the SwiftUI codebase; a **native
  AppKit/SwiftUI port is in progress** (Phase 0 underway — native-macOS FFI slice added,
  `HavenMac` target — see `MACOS-NATIVE-PORT.md`).
- 🟡 **Windows / Linux desktop** — **in progress** (`desktop/`, Tauri 2; the Rust backend
  links the core directly — a real iroh peer, not a web client). GUI at near-parity (feed,
  circles, DMs, stories, camera, media, WebRTC group calls + **screen share**, tray,
  notifications, BYO storage) plus a headless relay in the same binary. Linux ships across
  Ubuntu/Debian/Raspbian (`.deb`/AppImage/`.rpm`), Arch (AUR), and SteamOS/Steam Deck
  (Flatpak); the `haven-relay` daemon cross-builds for x86_64/aarch64/armv7/armv6 (Pi). See
  [`WINDOWS-PORT.md`](WINDOWS-PORT.md) + [`LINUX.md`](LINUX.md). Remaining: MSIX/Store
  packaging, on-device sensitive-content classifier, live multi-machine media/call tests.
- 🟡 **Apple Watch** companion — **in progress** (`apple/HavenWatch`). A standalone
  single-target SwiftUI watchOS app (`com.blaineam.kith.watchkitapp`, embedded in the iOS
  app) that is a **thin WCSession client** — the iPhone keeps the iroh node + identity; the
  Watch links NEITHER HavenFFI NOR WebRTC. Shows recent DM threads / circle posts + reactions,
  opens a thread, sends quick replies (dictation / Scribble / canned) and tap-to-react, and
  mirrors the phone's local notifications. Scoped per DECISIONS D13: messages/reactions/
  notifications/quick replies — *not* bulk video/large files. Bridge: `WatchSessionManager`
  (phone) ↔ `WatchConnectivityClient` (watch) over FFI-free `WatchShared` Codable models.

## 🟡 M9 — Launch surface

- ✅ **TestFlight pipeline** via rocket: `.local-ci.conf` (iOS, scheme Haven, team,
  XCFramework prebuild) → `rocket build Haven` archives + cloud-signs + uploads.
  Haven is **live on TestFlight** in ASC app "Haven Community" (com.blaineam.kith);
  see `PROGRESS.md` for the current build number.
- ⏭️ Answer export compliance in TestFlight; add testers
- **Marketing page** at `blaineam.github.io` repo under `/apps/haven/` — only once
  close to App Store submission
- **Screenshot automation**: wire Haven into the shared capture → **Monkr-frame** →
  ASC pipeline in `_shared/` (depends on Monkr `/headless`), via the **rocket** flow,
  matching the existing app-portfolio screenshot style
- CHANGELOG + docs/pages-site + README kept current on every push

## Toolchain prerequisites (this machine)

Installed: Rust (rustup) + Apple targets (iOS device/sim, Mac Catalyst, native macOS),
`uniffi-bindgen`, cargo, Xcode, XcodeGen, swift.
Still needed (when their milestone arrives):
- Android NDK + `cargo-ndk` + JDK 17 pin — for M8 (the native Android client)
