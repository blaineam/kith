# Android Parity Plan

How each Haven capability reaches the Android app, and at what parity. Android is
explicitly sequenced **after the web client works properly** — this is the map for when we
start, not a commitment to start now. Targets the user's old device: **Android 10/11
(API 29/30)**, so every choice below is checked against API 29.

## The big lever: the core is already portable

The entire trust + data layer is Rust in `core/p2pcore`, exposed through `p2pcore-ffi`
(crate `haven_ffi`) with **UniFFI**, which generates **Kotlin bindings from the same
`.udl`/proc-macros that generate Swift**. So everything below the UI ports with *zero
reimplementation* — only a Gradle/NDK build of the same crate:

- Identity, hybrid-PQ keys (Ed25519+ML-DSA, X25519+ML-KEM-768), sealing/opening
- Circles, roster, contact bundles, invite links, verification
- Feed/event model: posts, stories, edits, reactions, comments, DMs, media refs, music refs
- Mailbox envelope seal/open, circle-sealed media

`haven-net` (iroh QUIC transport) is also pure Rust and **compiles for Android** (iroh
supports `aarch64-linux-android`). The MLS/networking work we do for iOS is reused as-is.

**Consequence:** Android is overwhelmingly a *UI + platform-glue* project, not a
re-architecture. The parity table is really "which platform API replaces which Apple API."

## Parity table

| iOS feature | Android approach (API 29+) | Parity |
|---|---|---|
| Crypto / identity / circles / feed | Same `haven_ffi` crate via UniFFI Kotlin | **Full** — identical engine |
| iroh P2P transport + mesh relay | Same `haven-net` crate, `aarch64/armv7-linux-android` | **Full** |
| Nearby offline transport (MultipeerConnectivity) | **Nearby Connections API** (`P2P_CLUSTER`), BLE+Wi-Fi | **Full-ish** — different API, same role; needs the iroh-or-nearby ladder reimplemented in Kotlin |
| S3 mailbox / BYO-storage / shared relay | Plain HTTPS + SigV4 — port `S3Client.swift` to Kotlin (OkHttp + HMAC), or do SigV4 in Rust and expose via FFI (preferred — one impl) | **Full** |
| Keychain (key storage) | **Android Keystore** + EncryptedSharedPreferences; same "keys never leave device" rule | **Full** |
| Local notifications + background fetch | **WorkManager** periodic sync + `NotificationManager`; no server, same as iOS | **Full** (Android bg is actually *more* permissive) |
| Camera + story capture | **CameraX** (preview/capture/video) | **Full** — CameraX is modern + clean |
| Photos export / picker | **MediaStore** + Photo Picker (API 30 `ACTION_PICK_IMAGES` fallback to `GET_CONTENT` on 29) | **Full** |
| Video trim / mute before posting | **Media3/ExoPlayer Transformer** (trim, mute) | **Full** |
| Screenshot-protected secret messages | `WINDOW_FLAG_SECURE` on the reveal view | **Full** (cleaner than the iOS secure-field hack) |
| Audio voice messages | `MediaRecorder` (AAC/m4a) + `MediaPlayer` | **Full** |
| **Apple Music** song attach + playback | ⚠️ **No equivalent.** Android has no universal "play this catalog track" API. Options: (a) attach a **local audio file** the user picks; (b) deep-link a track id to **YouTube Music/Spotify** (shows, doesn't auto-play inline); (c) MediaStore local library playback only | **Redesign** — share a portable music *reference* model: local file → full; streaming → deep-link only |
| Audio/video P2P calls | Audio via `AudioRecord`/`AudioTrack`; video via CameraX frames → same wire frame type 15; **Telecom/ConnectionService** for the system call UI (replaces CallKit) | **Full** (more setup than CallKit) |
| CloudKit favorites/resume sync | ⚠️ **No equivalent.** Use the existing **mailbox** (circle-sealed per-user prefs blob) instead of a platform cloud — actually *more* aligned with the no-server ethos | **Redesign → arguably better** |
| Liquid Glass / SwiftUI styling | **Jetpack Compose** + Material 3; rebuild the visual language (brand gradient, masonry, story ring) | **Full** (reimplement UI, not logic) |
| Widgets (ES-style) | **Glance** (Compose for App Widgets) — if we want them | **Full** |
| Push (the OneSignal/APNs discussion) | Same conclusion as iOS: real push needs a server → parked. Local-notif + WorkManager covers it serverlessly. **FCM would be the Android equivalent of the APNs-relay path** if ever pursued | n/a (parked) |

## Recommended build order (when we start)

1. **Cargo-NDK build of `haven_ffi` + `haven-net`** → `.so` per ABI + UniFFI Kotlin bindings. Prove `self_test()` + a seal/open round-trip in a bare Compose app. *(toolchain already installed this session: android targets, cargo-ndk, NDK — only the JDK-17 pin remains, current JDK 26 is too new for AGP.)*
2. **Identity + circles + invite link** (paste a Haven link, add a contact, verify). No UI polish.
3. **Mailbox transport in Rust** — do SigV4 + put/get/list *in the core* and expose via FFI, so iOS and Android share one implementation (retires the per-platform `S3Client`). This is also what unblocks **web** (same Rust → WASM).
4. **Feed** (posts + media via CameraX/MediaStore) over the mailbox. First real cross-platform post (iPhone ↔ Android).
5. **DMs + stories + reactions/comments.**
6. **Calls** (audio first, then the type-15 video path) via Telecom.
7. **Music redesign** — portable reference model (local-file full; streaming deep-link).
8. **Nearby offline** (Nearby Connections) + notifications (WorkManager).

## Parity summary

- **Full parity, no redesign:** crypto, circles, feed, DMs, stories, transport, mailbox, camera, media, calls, secret messages, notifications, nearby, key storage. (~90% of the app.)
- **Needs a redesign (and it's healthier for it):** Apple Music → portable music refs; CloudKit → mailbox-based prefs sync.
- **Parked (same as iOS):** real push (FCM/APNs relay), pending the no-server decision.

The single most valuable cross-platform investment is **moving the mailbox/S3 transport
into the Rust core** (step 3): it gives iOS, Android, and the web client the *same*
networking from one implementation — which is exactly what #44 and web continuity need too.
