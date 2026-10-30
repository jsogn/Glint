# Input Method Support Installer Design

## Goal

Add a top-level `输入法支持` page that lets a user install or remove the Rime
candidate bridge with one action while preserving their existing configuration.

## Constraints

- Squirrel support is a best-effort production capability. Users must opt in
  explicitly before Glint writes any Rime configuration.
- Release builds bundle the bridge assets and provide the same install,
  migrate, repair, and uninstall flows as Debug builds.
- Apple Pinyin, WeType, Sogou, and generic AX readers must not change behavior.
- The installer may only modify Rime user files. It must never modify
  `/Library/Input Methods/Squirrel.app`.
- Candidate text must not be written to logs or the installation manifest.
- The relay must come from the signed Glint bundle. The installer must not
  download executable code.
- If an existing schema patch cannot be merged safely, stop without writing it
  and direct the user to the manual instructions.

## User Experience

The sidebar becomes:

```text
概览
通用配置
输入法支持
显示与触发
插件与模型
权限与隐私
关于
```

The `输入法支持` page contains:

- `Rime`: an outcome-first summary such as automatic candidate translation.
  Protocol version and schema IDs live in a collapsed `技术详情` disclosure.
- The plugin is named `候选读取支持` and its copy describes only candidate
  reading, not Glint's overall translation feature.
- One primary action for an uninstalled plugin: `安装`.
- Installed and reinstall-required actions use `重新安装`; uninstall uses `卸载`.

The overview input-method block links to `输入法支持` when Rime is selected and
the bridge is not installed.

## Components

### GlintMac

`SquirrelIntegrationService` is an actor that owns all filesystem mutations.

- Detect Squirrel and the Rime user directory.
- Read the effective shared `default.yaml`, apply a simple user
  `default.custom.yaml` `schema_list` replacement or append, and intersect that
  list with compiled schema IDs under `~/Library/Rime/build/*.schema.yaml`.
- Refuse automatic editing when `schema_list` cannot be resolved without guessing.
- Inspect bundled Lua and relay assets.
- Produce a status snapshot without modifying disk.
- Install, repair, reload, and uninstall transactionally.

`RimeSchemaPatchEditor` is a pure, source-preserving editor.

- Create a new `<schema>.custom.yaml` when absent.
- Insert `engine/filters/+` under an existing `patch:` map.
- Extend an existing `engine/filters/+` list with a managed marker block.
- Treat nested `engine:` mappings, anchors, inline filter lists, and unknown
  patch roots as unsupported rather than rewriting them.

### GlintUI

`MainWindowModel` receives async closures for status, install, and uninstall.
`InputMethodSupportPage` renders those values and never touches files directly.

### App

`AppEnvironment` constructs the service with:

- the Rime user directory;
- Glint's Application Support directory;
- the signed relay in `Contents/Helpers`;
- the two Lua files copied into the app resources.

`AppDelegate` maps `SquirrelIntegrationStatus` to UI-facing status values.

## Installation Transaction

1. Re-read and validate the Squirrel application and compiled schemas.
2. Build a patch plan for every enabled, compiled schema.
3. Abort before writing anything if any schema is unsupported.
4. Create a timestamped backup directory and copy every existing target file.
5. Atomically write Lua files and the relay helper with mode `0700`.
6. Atomically write each schema custom file.
7. Write `install-manifest.json` with protocol version, SHA256 file hashes,
   schema IDs, created files, and backup paths.
8. Run `Squirrel --reload`.
9. On any failure, restore every original file and remove files created by the
   transaction.

The manifest never contains candidate text.

## Uninstallation

- Prefer restoring the exact backups recorded in the manifest.
- Delete schema custom files that the installer created.
- Delete only bridge files whose hashes match the bundle or manifest.
- Remove the relay helper installed by Glint.
- Re-run `Squirrel --reload`.
- If no manifest exists, remove only an exact Glint filter marker and files
  with known matching hashes.

## Failure Handling

- Squirrel absent: `不可用`.
- Compiled schemas absent: ask the user to launch and deploy Squirrel first.
- Bundled Lua/helper missing: `安装包损坏`.
- Existing custom YAML unsupported: `需要手动配置`, no writes.
- Reload fails: restore backups and report the command failure.
- App protocol version differs from installed manifest: `需要修复`.

## Verification

- Pure patch-editor tests cover new, simple existing, filter-list existing,
  already-installed, and unsupported files.
- Installer tests use temporary directories and verify files, hashes,
  permissions, backups, repaired installs, reload failure rollback, and
  uninstall restoration.
- UI-model tests cover loading, success, error, install, and uninstall actions.
- App build verification checks that the helper and Lua assets are embedded in
  Release, executable where applicable, and signed with the app.
- Real Squirrel validation installs into a temporary Rime user directory first.
