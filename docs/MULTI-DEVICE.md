# Multi-device: one account, many authorized devices

> **Status — building the full model in phases (D16).** What already ships: a
> **multi-identity switcher**, **move-to-device** via a transfer code / QR (`haven-seed:…`),
> **iCloud-Keychain backup/restore** of identity history (the active seed stays device-only),
> and **multi-token push** (the relay holds several device tokens per identity, so every
> linked device gets pushes and authored events self-sync through the shared circle mailbox).
>
> **Phase 1 (done):** the **device-credential trust layer** is implemented and unit-tested in
> the core — [`p2pcore::device`](../core/p2pcore/src/device.rs): a per-device keypair, an
> account-signed [`DeviceCredential`] (`{account_id, device bundle, name, created_at}`), and a
> versioned, account-signed [`DeviceList`] (active + revoked, higher-version-wins merge,
> rollback-defended). This is deliberately **MLS-independent** — it's just signed bindings the
> existing per-recipient hybrid-KEM sealing can already encrypt to, so it works on today's
> engine and the MLS hardening (Phase 5) layers on without changing these signatures.
>
> **Phase 3 (core done):** the **convergence engine** is implemented and unit-tested —
> [`p2pcore::selfsync`](../core/p2pcore/src/selfsync.rs): an `AccountState` CRDT (last-write-wins
> registers for roster / contacts / profile / settings / blocked, grow-only max read cursors)
> with a commutative/associative/idempotent `merge`, plus self-encryption via a seed-derived
> [`Identity::self_sync_key`] only the user's own devices can derive. So concurrent edits on two
> devices provably converge, and the mailbox only ever sees ciphertext. Remaining for Phase 3:
> the mailbox read/write channel + sync loop, FFI export, and per-client wiring.
>
> **Still ahead:** enrollment flow + UI (Phase 2), the mailbox channel + client wiring that
> drives the Phase 3 engine, live device-to-device delivery + a personal forwarder (Phase 4),
> and the MLS leaf/commit hardening for forward secrecy + post-compromise security (Phase 5).
> See **Implementation phases** below.

## Implementation phases (D16)

| Phase | Scope | Where | State |
|---|---|---|---|
| **1. Device-credential trust layer** | Per-device keys; account-signed `DeviceCredential`; versioned signed `DeviceList` (add/revoke, higher-version-wins, rollback defense); verify against the pinned account key. | `p2pcore::device` | **✅ core done & tested** |
| **2. Enrollment & UI** | FFI export (done): `issue/verify_device_credential`, `sign/verify_device_list`, `device_list_is_authorized`, plus an `AccountStateHandle` object + `seal/open_account_state`. Ahead: QR/short-code link of a new device + out-of-band verification phrase; the authorizing device issues the credential and publishes a new `DeviceList`; "Blaine linked a new device" notice. Per-client (iOS → Android → desktop). | `p2pcore-ffi::multidevice` + clients | 🟡 **FFI export done**; enrollment QR/verify + UI ahead |
| **3. Account-state self-sync** | A per-account state blob (roster, circles, contacts, profile, settings, blocked list, read state) **self-sealed to the account's own devices** and synced via the mailbox; CRDT/LWW merge so devices converge. Gives "my devices show the same thing." | `p2pcore::selfsync` + relay channel | 🟡 **CRDT core done & tested**; mailbox channel + FFI + client wiring ahead |
| **4. Live delivery + personal forwarder** | Real-time device-to-device push when both are online; an always-on device (Mac) as the user's ordered store-and-forward node, complementing the relay. | `haven-net` + clients | ⏭️ |
| **5. MLS hardening** | Each device becomes an MLS leaf; Add/Remove **commits** give forward secrecy + post-compromise security on link/revoke. Gated on the separate MLS (D3) work. | `p2pcore` (mls-rs) | ⏭️ (after MLS) |

> **Honest dependency:** the *fully drawn* design (device = MLS leaf, revocation = MLS Remove
> commit re-key) needs **MLS**, which is itself not yet built (the engine currently seals a
> fresh content key per recipient via the hybrid KEM — see `ARCHITECTURE.md`). Phases 1–4 are
> built on **today's** engine and deliver real live multi-device sync; Phase 5 upgrades the
> secrecy guarantees once MLS lands. Nothing in 1–4 has to change when 5 arrives.

