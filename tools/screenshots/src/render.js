// ─────────────────────────────────────────────────────────────────────────────
// render.js — the compositor. Given a raw screenshot + caption + a size preset,
// produce a polished, branded store marketing PNG.
//
// Pipeline per image:
//   1. Build a full-canvas background SVG (brand gradient or dark, with the same
//      radial glows the website uses) and rasterize it with sharp.
//   2. Resize/crop the raw screenshot to fit the device's screen rectangle.
//   3. Build an SVG "frame" layer: a soft drop shadow, the device bezel/window
//      chrome, rounded screen mask, and the headline/subtitle text.
//   4. Composite: background ← screenshot (masked to screen) ← frame+text.
//
// Everything is parametric off the size preset so adding store sizes is free.
// ─────────────────────────────────────────────────────────────────────────────

import sharp from 'sharp';
import { BRAND, GRADIENT_STOPS, FONT_STACK, esc, wrap } from './brand.js';

// ── Layout maths ────────────────────────────────────────────────────────────
// We reserve a caption band (headline + subtitle) and place the device in the
// remaining area, inset with generous margins so it reads as premium.

function layout(size) {
  const { width: W, height: H, device } = size;
  const portrait = size.orientation === 'portrait';

  // Outer safe margin (percentage of the shorter edge).
  const short = Math.min(W, H);
  const margin = Math.round(short * (portrait ? 0.085 : 0.07));

  // Caption band height.
  const captionH = portrait
    ? Math.round(H * 0.2)
    : Math.round(H * 0.26);

  // Headline sizing scales with canvas.
  const headlineSize = Math.round(short * (portrait ? 0.062 : 0.058));
  const subtitleSize = Math.round(headlineSize * 0.46);

  // Available area for the device below the caption band.
  const deviceAreaTop = captionH;
  const deviceAreaH = H - captionH - margin;
  const deviceAreaW = W - margin * 2;

  return {
    W, H, device, portrait, margin,
    captionH, headlineSize, subtitleSize,
    deviceAreaTop, deviceAreaH, deviceAreaW,
  };
}

// Fit a (sw×sh) rectangle inside (mw×mh) preserving aspect ratio.
function contain(sw, sh, mw, mh) {
  const scale = Math.min(mw / sw, mh / sh);
  return { w: Math.round(sw * scale), h: Math.round(sh * scale), scale };
}

