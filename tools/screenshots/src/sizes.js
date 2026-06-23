// ─────────────────────────────────────────────────────────────────────────────
// Store output size presets. All sizes are exact pixel dimensions required (or
// accepted) by the respective stores. Add or tweak presets here — the rest of
// the pipeline is fully driven by these numbers.
//
//   Google Play (phone screenshots):
//     - 1080×1920  portrait 9:16  (the modern recommended phone size)
//     - 1242×2208  portrait       (legacy high-density variant, still accepted)
//   Microsoft Store (app screenshots, landscape desktop):
//     - 2160×1440  3:2
//     - 1920×1080  16:9
//
// `device` selects which frame renderer to use: 'phone' (rounded bezel) or
// 'desktop' (window chrome with titlebar dots).
// ─────────────────────────────────────────────────────────────────────────────

export const SIZES = {
  // ── Google Play (Android) ──────────────────────────────────────────────
  play_phone: {
    label: 'Google Play phone 1080×1920',
    store: 'android',
    width: 1080,
    height: 1920,
    orientation: 'portrait',
    device: 'phone',
  },
  play_phone_hd: {
    label: 'Google Play phone 1242×2208',
    store: 'android',
    width: 1242,
    height: 2208,
    orientation: 'portrait',
    device: 'phone',
  },

  // ── Microsoft Store (Windows) ──────────────────────────────────────────
  ms_32: {
    label: 'Microsoft Store 2160×1440 (3:2)',
    store: 'windows',
    width: 2160,
    height: 1440,
    orientation: 'landscape',
    device: 'desktop',
  },
  ms_169: {
    label: 'Microsoft Store 1920×1080 (16:9)',
    store: 'windows',
    width: 1920,
    height: 1080,
    orientation: 'landscape',
    device: 'desktop',
  },
};

// Default set of sizes rendered per platform when a scene does not override it.
export const DEFAULT_SIZES = {
  android: ['play_phone', 'play_phone_hd'],
  windows: ['ms_32', 'ms_169'],
};
