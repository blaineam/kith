#!/usr/bin/env node
// Haven US export-compliance automation.
//
// Haven uses real end-to-end, post-quantum encryption, so it is "non-exempt"
// (ECCN 5D992.c, mass-market, License Exception ENC §740.17(b)(1)). That does NOT
// restrict App Store distribution — it just requires two pieces of US paperwork,
// both generated here:
//
//   1. ONE-TIME: a "publicly available encryption source code" notification
//      (EAR §742.15(b)) — because Haven's source is open on GitHub. Email it once
//      (and again only if the URL changes).
//   2. ANNUAL (due Feb 1): a self-classification report of the mass-market app
//      (Supplement No. 8 to Part 742), as a CSV emailed to BIS + NSA.
//
//   Usage:  node Scripts/export-compliance.mjs            # generate both
//           node Scripts/export-compliance.mjs --print    # print to stdout too

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'Scripts', 'export-compliance');
mkdirSync(OUT, { recursive: true });

const COMPANY = 'Blaine Miller';
const EMAIL = 'blaine@wemiller.com';
const PRODUCT = 'Haven';
const SOURCE_URL = 'https://github.com/blaineam/haven';
const ALGORITHMS = 'AES-256-GCM, X25519, ML-KEM-768 (FIPS 203), Ed25519, ML-DSA-65 (FIPS 204), HKDF-SHA256, BLAKE3';
const TO = 'crypt@bis.doc.gov, enc@nsa.gov';

// 1) One-time publicly-available source-code notification (EAR §742.15(b)).
const notification = `To: ${TO}
From: ${COMPANY} <${EMAIL}>
Subject: Notification of Publicly Available Encryption Source Code — ${PRODUCT}

Pursuant to EAR §742.15(b), this is notification that encryption source code
that would be classified under ECCN 5D002 is publicly available, without charge
to obtain, at the following internet location:

  ${SOURCE_URL}

Product:        ${PRODUCT} (peer-to-peer, end-to-end encrypted social application)
Author/Owner:   ${COMPANY} <${EMAIL}>
Encryption:     Standard published algorithms — ${ALGORITHMS}
                used for end-to-end confidentiality, key establishment, and
                authentication of user-to-user communications.

This notification covers the source code at the URL above and any updates posted
to that same location. Please contact the address above with any questions.

${COMPANY}
${EMAIL}
`;

// 2) Annual self-classification report (Supplement No. 8 to Part 742) — CSV.
const csvHeader = [
  'Manufacturer', 'ProductName', 'ModelNumber', 'ECCN', 'AuthorizationType',
  'ItemType', 'Description', 'NonStandardCrypto', 'SourceCodeURL', 'PointOfContact', 'Email',
].join(',');
const csvRow = [
  COMPANY, PRODUCT, 'iOS', '5D992.c', '740.17(b)(1)',
  'Network application / messaging', 'End-to-end encrypted social app',
  'No (standard published algorithms only)', SOURCE_URL, COMPANY, EMAIL,
].map((f) => `"${String(f).replace(/"/g, '""')}"`).join(',');
const report = `${csvHeader}\n${csvRow}\n`;

const reportEmail = `To: ${TO}
From: ${COMPANY} <${EMAIL}>
Subject: Annual Self-Classification Report — ${COMPANY}

Attached is the annual self-classification report for mass-market encryption
items (ECCN 5D992.c) under License Exception ENC §740.17(b)(1), per Supplement
No. 8 to Part 742. CSV attached: self-classification-report.csv

${COMPANY}
${EMAIL}
`;

writeFileSync(join(OUT, 'open-source-notification.txt'), notification);
writeFileSync(join(OUT, 'self-classification-report.csv'), report);
writeFileSync(join(OUT, 'self-classification-email.txt'), reportEmail);

console.log(`✓ Wrote to ${OUT}:
  • open-source-notification.txt      → send ONCE to ${TO}
  • self-classification-report.csv    → attach to the annual report
  • self-classification-email.txt     → send by Feb 1 each year to ${TO}

App Store Connect (one-time App Encryption Declaration):
  Uses encryption?                         Yes
  Qualifies for exemptions in 5, Part 2?   No  (it's E2E confidentiality)
  Standard (published) algorithms only?    Yes
  Available as mass market / open source?  Yes → ECCN 5D992.c, License Exception ENC
  → Apple accepts the self-classification; no CCATS upload needed.

The Info.plist already declares ITSAppUsesNonExemptEncryption = YES.
Global distribution is NOT restricted by any of this.`);

if (process.argv.includes('--print')) {
  console.log('\n--- open-source-notification.txt ---\n' + notification);
  console.log('\n--- self-classification-report.csv ---\n' + report);
}