// ── Background ────────────────────────────────────────────────────────────────
function backgroundSVG(L, style) {
  const { W, H } = L;
  const stops = GRADIENT_STOPS.map(
    (s) => `<stop offset="${s.offset}" stop-color="${s.color}"/>`
  ).join('');

  // Dark base always present; gradient variants add brand colour with restraint
  // using the same radial glow positions as web/styles.css body background.
  const glows = `
    <radialGradient id="gV" cx="-6%" cy="4%" r="60%">
      <stop offset="0" stop-color="${BRAND.violet}" stop-opacity="0.42"/>
      <stop offset="0.6" stop-color="${BRAND.violet}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="gP" cx="92%" cy="-6%" r="62%">
      <stop offset="0" stop-color="${BRAND.pink}" stop-opacity="0.40"/>
      <stop offset="0.6" stop-color="${BRAND.pink}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="gA" cx="50%" cy="118%" r="60%">
      <stop offset="0" stop-color="${BRAND.amber}" stop-opacity="0.26"/>
      <stop offset="0.6" stop-color="${BRAND.amber}" stop-opacity="0"/>
    </radialGradient>`;

  let base;
  if (style === 'gradient') {
    base = `
      <linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"
        gradientTransform="rotate(8 .5 .5)">${stops}</linearGradient>
      <rect width="${W}" height="${H}" fill="${BRAND.bg}"/>
      <rect width="${W}" height="${H}" fill="url(#brand)" opacity="0.16"/>`;
  } else {
    // 'dark' — the calmer, default option.
    base = `<rect width="${W}" height="${H}" fill="${BRAND.bg}"/>`;
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
    <defs>${glows}</defs>
    ${base}
    <rect width="${W}" height="${H}" fill="url(#gV)"/>
    <rect width="${W}" height="${H}" fill="url(#gP)"/>
    <rect width="${W}" height="${H}" fill="url(#gA)"/>
  </svg>`;
}

// ── Caption (headline + subtitle) ───────────────────────────────────────────
function captionSVG(L, headline, subtitle, accent) {
  const { W, captionH, headlineSize, subtitleSize, margin } = L;
  const cx = W / 2;

  // Wrap headline to ~16 chars/line for portrait, ~22 for landscape.
  const maxChars = L.portrait ? 17 : 24;
  const lines = wrap(headline, maxChars, 2);
  const lineGap = Math.round(headlineSize * 1.14);

  // Vertically centre the headline block within the caption band, leaving room
  // for the subtitle just under it.
  const blockH = lines.length * lineGap + (subtitle ? subtitleSize * 1.7 : 0);
  let y = Math.round((captionH - blockH) / 2 + headlineSize);

  const accentColor = accent || BRAND.pink;

  const headlineTspans = lines
    .map((ln, i) => {
      const dy = i === 0 ? 0 : lineGap;
      return `<tspan x="${cx}" dy="${dy}">${esc(ln)}</tspan>`;
    })
    .join('');

  const headlineEl = `<text x="${cx}" y="${y}" text-anchor="middle"
      font-family="${FONT_STACK}" font-size="${headlineSize}" font-weight="850"
      letter-spacing="-1" fill="url(#headGrad)">${headlineTspans}</text>`;

  let subtitleEl = '';
  if (subtitle) {
    const sy = y + (lines.length - 1) * lineGap + Math.round(subtitleSize * 1.85);
    // wrap subtitle generously
    const subLines = wrap(subtitle, L.portrait ? 34 : 48, 2);
    const subGap = Math.round(subtitleSize * 1.3);
    const subTspans = subLines
      .map((ln, i) => `<tspan x="${cx}" dy="${i === 0 ? 0 : subGap}">${esc(ln)}</tspan>`)
      .join('');
    subtitleEl = `<text x="${cx}" y="${sy}" text-anchor="middle"
        font-family="${FONT_STACK}" font-size="${subtitleSize}" font-weight="600"
        fill="${BRAND.text2}">${subTspans}</text>`;
  }

  // Small brand eyebrow dot row, like the site's pills — adds polish.
  const eyebrowY = Math.max(margin * 0.7, headlineSize * 0.55);
  const eyebrow = `<g opacity="0.95">
      <circle cx="${cx - 36}" cy="${eyebrowY}" r="6" fill="${BRAND.violet}"/>
      <circle cx="${cx}" cy="${eyebrowY}" r="6" fill="${BRAND.pink}"/>
      <circle cx="${cx + 36}" cy="${eyebrowY}" r="6" fill="${BRAND.amber}"/>
    </g>`;

  const stops = GRADIENT_STOPS.map(
    (s) => `<stop offset="${s.offset}" stop-color="${s.color}"/>`
  ).join('');

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${captionH}" viewBox="0 0 ${W} ${captionH}">
    <defs>
      <linearGradient id="headGrad" x1="0" y1="0" x2="1" y2="0">${stops}</linearGradient>
    </defs>
    ${eyebrow}
    ${headlineEl}
    ${subtitleEl}
  </svg>`;
}

// ── Phone bezel frame (Android) ─────────────────────────────────────────────
// Returns { frameSVG, screen: {x,y,w,h,radius} } where screen is the rectangle
// the raw screenshot is composited into (relative to the full canvas).
function phoneFrame(L) {
  const { deviceAreaTop, deviceAreaH, deviceAreaW, margin, W } = L;

  // Typical modern phone screen aspect ~ 9:19.5. Fit a device of that aspect
  // inside the device area.
  const screenAspect = 9 / 19.5;
  // device outer is screen + bezel
  const bezel = Math.round(Math.min(deviceAreaW, deviceAreaH) * 0.022) + 6;
  const innerMaxW = deviceAreaW - bezel * 2;
  const innerMaxH = deviceAreaH - bezel * 2;

  // Solve for screen size honouring aspect within inner max box.
  let sw, sh;
  if (innerMaxW / innerMaxH > screenAspect) {
    sh = innerMaxH;
    sw = Math.round(sh * screenAspect);
  } else {
    sw = innerMaxW;
    sh = Math.round(sw / screenAspect);
  }

  const outerW = sw + bezel * 2;
  const outerH = sh + bezel * 2;
  const outerX = Math.round((W - outerW) / 2);
  const outerY = Math.round(deviceAreaTop + (deviceAreaH - outerH) / 2);

  const screenX = outerX + bezel;
  const screenY = outerY + bezel;
  const screenR = Math.round(bezel * 1.6);
  const outerR = Math.round(bezel * 2.2);

  // Camera notch / pill at top centre.
  const notchW = Math.round(sw * 0.30);
  const notchH = Math.round(bezel * 0.9);
  const notchX = screenX + (sw - notchW) / 2;
  const notchY = screenY + Math.round(bezel * 0.5);

  const shadowBlur = Math.round(bezel * 2.4);

  // The body rect is drawn FIRST (under the screenshot) so it casts the shadow
  // and supplies the bezel colour around the screen. The screenshot is then
  // composited on top of the screen rect. Finally an "overlay" (notch + inner
  // hairline) is drawn above the screenshot. We return both layers.
  const bodySVG = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${L.H}" viewBox="0 0 ${W} ${L.H}">
    <defs>
      <filter id="devShadow" x="-40%" y="-40%" width="180%" height="180%">
        <feDropShadow dx="0" dy="${Math.round(bezel * 1.2)}" stdDeviation="${shadowBlur}"
          flood-color="#000000" flood-opacity="0.55"/>
      </filter>
      <linearGradient id="bezelG" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#1c1c22"/>
        <stop offset="1" stop-color="#0d0d12"/>
      </linearGradient>
    </defs>
    <rect x="${outerX}" y="${outerY}" width="${outerW}" height="${outerH}"
      rx="${outerR}" ry="${outerR}" fill="url(#bezelG)"
      stroke="${BRAND.cardBorder}" stroke-width="1.5" filter="url(#devShadow)"/>
  </svg>`;

  const overlaySVG = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${L.H}" viewBox="0 0 ${W} ${L.H}">
    <!-- inner hairline around the screen for a crisp edge -->
    <rect x="${screenX - 1}" y="${screenY - 1}" width="${sw + 2}" height="${sh + 2}"
      rx="${screenR}" ry="${screenR}" fill="none"
      stroke="rgba(255,255,255,0.08)" stroke-width="2"/>
    <!-- camera notch / pill -->
    <rect x="${notchX}" y="${notchY}" width="${notchW}" height="${notchH}"
      rx="${notchH / 2}" ry="${notchH / 2}" fill="#000000" opacity="0.92"/>
  </svg>`;

  return {
    bodySVG,
    overlaySVG,
    screen: { x: screenX, y: screenY, w: sw, h: sh, radius: screenR },
  };
}

// ── Desktop window chrome (Windows) ─────────────────────────────────────────
function desktopFrame(L) {
  const { deviceAreaTop, deviceAreaH, deviceAreaW, W } = L;

  // Desktop app window aspect ~ 16:10. Title bar on top.
  const winAspect = 16 / 10;
  const titleH = Math.round(Math.min(deviceAreaW, deviceAreaH) * 0.052) + 18;

  // Fit window (title + content) into device area.
  let cw, ch; // content (screen) dims
  const maxContentH = deviceAreaH - titleH;
  if (deviceAreaW / maxContentH > winAspect) {
    ch = maxContentH;
    cw = Math.round(ch * winAspect);
  } else {
    cw = deviceAreaW;
    ch = Math.round(cw / winAspect);
  }

  const winW = cw;
  const winH = ch + titleH;
  const winX = Math.round((W - winW) / 2);
  const winY = Math.round(deviceAreaTop + (deviceAreaH - winH) / 2);

  const radius = Math.round(titleH * 0.5);
  const screenX = winX;
  const screenY = winY + titleH;

  const dot = Math.round(titleH * 0.18);
  const dotY = winY + titleH / 2;
  const dotX0 = winX + Math.round(titleH * 0.7);
  const dotGap = Math.round(dot * 3.2);

  const shadowBlur = Math.round(titleH * 1.6);

  // Body: full rounded window + shadow, drawn UNDER the screenshot.
  const bodySVG = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${L.H}" viewBox="0 0 ${W} ${L.H}">
    <defs>
      <filter id="winShadow" x="-30%" y="-30%" width="160%" height="160%">
        <feDropShadow dx="0" dy="${Math.round(titleH * 0.5)}" stdDeviation="${shadowBlur}"
          flood-color="#000000" flood-opacity="0.5"/>
      </filter>
    </defs>
    <rect x="${winX}" y="${winY}" width="${winW}" height="${winH}"
      rx="${radius}" ry="${radius}" fill="#101015"
      stroke="${BRAND.cardBorder}" stroke-width="1.5" filter="url(#winShadow)"/>
  </svg>`;

  // Overlay: titlebar (rounded top) + dots + title + bottom-corner rounding,
  // drawn OVER the screenshot so the square-cropped shot gets rounded corners
  // and a clean chrome. The titlebar covers the top of the screen rect.
  const overlaySVG = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${L.H}" viewBox="0 0 ${W} ${L.H}">
    <defs>
      <linearGradient id="titleG" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#17171d"/>
        <stop offset="1" stop-color="#101015"/>
      </linearGradient>
      <!-- mask = everything EXCEPT the rounded window shape, used to knock out
           the square screenshot corners by painting bg colour back over them -->
    </defs>
    <!-- corner cover: paint window-bg over the area outside the rounded rect but
         inside the window bbox, so the cover hides the square screenshot corners.
         We do this by drawing 4 small corner wedges. Simpler: stroke a thick
         rounded rect in bg colour just inside the border is unreliable; instead
         we re-draw the rounded border which sits on top and a subtle inner ring -->
    <!-- title bar (top rounded only) -->
    <path d="M${winX} ${winY + radius}
      a${radius} ${radius} 0 0 1 ${radius} ${-radius}
      h${winW - radius * 2}
      a${radius} ${radius} 0 0 1 ${radius} ${radius}
      v${titleH - radius}
      h${-winW}
      z" fill="url(#titleG)"/>
    <line x1="${winX}" y1="${winY + titleH}" x2="${winX + winW}" y2="${winY + titleH}"
      stroke="${BRAND.cardBorder}" stroke-width="1"/>
    <!-- traffic-light dots -->
    <circle cx="${dotX0}" cy="${dotY}" r="${dot}" fill="#ff5f57"/>
    <circle cx="${dotX0 + dotGap}" cy="${dotY}" r="${dot}" fill="#febc2e"/>
    <circle cx="${dotX0 + dotGap * 2}" cy="${dotY}" r="${dot}" fill="#28c840"/>
    <!-- window title -->
    <text x="${winX + winW / 2}" y="${dotY + dot * 0.55}" text-anchor="middle"
      font-family="${FONT_STACK}" font-size="${Math.round(titleH * 0.42)}"
      font-weight="600" fill="${BRAND.text2}">Haven</text>
    <!-- crisp rounded border on top of everything -->
    <rect x="${winX}" y="${winY}" width="${winW}" height="${winH}"
      rx="${radius}" ry="${radius}" fill="none"
      stroke="${BRAND.cardBorder}" stroke-width="2"/>
  </svg>`;

  // We round the content screenshot's BOTTOM corners only via a mask so it sits
  // flush under the square titlebar. screen.radius carries the bottom radius;
  // render() applies a uniform rounded mask which is acceptable here because the
  // titlebar overlay covers the top corners anyway.
  return {
    bodySVG,
    overlaySVG,
    screen: { x: screenX, y: screenY, w: cw, h: ch, radius: Math.round(radius * 0.8), bottomOnly: true },
  };
}

// Round-rect mask the screenshot to the screen radius. When `bottomOnly` is set
// the top corners are kept square (so the screenshot tucks under a titlebar).
async function roundedScreenshot(buf, w, h, radius, bottomOnly = false) {
  const resized = await sharp(buf)
    .resize(w, h, { fit: 'cover', position: 'top' })
    .toBuffer();
  if (!radius) return resized;

  const maskShape = bottomOnly
    ? // path: square top, rounded bottom corners
      `<path d="M0 0 H${w} V${h - radius}
         a${radius} ${radius} 0 0 1 ${-radius} ${radius}
         H${radius}
         a${radius} ${radius} 0 0 1 ${-radius} ${-radius}
         Z" fill="#fff"/>`
    : `<rect width="${w}" height="${h}" rx="${radius}" ry="${radius}" fill="#fff"/>`;

  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">${maskShape}</svg>`
  );
  return sharp(resized)
    .composite([{ input: mask, blend: 'dest-in' }])
    .png()
    .toBuffer();
}

