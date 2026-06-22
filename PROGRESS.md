# Haven — Live Progress

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
- [x] Engine: `HavenSocial` holds multiple circles (each its own group / event-log / seen-set)
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

## ✅ macOS — DONE (Mac Catalyst)
Same engine + SwiftUI app builds + runs on macOS (Apple Silicon). Added the macabi Rust slice; guarded the one iOS-only API. Mac Catalyst build green.

## ✅ Modern story camera — DONE
Instagram-style: live camera (tap=photo, hold=video, flip, library), then a composer to add a **song** + an easy **caption**, then Share to story. Viewer plays the song while watching.

## ✅ Static web client — DONE
Single-file, zero-dep web app mirroring the iOS look (gradient, cards, story rings, tab bar, DM threads, You page, story viewer). Interactive on local data; deployed to apps/haven/app/.

## ✅ Shared circle store (#12) — DONE
seal_bytes/open_bytes group primitive + a real SigV4 S3 client + "Volunteer as tribute": a member keeps a circle-sealed (host can't read) copy of media in their bucket and re-serves it P2P to anyone missing it. No cred sharing.

## ✅ P2P voice calls (#11) — DONE (device-test pending)
CallKit UI + invite/accept/hangup signaling + 16 kHz audio, all over the existing P2P transport — no call server. Call button in DM threads + in-call overlay. Live audio quality needs on-device testing (no mic/CallKit in the simulator); video is the follow-on.

---

## 🎉 The whole backlog is done
Multi-circle · Mesh relay · Direct messages · Stories + modern camera (song + caption) · Video trim/mute · Local notifications · macOS (Mac Catalyst) · Static web client · Shared "volunteer" store · P2P voice calls.

Everything builds (iOS + Mac Catalyst), Rust + UI tests green, all committed + pushed.
**Next:** device-test the new features (esp. calls + camera), then batch-upload to App Store Connect once the daily limit resets.

---

## 👀 How to watch progress
- **This file** on GitHub — updated as each box above is checked.
- **Commit feed** — github.com/blaineam/haven — every piece is a pushed commit with a clear message.
- **Task board** in your Claude app — live status of each item.
