# Scheduled messages ("send later")

Queue a message or post now, have it go out at a specific time — with no server to
hold the queue or fire it. The trick is that the **send comes from one of the user's
own awake devices**, which is exactly what the multi-device design (D16) enables.

## Core principles

1. **Queue plaintext-at-rest, don't pre-seal.** Store the pending message as plaintext
   encrypted with the device key and **synced across the user's own devices** (account
   state). Do **not** pre-encrypt it as an MLS message: the group epoch may change
   before send time (a device is linked, a member leaves), and a message sealed
   against a stale epoch won't decrypt. Instead, **seal-and-send at send time** against
   the *current* epoch.
2. **An awake authorized device fires it.** At T, whichever of the user's devices is
   awake seals the queued plaintext and sends it. The **always-on device (a Mac, per
   D16) is the primary firer**, so a scheduled send works even if the phone is asleep.
3. **Editable / cancelable until it fires.** Because it's local plaintext, a scheduled
   message can be changed or canceled right up to T (ties to edit/unsend, D11). After
   it sends, normal unsend applies.

## Two modes

| | Send-time (default, private) | Display-time (optional, resilient) |
|---|---|---|
| Behavior | Nothing transmitted until T; an awake device sends then | Ciphertext pre-delivered now; recipients reveal at T |
| Needs at T | An awake device of yours (Mac ideal) | Recipient to have received it already |
| Strength | Strongest — nothing exists anywhere until T | On-time even if sender is asleep/offline |
| Weakness | If no device awake at T → sends late (marked) | Weaker secrecy: ciphertext sits at recipient early; a modified client could peek |
| Use for | Private messages | Non-secret timed posts ("Happy Birthday at midnight") |

Default is **send-time** (most private, edit/cancelable). Display-time is an explicit,
clearly-labeled choice for posts that must appear exactly on time and aren't secret.

## Reliability tiers (send-time mode)

- **Always-on device awake at T** → exact.
- **A device awake / app open near T** → exact-ish.
- **Otherwise** → sends when a device is next online after T, surfaced as
  *"scheduled for 9:00, sent 9:42."*

**iOS honesty:** `BGTaskScheduler` background wake-ups are best-effort, **not** exact.
Guaranteed exact-time sending while the phone is backgrounded/asleep genuinely
requires an always-on device — which is why D16's always-on forwarder matters here too.

## Correctness mechanics

- **No double-send:** a **primary-firer** designation (the always-on device, else a
  deterministic election by device id) means only one device sends. Backed by
  **recipient-side dedup by message id**, so even a race is harmless (idempotent).
- **Timezones:** store the schedule as an absolute instant (UTC) plus the intended
  timezone; fire at the instant.
- **Privacy:** the scheduled queue is encrypted at rest and in device-to-device sync;
  no relay or storage backend ever sees the plaintext or the schedule.

## Connections

- **D16 (multi-device):** the always-on device is the firer; the queue syncs across the
  user's devices.
- **D3 (MLS):** seal at send time against the current epoch (don't pre-seal).
- **D11 (edit/unsend):** scheduled items are editable/cancelable before T; unsend after.
- **D15 (store-and-forward):** delivers the message once fired, including to offline
  recipients.

## Desktop implementation status

The Tauri desktop client implements the **send-time** mode end to end (`desktop/src-tauri`):

- **Queue** (`scheduled.rs`): pending items (post or DM) are stored as plaintext in
  `scheduled.json` and fired by an in-process timer; `take_due(now)` is pure + unit-tested.
  Items are editable/cancelable until they fire (matches D11) and seal at send time against
  the current state (matches D3 — no pre-sealing).
- **GUI open** → the 15s mailbox loop fires due items; overdue items flush once on launch.
- **GUI closed (Option A — done):** `haven-desktop --headless` now also builds the active
  identity's engine, so leaving the desktop binary running headless on an **always-on machine
  makes that machine the primary firer** — scheduled sends go out with no window open. The
  messaging keys stay on that machine; the co-hosted relay still only ever moves ciphertext.
  This is the desktop realization of D16's "always-on forwarder fires it."

### Option B — relay timed-release (planned, cross-platform)

A stronger **display-time** variant that works even when *none* of the sender's machines is
awake at T, without the secrecy weakness of pre-delivering ciphertext to recipients early:

- At schedule time the client seals the envelope (`created_at = T`) and hands the **opaque
  blob** to the relay/mailbox tagged `release_at = T`.
- The relay holds ciphertext (it still can't read it) and **only surfaces the blob in
  `list`/`get` once `now ≥ T`**; recipients pull it then and see a post timestamped T.
- Ciphertext sits at the relay (which already only holds ciphertext), **not** at recipients —
  closing the "modified client could peek early" gap of the recipient-pre-delivery approach.

**Why it's a coordinated change, not a desktop tweak:** it touches the shared mailbox protocol
used by iOS/Android — `haven-net` `BlobServer`, `RelayServerHandle`/`RelayClient`
(`put_with_release(key, blob, release_at)` + release-gated `list`/`get`), and the standalone
`haven-relay`. It needs a security review (a malicious relay could withhold or early-release —
mitigated because content stays sealed and `created_at` is authenticated in the envelope) and
matching client logic on every platform. Tracked as a follow-up; the desktop client will adopt
`put_with_release` once the core lands it. Until then, **Option A covers app-closed delivery**
for anyone running an always-on Haven machine.