// ── Public API ──────────────────────────────────────────────────────────────
// Render one scene at one size. Returns a PNG buffer.
export async function renderImage({ sourceBuffer, size, headline, subtitle, background, accent }) {
  const L = layout(size);

  // 1. background
  const bg = await sharp(Buffer.from(backgroundSVG(L, background || 'dark')))
    .png()
    .toBuffer();

  // 2. frame geometry — body (under) + overlay (over) layers
  const frame = size.device === 'desktop' ? desktopFrame(L) : phoneFrame(L);
  const { screen } = frame;

  // 3. screenshot fitted+masked to the screen rect
  const shot = await roundedScreenshot(
    sourceBuffer, screen.w, screen.h, screen.radius, !!screen.bottomOnly
  );

  // 4. caption
  const caption = await sharp(Buffer.from(captionSVG(L, headline, subtitle, accent)))
    .png()
    .toBuffer();

  // 5. composite, bottom → top:
  //    background ← device body+shadow ← screenshot ← chrome overlay ← caption
  return sharp(bg)
    .composite([
      { input: Buffer.from(frame.bodySVG), left: 0, top: 0 },
      { input: shot, left: screen.x, top: screen.y },
      { input: Buffer.from(frame.overlaySVG), left: 0, top: 0 },
      { input: caption, left: 0, top: 0 },
    ])
    .png({ compressionLevel: 9 })
    .toBuffer();
}
