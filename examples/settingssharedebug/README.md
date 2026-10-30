# Settings Share Debug

A standalone PrettyUI panel for the installed `settingsshare` dependency. It sends
all requests through the helper and creates its own window when enabled in-game.
Every call passes `SettingsShareDebug` as its plugin name, which the helper sends
as the `User-Agent` header.

## Install

Install `settingsshare` and PrettyUI, then copy this example into the client's
plugin directory as `settingssharedebug`. Its manifest uses local
`requiredDependencies` mappings; published dependencies may need their registered
IDs instead. HTTP permission belongs to `settingsshare`, not the debug panel.

```text
prf
pon settingsshare
ppe settingsshare httpAccess
pon settingssharedebug
```

The footer shows **Helper 1.0.0 | Debug 1.3.0**. Use `prl settingssharedebug` to
reopen the panel. When upgrading the helper, disable the debug panel first,
reload the helper, then re-enable the panel.

## Test

1. Type a string and click **Create share**. The UUID appears immediately but is
   pending until **Share created** confirms the upload.
2. Click **Fetch share**. Expect the original string, **MATCH**, and a TTL of
   **604800 seconds**. Each successful fetch restarts the seven-day TTL.
3. Click **Create dump**. Copy its code into **https://settings.rs3.dev/dump**.
   Expect one download containing the string; a second redemption is unavailable.
   An unused dump expires after 24 hours.

Wait 60 seconds between creations of the same type. Errors display the API code
and retry delay. The panel allows one pending request and never retries
automatically. Closing it prevents late callbacks from touching destroyed UI.
Input is limited to 2,048 characters; status logs do not include the payload.

Crash probes, checkpoints, tracing, and the separate generation/upload controls
have been removed. The helper retains empty native callbacks and processes
results on Logic. Automated tests cover dispatch and UI lifetime; native client
behavior still requires an in-game smoke test after cleanup.

Build the example with `./tools/package.ps1 -Debug`. The output is
`artifacts/settingssharedebug-1.3.0.zip`.
