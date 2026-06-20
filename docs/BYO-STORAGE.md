# Bring-your-own storage (S3 + cloud drives), no secrets you host

Users can keep their media on **their own** storage — and you (the maker) never host
an API key or client secret for any of it. This is core to the "clean hands" rule:
nothing you hold can be used to bypass a user's storage.

## Options (Settings → Storage)

| Option | How | What you host |
|---|---|---|
| **Your iCloud** (default) | private CloudKit / iCloud Drive, billed to the user's quota | nothing |
| **Custom S3 bucket** | user enters endpoint + region + bucket + access key + secret; stored only in the device **Keychain** | nothing |
| **Google Drive / Dropbox** | **OAuth 2.0 + PKCE** — user signs in on the provider's page; Kith keeps only a token in the Keychain | nothing |

Works with AWS S3, Cloudflare R2, Backblaze B2, rclone serve s3, etc. for the S3 path.

## Why no secrets to host — PKCE

Native apps use the **Authorization Code flow with PKCE** (RFC 7636). The app is a
**public client**:

- The **client ID is public** (embedded in the app) — it is *not* a secret.
- Instead of a client secret, the app proves itself with a one-time
  **code_verifier / code_challenge** pair generated on-device per login.
- The user authenticates on the **provider's own page** (`ASWebAuthenticationSession`),
  so Kith never sees their password; the redirect comes back to the app's URL scheme.
- Kith stores only the resulting **access/refresh token**, in the Keychain.

So there is **no client secret anywhere** — not in the app, and nothing you host on a
server. You register a *public* OAuth client per provider (Google Cloud / Dropbox
console) once; only the public client ID ships in the app.

## Security posture

- Media is **end-to-end encrypted before it is stored** anywhere — the storage
  provider (even the user's own bucket) only ever holds ciphertext.
- S3 keys and OAuth tokens live **only in the device Keychain**
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synced to you.
- You cannot read, enumerate, or revoke a user's storage — you hold no credentials.

## Status

- ✅ Storage settings UI; **functional Custom S3 config** (saved to Keychain);
  provider selection; PKCE helper (`PKCE` in `Storage.swift`); OAuth connect UI.
- ⏭️ Live OAuth token exchange + the actual upload/download against the chosen
  provider land with the storage/send path (roadmap M5) — they need the per-provider
  public client IDs (registered by you, no secret) and the encrypted-blob upload code.
