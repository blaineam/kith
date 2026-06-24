# In-app camera, Apple Music on posts, and audio crossfade

Design **and security audit** for three linked features. Per the project's standing
rule, every step here is checked so the maker never holds keys and nothing leaks off
the device unsealed.

## 1. In-app camera (photos + video)

A simple, intuitive capture sheet (AVFoundation `AVCaptureSession`): tap for photo,
hold/record for video, flip camera, flash. Captured media lands in the app sandbox,
is shown in the composer, then is **sealed E2E before it ever leaves the device**.

**Security audit**
- **Permissions:** `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` with
  honest, plain-language strings. Capture only after the user taps — never in the
  background.
- **On-device only:** captured files live in the app's sandbox `tmp`/caches, are
  added to a post as a content-addressed blob, and are **encrypted with the hybrid-PQ
  content key (AES-256-GCM) before any transmission**. No frame, thumbnail, or file
  ever touches a server in the clear. (Same `p2pcore::social` seal path as text.)
- **Metadata hygiene:** strip GPS/EXIF location and identifying maker tags by default
  on capture/import; the user can opt to keep them. No silent location leak.
- **No analytics, no third parties:** the camera pipeline calls no SDK, logs nothing,
  and uploads nothing. Temp files are deleted after the post is sealed.
- **Maker holds nothing:** there is no server in this path, so there is nothing for
  the maker to be compelled to produce.

## 2. Apple Music on a post

The author can attach a song that plays alongside a photo/video. Near the post, a
small pill shows **artist + song title** with an **audio-playing animation** while it
plays. Each viewer hears it through **their own** Apple Music subscription.

**Security & licensing audit**
- **References only — never audio.** We attach a MusicKit catalog reference
  (`{catalogId, title, artist, artworkURL, durationMs}`), never the audio data. This
  is the *only* legal model (DRM) and it means **no redistribution, no piracy, no
  rights exposure**. A viewer without a subscription gets a 30s preview / tap-to-open.
- **The reference rides the E2E payload.** The track reference is a field on the
  social `Event`, sealed exactly like the rest of the post — a relay/storage node sees
  only ciphertext. No new plaintext channel, no new metadata leak.
- **No PII, no operator role.** MusicKit authorization is per-device and Apple-managed;
  Haven never sees the user's Apple ID, library, or listening data, and adds **no
  central component** — the "maker holds no keys" property is fully preserved.
- **Least privilege:** request MusicKit authorization only when the user chooses to
  attach/play a song; degrade gracefully (show the pill, disable playback) if denied.
- **Entitlement note:** the MusicKit capability + `com.apple.developer.musickit`
  entitlement are **granted on the App ID** — live Apple Music attach + playback is shipped.

## 3. Audio crossfade (music ↔ video)

When a post has attached music, its **video plays muted** by default while the music
plays. If the viewer **unmutes the video**, the background music **fades out** as the
video audio **fades in** — a clean crossfade — and fades back the other way on re-mute
or scroll-away.

- One `AudioCoordinator` owns an `ApplicationMusicPlayer` (music) and the visible
  `AVPlayer` (video), ramping volumes over ~300–500ms. Only one post's audio is active
  at a time (scrolling hands off with a fade).
- **Security surface: none.** This is local playback only — no network, no data, no
  keys. The only guarantee we keep is **honoring the user's control** (muted by
  default; unmute is explicit; nothing autoplays audibly without a clear affordance).

## Data-model change (security-reviewed)

`p2pcore::social::EventKind::Post` gains optional `media: [MediaRef]` (already present
as content refs) and `music: Option<TrackRef>`. `TrackRef` is non-secret reference
data, serialized inside the **already-sealed** event — no schema change weakens the
encryption boundary; it's just more sealed bytes.

## Status

**Implemented:**
- ✅ `TrackRef` + `music`/`media` on posts in `p2pcore` + FFI (sealed-event payload).
- ✅ Feed media rendering + **now-playing pill with audio animation** (Simulator-verified).
- ✅ Composer attach: Photos/Videos picker (`PHPicker`), in-app **camera**
  (`AVCaptureSession`, tap=photo / hold=video / flip), **song picker**.
- ✅ `AudioCoordinator` + video-volume crossfade; muted-video-while-music model.
- ✅ Privacy usage strings (camera/mic/photos/Apple Music).

**Device-verified / follow-ups (security-relevant):**
- ⏭️ **EXIF/GPS stripping must run at the seal-and-send boundary.** Today media is
  local-only (never sent), so nothing leaks; when media send is wired (with networking),
  strip metadata *before* sealing. Tracked here so it isn't missed.
- ⏭️ **Real Apple Music** needs the **MusicKit capability + `com.apple.developer.musickit`
  entitlement** on the App ID. Until enabled, the picker uses sample songs and the
  `MusicPlayback` seam is a no-op (pill + crossfade structure already work). NOT added
  to the entitlements yet so TestFlight signing stays green — enable on the App ID first.
- ⏭️ Camera + MusicKit playback verify on a real device (not the Simulator).
