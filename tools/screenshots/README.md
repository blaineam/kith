# Haven — Store Screenshot Pipeline

A small, config-driven tool that turns **raw app screenshots** into **polished,
branded store marketing images** for **Google Play (Android)** and the
**Microsoft Store (Windows)**.

It frames each raw shot inside a device (a phone bezel for Android, a desktop
window for Windows), drops it on a Haven-branded background, adds a punchy
gradient headline + subtitle, and exports at the exact pixel sizes each store
wants.

Brand matches the app/site exactly — violet `#7C3AED` → pink `#EC4899` → amber
`#F59E0B` on a `#0b0b10` dark base, system font stack — pulled straight from
`web/styles.css`.

```
tools/screenshots/
├── package.json            # node tool, deps: sharp
├── screens.json            # ← edit captions / scenes here
├── screens.schema.json     # JSON schema for editor autocomplete
├── src/
│   ├── cli.js              # entry: frame | one | samples | list
│   ├── render.js           # the compositor (background, frame, text)
│   ├── brand.js            # brand tokens mirrored from web/styles.css
│   └── sizes.js            # store output size presets
├── scripts/
│   ├── capture-android.sh  # adb demo-mode capture → raw/android/*.png
│   └── capture-windows.ps1 # PowerShell window capture → raw/windows/*.png
├── raw/{android,windows}/  # raw input screenshots land here
├── out/{android,windows}/  # framed marketing images land here
└── samples/                # committed sample renders from placeholder input
```

---

## Prerequisites

- **Node.js ≥ 18** and **npm** (the framer; cross-platform — runs on macOS).
- **`sharp`** — installed via `npm install` (pure-JS-friendly image compositing).
- **Android capture:** `adb` (Android platform-tools) + a connected device or
  emulator running a **debug build of Haven** with demo mode.
- **Windows capture:** **PowerShell** on a Windows machine (or a
  `windows-latest` CI runner) with the built/installed Haven desktop app.

Install:

```bash
cd tools/screenshots
npm install
```

---

## Output sizes (per store)

| Preset key       | Store            | Pixels       | Ratio | Frame   |
|------------------|------------------|--------------|-------|---------|
| `play_phone`     | Google Play      | **1080×1920**| 9:16  | phone   |
| `play_phone_hd`  | Google Play      | **1242×2208**| 9:16  | phone   |
| `ms_32`          | Microsoft Store  | **2160×1440**| 3:2   | desktop |
| `ms_169`         | Microsoft Store  | **1920×1080**| 16:9  | desktop |

By default Android scenes render `play_phone` + `play_phone_hd`, and Windows
scenes render `ms_32` + `ms_169`. Override per scene with a `"sizes": [...]`
array, or globally with `--size <key>`. See/print all presets:

```bash
node src/cli.js list
```

Framed files land at:

```
out/android/<scene-id>__<sizeKey>.png      e.g. out/android/android-feed__play_phone.png
out/windows/<scene-id>__<sizeKey>.png      e.g. out/windows/windows-calls__ms_32.png
```

---

## Full workflow: capture → frame → upload

### 1. Capture raw screenshots

**Android** (run with a debug Haven build on a device/emulator):

```bash
# default device + package com.blaineam.haven
./scripts/capture-android.sh

# pick a specific device / package
SERIAL=emulator-5554 PKG=com.blaineam.haven ./scripts/capture-android.sh

# non-interactive (only tab-level scenes, no manual taps)
CAPTURE_INTERACTIVE=0 ./scripts/capture-android.sh
```

It launches each tab in demo mode via intent extras and grabs the screen:

```
adb shell am start -n com.blaineam.haven/.MainActivity \
    --ez haven_demo true --es haven_tab <circle|messages|you> [--es haven_scene <name>]
adb exec-out screencap -p > raw/android/<scene>.png
```

