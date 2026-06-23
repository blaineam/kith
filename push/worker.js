// Haven push relay — a "blind" APNs sender on Cloudflare Workers.
//
// It knows only `nodeId → device token` and forwards ENCRYPTED payloads; it never sees
// message content (the app's Notification Service Extension decrypts on-device). APNs is
// free; this Worker is free to 100k req/day, then ~$5/mo for 10M. No third-party SDK.
//
// Secrets (set with `wrangler secret put …`):
//   APNS_KEY      – the .p8 AuthKey PEM contents (-----BEGIN PRIVATE KEY----- … )
//   APNS_KEY_ID   – the 10-char Key ID
//   APNS_TEAM_ID  – your Apple Team ID (8ZVSPZYSVF)
// Vars (in wrangler.toml):
//   APNS_TOPIC = "com.blaineam.kith"
//   APNS_HOST  = "api.push.apple.com"   (use api.sandbox.push.apple.com for dev builds)
// Binding: KV namespace `TOKENS`.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return json({ ok: true, service: "haven-push" });

    try {
      if (url.pathname === "/register") {
        // A node id can have MULTIPLE devices (multi-device / linked devices) — keep a list of
        // tokens, not one, so a push reaches every device on that identity.
        const { nodeId, token, sandbox } = await request.json();
        if (!nodeId || !token) return json({ error: "nodeId + token required" }, 400);
        const rec = (await env.TOKENS.get(nodeId, "json")) || { tokens: [] };
        const tokens = (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : []))
          .filter((t) => t.token !== token);
        tokens.push({ token, sandbox: !!sandbox });
        if (tokens.length > 10) tokens.splice(0, tokens.length - 10);   // cap per identity
        await env.TOKENS.put(nodeId, JSON.stringify({ tokens }));
        return json({ ok: true, devices: tokens.length });
      }

      if (url.pathname === "/register-owner") {
        // A member who shares an S3 bucket as their circle's mailbox registers here, so the cron
        // can nudge them (silently) to re-mint fresh pre-signed URLs before the old ones expire.
        const { nodeId, token, sandbox } = await request.json();
        if (!nodeId || !token) return json({ error: "nodeId + token required" }, 400);
        await env.TOKENS.put(`owner:${nodeId}`, JSON.stringify({ token, sandbox: !!sandbox }));
        return json({ ok: true });
      }

      if (url.pathname === "/register-voip") {
        // PushKit VoIP token (separate from the regular APNs token) so calls can ring from a
        // fully-killed/locked device. One token per node id.
        const { nodeId, token, sandbox } = await request.json();
        if (!nodeId || !token) return json({ error: "nodeId + token required" }, 400);
        await env.TOKENS.put(`voip:${nodeId}`, JSON.stringify({ token, sandbox: !!sandbox }));
        return json({ ok: true });
      }

      if (url.pathname === "/call") {
        // Blind VoIP wake for an incoming call. `ciphertext` is the caller's name SEALED to the
        // callee — the worker can't read it; the device's PushKit handler decrypts it and calls
        // reportNewIncomingCall. The worker is NOT in the call: signaling rides sealed iroh,
        // media is P2P DTLS-SRTP. This is a one-shot doorbell.
        const { nodeId, ciphertext } = await request.json();
        if (!nodeId) return json({ error: "nodeId required" }, 400);
        const rec = await env.TOKENS.get(`voip:${nodeId}`, "json");
        if (!rec || !rec.token) return json({ error: "no voip token" }, 404);
        const jwt = await providerToken(env);
        const host = rec.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
        const res = await fetch(`https://${host}/3/device/${rec.token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": `${env.APNS_TOPIC}.voip`,   // VoIP pushes use the <bundleId>.voip topic
            "apns-push-type": "voip",
            "apns-priority": "10",
          },
          body: JSON.stringify({ e: ciphertext || "" }),
        });
        if (res.status === 410) await env.TOKENS.delete(`voip:${nodeId}`);
        return json({ ok: res.ok }, res.ok ? 200 : 502);
      }

      if (url.pathname === "/notify") {
        // ciphertext = base64 of the circle-sealed banner the NSE decrypts.
        // event = base64 of the sealed circle event itself (push-inline sync).
        // silent = true → a content-available push with no banner (used to sync an authored
        //          event to the sender's OWN other devices, so it doesn't self-notify).
        // The relay reads neither `e` nor `ev` (both ciphertext).
        const { nodeId, ciphertext, event, silent } = await request.json();
        if (!nodeId || (!silent && !ciphertext)) return json({ error: "nodeId required" }, 400);
        const rec = await env.TOKENS.get(nodeId, "json");
        const tokens = rec ? (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : [])) : [];
        if (!tokens.length) return json({ error: "unknown node" }, 404);

        const jwt = await providerToken(env);
        const body = JSON.stringify((() => {
          const payload = silent
            ? { aps: { "content-available": 1 } }
            : {
                aps: {
                  "mutable-content": 1,                              // triggers the on-device NSE
                  alert: { title: "Haven", body: "New activity" },  // fallback if the NSE can't decrypt
                  sound: "default",
                },
                e: ciphertext,
              };
          // Inline the sealed event only if the whole payload stays under APNs' 4KB limit.
          if (event && JSON.stringify(payload).length + event.length < 3900) payload.ev = event;
          return payload;
        })());

        const survivors = [];
        let anyOk = false;
        for (const t of tokens) {
          const host = t.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
          const res = await fetch(`https://${host}/3/device/${t.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": env.APNS_TOPIC,
              "apns-push-type": silent ? "background" : "alert",
              "apns-priority": silent ? "5" : "10",
            },
            body,
          });
          if (res.ok) anyOk = true;
          if (res.status !== 410) survivors.push(t);   // drop tokens APNs says are dead
        }
        if (survivors.length !== tokens.length) {
          if (survivors.length) await env.TOKENS.put(nodeId, JSON.stringify({ tokens: survivors }));
          else await env.TOKENS.delete(nodeId);
        }
        return json({ ok: anyOk, devices: tokens.length }, anyOk ? 200 : 502);
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },

  // Cron trigger (see wrangler.toml): nudge every S3-bucket owner with a SILENT push so their
  // app wakes in the background and re-mints fresh pre-signed URLs for their circles — keeping
  // the mailbox alive without the user thinking about it. Best-effort (iOS throttles silent
  // pushes); the app also re-mints on launch and schedules a local fallback reminder.
  async scheduled(event, env, ctx) {
    ctx.waitUntil((async () => {
      const jwt = await providerToken(env);
      let cursor;
      do {
        const page = await env.TOKENS.list({ prefix: "owner:", cursor });
        cursor = page.list_complete ? undefined : page.cursor;
        for (const k of page.keys) {
          const rec = await env.TOKENS.get(k.name, "json");
          if (!rec || !rec.token) continue;
          const host = rec.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
          const res = await fetch(`https://${host}/3/device/${rec.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": env.APNS_TOPIC,
              "apns-push-type": "background",
              "apns-priority": "5",
            },
            body: JSON.stringify({ aps: { "content-available": 1 }, remint: 1 }),
          });
          if (res.status === 410) await env.TOKENS.delete(k.name);   // owner's token died
        }
      } while (cursor);
    })());
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

// ---- APNs provider JWT (ES256), cached ~50 min ----
let _cached = { jwt: null, at: 0 };
async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (_cached.jwt && now - _cached.at < 3000) return _cached.jwt;   // reuse for <50 min

  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const payload = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8", pemToBytes(env.APNS_KEY),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput));
  const jwt = `${signingInput}.${b64urlBytes(new Uint8Array(sig))}`;
  _cached = { jwt, at: now };
  return jwt;
}

function pemToBytes(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}
function b64url(str) { return b64urlBytes(new TextEncoder().encode(str)); }
function b64urlBytes(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