A user is **one account identity** with a set of **authorized devices**, each holding
its *own* key. No private key is ever copied between devices. This gives "receive on
all my devices" plus instant revocation of a lost one — without ever changing who you
are to your contacts.

## The key hierarchy

```
Account identity key  (long-term; represents you to contacts; escrowed for recovery)
        │ signs
        ├── Device credential  →  iPhone   device keypair
        ├── Device credential  →  MacBook  device keypair
        └── Device credential  →  Web      device keypair
```

- **Account identity key** — the long-term key contacts pin (from the first QR/link
  verification). It signs device credentials and signed device-list updates. It is
  *not* needed for day-to-day messaging (devices use their own keys), so it can stay
  escrowed (passphrase-encrypted in the user's own iCloud Keychain, per D2) and only
  be unlocked when linking or revoking a device. Signed with the hybrid signature
  (Ed25519 + ML-DSA).
- **Device key** — generated on-device, never leaves it (Secure Enclave on Apple).
- **Device credential** — `{account_id, device_pubkey, device_name, created_at}`
  signed by the account identity key. Proves "this device is authorized by this
  account."

## Linking a new device (no PII)

1. New device generates its keypair and shows a QR / short code.
2. An already-authorized device scans it; both screens display a **short verification
   phrase** the user confirms (out-of-band check so a relay can't inject a rogue
   device).
3. The authorizing device issues a **signed device credential** for the newcomer.
4. It adds the new device as a **leaf** to all the user's active MLS groups (Add +
   Commit), so it starts receiving immediately.
5. Contacts' clients see a new leaf whose credential chains to the **pinned account
   key** → trusted automatically, optionally with a transparent *"Blaine linked a new
   device (MacBook)"* notice (iMessage-style).

## Receiving on all devices (how it maps to MLS)

Each device is its own **leaf** in every group the user belongs to. MLS encrypts to
all leaves efficiently, so a message is decryptable by **all** of the user's devices.
Adding/removing a device is an MLS Add/Remove commit. This is precisely what MLS was
designed for (chosen in D3), so multi-device is native, not bolted on.

## The always-on device as a personal forwarder

An always-on device (typically a **Mac** — a web tab is a weak always-on node) doubles
as the user's **personal store-and-forward node**, advancing the $0 goal because it's
infrastructure the user already owns:

- It caches encrypted group traffic and **forwards it to the user's other devices**
  when they come online — complementing or replacing a Haven relay mailbox / BYO
  S3 bucket for *your own* devices.
- It forwards **ciphertext**; it doesn't need to decrypt to relay (though, being your
  device, it legitimately could read its own copy).

**Honest MLS constraint:** MLS requires each device to process group changes
(commits) **in order** to stay in sync. So the forwarder must keep the **ordered
backlog** of handshake + application messages — not just the latest — or a
long-offline device can't catch up. This is the standard MLS "delivery service" role,
which our store-and-forward layer (D15) already plays.

## Revocation & recovery

- **Lost/stolen device:** the account key signs an updated device list excluding it;
  an MLS Remove commit re-keys the groups (post-compromise security — the removed
  device can't read anything after removal). You stay *you*; only that device goes
  dark. Contacts honor the signed update.
- **Lost one device, others remain:** revoke as above, link a replacement.
- **Lost all devices:** restore the **account key from escrow** (passphrase + iCloud
  Keychain), then re-authorize fresh devices. This is the one place the account key
  must be recoverable — hence escrow (D2).

## Device-list authentication (anti-rogue-device)

Contacts encrypt to the user's *current* device set, so that set must be trustworthy:
the device list / each credential is **signed by the account key**, contacts **pin**
that account key at first verification, and any new device must present a credential
that chains to it. A malicious relay cannot forge or inject a device. The optional
"new device linked" notices make additions visible to contacts.

## Honest limits

- **Account-key compromise = full-account compromise.** Mitigated by escrow + Secure
  Enclave + keeping it offline-ish (not needed for daily messaging). It is the crown
  jewel; protect accordingly.
- **Long-offline devices** must replay the ordered backlog to catch up (MLS in-order
  commits) — the forwarder/relay must preserve order.
- **Web as always-on is weak** (open-tab / service-worker lifetime limits); native
  desktop is the real always-on node.
