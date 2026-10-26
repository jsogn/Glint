import { defineConfig } from "astro/config";

export default defineConfig({
  output: "static",
  site: process.env.PUBLIC_SITE_ORIGIN || undefined,
  build: {
    inlineStylesheets: "auto"
  }
});
