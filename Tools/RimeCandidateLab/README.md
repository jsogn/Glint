# Rime Candidate Bridge Lab

Experimental bridge for reading Rime candidates without modifying Squirrel.

The stock Squirrel candidate panel exposes one `AXTextArea` with no candidate
children, candidate text, or selected-candidate semantics. Squirrel bundles
`librime-lua`, which can read the engine candidate stream and selected index.
This lab forwards that state to Glint over a local Unix domain socket.

## Architecture

```text
Squirrel + librime-lua
  └─ glint.candidate_bridge filter
       └─ RimeCandidateBridge relay
            └─ Unix domain socket
                 └─ Glint RimeCandidateBridgeReceiver
```

Candidate text travels only through process pipes and a user-only socket. The
adapter does not write candidate text to files or logs.

Protocol v3 carries the selected candidate explicitly and reports the selected
index relative to the current Rime page. Each snapshot also carries a session
ID, a monotonic sequence, and a heartbeat flag.

The relay repeats its last protocol line once per second with `heartbeat: true`.
Glint only uses a heartbeat to refresh a snapshot with the same session ID and
sequence. A stale session can therefore keep its current candidate alive
without overwriting a newer candidate from another session.

Lua snapshots are emitted from Rime's update/select notifiers after the complete
current page is available. The filter never publishes a partially prepared page
during lazy iteration.

## Application integration

Debug builds of Glint provide the preferred installation path:

1. Build and launch with `./scripts/dev.sh`.
2. Open `输入法支持`.
3. Choose `一键启用`, `修复安装`, or `重新部署`.

The installer resolves enabled Rime schemas from `schema_list`, intersects them
with compiled schemas, and refuses to modify unsupported YAML. It creates a
backup and an install manifest before writing, then rolls back on any failure.
See [鼠须管输入法支持](../../docs/SQUIRREL-CANDIDATE-BRIDGE.md) for the full
transaction, managed paths, privacy boundary, and uninstall behavior.

Release builds do not expose this page, start the socket receiver, or perform
an install.

## Build and test

```bash
swift build --package-path Tools/RimeCandidateLab
swift test --package-path Packages/GlintCore --filter RimeCandidateEnvelopeTests
swift test --package-path Packages/GlintMac --filter RimeCandidateBridgeTests
swift test --package-path Packages/GlintMac --filter SquirrelIntegrationServiceTests
lua Tools/RimeCandidateLab/rime/tests/glint_json_test.lua
lua Tools/RimeCandidateLab/rime/tests/glint_filter_test.lua
```

The Xcode project also builds `RimeCandidateBridge` as a tool target and copies
it to `Glint.app/Contents/Helpers/RimeCandidateBridge`. Development signing signs
the nested helper before signing the app.

## Manual lab setup

Use this path only when the in-app installer reports that the Rime YAML cannot
be merged automatically.

Copy the relay into the path expected by the Lua adapter:

```bash
relay_dir="$HOME/Library/Application Support/Glint/RimeCandidateLab"
mkdir -p "$relay_dir" "$HOME/Library/Rime/lua/glint"
cp Tools/RimeCandidateLab/.build/debug/RimeCandidateBridge "$relay_dir/"
cp Tools/RimeCandidateLab/rime/lua/glint/*.lua \
  "$HOME/Library/Rime/lua/glint/"
```

Back up the target `<schema>.custom.yaml`, then merge this filter into its
existing `patch:` map:

```yaml
patch:
  engine/filters/@before 0: lua_filter@*glint.candidate_bridge
```

Do not replace unrelated `engine:` or filter-list configuration. Redeploy
Squirrel:

```bash
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload
```

Run the monitor before typing:

```bash
"$relay_dir/RimeCandidateBridge" monitor \
  --socket "$relay_dir/bridge.sock"
```

`--show-text` is development-only. Without it, the monitor prints hashes and
metadata only.

## Headless engine check

The included console harness builds its own Rime session and exercises the same
Lua filter without changing the active input source:

```bash
Tools/RimeCandidateLab/build_engine_console.sh /path/to/librime-source
```

Run it with a disposable copy of the Rime user directory:

```bash
Tools/RimeCandidateLab/.build/engine_console \
  "/Library/Input Methods/Squirrel.app/Contents/SharedSupport" \
  "$rime_user_dir" \
  nihao \
  '{Down}'
```

To capture relay output without competing with Glint's live socket, set a
temporary socket:

```bash
GLINT_RIME_BRIDGE_SOCKET="$tmp_dir/bridge.sock" \
Tools/RimeCandidateLab/.build/engine_console \
  "/Library/Input Methods/Squirrel.app/Contents/SharedSupport" \
  "$rime_user_dir" \
  nihao \
  '{Down}'
```

## Current boundaries

- Candidate text and selected index are available from Rime's final candidate
  stream.
- Candidate geometry is not exposed by Lua, Squirrel AX, or CGWindow. Glint
  falls back to the host input caret when the panel frame is unavailable.
- `selectedText` is authoritative, and `selectedIndex` is optional page
  context.
- The adapter is not bundled or installed by Squirrel itself. Installation
  remains explicit, auditable, and removable.
- Running Lua inside the input method expands the trust boundary.
