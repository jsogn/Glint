export const fallbackRelease = {
  version: "0.4.1",
  publishedAt: "2026-10-27T13:19:41Z",
  source: "https://github.com/jsogn/Glint/releases/tag/v0.4.1",
  pkg: {
    stableURL: "/latest/Glint-Installer-macOS26-arm64.pkg",
    versionedURL:
      "/releases/v0.4.1/Glint-0.4.1-Installer-macOS26-arm64.pkg",
    size: 117603560,
    sha256:
      "7cd0413b890ef05e517c8282c6ce79e20a671d235827e3d30c832608f45f9b17"
  },
  dmg: {
    stableURL: "/latest/Glint-macOS26-arm64.dmg",
    versionedURL: "/releases/v0.4.1/Glint-0.4.1-macOS26-arm64.dmg",
    size: 124449249,
    sha256:
      "9542376aa3f8ce5508f8d29a2511d2973e0299b726d1d798a98b42d69e77718b"
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
