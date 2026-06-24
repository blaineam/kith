# Multi-device: one account, many authorized devices

> **Status (shipped vs. designed):** the account-key / device-credential / MLS-leaf model
> below is the **target design**, not yet built. What ships **today** is simpler: a
> **multi-identity switcher** (a roster of identities you can jump between, each with its
> own profile namespaced by node-id), **move-to-device** via a transfer code / QR
> (`haven-seed:…`), **iCloud-Keychain backup/restore** of identity history (the active
> seed stays device-only), and **multi-token push** (the relay holds several device tokens
> per identity, so every linked device gets pushes and authored events self-sync). True
> per-device keys + signed device credentials + live device-to-device sync are still ahead
> (see `ROADMAP.md` M2b).

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
