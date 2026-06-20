# Kith — Live Progress

A running log of what's built, what's shipping, and what I'm working on right now.
Updated continuously. (Times in your local day.)

---

## 🚦 Shipping status

- **Live on TestFlight:** build 26
- **Built + committed, batched for next upload (one binary):** build 27
  - 🐛 Crash-on-open fix (panic contained at the Swift-callback boundary)
  - 🎞️ Real media optimization — 1080p video, ≤2560px photos (the toggle was cosmetic before; this is what fixes videos not sending)
  - 📦 Chunked media transfer (512KB sealed chunks → large videos send, flat memory)
  - 🔇 Silent mode · ❤️ double-tap heart · 🔈 tap-to-mute · 👀 see-who-reacted · 🕑 relative timestamps
  - Honest connection status on the You page
- ⏳ Holding uploads ~24h (hit Apple's daily upload limit) — everything below rolls into the same single build.

## ✅ Proven working (device-to-device, user + mom)
Post-quantum E2E identity · invite QR + scanner + verified handshake · **two-way messaging over internet AND nearby Bluetooth/Wi-Fi mesh** · encrypted media · persistence · circle management · retention · Apple Music · scroll-driven playback.

---

## 🔨 Now building

### #4 — Multi-circle (in progress)
- [ ] Engine: `KithSocial` holds multiple circles (each = its own group / event-log / seen-set)
- [ ] Wire protocol: frames carry a circle id; route received events to the right circle
- [ ] Persistence: per-circle state in the on-disk store
- [ ] UI: circle switcher + per-circle feed; create / name / leave a circle
- [ ] Circle roster: signed member list so joiners can see who else is in a circle

---

## 🗺️ Queue (in order)
1. **#4 Multi-circle** ← here
2. #13 Mesh relay (nearby-first; internet peers relay opaque sealed messages onward)
3. #9 Direct messages (1:1 private threads)
4. #10 Stories (ephemeral full-screen)
5. **macOS** build (adapt the iOS app)
6. **Static web client** (matching the iOS look)
- Backlog: #6 notifications (background fetch, no server) · #3 video trim + mute · #11 calls · #12 shared-circle S3 store

---

## 👀 How to watch progress
- **This file** on GitHub — updated as each box above is checked.
- **Commit feed** — github.com/blaineam/kith — every piece is a pushed commit with a clear message.
- **Task board** in your Claude app — live status of each item.
