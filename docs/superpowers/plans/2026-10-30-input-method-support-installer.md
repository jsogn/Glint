# Input Method Support Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Debug-only `输入法支持` page with a transactional one-click
Rime bridge installer.

**Architecture:** A pure Rime patch editor handles schema source safely. A
GlintMac actor performs detection and transactional file operations. GlintUI
renders status through injected model actions. The App bundles the signed relay
and Lua resources and maps service state into UI state.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, XcodeGen, CryptoKit.

**Spec:** `docs/superpowers/specs/2026-10-30-input-method-support-design.md`

## Global Constraints

- Minimum macOS: 26.0.
- Arm64-only app build.
- No third-party UI components.
- Squirrel bridge remains Debug-only.
- Do not modify Squirrel.app.
- Do not log or persist candidate text.
- Do not commit or push unless explicitly requested.

---

### Task 1: Safe Rime schema patch editor

**Files:**
- Create: `Packages/GlintMac/Sources/GlintMac/RimeBridge/RimeSchemaPatchEditor.swift`
- Test: `Packages/GlintMac/Tests/GlintMacTests/RimeSchemaPatchEditorTests.swift`

**Interfaces:**
- Produces:
  - `enum RimeSchemaPatchError: Error, Equatable`
  - `struct RimeSchemaPatchEditor`
  - `func install(into source: String?, schemaID: String) throws -> RimeSchemaPatchResult`
  - `func removeManagedFilter(from source: String) -> String`

- [x] Write a test that creates a managed `patch:` block for a missing custom
  file and asserts the exact `engine/filters/+` structure.
- [x] Run `swift test --package-path Packages/GlintMac --filter
  RimeSchemaPatchEditorTests`; expect failure because the editor does not exist.
- [x] Implement creation, existing-filter detection, simple insertion, managed
  list insertion, and unsupported nested-structure rejection.
- [x] Add tests for idempotency, existing manual Glint filter, and uninstall
  removal.
- [x] Re-run the targeted tests and expect all to pass.

### Task 2: Squirrel integration service

**Files:**
- Create: `Packages/GlintMac/Sources/GlintMac/RimeBridge/SquirrelIntegrationService.swift`
- Test: `Packages/GlintMac/Tests/GlintMacTests/SquirrelIntegrationServiceTests.swift`

**Interfaces:**
- Produces:
  - `enum SquirrelIntegrationState: Sendable, Equatable`
  - `struct SquirrelIntegrationStatus: Sendable, Equatable`
  - `actor SquirrelIntegrationService`
  - `func status() async -> SquirrelIntegrationStatus`
  - `func install() async throws -> SquirrelIntegrationStatus`
  - `func uninstall() async throws -> SquirrelIntegrationStatus`

- [x] Write installer tests using temporary Rime, support, Lua, and relay
  directories.
- [x] Verify RED with the service test filter.
- [x] Resolve `schema_list` from shared and user Rime configuration, intersect
  it with compiled schemas, and fail closed on ambiguous YAML.
- [x] Implement enabled-schema discovery, asset validation, transactional backups,
  atomic writes, manifest encoding, reload injection, rollback, repair, and
  uninstall.
- [x] Verify file contents, hashes, relay permissions, manifest contents, and
  restoration after injected reload failure.
- [x] Re-run the targeted tests and expect all to pass.

### Task 3: Bundle signed relay and Lua assets

**Files:**
- Modify: `project.yml`
- Modify: `scripts/build.sh`
- Test: `App/GlintTests/AppSmokeTests.swift`

**Interfaces:**
- Produces app bundle paths:
  - `Contents/Helpers/RimeCandidateBridge`
  - `candidate_bridge.lua`
  - `json.lua`

- [x] Add a failing App smoke test that requires the helper and Lua resources
  in `Bundle.main`.
- [x] Run the App test and observe the missing-resource failure.
- [x] Add the `RimeCandidateBridge` tool target, app resource entries, copy
  phase to `Contents/Helpers`, and ad-hoc nested-helper signing in
  `scripts/build.sh`.
- [x] Re-run `./scripts/dev.sh --build-only` and the App smoke test.
- [x] Verify the helper is executable and `codesign --verify --deep --strict`
  succeeds.

### Task 4: Input-method UI state and page

**Files:**
- Create: `Packages/GlintUI/Sources/GlintUI/InputMethods/InputMethodSupportStatus.swift`
- Create: `Packages/GlintUI/Sources/GlintUI/Pages/InputMethodsPage.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/MainWindowView.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/MainWindowModel.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/OverviewPage.swift`
- Test: `Packages/GlintUI/Tests/GlintUITests/InputMethodSupportModelTests.swift`

**Interfaces:**
- Produces `InputMethodSupportStatus` and async model actions for refresh,
  install, and uninstall.

- [x] Write failing model tests for initial native Apple status, successful
  refresh, install, uninstall, and surfaced errors.
- [x] Implement the status model and action closures.
- [x] Add the `输入法支持` sidebar item, Rime status card, confirmation
  dialogs, and overview navigation action.
- [x] Re-run GlintUI tests and the targeted page rendering tests.

### Task 5: App wiring and Debug gating

**Files:**
- Modify: `App/Glint/AppEnvironment.swift`
- Modify: `App/Glint/AppDelegate.swift`
- Test: `App/GlintTests/AppSmokeTests.swift`

**Interfaces:**
- Consumes the GlintMac service and GlintUI status types.
- Produces Debug-only model actions; Release leaves Squirrel support hidden.

- [x] Add a failing App smoke test for Debug status registration and Release
  absence.
- [x] Wire the service to `MainWindowModel` inside `#if DEBUG`.
- [x] Map service states to UI status values.
- [x] Re-run App tests and verify Release still uses
  `MonitoringController(router:)`.

### Task 6: Documentation and end-to-end validation

**Files:**
- Modify: `docs/SQUIRREL-CANDIDATE-BRIDGE.md`
- Modify: `Tools/RimeCandidateLab/README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] Document the one-click install, managed files, backup location,
  uninstall, Debug-only boundary, and complex-YAML fallback.
- [x] Run Lua tests, `swift build --package-path Tools/RimeCandidateLab`,
  targeted GlintMac/UI tests, and `./scripts/test.sh`.
- [x] Build Release arm64 and verify no helper is installed by the Release app.
- [x] Run `swift format lint`, `git diff --check`, and verify user Rime files
  are byte-identical after uninstall tests.
