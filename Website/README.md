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
PUBLIC_NOINDEX=true
```

- `PUBLIC_SITE_ORIGIN` controls canonical metadata.
- `PUBLIC_NOINDEX` keeps temporary preview deployments out of search engines.

Vercel deploys the site from the repository's `Website/` root. Download actions
link to the GitHub Latest Release, so release binaries are not duplicated in
the website deployment or on a separate origin.

The Bilibili player starts inline with sound muted and restarts for continuous
showcase playback. It hands control back to Bilibili after the visitor first
interacts with the player, so native pause and seeking keep working. An explicit
user action inside the player can navigate to Bilibili in a popup or in the current
page; automatic player behavior cannot replace the product page.
