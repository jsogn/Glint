export const fallbackRelease = {
  version: "0.4.0",
  publishedAt: "2026-10-26T07:06:28Z",
  source: "https://github.com/jsogn/Glint/releases/tag/v0.4.0",
  pkg: {
    stableURL: "/latest/Glint-Installer-macOS26-arm64.pkg",
    versionedURL:
      "/releases/v0.4.0/Glint-0.4.0-Installer-macOS26-arm64.pkg",
    size: 117589936,
    sha256:
      "d05ef583c0852bc8e0b25a864232e49a3d8e4e875d3ac93f4d32a7d2d469bfde"
  },
  dmg: {
    stableURL: "/latest/Glint-macOS26-arm64.dmg",
    versionedURL: "/releases/v0.4.0/Glint-0.4.0-macOS26-arm64.dmg",
    size: 124441085,
    sha256:
      "7bb6b21ad4b0a6556a791f09df2749950f4202e0e0cea7b71f02592187dfff05"
  }
} as const;

export const downloadOrigin = (
  import.meta.env.PUBLIC_DOWNLOAD_ORIGIN ??
  "https://glint-release.tos-cn-beijing.volces.com"
).replace(/\/$/, "");

export function downloadURL(path: string): string {
  return `${downloadOrigin}${path}`;
}

export function formatBytes(bytes: number): string {
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}
