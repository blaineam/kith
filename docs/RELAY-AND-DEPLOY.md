# Relays, storage, and the deployment tool

Kith has **no central service**. What little infrastructure exists is federated,
swappable, hardened-by-default, and runnable by anyone. This doc defines the two
relay roles, the storage model, the IP-privacy guarantees (honestly), and the
multi-cloud deployment tool.

## Two relay roles — keep them separate

| | **Connection relay** | **Storage relay** ("mailbox") |
|---|---|---|
| Purpose | Forward live packets when two *online* peers can't NAT-punch directly | Hold an encrypted blob for an *offline* peer until pulled |
| Shape | Stateless running service (TURN/DERP-style, RAM-only) | Mostly **object storage** (S3/R2/B2/GCS) + a thin stateless broker |
| Sees | Ciphertext + the two IPs it bridges | Ciphertext + uploader/downloader requests |
| Best for | Real-time (calls, both-online transfers) | **Offline delivery + large/lossless files** |
| Cost | ~$5/mo VPS, or per-GB TURN | Storage + egress only; can be the user's *own* bucket |

A peer with no route at all falls through the chain from `ARCHITECTURE.md`:
**sender-online → group-gossip cache → storage relay (BYO or quota'd)**. The
connection relay is only for the live-but-NAT-blocked case.

## Storage model

> **Updated per DECISIONS D15 (zero operator cost).** The default is the *sender's
> own* storage; there is **no operator-funded bucket** and therefore **no quota
> system, blind tokens, or storage subscription**. A shared/quota'd bucket is now
> only a *voluntary, community-run* option, never something the operator must fund.

1. **Sender's own iCloud (Apple-first default).** Blobs go in the sender's **private
   CloudKit DB** (billed to the *user's* iCloud quota — $0 to the operator) and are
   shared to other Apple users via **`CKShare`**. The sender funds their own sharing.
2. **BYO bucket.** Any user can point Kith at their own S3 / R2 / B2 / NAS — their
   storage, their cost. Needed for cross-platform offline delivery (a web/Android peer
   can't read a sender's iCloud).
3. **Voluntary community bucket (optional).** Any entity *may* run a shared bucket
   others use, fronted by the thin stateless broker below. This is opt-in generosity,
   not required infrastructure.

Blobs are E2E-encrypted and content-addressed (BLAKE3) before leaving the device, and
get a **lifecycle expiry** (auto-delete after N days) so nothing lingers.

**The broker (only for shared/BYO-served buckets).** You can't hand arbitrary clients
raw bucket credentials, so a **thin, stateless broker** mints **scoped presigned
URLs** (PUT/GET for one content hash). It is small — but it is *the* component where
the no-log discipline must be absolute (see below). For a sender's own iCloud, CloudKit
*is* the broker, so none of this is needed in the Apple↔Apple path.

## IP privacy — what is and isn't guaranteed

**A relay or storage node transiently handles your IP — that is physically how bytes
reach you.** "No node ever sees your IP" is false for direct access and we will not
claim it. What we *do* guarantee, enforced by the deploy tool's default config:

- **Zero logging / zero persistence.** RAM-only operation, no access logs, no disk
  spill, provider-side request logging disabled where the provider allows it.
- **No identity ↔ IP linkage.** Peers authenticate **to each other** end-to-end,
  never to the relay. The relay/broker sees opaque sealed frames addressed by
  **ephemeral rendezvous tokens**, not Kith public keys. A node that somehow logged
  an IP still could not tie it to a Kith identity.
- **Quota without identity.** Allotments use **blind-signed tokens** (Privacy
  Pass-style): the operator issues N tokens and cannot link a redeemed token to who
  received it. Quota is enforced without knowing *who* you are.
- **Opt-in onion/proxy mode for true hiding.** The only way a node genuinely cannot
  see your IP is to not connect to it directly. Kith ships an **optional** mode that
  routes relay + storage access through Tor or a user-chosen proxy. Off by default
  (latency cost); on for users who want full IP hiding.

Summary of the honest promise: **never logged, never linked to you, optionally fully
hidden.**

## The deployment tool (`kith-relay`)

Goal: anyone can stand up a compliant relay on any major cloud in one command, with
privacy-hardened defaults they can't accidentally turn off.

- **Artifact:** the relay is a single **static Rust binary** + a container image,
  no runtime dependencies.
- **IaC:** **OpenTofu** (open-source Terraform) modules, one per provider:
  **AWS, GCP, Azure, Hetzner, Fly.io, DigitalOcean, Cloudflare R2, Oracle (free
  tier), bare VPS/Docker.**
- **CLI:**
  ```sh
  kith-relay deploy --provider hetzner --role both       # connection + storage
  kith-relay deploy --provider cloudflare-r2 --role storage   # bucket + broker only
  kith-relay deploy --provider oracle --role connection       # free-tier TURN/DERP
  ```
  Each run: provisions the box and/or bucket, gets auto-TLS, applies the
  **hardened no-log config by default**, sets blob lifecycle expiry, and
  **self-registers to discovery** so clients can find and rank it.
- **Storage-only needs no compute** — a Tofu module that provisions just a bucket +
  scoped creds + auto-expiry + the broker. The cheapest possible relay.
- **Defaults are the product.** No-logging, RAM-only, identity-blind rendezvous, and
  token-based quota are *on by default and hard to disable*, so a casual operator
  can't accidentally run a surveilling relay.

## Status

Design only. Implementation order (see `ROADMAP.md`): the storage-relay + broker and
the deploy tool come after the core transport (M1b) and group messaging (M2), since
they depend on the on-wire framing and rendezvous-token format those milestones
define.
