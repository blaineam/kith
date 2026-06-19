# US export compliance (automated)

Kith uses **real end-to-end, post-quantum encryption**, so it is **non-exempt**
(ECCN **5D992.c**, mass-market, License Exception ENC §740.17(b)(1)). Keeping that
encryption is non-negotiable — and it does **not** restrict global App Store
distribution. It only requires US paperwork, which is automated.

## Fully automated via rocket

```sh
node _shared/rocket/rocket.mjs compliance Kith
```

This **creates the App Encryption Declaration** in App Store Connect (standard
algorithms, not proprietary, third-party crypto, available on the French store) and
**attaches it to the latest build** — so non-exempt builds never hit "Missing
Compliance" and future builds inherit it. Run it once after the first upload (or after
`rocket build Kith`); no manual ASC questionnaire needed. (Done — declaration created
and attached to build 2.)

## What's declared

- `Info.plist`: **`ITSAppUsesNonExemptEncryption = YES`** (honest; set in `project.yml`).
- **App Store Connect — one-time App Encryption Declaration** (the answers):
  - Uses encryption? **Yes**
  - Qualifies for an exemption in Category 5, Part 2? **No** (it's E2E confidentiality)
  - Standard, published algorithms only? **Yes**
  - Mass market / open source? **Yes** → ECCN 5D992.c, License Exception ENC
  - Apple accepts the self-classification — **no CCATS upload needed**.

## The two filings (generated for you)

Run `node Scripts/export-compliance.mjs` → writes ready-to-send files:

1. **One-time** — `open-source-notification.txt`: because Kith's source is public on
   GitHub, EAR §742.15(b) lets you notify BIS + NSA of the URL. Send once (and again
   only if the URL changes).
2. **Annual (due Feb 1)** — `self-classification-report.csv` + `self-classification-email.txt`:
   the mass-market self-classification report, emailed to `crypt@bis.doc.gov` and
   `enc@nsa.gov`.

The generated files are gitignored (they contain contact details); regenerate anytime.
Consider a yearly calendar reminder for the Feb 1 deadline.

## Why this keeps distribution global

Non-exempt ≠ restricted. 5D992.c mass-market apps under ENC are eligible for export to
essentially all destinations (excluding embargoed countries, which Apple already
excludes). The open-source notification further places the *source* outside EAR
control. Net: strongest encryption **and** worldwide availability.
