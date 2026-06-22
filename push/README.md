# Haven push relay (Cloudflare Worker)

A **blind** APNs sender: it only maps `nodeId → device token` and forwards **encrypted**
payloads. Content is decrypted on-device by the app's Notification Service Extension. APNs
is free; the Worker is free to 100k req/day (~$5/mo at 10M). No third-party SDK, no content.

## Deploy (≈5 min)
1. Apple Developer → Keys → create an **APNs Auth Key** (.p8). Note the **Key ID** + your **Team ID**.
2. `npm i -g wrangler && wrangler login`
3. `wrangler kv namespace create TOKENS` → paste the `id` into `wrangler.toml`.
4. Secrets:
   ```
   wrangler secret put APNS_KEY      # paste the .p8 file contents
   wrangler secret put APNS_KEY_ID   # 10-char Key ID
   wrangler secret put APNS_TEAM_ID  # 8ZVSPZYSVF
   ```
5. `wrangler deploy` → note the `https://haven-push.<you>.workers.dev` URL.

## API
- `POST /register { nodeId, token, sandbox? }` — the app calls this with its APNs token.
- `POST /notify { nodeId, ciphertext }` — sender/mailbox calls this to wake an offline peer;
  `ciphertext` = base64 of the circle-sealed blob the NSE will decrypt.

## App side (still to wire — see docs/NOTIFICATIONS.md)
- Add a **Notification Service Extension** target that decrypts `e` via the Rust core and
  rewrites the alert. Needs a **Keychain access group / app group** so the extension can read
  the identity seed.
- `registerForRemoteNotifications`, POST the token to `/register`.
- Call `/notify` on the mailbox-upload path (offline recipient).

Dev builds use the sandbox: register with `sandbox: true`.
