# Using Settings Share

Settings Share 1.0.0 stores strings for reusable share codes and one-use file
downloads. Your plugin handles serialization, validation, and applying settings.
The service URL is `https://settings.rs3.dev`.

## Add the dependency

Install the helper in a client plugin folder named `settingsshare`. Its runtime
contains `main.lua`, `plugin.json`, `lib/json.lua`, and `lib/uuid.lua`.
Merge this entry into your consuming plugin's `plugin.json`:

```json
"requiredDependencies": {
  "settingsshare": "settingsshare"
}
```

This local mapping uses the folder name. For a published dependency, replace the
value with its registered dependency ID. The client exposes the helper through
the `settingsshare` global; no `require` call is needed.

Refresh the manifests and enable HTTP access on **settingsshare**:

```text
prf
pon settingsshare
ppe settingsshare httpAccess
```

Then enable or reload your consuming plugin. A plugin using only this helper
does not need its own HTTP permission, service URL, or Logic subscription.

## Identify your plugin

Pass a stable plugin name as the first argument to every network method. The
helper sends it unchanged as the `User-Agent` header. Names must contain 1-128
printable ASCII characters, without leading/trailing spaces or control
characters. Internal spaces are allowed. Names identify callers; they do not
restrict who can retrieve a code or authenticate the caller.

Use your own name in place of `MyPlugin` in these examples. Call the helper from
a normal plugin action, such as a button click. All examples below are separate
actions, not a script to run repeatedly from an update loop.

## Create a share

```lua
local serializedSettings = "myplugin:v1:your serialized settings"
local pendingCode, problem = settingsshare.write("MyPlugin", serializedSettings, function(code, err)
    if err then
        log("Could not create share: ", err)
        return
    end
    -- Only now is the code confirmed and ready to share.
    log("Share code: ", code)
end)

if not pendingCode then
    log("Could not start sharing: ", problem)
end
```

The UUID is generated locally. The immediate return is a **pending code**, not
proof that the upload succeeded. On success, the callback receives the same code.
A live code's contents cannot be replaced; create a new share for changed settings.

## Retrieve a share

```lua
local started, problem = settingsshare.read("MyPlugin", "paste-share-code-here", function(data, err)
    if err then
        log("Could not fetch share: ", err)
        return
    end
    -- Deserialize data, validate its format/version and values, then apply it.
    log("Received ", #data, " bytes")
end)

if not started then
    log("Could not start retrieval: ", problem)
end
```

Anyone holding the code can fetch it, including a different plugin or account.
Shares expire after **seven days of inactivity**; every successful fetch restarts
that period. Empty settings strings are valid results.

## Create a one-use download

```lua
local started, problem = settingsshare.dump.create("MyPlugin", "your serialized settings", function(code, err, info)
    if err then
        log("Could not create dump: ", err)
        return
    end
    log("Open ", info.downloadUrl, " and enter code: ", code)
end)

if not started then
    log("Could not start dump creation: ", problem)
end
```

The server generates this code, so it arrives in the callback. Enter it at
[settings.rs3.dev/dump](https://settings.rs3.dev/dump) to download a text file.
Unused dumps expire after **24 hours**. Redemption consumes the code before file
delivery; if delivery fails, create another dump.

## Handle errors and UI lifetime

Check both the immediate return and the callback. Validation, permission, and
queue errors return `nil, problem` immediately without invoking the callback.
Queued requests report their eventual result through the callback:

- Success: `(value, nil, metadata)`.
- Failure: `(nil, problem, metadata)`; metadata can be absent.
- Rate limits: check `metadata.code == "rate_limited"` and
  `metadata.retryAfterSeconds`, guarding against absent metadata first.

The helper does not retry. Share creation and dump creation each allow one
request per IP per minute; payloads are capped at 256 KiB. Disable duplicate
buttons while a request is pending. Keep local settings if retrieval fails.

Callbacks run on the helper's normal Logic update. If they update UI, first
check that the panel still exists and the result belongs to the current request.
Closing a panel does not cancel an already queued request. See the
[working debug example](examples/settingssharedebug/main.lua) for a lifetime guard.
You do not need native HTTP callbacks, coroutines, or a blocking wait.

## API reference

| Method | Immediate success return | Callback success value |
| --- | --- | --- |
| `write(pluginName, data, callback)` | Pending UUID string | Confirmed UUID string |
| `read(pluginName, code, callback)` | `true` | Original data string |
| `dump.create(pluginName, data, callback)` | `true` | Server-generated dump code |
| `upload(pluginName, code, data, callback)` | `true` | Confirmed supplied UUID |
| `createCode()` | Local UUID string | No callback or network request |

Callbacks are optional, but provide one when you need upload confirmation or
retrieved data. `createCode()` and `upload(...)` let you separate local generation
from upload when your UI needs it. `settingsshare.version` identifies the loaded
helper. The [README](README.md) includes the complete behavior and HTTP routes.

Only send non-sensitive settings, and validate all imported data. See the
[privacy notice](https://settings.rs3.dev/privacy) for storage and retention.
