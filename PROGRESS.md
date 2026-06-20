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

## ✅ Multi-circle — DONE (committed, tested)
- [x] Engine: `KithSocial` holds multiple circles (each its own group / event-log / seen-set)
- [x] Persistence: per-circle state on disk + legacy-format migration
- [x] Wire protocol: Hello/Event carry a circle id; received events route to the right circle
- [x] FeedStore + UI: circle switcher in the feed title, per-circle feed, create circle
- [x] Circle propagation: a Hello for an unknown circle auto-creates it (verified sender), so it forms on their side
- [x] CircleView: add existing contacts to a circle / leave a circle

---

## ✅ Mesh relay (#13) — DONE
Relay frame (type 9): an internet-connected nearby phone forwards a sealed frame it can't read toward its destination (cleartext routing header, E2E payload), re-floods nearby (ttl-bounded), msg-id dedup. Posts + handshakes originate relays.

## ✅ Direct messages (#9) — DONE
A DM = a private 2-person circle (reuses the whole E2E + delivery + mesh stack).
Messages list, contact picker, chat-bubble thread; DMs hidden from the feed switcher.

## ✅ Stories (#10) — DONE
`story` flag on posts (24h retention auto-expiry); stories tray (rings) at the top of the feed; full-screen viewer with progress bars + tap nav.

## ✅ Video mute + trim (#3) — DONE
Attached video chips get a Trim (system editor) + Mute-audio (strip audio track) menu.

## ✅ Notifications (#6) — DONE
Local-only, no server/third party. BGAppRefreshTask wakes → syncs → local notification for anything new; live inbound notifies directly (deduped, foreground-suppressed).

## 🔨 Now building

### macOS build (adapt the iOS app)
- [ ] Add a macOS target sharing the engine + SwiftUI code

---

## 🗺️ Queue (in order)
1. ~~#4 Multi-circle~~ ✅ · ~~#13 Mesh~~ ✅ · ~~#9 DMs~~ ✅ · ~~#10 Stories~~ ✅ · ~~#3 Video~~ ✅ · ~~#6 Notifications~~ ✅
2. **macOS** build ← here · **Static web client**
3. Hardest, last: #11 calls · #12 shared-S3 store

---

## 👀 How to watch progress
- **This file** on GitHub — updated as each box above is checked.
- **Commit feed** — github.com/blaineam/kith — every piece is a pushed commit with a clear message.
- **Task board** in your Claude app — live status of each item.
