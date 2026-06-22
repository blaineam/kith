# The reach-me link / QR system

## The core idea

**Your public key is your permanent address.** You don't need a server to "host
you": iroh's discovery publishes a *signed* record of your current network location
to the **mainline DHT** (the decentralized DHT BitTorrent uses — no central
directory), keyed by your Ed25519 public key. Anyone who has your key can always find
your current address, even as you move between networks. So a link can be permanent
with zero backend.

## Anatomy

```
https://haven.link/u/<base32-id>#<base32-verify>
        └─ Universal Link ─┘     └─ stays in the fragment ─┘

haven://u/<base32-id>#<base32-verify>     (deep link / QR form)
```

| Part | Bytes | Purpose |
|---|---|---|
| `id` | 32 | Ed25519 public key = routable node id; resolved to a live address via DHT discovery |
| `verify` (fragment) | 16 | BLAKE3 hash of the *full* hybrid key bundle (Ed25519 + X25519 + ML-KEM); tamper/MITM check |

Three deliberate properties:

1. **The id is the whole address.** No lookup table, no account row. Works forever.
2. **The sensitive part lives in the `#fragment`**, which browsers never send to the
   server — so even the page hosting the link sees nothing. Honors "collect no data"
   at the protocol level.
3. **Graceful degradation.** On a phone with the app → opens the app (Universal Link
   / App Link). Without the app → the static web client (same WASM core) starts the
   identical connection. One link, every platform.

## On your own website

Just drop an `<a href="https://yoursite/u/...#...">`. No backend. The only static
infra anywhere is a tiny `apple-app-site-association` / `assetlinks.json` file (zero
data, ~free static hosting) telling phones the domain opens the app. Host it on a
default `haven.link` domain *or* on your own site for your own links. Custom scheme
`haven://` is the no-domain fallback (loses the graceful web landing).

## Trust & the approval flow

A QR scanned in person is a strong anchor (nobody can MITM a screen you're looking
at). A link shared over the internet is weaker, so link-connects are **never
automatic**:

1. Someone uses your link → creates a **pending connection request**, inert until you
   approve. (Also the spam/abuse defense for a public link: anyone can knock, nobody
   gets in without you opening the door.)
2. On approval, both sides compare a **short verification phrase** derived from the
   `#fragment` — Signal's "safety number," made friendly — to confirm no tampering.

Implemented today in `link.rs`: encoding both forms, parsing, requiring the
verification fragment, and `HavenLink::matches()` (the tamper check against the
identity fetched from discovery).

## Two flavors of link

| | **Identity link** (on your website) | **Invite link** (private, scoped) |
|---|---|---|
| Carries | just your id | a signed, optionally expiring / single-use token |
| Use | "anyone can request to reach me" | "this link joins *the Miller Family* group, once" |
| Revoke | block per-requester | invalidate the token — link dies, key stays safe |
| Privacy | permanent (the point) | rotate / expire freely |

The identity link is permanent and safe because requests are inert until approved;
private invites are revocable capabilities you can hand out and kill individually.
Both are just bytes in a URL — no server holds them.

*(Invite-link tokens are designed but not yet implemented; `HavenLink` currently
covers the identity link. Token format is an open item in `THREAT-MODEL.md`.)*
