# Settings Share Debug

A small in-game panel that calls the installed **settingsshare v3.0.0** dependency.
It never constructs HTTP requests or calls the backend directly. Code generation
and upload are separate calls to the helper, so crashes can be isolated.

## Install

1. Install/enable the current `settingsshare` plugin and grant **that dependency**
   its optional `httpAccess` permission before making network requests. The helper
   can load without the grant; requests then report a permission error.
2. Install/enable **PrettyUI**, then copy this folder into the local plugin
   directory as `settingssharedebug`.
3. Run `prf` to refresh the manifests. While in the game, enable/reload
   `settingssharedebug`. It creates its own panel
   immediately in the centre, without plugin-panel registration. It uses the
   same `prettyui.Window` startup setup as Taint Check, plus PrettyUI text fields
   and sprite-backed buttons. Startup logs each UI creation step.

The manifest uses `requiredDependencies` with local folder mappings for both
`settingsshare` and `prettyui`. If testing a published dependency, use its
registered dependency ID instead (PrettyUI's published ID is `6398181`).
The debug plugin itself requests no permissions and declares no service URLs.

For a fresh local install, run `prf`, `pon settingsshare`,
`ppe settingsshare httpAccess`, and `pon settingssharedebug` in that order.
Use `prl settingssharedebug` to reopen an already loaded panel.
The ready message identifies the helper version actually loaded; expect
`Helper 3.0.0`. `unknown` indicates an older helper without a version export.
The footer permanently shows **Loaded Helper ... | Debug ...**. The separate
**Saved checkpoint from previous attempt** status can show an older version; it
identifies that recorded attempt, not the helper currently loaded.

## Regular tests

Helper **2.0.11** and debugger **1.0.11** passed the normal share sequence in
client **951-1** on 29 October 2026: local code generation, upload confirmation
and UI update, then retrieval. No crash or nil-function error was reported.
The current helper 3.0.0 removes sync and keeps that HTTP transport unchanged.
Dump has passed live API tests through the development adapter; use the steps
below to confirm its native client path too.

1. Type a short string and select **Generate code**, then **Upload share**.
   Wait for **Share created**. The code is generated locally, and the helper
   uploads it with the string; the panel never waits for a server-generated share
   code. Generation alone does not create a usable share.
2. Select **Fetch share**. Expect the original string, **MATCH**, and a TTL of
   **604800 seconds**.
3. Select **Create one-use dump**. Copy the code and redeem it at
   **https://settings.rs3.dev/dump**. Expect the string to download once, with a
   second redemption unavailable.

Wait **60 seconds** between share creations, or dump creations. Status shows API error codes and retry delays when a limit is reached.
The debug panel sends one request at a time and never retries automatically.
Input is limited to 2,048 characters. Status messages log no submitted strings.

The panel's regular buttons demonstrate consuming-plugin integration: call the
helper, check the immediate return, then handle the result in an application
callback. Closing or unloading the panel invalidates its pending UI callbacks so
late results do not write into destroyed controls. Reload the debug plugin to
reopen it, including after logging back into the game.

## Diagnostic controls

These controls are optional and are not prerequisites for normal API calls.

- **Prepare loop** arms local phase checkpoints and registers the normal helper
  Logic handler with an empty queue. It sends no request. Checkpoints store only
  helper version, phase, and before/after/error marker under
  `settingsshare:transport-checkpoint:v1`; no settings, codes, player IDs, or URLs.
- **Upload no callback** requires **Prepare loop** and a fresh generated code.
  It calls the ordinary upload API without an *application* callback. Its queued
  status deliberately stays on screen; reload the debug panel afterward.
  Empty native completion/progress functions are still supplied internally.
- **Probe HTTP step** isolates permission, subscription, request construction,
  headers, POST, the finished flag, and response reading. Click once to queue an
  HTTP operation and again to view its saved result. Normal tests are blocked
  once probing starts. Reload both helper and debugger before switching back.

After a client restart, the panel displays the last checkpoint without arming or
retrying a request. Copy it before preparing another attempt. It identifies the
last recorded stage, not necessarily the exact faulting native instruction.

Regular calls use the helper's Logic subscription; the UI has no update-loop or
game-state subscription. Native HTTP callbacks are empty, and all response work
runs on Logic. Omitting those native callbacks previously produced a nil-function
error; supplying them removed the error in the verified share sequence. The
precise cause of every earlier crash remains unproven. Helper tracing stays off
by default, and the helper performs no coroutine inspection.

Build the debug upload ZIP from the repository root with
`./tools/package.ps1 -Debug`. It writes
`artifacts/settingssharedebug-1.1.0.zip`, with both runtime files at its root.
