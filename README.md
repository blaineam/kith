# Haven

> Your friends *and* your family. That's the whole product.

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue.svg)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](docs/ROADMAP.md)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20Android%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#platforms)
[![Crypto](https://img.shields.io/badge/crypto-hybrid%20post--quantum-success.svg)](docs/DECISIONS.md)

A peer-to-peer, end-to-end encrypted social network for the people you actually
know — photos, video, music, messages, and calls shared inside small circles of
friends and family. **No central server holds your content. No phone number or
email. No tracking. No ads. No doomscroll.**

Think iMessage + Apple Photos + Apple Music as a private social network — without the
ads, the surveillance, or the infinite feed. The maker runs no servers and pays
nothing monthly; your media rides on a Haven relay you (or a friend) run, your own
S3-compatible bucket, or a direct peer-to-peer link.

## What makes it different

- **No surveillance, zero operator cost.** There is no server that ever sees your
  plaintext or any personal data — and nothing the maker has to pay for monthly.
  Media rides on a Haven relay you run (any official app, or the tiny `haven-relay` on a
  Pi/server) or your own S3-compatible bucket (S3/R2/B2) — nothing else, nothing of ours.
  Peer connections use free, swappable, community/public relays only as a last-resort
  encrypted pipe. The app is a one-time $9.99 with no subscription.
- **Quantum-safe by default.** Every content key is derived from a *hybrid* of
  classical (X25519) and post-quantum (ML-KEM-768) key exchange, so stored
  ciphertext is protected against "harvest-now, decrypt-later" attacks.
- **No PII.** An account is just a keypair generated on-device. You're reachable
  by a permanent link or QR — no phone, no email, ever.
- **Local-first transport.** Traffic prefers Bluetooth, then local/peer-to-peer
  WiFi, and only falls back to a relay when there's no closer path.
- **You're in control.** Block anyone, approve every new contact, and on-device
  sensitive-content guards keep flagged media blurred — all without anything
  leaving your phone.

## Status

Alpha. It runs on iPhone **and** macOS, is on TestFlight, and has been used
device-to-device over the real internet and a nearby Bluetooth/Wi-Fi mesh. Done so far:

- **Hybrid post-quantum core** (`p2pcore`) — identity (Ed25519+ML-DSA, X25519+ML-KEM-768),
  AEAD seal/open, reach-me links, deterministic seed-based identity; unit-tested.
- **Real P2P transport** — sealed posts, DMs, reactions, comments, and media move
  peer-to-peer over iroh QUIC (with a nearby Bluetooth/Wi-Fi mesh fallback and a
  ttl-bounded mesh-relay), decrypted byte-identical.
- **Apple app (iOS + macOS via Mac Catalyst)** — SwiftUI on the real Rust core via a
  UniFFI XCFramework: circles + multi-circle feed, stories (multi-clip + captions),
  DMs, in-app camera with filters, Apple Music on posts, **WebRTC 1:1 and group calls**
  (audio+video, screen share), **multi-identity switcher** with per-identity profiles,
  a blind-APNs notification relay with on-device NSE decrypt, and an in-app/standalone
  store-and-forward relay.

In progress: a **native AppKit/SwiftUI macOS port** (replacing Mac Catalyst — see
[`docs/MACOS-NATIVE-PORT.md`](docs/MACOS-NATIVE-PORT.md)), a **native Android client**
(`android/`, Jetpack Compose + the same Rust core via UniFFI/Kotlin), and a **Windows /
Linux desktop client** (`desktop/`, Tauri 2 — the Rust backend links the core *directly*
and the same binary runs headless as your circle's relay; see
[`docs/WINDOWS-PORT.md`](docs/WINDOWS-PORT.md)). The web client was abandoned (a browser
can't be an iroh peer); `web/` is now just an invite-landing page. See
[`docs/ROADMAP.md`](docs/ROADMAP.md) and [`apple/README.md`](apple/README.md).

## Repository layout

```
core/        Rust workspace — the portable, security-critical core
  p2pcore/     identity, hybrid-PQ crypto, links, social engine, transport seam
  haven-net/   iroh QUIC networking node (listen/dial, sealed payloads)
  haven-relay/ standalone store-and-forward relay daemon
  haven-s3/    shared AWS SigV4 S3 client (BYO-storage mailbox) — used by the desktop client
  p2pcore-ffi/ UniFFI crate (`haven_ffi`) — Swift/Kotlin bindings
apple/       SwiftUI app (iOS/macOS) — consumes the core via an XCFramework
android/     Native Android app (Jetpack Compose) — same core via UniFFI/Kotlin
desktop/     Windows/Linux Tauri 2 app — Rust backend links the core directly; GUI + relay
relay/       Self-hostable relay packaging (launchd / systemd / Docker)
web/         Invite-landing / app-promo page (the web client was abandoned)
docs/        Architecture, decisions, threat model, link spec, roadmap
```

## Build & test the core

```sh
cd core
cargo test
```

## Platforms

One Rust core (`p2pcore`) powers every client, so new platforms are mostly UI:

- **iOS / macOS** — SwiftUI + UniFFI (primary; macOS ships today via Mac Catalyst, with
  a native AppKit/SwiftUI port in progress)
- **Android** — native Jetpack Compose + the same core via UniFFI→Kotlin (in progress)
- **Windows / Linux** — Tauri 2 (Rust backend links the core directly; WebView2/WebKitGTK
  UI). GUI client *and* a headless circle-relay in one binary (in progress). Linux ships on
  **Ubuntu / Debian / Raspberry Pi OS** (`.deb`/AppImage/`.rpm`), **Arch** (AUR), and
  **SteamOS / Steam Deck** (Flatpak); the `haven-relay` daemon cross-builds for
  x86_64/aarch64/armv7/armv6. See [`docs/LINUX.md`](docs/LINUX.md) and
  [`docs/WINDOWS-PORT.md`](docs/WINDOWS-PORT.md)
- **Apple Watch** — glanceable companion (messages/photos/reactions/quick replies;
  not bulk video)

## License

Source-available under **PolyForm Noncommercial 1.0.0** (see [`LICENSE`](LICENSE)) —
read it, learn from it, fork it, use it noncommercially, but **not** commercially.
Copyright © Blaine Miller. The paid iOS app on the App Store is distributed by the
copyright holder. This is *source-available*, not OSI-approved open source (the
noncommercial restriction is the difference). Contributions require a CLA/DCO.

## Documentation

- [`docs/DECISIONS.md`](docs/DECISIONS.md) — the architectural decisions and why
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit together
- [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md) — what we defend against, and abuse resistance
- [`docs/LINK-SYSTEM.md`](docs/LINK-SYSTEM.md) — the reach-me link / QR design
- [`docs/MULTI-DEVICE.md`](docs/MULTI-DEVICE.md) — multi-identity switcher today; many-device account design ahead
- [`docs/SCHEDULED-MESSAGES.md`](docs/SCHEDULED-MESSAGES.md) — "send later" without a server
- [`docs/MEDIA-AND-MUSIC.md`](docs/MEDIA-AND-MUSIC.md) — in-app camera, Apple Music on posts, audio crossfade
- [`docs/NOTIFICATIONS.md`](docs/NOTIFICATIONS.md) — blind APNs relay + on-device NSE decrypt
- [`docs/RELAY-AND-DEPLOY.md`](docs/RELAY-AND-DEPLOY.md) — relay roles, BYO storage, IP privacy, the deploy tool
- [`docs/HAVEN-NET-RELAY.md`](docs/HAVEN-NET-RELAY.md) — routing the relay/mailbox over Haven Net (no public host)
- [`docs/BYO-STORAGE.md`](docs/BYO-STORAGE.md) — bring-your-own S3 / cloud-drive storage
- [`docs/OPERATING-COSTS.md`](docs/OPERATING-COSTS.md) — $0 operator cost model
- [`docs/EXPORT-COMPLIANCE.md`](docs/EXPORT-COMPLIANCE.md) — US export-compliance (automated)
- [`docs/MACOS-NATIVE-PORT.md`](docs/MACOS-NATIVE-PORT.md) — Mac Catalyst → native AppKit/SwiftUI port
- [`docs/ANDROID-PARITY.md`](docs/ANDROID-PARITY.md) — the native Android client plan + status
- [`docs/WINDOWS-PORT.md`](docs/WINDOWS-PORT.md) — the Windows/Linux Tauri desktop client plan + status
- [`docs/LINUX.md`](docs/LINUX.md) — Linux GUI + headless relay: per-distro install (Ubuntu/Debian/Raspbian/Arch/SteamOS), packaging, parity
- [`docs/WEB-PARITY.md`](docs/WEB-PARITY.md) — why the web client was abandoned
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and prerequisites
