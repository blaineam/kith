# Threat model & abuse resistance

## Who we protect, against whom

Haven is for small circles of real-world friends and family sharing private media. We
protect **content confidentiality, content integrity, and user anonymity** against:

| Adversary | What they can do | Our defense |
|---|---|---|
| Relay operator / network observer | See traffic timing & size; store ciphertext | Everything is E2E hybrid-PQ encrypted; relays never hold plaintext or PII |
| **Future quantum adversary** ("harvest now, decrypt later") | Store today's ciphertext, decrypt later | Hybrid X25519 + ML-KEM-768 key establishment — must break *both* |
| Active MITM on a shared link | Substitute their keys for the real recipient's | Link carries a verification hash; in-person QR is the strong anchor; new contacts are *approved*, with safety-phrase confirmation |
| Lost/stolen device | Read local content & keys | **Every on-device copy of the master seed is Secure-Enclave-wrapped** — the active seed, the NSE's shared-group push-decrypt mirror, and the device-local identity-recovery archive are each ECIES-sealed to a non-extractable P-256 Enclave key, so a raw Keychain dump yields nothing without the Enclave. (The one unsealed copy is the *opt-in* iCloud-synced archive, which must travel between devices and is protected by Apple's E2E iCloud Keychain instead.) Passphrase-encrypted backup; (planned) at-rest content encryption + remote disavow |
| Spammer using a public link | Flood connect requests | Requests are inert until approved; per-link expiring/single-use tokens; block list |
| A blocked user | Keep contacting you | Client-side refusal + removal from shared groups; no central account to reach you through |

## IP addresses (the honest version)

A relay or storage node **transiently handles your IP** — that is physically how it
moves bytes to you. So "no node ever sees your IP" is false and we don't claim it.
What we guarantee instead, enforced by default config (see `RELAY-AND-DEPLOY.md`):

- **Never logged / never persisted** — RAM-only, no access logs, provider logging off.
- **Never linked to your identity** — peers authenticate to each other E2E, never to
  the relay; the relay/mailbox sees opaque circle-sealed blobs, not your public key. The
  storage mailbox is a Haven relay (the user's own or a volunteer's) or the user's own
  S3-compatible bucket, so there is no operator-funded quota to meter (per D15).
- **Optionally fully hidden (planned, not yet shipped)** — an opt-in onion/proxy (Tor) mode for users who want a
  node to be unable to see their IP at all (off by default; latency cost).

Promise: **never logged, never linked to you, optionally fully hidden.**

## Explicit non-goals (for honesty)

- **Metadata-perfect anonymity vs. a global passive adversary, by default.** We hide
  content and identity-PII and never log/link IPs, but a relay still *handles* an IP
  to route bytes. Full metadata/IP hiding is the (planned) opt-in onion mode; today, run Haven behind your own VPN.
- **Protecting against a fully compromised endpoint.** If malware owns the device, it
  owns the plaintext. Standard for any E2E system.
- **Moderating content centrally.** There is no server to moderate from (by design).

## Abuse resistance — the hard part of E2E social

A private, server-free, E2E network *will* attract "how do you stop bad content"
questions, especially CSAM. Our answers are structural, not bolted-on:

1. **No global discovery, ever.** Distribution is strictly friend-graph-bounded.
   There is no public feed, no stranger-reach, no virality mechanic. You can only
   send to people who approved you. This removes the broadcast vector entirely.
2. **On-device sensitive-content analysis.** Apple's `SensitiveContentAnalysis`
   flags nudity locally (nothing leaves the device); flagged media is blurred with
   tap-to-reveal, per-group toggle. This is a *safety* feature for recipients, run
   with zero data collection.
3. **Approval + blocking as first-class.** Every contact is opt-in; blocking is
   immediate and complete.
4. **No anonymity for *abuse within a group*.** Posts are signed by identity keys, so
   members of a group can always attribute content to a member and remove/block them.

These are deliberately the same mechanisms that prevent the doomscroll dynamic the
product exists to avoid: small, bounded, consensual circles.

## Open questions to resolve before real users

- Key-recovery UX vs. security (escrow design).
- Per-link capability/revocation token format (see `LINK-SYSTEM.md`).
- Whether to support optional, *user-held* hash-matching against known-bad media
  sets without any server or reporting (privacy-preserving, controversial — needs
  thought).
