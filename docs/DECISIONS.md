# Architectural decisions

Each entry is a decision we've committed to, with the reasoning and the honest
trade-off. Newest concerns first.

## D1 — "No surveillance, near-zero cost" instead of "literally no servers"

**Decision:** Allow tiny, swappable, **federated relays** that only route opaque
encrypted blobs and hold zero plaintext / zero PII. They are never load-bearing
for trust, and anyone can run one.

**Why:** Pure zero-server is physically in tension with "reliable, including a web
client." Two phones behind home routers can't always reach each other directly
(~15–20% of connections need a relay due to symmetric/CGNAT). Peers also go
offline, so content needs somewhere to wait. Forcing "sender must stay online"
would wreck the experience for the non-technical family users this is *for*.

**Trade-off:** There is some always-on infrastructure. We make it cheap (a $5 box),
dumb (sees only ciphertext), and federated (no single one matters), and frame the
product promise as *no surveillance / no data collection* rather than *no servers*.

## D2 — Identity is a keypair; no PII

**Decision:** An account is an on-device keypair. The public key is the user id and
routable address. Contacts are added by QR (in person) or link (remote). Recovery
is via passphrase-encrypted escrow in the user's *own* iCloud Keychain / Secure
Enclave + an exportable recovery code.

**Why:** No phone/email means no PII to collect, leak, or subpoena. Public-key
identity is also exactly what the transport layer needs to dial a peer.

**Trade-off:** Losing the key = losing the identity, so recovery UX is a real
problem we own (not the user's email provider's).

## D3 — Group encryption via MLS (`mls-rs`), not pairwise Signal

**Decision:** Use **MLS (RFC 9420)** for all E2E encryption, via AWS's **`mls-rs`**.
1:1 chats are just 2-member groups.

**Why:** The product is *groups* (family, friends), and MLS is built for efficient
group membership changes. `mls-rs` has a pluggable crypto-provider model, which is
what lets us register hybrid post-quantum ciphersuites (see D4) — OpenMLS is more
locked to its built-in suites.

## D4 — Hybrid post-quantum crypto everywhere

**Decision:** Derive every content key from a **hybrid** of classical + PQ:
- KEM: **X25519 + ML-KEM-768** (FIPS 203), mixed via HKDF-SHA256.
- Signatures/identity: **Ed25519 + ML-DSA** (FIPS 204). *(ML-DSA is the next crypto
  addition; the `sign`/`verify` seam is already isolated. Ed25519 ships first.)*
- Symmetric: **AES-256-GCM** (already quantum-resistant).

**Why:** Relays route ciphertext an adversary could store today and crack with a
future quantum computer ("harvest now, decrypt later"). Hybrid means an attacker
must break *both* primitives, so we're never weaker than classical even if young PQC
algorithms are later found flawed. Same approach as Signal PQXDH and Apple PQ3.

**Trade-off:** Slightly larger keys/signatures (ML-KEM ct ~1 KB, ML-DSA sig ~2–3 KB).
Negligible against media; only mildly relevant to tiny text messages.

**Status:** Hybrid PQ **KEM** is implemented and tested (`crypto.rs`). Hybrid PQ
**signatures** are staged next.

## D5 — Transport priority ladder: Bluetooth → local WiFi → relay

**Decision:** A path-selector races available transports and prefers the
cheapest/most-private reachable one: Bluetooth (presence + small payloads) → local
or peer-to-peer WiFi (bulk) → relay (last resort). Bulk transfers skip Bluetooth's
low-bandwidth pipe.

**Why:** Staying off the relay is better for privacy, latency, and cost. Bluetooth
is always-on and works with no network at all; local WiFi is the high-bandwidth lane
for big files.

**Trade-offs / honest limits:**
- Web/Android-web clients **cannot** do Bluetooth or WiFi-direct (no browser API),
  so they always use WebRTC/relay. The rich local mesh is a native superpower.
- Apple↔Android *local* transport is hard (AWDL vs Nearby/WiFi-Direct don't
  interoperate); cross-OS over relay always works. A custom BLE+socket protocol for
  cross-OS local is a later milestone.

## D6 — Rust core, Swift UI, shared into the web via WASM

**Decision:** One Rust crate (`p2pcore`) is the single source of truth for all
security-critical logic. It's exposed to Swift via **UniFFI** (XCFramework) and to
the web/Android client via **wasm-bindgen**.

**Why:** `iroh` and `mls-rs` are Rust, and one core means the native and web clients
run *identical* crypto — no second implementation to audit or drift.