Tab-level scenes (`circle`, `messages`, `you`/profile) are captured tap-free.
Scenes that need in-app navigation (the **story camera**, an **in-call** screen,
a specific **DM thread**) pause and prompt you to tap, then capture — **no
fragile hardcoded coordinates**. Each pause is a clearly-marked `TODO HOOK` in
the script; if the app later adds a `--es haven_scene` deep-link for that scene,
delete the pause and it becomes fully automatic.

**Windows** (run on a Windows box / `windows-latest` runner):

```powershell
cd tools\screenshots
.\scripts\capture-windows.ps1
# or point at an installed build / disable prompts:
.\scripts\capture-windows.ps1 -ExePath "C:\Program Files\Haven\Haven.exe" -Interactive:$false
```

It launches the Tauri release binary
(`desktop\src-tauri\target\release\haven.exe` by default) with `HAVEN_DEMO=1`,
finds the window titled **"Haven"**, and saves each scene with .NET
`System.Drawing` window capture to `raw\windows\*.png`. Same `TODO HOOK` pattern
for click-required scenes. *(This script can only run on Windows; it's provided
correct and documented for the user / CI.)*

### 2. Frame everything

```bash
# frame every scene listed in screens.json
node src/cli.js frame

# only Android scenes / only Windows scenes
node src/cli.js frame --platform android
node src/cli.js frame --platform windows

# just a few scenes, at one size
node src/cli.js frame --only android-feed,android-calls --size play_phone

# one-off, without editing the config
node src/cli.js one --source raw/android/circle.png \
  --headline "Your circle, encrypted" --subtitle "Just your people." \
  --platform android --background gradient
```

Scenes whose `source` PNG doesn't exist yet are skipped with a warning, so you
can frame whatever you've captured so far.

### 3. Upload

Upload `out/android/*.png` to the Google Play Console (phone screenshots) and
`out/windows/*.png` to Partner Center (Microsoft Store app screenshots). The
pixel dimensions already match each store's requirements exactly.

---

## Editing captions / scenes

Open **`screens.json`** and edit. Each scene:

```jsonc
{
  "id": "android-feed",          // output filename prefix
  "platform": "android",         // android = phone frame, windows = desktop frame
  "tab": "circle",               // android demo tab (capture script)
  "scene": "feed",               // optional deep-link scene (capture script)
  "source": "raw/android/circle.png",   // raw screenshot path (relative to tools/screenshots)
  "headline": "Your circle, end-to-end encrypted",
  "subtitle": "Share photos and moments only with the people you love.",
  "background": "dark",          // "dark" (calm) or "gradient"
  "sizes": ["play_phone"]        // optional: override default store sizes
}
```

The repo ships **6 Android** + **3 Windows** default scenes with finished copy
("Your circle, end-to-end encrypted", "Stories with real film filters", "Group
video calls, no servers", "Private DMs", "Your keys never leave your device",
…) so the moment real screenshots exist in `raw/`, `node src/cli.js frame`
produces a full store set.

---

## Validating without app screenshots

`samples` renders the full pipeline from **synthetic placeholder** inputs it
generates itself — proving the framing, compositing, text rendering, and exact
output sizes all work before any real screenshot exists:

```bash
node src/cli.js samples
```

Outputs (committed for inspection) in `samples/`:

- `sample-android__play_phone.png` — **1080×1920**
- `sample-android-grad__play_phone_hd.png` — **1242×2208**
- `sample-windows__ms_32.png` — **2160×1440**
- `sample-windows-169__ms_169.png` — **1920×1080**

---

## Notes

- Pure Node + `sharp`; text is rendered as SVG and rasterized by `sharp`, so the
  exact headline font depends on the fonts installed on the rendering host
  (the system stack falls through to a sans-serif). For pixel-identical output
  in CI, install the SF Pro / Segoe UI / a bundled font on the runner.
- This tool **only reads** raw PNGs and **writes** to `raw/` and `out/`. It does
  not touch app source.
