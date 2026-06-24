# Bring-your-own storage (Haven relay or your own S3), no secrets you host

Users can keep their media on **their own** storage — and you (the maker) never host
an API key or client secret for any of it. This is core to the "clean hands" rule:
nothing you hold can be used to bypass a user's storage.

## Options (Settings → Storage)

The only two media-storage backends are a **Haven relay mailbox** and the user's **own
S3-compatible bucket**:

| Option | How | What you host |
|---|---|---|
| **Haven relay mailbox** (default) | sealed blobs park on a Haven relay's local disk — the in-app relay any official client can host, or the standalone `haven-relay` daemon | nothing (relay is user/community-run) |
| **Custom S3 bucket** | user enters endpoint + region + bucket + access key + secret; stored only in the device **Keychain** | nothing |

The S3 path works with **AWS S3, Cloudflare R2, Backblaze B2, MinIO**, rclone serve s3,
etc.

## Security posture

- Media is **end-to-end encrypted before it is stored** anywhere — the storage
  backend (a Haven relay or the user's own bucket) only ever holds ciphertext.
- S3 keys live **only in the device Keychain**
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synced to you.
- You cannot read, enumerate, or revoke a user's storage — you hold no credentials.

## Status

- ✅ Storage settings UI; **functional Custom S3 config** (saved to Keychain);
  backend selection.
- ✅ **Working S3 path**: a real SigV4 `S3Client` does encrypted-blob put/get/list against
  a BYO bucket; the per-circle mailbox uses **pre-signed URLs** (`PresignStore`) so members
  never hold the bucket credentials. Circle-sealed media is stored + re-served peer-to-peer.
- ✅ **Haven relay mailbox**: sealed blobs park on the relay's local disk (in-app
  `RelayHost` or the standalone `haven-relay` daemon) and are pulled by other members.