**Trade-off:** Requires a Rust toolchain in the build (the user already runs a
Rust-XCFramework pipeline for MLX, so this is a paved road). `rustup` + iOS targets
must be installed before the XCFramework step (the Homebrew Rust on this machine has
no `rustup` yet).

## D7 — Reach-me links carry only the id + a verification hash

**Decision:** A link is `kith://u/<id>#<verify>` or `https://<domain>/u/<id>#<verify>`.
It carries the 32-byte Ed25519 id (resolved to a live address via decentralized
discovery) and a 16-byte hash of the full hybrid key bundle, kept in the URL
**fragment** so no web server ever sees it. Using a link creates a *pending* request
the owner must approve. See [`LINK-SYSTEM.md`](LINK-SYSTEM.md).

**Why:** Permanent, server-free, works on a plain static website, and the fragment
keeps even the hosting page blind. The pending-approval step is the spam/abuse
defense for a publicly posted link.

## D8 — Apple Music = share references, not audio

**Decision:** Music sharing means attaching a track/playlist *reference*; each user
plays it through their own Apple Music subscription (MusicKit native, MusicKit JS on
web). Users' own audio files flow through the normal encrypted file path.

**Why:** MusicKit/DRM forbids transmitting the audio itself. This is the only legal
model — and it's clean: no piracy, no licensing exposure.

**Trade-off:** A friend without a subscription hears 30-second previews.

## D9 — Calls: WebRTC mesh now, E2E SFU later

**Decision:** Group audio/video via WebRTC mesh for small groups (≤~5), which stays
serverless. Larger calls later via an insertable-streams E2E SFU that relays frames
it can't decrypt.

**Why:** Mesh uplink dies beyond ~5 participants, but small family/friend calls fit
mesh and need no server.

## D10 — Safety is on-device and graph-bounded

**Decision:** Blocking is client-side refusal + group removal. Sensitive-content
guards use Apple's on-device `SensitiveContentAnalysis` (nothing leaves the device).
Distribution is friend-graph-only — **no global discovery feed, ever**.

**Why:** Aligns with the no-server / no-data ethos and is the defensible answer to
abuse (incl. CSAM): on-device analysis + invite-only, graph-bounded sharing. Also
structurally prevents the doomscroll the product exists to avoid.

## D11 — Edit & unsend as signed, ordered events (with timers + an "edited" badge)

**Decision:** Messages are immutable once sent. **Editing** posts a new signed
`Edit{target, new_ciphertext, ts}` event into the same MLS group; clients render the
latest version and show an **"Edited"** badge (keeping the original timestamp).
**Unsending** posts a signed `Retract{target, ts}` event; honoring clients remove the
content and show **"Message unsent."** Both are gated by client-enforced **timers**
(e.g. edit ≤ 15 min, unsend ≤ a few min); receivers reject edit/retract events whose
`ts` falls outside policy, so the window can't be abused later.

**Why:** With no central store, you can't mutate a row — but a signed, ordered event
*is* the edit history, and it's tamper-evident within the group (everyone sees the
same sequence). The badge/“unsent” marker are themselves part of that history.

**Honest limit:** unsend is **best-effort**, exactly like iMessage/Signal. We can't
force deletion on a recipient's *device*, a *modified* client, or a *screenshot*, and
a relay may have briefly held an encrypted copy. The timer + signed retract are the
strongest guarantees possible without a server policing everyone's device.

## D12 — License: PolyForm Noncommercial 1.0.0, copyright retained

**Decision:** The codebase is **source-available under PolyForm Noncommercial 1.0.0**
(`LICENSE`). Copyright is retained by Blaine Miller, who distributes the paid
($4.99) App Store binary — permitted because the copyright holder isn't bound by the
public license. Outside contributions require a lightweight **CLA/DCO** granting
relicensing rights, so the app can keep being sold.

**Why:** PolyForm Noncommercial cleanly does the one thing requested — anyone may
read, learn from, fork, and use it noncommercially, but **not** ship it commercially.
It's professionally drafted and plain-language.

**Terminology honesty:** this is **"source-available," not OSI-approved "open
source"** — the noncommercial restriction is exactly what disqualifies it from the
OSI definition. Fine to call it open *source* loosely, but not *open-source licensed*.

**Alternatives if you ever want *eventual* true-OSS:** FSL (Functional Source
License, converts to MIT/Apache after ~2 years) or BSL (Business Source License,
time-delayed). Swap-in is a one-file change.

## D13 — One Rust core → every platform

**Decision:** Because all security-critical logic lives in `p2pcore` (Rust), new
clients are mostly UI:

