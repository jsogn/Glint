# Glint Website

Static product and download site for Glint, built with Astro.

## Development

Use Node 22.23.4 or newer:

```bash
nvm use
npm install
npm run dev
```

The site is available at `http://127.0.0.1:4321`.

## Build

```bash
npm run build
```

The static output is written to `dist/`.

## Environment

```text
PUBLIC_SITE_ORIGIN=https://glint.jiangwang.space
PUBLIC_DOWNLOAD_ORIGIN=https://glint-release.tos-cn-beijing.volces.com
PUBLIC_NOINDEX=true
```

- `PUBLIC_SITE_ORIGIN` controls canonical metadata.
- `PUBLIC_DOWNLOAD_ORIGIN` controls release links and `latest.json`.
- `PUBLIC_NOINDEX` keeps temporary preview deployments out of search engines.

Vercel deploys the site from the repository's `Website/` root. Installer and
disk-image downloads remain on Tencent Cloud object storage.

The homepage links directly to the stable `/latest/` objects in the release
bucket, so normal downloads do not depend on runtime release metadata.

The Bilibili player starts inline with sound muted and restarts for continuous
showcase playback. It hands control back to Bilibili after the visitor first
interacts with the player, so native pause and seeking keep working. An explicit
user action inside the player can navigate to Bilibili in a popup or in the current
page; automatic player behavior cannot replace the product page.
