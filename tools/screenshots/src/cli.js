#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// haven-shots — config-driven store screenshot framer.
//
//   node src/cli.js frame [--config screens.json] [--only id1,id2] [--size key]
//   node src/cli.js one --source raw/x.png --headline "..." [--subtitle "..."]
//                       --platform android|windows [--size play_phone]
//   node src/cli.js samples            # generate synthetic placeholder renders
//   node src/cli.js list               # list scenes + sizes
//
// Output lands in out/<store>/<scene-id>__<sizeKey>.png
// ─────────────────────────────────────────────────────────────────────────────

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { renderImage } from './render.js';
import { SIZES, DEFAULT_SIZES } from './sizes.js';
import { BRAND } from './brand.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..'); // tools/screenshots/

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    } else {
      args._.push(a);
    }
  }
  return args;
}

function rel(p) {
  return path.isAbsolute(p) ? p : path.join(ROOT, p);
}

async function ensureDir(p) {
  await mkdir(p, { recursive: true });
}

function sizesForScene(scene, overrideSize) {
  if (overrideSize) return [overrideSize];
  if (Array.isArray(scene.sizes) && scene.sizes.length) return scene.sizes;
  return DEFAULT_SIZES[scene.platform] || [];
}

async function renderScene(scene, { overrideSize } = {}) {
  const srcPath = rel(scene.source);
  if (!existsSync(srcPath)) {
    console.warn(`  ⚠ skip ${scene.id}: source not found → ${scene.source}`);
    return [];
  }
  const sourceBuffer = await readFile(srcPath);
  const store = scene.platform === 'windows' ? 'windows' : 'android';
  const outDir = path.join(ROOT, 'out', store);
  await ensureDir(outDir);

  const outputs = [];
  for (const sizeKey of sizesForScene(scene, overrideSize)) {
    const size = SIZES[sizeKey];
    if (!size) {
      console.warn(`  ⚠ unknown size '${sizeKey}' for ${scene.id}`);
      continue;
    }
    const png = await renderImage({
      sourceBuffer,
      size,
      headline: scene.headline,
      subtitle: scene.subtitle,
      background: scene.background,
      accent: scene.accent,
    });
    const outPath = path.join(outDir, `${scene.id}__${sizeKey}.png`);
    await writeFile(outPath, png);
    const meta = await sharp(png).metadata();
    outputs.push({ outPath, w: meta.width, h: meta.height, sizeKey });
    console.log(
      `  ✓ ${path.relative(ROOT, outPath)}  ${meta.width}×${meta.height}`
    );
  }
  return outputs;
}

async function loadConfig(configArg) {
  const cfgPath = rel(configArg || 'screens.json');
  const raw = await readFile(cfgPath, 'utf8');
  return JSON.parse(raw);
}

