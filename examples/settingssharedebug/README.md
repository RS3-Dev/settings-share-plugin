# Settings Share Debug

A small in-game panel that calls the installed **settingsshare v2.0.0** dependency.
It never constructs HTTP requests, generates codes itself, or calls the backend directly.

## Install

1. Install/enable the current `settingsshare` plugin and grant **that dependency**
   its required HTTP permission.
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

## Test

- For crash diagnosis, select **Check click**, then **Check input** before testing
  network actions. The first only logs; the second reads the string and updates
  status. Neither calls the helper, subscribes to its HTTP loop, or sends data.
  The debug plugin logs button entry, field reads, and the boundary before and
  after calling the helper, independently of the helper's own logging setting.
- Type any short string and select **Create share**. The helper generates a local
  UUID and the code field shows it immediately as pending. Wait for **Share created**
  to confirm the upload, then select **Fetch share**. The original string returns to the text
  field, and status shows **MATCH** and a TTL of **604800 seconds**.
- Select **Save sync**, change the text, and select **Fetch sync**. The saved
  string should return. This always uses `PluginDev` and the editable test player
  ID. Use the same ID on another device to test syncing; use your own distinctive
  ID if you do not want to share a record with other testers.
- Select **Create one-use dump**. Copy the code from its field and enter it at
  **https://settings.rs3.dev/dump**. It should download the string once. A second
  redemption should be unavailable.

Wait **60 seconds** between share creations, dump creations, or saves to the same
sync pair. Status shows API error codes and retry delays when a limit is reached.
The debug panel sends one request at a time and never retries automatically.
Results and metadata are shown in the panel; status messages also go to the plugin
log without logging the submitted string. Input is limited to 2,048 characters.

Requests are queued from the buttons; native request creation, Post, and completion
all run on the helper's `Event.Logic` update. The example enables stage-only HTTP
diagnostics in the plugin log. If the client crashes again, the final
`[Settings Share HTTP]` line helps identify which boundary was reached; it does
not establish a cause by itself. No submitted or received settings are logged.
Diagnostics also report the Lua context at event subscription and HTTP creation
using `coroutine.running()` when the client exposes it. The helper never creates
or resumes a coroutine itself.
Lua tests cover this dispatch pattern, but the native crash fix is not yet verified.
The debug
UI has no update-loop or game-state subscriptions. Closing the panel (X) or
unloading prevents old callbacks from writing into destroyed UI. Reload the debug
plugin to reopen it, including after logging back into the game.

Build the debug upload ZIP from the repository root with
`./tools/package.ps1 -Debug`. It writes
`artifacts/settingssharedebug-1.0.0.zip`, with both runtime files at its root.
