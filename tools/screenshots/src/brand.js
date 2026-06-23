// ─────────────────────────────────────────────────────────────────────────────
// Haven brand tokens — mirrored 1:1 from web/styles.css :root.
// Keep these in sync with the site so store art always matches the marketing.
// ─────────────────────────────────────────────────────────────────────────────

export const BRAND = {
  violet: '#7C3AED',
  pink: '#EC4899',
  amber: '#F59E0B',
  bg: '#0b0b10',
  text: '#f5f5f7',
  // rgba(245,245,247,.66)
  text2: 'rgba(245,245,247,0.66)',
  text3: 'rgba(245,245,247,0.42)',
  cardBorder: 'rgba(255,255,255,0.10)',
};

// The signature 135deg violet → pink → amber gradient (web --brand).
export const GRADIENT_STOPS = [
  { offset: 0, color: BRAND.violet },
  { offset: 0.5, color: BRAND.pink },
  { offset: 1, color: BRAND.amber },
];

// System font stack used everywhere on the site. SVG <text> will fall through
// this list to whatever the rendering host has installed.
export const FONT_STACK =
  "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, system-ui, 'Helvetica Neue', Arial, sans-serif";

// Escape text for safe inclusion inside SVG markup.
export function esc(s = '') {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Word-wrap a string to at most `maxChars` per line, up to `maxLines` lines.
// Returns an array of line strings. Approximate (char-count based) which is
// plenty for headline-length copy at known font sizes.
export function wrap(text, maxChars, maxLines = 3) {
  const words = String(text).split(/\s+/).filter(Boolean);
  const lines = [];
  let cur = '';
  for (const w of words) {
    const candidate = cur ? `${cur} ${w}` : w;
    if (candidate.length > maxChars && cur) {
      lines.push(cur);
      cur = w;
      if (lines.length === maxLines - 1) break;
    } else {
      cur = candidate;
    }
  }
  if (cur && lines.length < maxLines) lines.push(cur);
  // If we ran out of lines, append any leftover words to the last line.
  const consumed = lines.join(' ').split(/\s+/).filter(Boolean).length;
  if (consumed < words.length) {
    lines[lines.length - 1] += ' ' + words.slice(consumed).join(' ');
  }
  return lines;
}
