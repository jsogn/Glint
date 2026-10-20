# ADR-0001: Native macOS shell

## Status

Accepted.

## Decision

Glint uses Swift 6 with AppKit for application and window lifecycle and SwiftUI
for settings and HUD content.

## Context

The product depends on ScreenCaptureKit, Vision, Accessibility, TIS, a
non-activating NSPanel, global TCC permissions, and notarization. These are
first-class macOS APIs.

## Consequences

- No Electron/Tauri/WebView layer.
- HUD window behavior remains under AppKit control.
- Settings and preview content can use SwiftUI's system controls.
