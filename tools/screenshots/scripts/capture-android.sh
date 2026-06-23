#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# capture-android.sh — launch Haven in demo mode and capture raw screenshots
# for each store scene into tools/screenshots/raw/android/<scene>.png.
#
# The Android app exposes a debug demo mode via intent extras (added by the app
# team). We launch one activity per TAB with seeded demo content, then grab the
# screen with `adb exec-out screencap -p`.
#
#   --ez haven_demo true            enable on-device demo mode (seeded content)
#   --es haven_tab <circle|messages|you>   which bottom tab to land on
#   --es haven_scene <name>         (optional) deep-link to a specific scene
#
# Some scenes (a story camera, an in-call screen, a specific DM thread) require
# an in-app tap that we deliberately DO NOT hardcode as raw coordinates (they're
# fragile across devices). Those are left as clearly-marked TODO hooks: the
# script pauses so a human can tap, then captures. Run with CAPTURE_INTERACTIVE=0
# to skip the pauses and only grab the tab-level scenes.
#
# Usage:
#   ./capture-android.sh                       # default device, default pkg
#   SERIAL=emulator-5554 ./capture-android.sh  # pick a device
#   PKG=com.blaineam.haven ./capture-android.sh
#   CAPTURE_INTERACTIVE=0 ./capture-android.sh  # non-interactive (tabs only)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config (override via env) ───────────────────────────────────────────────
PKG="${PKG:-com.blaineam.haven}"
ACTIVITY="${ACTIVITY:-.MainActivity}"
SERIAL="${SERIAL:-}"                       # empty = adb default device
CAPTURE_INTERACTIVE="${CAPTURE_INTERACTIVE:-1}"
SETTLE="${SETTLE:-2.0}"                     # seconds to wait after launch
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$HERE/.." && pwd)/raw/android"

ADB=(adb)
if [[ -n "$SERIAL" ]]; then ADB=(adb -s "$SERIAL"); fi

mkdir -p "$OUT_DIR"

# ── Sanity checks ───────────────────────────────────────────────────────────
if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found on PATH. Install Android platform-tools." >&2
  exit 1
fi
DEV_COUNT="$("${ADB[@]}" devices | grep -cE '\tdevice$' || true)"
if [[ "$DEV_COUNT" -eq 0 ]]; then
  echo "ERROR: no adb device. Connect a phone/emulator (and set SERIAL=)." >&2
  "${ADB[@]}" devices >&2
  exit 1
fi

echo "Device:   $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
echo "Package:  $PKG/$ACTIVITY"
echo "Output:   $OUT_DIR"
echo

# launch_tab <tab> [scene]
launch_tab() {
  local tab="$1"; local scene="${2:-}"
  local args=(shell am start -n "$PKG/$ACTIVITY" --ez haven_demo true --es haven_tab "$tab")
  if [[ -n "$scene" ]]; then args+=(--es haven_scene "$scene"); fi
  "${ADB[@]}" "${args[@]}" >/dev/null
  sleep "$SETTLE"
}

# grab <name>  → raw/android/<name>.png
grab() {
  local name="$1"
  "${ADB[@]}" exec-out screencap -p > "$OUT_DIR/$name.png"
  # screencap occasionally emits CRLF on some shells; normalise if tiny.
  if [[ ! -s "$OUT_DIR/$name.png" ]]; then
    echo "  ⚠ $name.png is empty — retrying once" >&2
    "${ADB[@]}" exec-out screencap -p > "$OUT_DIR/$name.png"
  fi
  echo "  ✓ $name.png"
}

# pause_for_tap <instruction>  — interactive hook for in-app navigation
pause_for_tap() {
  local msg="$1"
  if [[ "$CAPTURE_INTERACTIVE" == "1" ]]; then
    echo "  ↳ TODO (manual): $msg"
    read -r -p "      …then press ENTER to capture (or 's' to skip): " ans
    [[ "$ans" == "s" ]] && return 1
    return 0
  else
    echo "  ↳ SKIP interactive scene: $msg (CAPTURE_INTERACTIVE=0)"
    return 1
  fi
}

# ── Scenes ───────────────────────────────────────────────────────────────────
# Tab-level scenes captured purely via launch extras (robust, no taps):
echo "• circle / feed"
launch_tab circle feed
grab circle

echo "• messages"
launch_tab messages
grab messages

echo "• you / profile"
launch_tab you profile
grab profile

echo "• you / keys"
# If the app deep-links to the keys/security screen via haven_scene, this is
# tap-free. Otherwise fall back to a manual tap.
launch_tab you keys
if "${ADB[@]}" shell dumpsys window 2>/dev/null | grep -qi 'keys\|security'; then
  grab keys
else
  if pause_for_tap "open You → Security / Your keys, then continue"; then
    grab keys
  fi
fi

# ── Interactive scenes (require an in-app tap; no fragile coordinates) ────────
echo "• circle / story (camera + film filters)"
launch_tab circle story
# TODO HOOK: tap the story/camera FAB, pick a film filter. If the app supports
# --es haven_scene story to deep-link straight into the styled camera preview,
# this becomes tap-free — wire that in the app and the pause disappears.
if pause_for_tap "open the Story camera and select a film filter"; then
  grab story
fi

echo "• circle / call (group video call)"
launch_tab circle call
# TODO HOOK: start/join the demo group call. Same note: a haven_scene=call
# deep-link into a seeded call UI would make this tap-free.
if pause_for_tap "start the demo group video call"; then
  grab call
fi

echo "• messages / dm (open a thread)"
launch_tab messages dm
# TODO HOOK: tap into the seeded DM thread.
if pause_for_tap "open the seeded DM conversation"; then
  grab dm
fi

echo
echo "Done. Raw screenshots in: $OUT_DIR"
echo "Next: node src/cli.js frame   (frames every scene in screens.json)"
