# M5 Main Window and Settings Design

## Goal

Turn the existing main window shell into a truthful control surface for the
running translation pipeline. The window must show installed plugin state, use
the real HUD for preview, persist display preferences, and stop exposing
English-specific naming in its domain contract.

## Scope

- Read dictionary and translation plugins from `PluginManager`.
- Use the same plugin data on the overview and plugin pages.
- Preview the production HUD panel rather than a static mock.
- Persist HUD position and candidate stability delay in `UserDefaults`.
- Apply stability delay before showing the HUD.
- Apply the configured HUD position when real results and previews are shown.
- Rename `EnglishResult` to `TranslationResult`.

Remote plugin download remains outside M5.

## Components

### `DisplayPreferences`

An `@Observable`, main-actor settings object with:

- `position`: automatic, above, or below.
- `candidateDwellDuration`: clamped to 0.08...0.3 seconds.

Persistence uses `UserDefaults` and can be injected for tests.

### `MainWindowModel`

Owns the display preferences, the installed plugin snapshot, and the callbacks
used by the view:

- start and stop translation hints;
- preview the production HUD;
- refresh permission and plugin state.

Plugin summaries are computed from the installed manifests. The overview and
plugin pages read this single source of truth.

### HUD integration

`HUDController` accepts a position preference. Automatic preserves the current
behavior of preferring below the candidate and falling back above when needed.
Explicit above/below positions are clamped to the visible screen.

The app delegate delays HUD presentation using the configured stability delay,
but does not restart the timer while repeated OCR results report the same
candidate.

HUD background is one direct choice: dark glass, system candidate, or solid.
Dark glass is the default. Dark glass uses the native AppKit popover material
behind the window with a dark appearance. The system candidate style uses
regular Liquid Glass on macOS 26 and falls back to popover material with a white
tint on earlier supported systems. Its opacity is controlled by the system.
Solid background defaults to black at 80% opacity. Text color is independent,
and dark glass and solid backgrounds own separate opacity preferences.

### Window title

The selected page title lives in the unified toolbar as a capsule. macOS 26
uses the system Liquid Glass effect; earlier supported systems use the same
shape with regular material. The title bar and surrounding content remain
transparent, while the capsule keeps the title legible as settings content
scrolls underneath.

### About page

Keep the app version in the Glint identity block near the product tagline.
Present macOS and processor requirements as a separate system-requirements
row, not as page-level metadata or a current-environment label. Product copy
describes the benefit to the user rather than the candidate-reading internals.

### Permissions page

A granted accessibility permission renders as read-only status. When permission
is missing, show one primary action: request access before the first prompt,
then open System Settings afterward. The app refreshes permission state when it
becomes active and starts monitoring automatically when access changes from
missing to granted; do not require a separate refresh or restart.

## Error handling

- Empty plugin lists render as “未安装”.
- Plugin refresh has an explicit loading state.
- HUD preview is clamped to an available screen and does not activate the app.
- Invalid persisted settings fall back to automatic position and 200 ms delay.

## Responsive width

- The overview column uses one fluid maximum of 1,200 pt and remains centered
  within the detail area; it does not introduce breakpoint-based rearrangement.
- Narrow windows shrink to available width, while wide/full-screen windows use
  the additional space without allowing cards to span an unbounded display.

## Testing

- Unit tests verify preference persistence and delay clamping.
- Existing app, dictionary, inference, plugin, and macOS tests must continue to
  pass.
- Manual verification checks real plugin names, production HUD preview, and
  persistence of the selected HUD position.
