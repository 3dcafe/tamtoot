# Google Play store listings

This directory contains localized Google Play listing text for 32 widely used
locales. English (`en-US`) is the source locale.

Files:

- `listings.json` is the canonical, review-friendly source.
- `listings.csv` contains the same text in UTF-8 CSV format for import or copy.
- `assets/app-icon-512.png` is the 512 × 512 Google Play icon. It is an RGB
  PNG without transparency and is well below the 1 MB upload limit.

Google Play limits each title to 30 characters, each short description to 80
characters, and each full description to 4,000 characters. The current 32
listings fit these limits and use unique locale codes.

The Play Console import dialog can change and may offer AI translation from a
source document instead of accepting a translated table. If it rejects the CSV,
add each locale in **Store presence → Main store listing → Manage translations**
and paste the corresponding row. Keep the wording aligned with the features in
the released build and review machine translations before publishing.
