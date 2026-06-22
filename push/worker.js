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
        const { nodeId, token, sandbox } = await request.json();
        if (!nodeId || !token) return json({ error: "nodeId + token required" }, 400);
        await env.TOKENS.put(nodeId, JSON.stringify({ token, sandbox: !!sandbox }));
        return json({ ok: true });
      }

      if (url.pathname === "/notify") {
        // ciphertext = base64 of the circle-sealed payload; the NSE decrypts it.
        const { nodeId, ciphertext } = await request.json();
        if (!nodeId || !ciphertext) return json({ error: "nodeId + ciphertext required" }, 400);
        const rec = await env.TOKENS.get(nodeId, "json");
        if (!rec) return json({ error: "unknown node" }, 404);

        const host = rec.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
        const jwt = await providerToken(env);
        const res = await fetch(`https://${host}/3/device/${rec.token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": env.APNS_TOPIC,
            "apns-push-type": "alert",
            "apns-priority": "10",
          },
          // mutable-content lets the NSE intercept + decrypt before the banner shows.
          body: JSON.stringify({
            aps: { "mutable-content": 1, alert: { title: "Haven", body: "New message" }, sound: "default" },
            e: ciphertext,
          }),
        });
        if (res.status === 410) await env.TOKENS.delete(nodeId);   // token no longer valid
        return json({ ok: res.ok, status: res.status, apnsId: res.headers.get("apns-id") }, res.ok ? 200 : 502);
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
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