// ── Synthetic placeholder generator (for validation w/o real screenshots) ────
async function makePlaceholder(w, h, label, sub) {
  const stops = `
    <stop offset="0" stop-color="${BRAND.violet}"/>
    <stop offset="0.5" stop-color="${BRAND.pink}"/>
    <stop offset="1" stop-color="${BRAND.amber}"/>`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">${stops}</linearGradient></defs>
    <rect width="${w}" height="${h}" fill="#15151c"/>
    <rect x="${w * 0.08}" y="${h * 0.05}" width="${w * 0.84}" height="${h * 0.18}"
      rx="${Math.min(w, h) * 0.04}" fill="url(#g)" opacity="0.9"/>
    <text x="${w / 2}" y="${h * 0.16}" text-anchor="middle" fill="#fff"
      font-family="sans-serif" font-weight="800" font-size="${Math.round(w * 0.06)}">${label}</text>
    <g fill="#ffffff" opacity="0.10">
      ${Array.from({ length: 6 }).map((_, i) => {
        const y = h * 0.30 + i * h * 0.11;
        return `<rect x="${w * 0.08}" y="${y}" width="${w * 0.84}" height="${h * 0.08}" rx="${w * 0.03}"/>`;
      }).join('')}
    </g>
    <text x="${w / 2}" y="${h * 0.96}" text-anchor="middle" fill="#ffffff" opacity="0.5"
      font-family="sans-serif" font-size="${Math.round(w * 0.035)}">${sub}</text>
  </svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

async function cmdSamples() {
  console.log('Generating synthetic placeholder screenshots + sample renders…');
  const samplesDir = path.join(ROOT, 'samples');
  await ensureDir(samplesDir);

  // Android placeholder (portrait phone screen ~1080×2340)
  const androidShot = await makePlaceholder(1080, 2340, 'Haven', 'PLACEHOLDER — Android feed');
  const androidRaw = path.join(samplesDir, 'placeholder-android.png');
  await writeFile(androidRaw, androidShot);

  // Windows placeholder (landscape window content ~1600×1000)
  const winShot = await makePlaceholder(1600, 1000, 'Haven', 'PLACEHOLDER — Windows desktop');
  const winRaw = path.join(samplesDir, 'placeholder-windows.png');
  await writeFile(winRaw, winShot);

  const sampleScenes = [
    {
      id: 'sample-android', platform: 'android', source: 'samples/placeholder-android.png',
      headline: 'Your circle, end-to-end encrypted',
      subtitle: 'Share photos and moments only with the people you love.',
      background: 'dark', sizes: ['play_phone'],
    },
    {
      id: 'sample-android-grad', platform: 'android', source: 'samples/placeholder-android.png',
      headline: 'Stories with real film filters',
      subtitle: 'Capture the day with beautiful, true-to-life looks.',
      background: 'gradient', sizes: ['play_phone_hd'],
    },
    {
      id: 'sample-windows', platform: 'windows', source: 'samples/placeholder-windows.png',
      headline: 'Group video calls & screen share',
      subtitle: 'Serverless, peer-to-peer, end-to-end encrypted.',
      background: 'gradient', sizes: ['ms_32'],
    },
    {
      id: 'sample-windows-169', platform: 'windows', source: 'samples/placeholder-windows.png',
      headline: 'Your circle on the desktop',
      subtitle: 'The same private Haven, now on Windows.',
      background: 'dark', sizes: ['ms_169'],
    },
  ];

  // Render samples directly into samples/ for easy inspection.
  for (const scene of sampleScenes) {
    const sourceBuffer = await readFile(rel(scene.source));
    for (const sizeKey of scene.sizes) {
      const size = SIZES[sizeKey];
      const png = await renderImage({
        sourceBuffer, size,
        headline: scene.headline, subtitle: scene.subtitle, background: scene.background,
      });
      const outPath = path.join(samplesDir, `${scene.id}__${sizeKey}.png`);
      await writeFile(outPath, png);
      const meta = await sharp(png).metadata();
      console.log(`  ✓ samples/${scene.id}__${sizeKey}.png  ${meta.width}×${meta.height}`);
    }
  }
  console.log('Done. Inspect tools/screenshots/samples/*.png');
}

async function cmdFrame(args) {
  const cfg = await loadConfig(args.config);
  let scenes = cfg.scenes || [];
  if (args.only) {
    const ids = String(args.only).split(',').map((s) => s.trim());
    scenes = scenes.filter((s) => ids.includes(s.id));
  }
  if (args.platform) {
    scenes = scenes.filter((s) => s.platform === args.platform);
  }
  if (!scenes.length) {
    console.log('No matching scenes.');
    return;
  }
  console.log(`Framing ${scenes.length} scene(s)…`);
  let total = 0;
  for (const scene of scenes) {
    console.log(`• ${scene.id} (${scene.platform})`);
    const outs = await renderScene(scene, { overrideSize: args.size });
    total += outs.length;
  }
  console.log(`\nWrote ${total} image(s) under out/`);
}

async function cmdOne(args) {
  if (!args.source || !args.headline || !args.platform) {
    console.error('one: requires --source, --headline, --platform');
    process.exit(1);
  }
  const scene = {
    id: args.id || path.basename(args.source).replace(/\.[^.]+$/, ''),
    platform: args.platform,
    source: args.source,
    headline: args.headline,
    subtitle: args.subtitle || undefined,
    background: args.background || 'dark',
  };
  await renderScene(scene, { overrideSize: args.size });
}

function cmdList() {
  console.log('Sizes:');
  for (const [k, v] of Object.entries(SIZES)) {
    console.log(`  ${k.padEnd(16)} ${v.width}×${v.height}  [${v.store}/${v.device}]  ${v.label}`);
  }
  console.log('\nDefault sizes per platform:');
  for (const [k, v] of Object.entries(DEFAULT_SIZES)) {
    console.log(`  ${k.padEnd(10)} → ${v.join(', ')}`);
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);
  const cmd = args._[0] || 'frame';
  switch (cmd) {
    case 'frame': return cmdFrame(args);
    case 'one': return cmdOne(args);
    case 'samples': return cmdSamples();
    case 'list': return cmdList();
    default:
      console.error(`Unknown command: ${cmd}`);
      console.error('Commands: frame | one | samples | list');
      process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