| Platform | How | Effort |
|---|---|---|
| iOS / macOS | SwiftUI + UniFFI (XCFramework) | primary |
| **Android** | **UniFFI → Kotlin/JNI** reuses the *same* core; or the WASM web client short-term | low–medium |
| Web | wasm-bindgen → WASM (also serves Android immediately) | medium |
| **Windows / Linux desktop** | **Tauri** (reuses the web UI) + the Rust core natively, or egui | low–medium |
| **Apple Watch** | companion app, Rust core via `aarch64-apple-watchos` (tier-3) | scoped (see below) |

**Watch scope (honest):** messages, photos, reactions, notifications, quick replies,
and possibly audio messages/calls are feasible. **Bulk video / large-file transfer is
not** (watchOS media + bandwidth limits; cf. our watchOS video-wall findings). Ship
the Watch as a glanceable companion, not a full client.

**Why:** The Rust-core decision (D6) is what makes "someone can build an Android
client easily" actually true — they inherit identity, crypto, links, and transport
for free and only write UI.

> **D14 is partially superseded by [D15](#d15--zero-operator-cost-senders-own-storage-free-relays).**
> The two-role split and IP guarantees still hold; the *operator-funded quota'd
> bucket* and its quota machinery are dropped.

## D14 — Two relay roles; storage is BYO/federated; honest IP guarantees

**Decision:** Split "relay" into two roles (full detail in `RELAY-AND-DEPLOY.md`):
- **Connection relay** — stateless live packet forwarder for NAT traversal.
- **Storage relay ("mailbox")** — mostly object storage (S3/R2/B2/GCS) + a thin
  stateless broker, for offline delivery and large/lossless files.

Storage is **BYO by default** (user's own iCloud/S3/NAS) or an optional **quota'd
shared bucket** anyone can run — so there is no central service. A **deployment tool**
(`kith-relay`, OpenTofu + CLI) lets any entity stand up a compliant relay on AWS/GCP/
Azure/Hetzner/Fly/DO/Cloudflare-R2/Oracle/bare-VPS in one command, with
privacy-hardened defaults that are hard to disable.

**IP privacy — the honest version (also in `THREAT-MODEL.md`):** a relay/storage node
*transiently handles* your IP because that's how bytes reach you; "no node ever sees
your IP" is false and we won't claim it. We **do** guarantee, by default config:
- **zero logging / zero persistence** (RAM-only, provider logs disabled),
- **no identity↔IP linkage** (peers auth to each other E2E; relay sees ephemeral
  rendezvous tokens, not public keys),
- **quota without identity** (blind-signed Privacy-Pass-style tokens),
- **opt-in onion/proxy mode** for true IP *hiding* (the only way a node can't see
  your IP), off by default for latency.

Promise: **never logged, never linked to you, optionally fully hidden.**

**Why:** Removes you as a central operator, lets the network be genuinely federated,
and makes the strongest IP claim that is actually true rather than a comforting lie.

## D15 — Zero operator cost: sender's own storage, free relays

**Decision:** The operator pays **nothing monthly** and runs nothing required:
- **Storage relay = the sender's own iCloud** (private CloudKit DB + `CKShare`,
  billed to the *user's* iCloud quota) or a BYO S3/R2/NAS bucket. No operator-funded
  bucket. "The sender funds the cost to share," literally.
- **Connection relay** = iroh/n0 **free public relays** + community-run relays;
  hole-punching via **public STUN**; discovery via the **mainline DHT**.
- **Hosting** = GitHub Pages (`blaineam.github.io`) for the web client, AASA, and
  marketing page. **Notifications** = APNs / Web Push.
- App is a **one-time $4.99, no subscription**.

**This deletes** the 512MB quota, blind-signed tokens, App Attest gating, the storage
subscription, and the funded default bucket — they only existed to meter a bucket the
operator would have funded. `kith-relay` (D14) remains as an **optional** community /
self-host reliability layer, never required.

**Trade-offs (dependency, not dollars):**
- Connection relay depends on **best-effort free third-party relays** (no SLA);
  degradation hits hard-NAT links and live calls until community/self relays fill in.
- **iCloud storage is clean Apple↔Apple only.** Cross-platform *offline* delivery
  needs both-peers-online or a sender BYO bucket; a web/Android peer can't read a
  sender's iCloud. Ship **Apple-first**.

**Why:** The user explicitly wants no monthly cost, not even $5/mo. Self-funded
storage + free infrastructure achieves that and simplifies the product. See
`OPERATING-COSTS.md`.
