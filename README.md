# Kith

> *Kith and kin* — your friends *and* your family. That's the whole product.

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue.svg)](LICENSE)
[![Status: pre-alpha](https://img.shields.io/badge/status-pre--alpha-orange.svg)](docs/ROADMAP.md)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20Web-lightgrey.svg)](#platforms)
[![Crypto](https://img.shields.io/badge/crypto-hybrid%20post--quantum-success.svg)](docs/DECISIONS.md)

A peer-to-peer, end-to-end encrypted social network for the people you actually
know — photos, video, music, messages, and calls shared inside small circles of
friends and family. **No central server holds your content. No phone number or
email. No tracking. No ads. No doomscroll.**

Think iMessage + Apple Photos + Apple Music as a private social network — without the
ads, the surveillance, or the infinite feed. The maker runs no servers and pays
nothing monthly; your media rides on your own iCloud and direct peer-to-peer links.

## What makes it different

- **No surveillance, zero operator cost.** There is no server that ever sees your
  plaintext or any personal data — and nothing the maker has to pay for monthly.
  Media rides on *your own* iCloud/storage; peer connections use free, swappable,
  community/public relays only as a last-resort encrypted pipe. The app is a one-time
  $4.99 with no subscription.
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

Pre-alpha. The cryptographic spine (hybrid post-quantum identity + key
establishment + the reach-me link system) is implemented and unit-tested in the
Rust core. Transport, group messaging, the Swift app, and the web client are next.
See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Repository layout

```
core/      Rust workspace — the portable, security-critical core
  p2pcore/   identity, hybrid-PQ crypto, links, transport seam
apple/     SwiftUI app (iOS/macOS) — consumes the core via an XCFramework
web/       Static web/Android client — consumes the core via WASM
relay/     Self-hostable relay (a dumb encrypted-blob pipe)
docs/      Architecture, decisions, threat model, link spec, roadmap
```

## Build & test the core

```sh
cd core
cargo test
```

## Platforms

One Rust core (`p2pcore`) powers every client, so new platforms are mostly UI:

- **iOS / macOS** — SwiftUI + UniFFI (primary)
- **Web / Android** — the static WASM client (Android natively later via UniFFI→Kotlin)
- **Windows / Linux** — Tauri desktop reusing the web UI + native core
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
- [`docs/RELAY-AND-DEPLOY.md`](docs/RELAY-AND-DEPLOY.md) — relay roles, BYO storage, IP privacy, the deploy tool
- [`docs/OPERATING-COSTS.md`](docs/OPERATING-COSTS.md) — what it costs to run (≈free–low-tens/mo)
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and prerequisites
