/// <reference types="astro/client" />

interface ImportMetaEnv {
  readonly PUBLIC_SITE_ORIGIN?: string;
  readonly PUBLIC_DOWNLOAD_ORIGIN?: string;
  readonly PUBLIC_NOINDEX?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
