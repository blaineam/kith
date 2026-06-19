# Operating costs — $0 to the operator

**Design goal: nothing the operator runs is required, and the operator pays nothing
monthly.** The user's own storage and free/community infrastructure carry everything.
This supersedes the earlier quota'd-bucket model (see DECISIONS D15).

## Who pays for what

| Piece | How | Cost to operator |
|---|---|---|
| Discovery (find a peer by key) | mainline DHT (decentralized) | **$0** |
| NAT hole-punching (~80% of links) | public STUN | **$0** |
| Connection relay (~15–20% hard-NAT + calls) | iroh/n0 free relays + community-run relays | **$0** (best-effort, see trade-off) |
| Storage / offline delivery / large files | **the sender's own iCloud** (private CloudKit + `CKShare`) or BYO S3/R2/NAS | **$0** (funded by the sender's own storage) |
| Web client + AASA + marketing page | **GitHub Pages** (`blaineam.github.io`) | **$0** |
| "You got media" notifications | APNs / Web Push | **$0** |

**Result: the app is a one-time $4.99 with no subscription and no monthly operator
cost, ever.**

## Why storage is free to the operator

- Blobs go in the sender's **private CloudKit database**, billed to **the user's**
  iCloud quota. (Only the *public* CloudKit DB bills the developer — we never use it.)
- Apple-to-Apple sharing uses **`CKShare`**: the record stays in the sender's
  account; recipients pull from it. "The sender funds the cost to share" — literally.
- Non-iCloud / power users can **BYO** any S3/R2/NAS bucket — also their cost.

## The honest trade-off (dependency, not dollars)

1. **Connection relay leans on iroh/n0's free public relays** — production-grade but
   goodwill, not an SLA. If it degrades, hard-NAT connections and live calls suffer
   until community relays fill in. *Mitigation:* the optional `kith-relay` deploy tool
   lets anyone (incl. the operator, later) run a relay for reliability — **never
   required, never a mandatory monthly bill**.
2. **iCloud storage is clean Apple↔Apple only.** A web/Android recipient can't read a
   sender's iCloud. Cross-platform *offline* delivery falls back to both-peers-online
   (direct/connection-relay) or a sender-supplied BYO bucket. Apple↔Apple (the primary
   case) is seamless and free.

## What this model deletes

Removing any operator-funded storage removes all the machinery that existed only to
meter it: the 512MB quota, blind-signed tokens, App Attest gating, the storage
subscription, and the funded default bucket. Simpler product, cleaner story.

## Optional: paid reliability, if ever wanted

If the operator ever wants guaranteed relay reliability, a single ~$5/mo VPS running
`kith-relay` (or a Cloudflare R2 storage relay) is available — but it is strictly
optional and the app is fully functional without it.
