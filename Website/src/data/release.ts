export const fallbackRelease = {
  version: "0.4.1",
  publishedAt: "2026-10-27T12:42:42Z",
  source: "https://github.com/jsogn/Glint/releases/tag/v0.4.1",
  pkg: {
    stableURL: "/latest/Glint-Installer-macOS26-arm64.pkg",
    versionedURL:
      "/releases/v0.4.1/Glint-0.4.1-Installer-macOS26-arm64.pkg",
    size: 117608130,
    sha256:
      "2f53fb8bbd0f4d5c87bd6aef56bdbd00a5da19347f1026296deece6aebc04e67"
  },
  dmg: {
    stableURL: "/latest/Glint-macOS26-arm64.dmg",
    versionedURL: "/releases/v0.4.1/Glint-0.4.1-macOS26-arm64.dmg",
    size: 124445102,
    sha256:
      "c2d5516f6169972f91644598d7ec62b6025c457345ffc69bf6db60e557d3432d"
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
