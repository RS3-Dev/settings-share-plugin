# Short Share Codes

A RuneScape dependency library for sharing settings, syncing a player's settings
across devices, and creating one-use downloads. Its runtime name and global are
`settingsshare`.

Your plugin supplies the UI and converts its settings into a string. This library
transports that string without interpreting it. Your plugin owns serialization,
format/version validation, and applying retrieved settings.

The three services have separate rules:

- **Share:** `write` and `read` use reusable UUID codes. Codes expire after one
  week of inactivity; every successful retrieval resets expiry to one week.
- **Sync:** `sync.save` and `sync.fetch` use a registered plugin name plus player
  ID. Every successful save or fetch resets expiry to one week.
- **Dump:** `dump.create` returns a code for a one-use file download. Unused codes
  expire after 24 hours; redemption deletes the active record.

All services use **https://settings.rs3.dev**, backed by the self-hosted SQLite
service. Cloudflare provides the public HTTPS proxy.
The current privacy notice is **https://settings.rs3.dev/privacy**. The download
page is **https://settings.rs3.dev/dump**. The manifest declares `service` and
`privacy` URL aliases; all HTTP API calls use the same `service` base URL with
different endpoint paths.

The ready-to-paste plugin listing is in [DESCRIPTION.md](DESCRIPTION.md).

For a small in-game test panel, install the
[Settings Share Debug example](examples/settingssharedebug/README.md). It exercises
all five helper functions through the actual dependency.

## Installation

Copy `main.lua`, `plugin.json`, and `lib/` into a folder named `settingsshare`
inside your client's plugin directory.

Enable the plugin and grant its required HTTP access in the client. Version 2.0.0
uses client-generated share UUIDs and callback-free native HTTP requests.

## HTTP execution and upgrading from v1

The documented [client HTTP API](https://developer.runescape.com/rs/core/http.html)
does not expose a blocking request method. Calls enqueue work; the library creates
the native request and calls `request:Post(body)` on its own `Event.Logic` update,
with **no completion or progress callbacks**. It retains the request and checks
`request.finished` from that same subscription, registered lazily when the first
request is queued. Loading the dependency does not initialize native HTTP or
subscribe to events. Response decoding and
your application callback run only during that normal client update. There are
no busy waits, custom threads, sleeps, or coroutine-based HTTP handlers.

The network request itself still runs in the background. This avoids the native
HTTP callback path; it is not a synchronous network request. If the normal Logic
event is unavailable, the library returns an immediate error instead of falling
back to native HTTP callbacks. It retains at most 32 pending requests.

`write` generates a UUID locally and returns that pending code immediately when
the upload is queued, restoring the earlier return convention. It returns
`nil, problem` on an immediate validation or availability error. The code becomes
usable only after the callback confirms upload success. Native setup failures are
delivered through the callback. `read`, `sync.save`, `sync.fetch`, and `dump.create`
return `true` when queued; dump codes still arrive from the server in the callback.

For client crash diagnosis, `settingsshare.setDebugLogging(true)` logs only HTTP
stages (permission check, event subscription, queue, constructor, header, Post,
and dispatch), plus the Lua coroutine/main-thread context where available.
Reading `coroutine.running()` does not create or resume a coroutine. Logging defaults to off and
does not log payloads, codes, player IDs, or response contents. The debug example
enables it automatically. This execution path still needs in-client validation;
Lua mocks cannot demonstrate that the native HTTP implementation is crash-free.

For a local consuming plugin, add this entry to its `plugin.json` requiredDependencies
(keep any existing dependencies):

```json
"requiredDependencies": {
  "settingsshare": "settingsshare"
}
```

Run `prf` after changing a manifest, then reload the consuming plugin.
The client exposes the API as the `settingsshare` global. A published plugin may
need the registered dependency ID in place of the local `"settingsshare"` value.

## Export settings

Pass a serialized string owned by your plugin:

```lua
local pendingCode, problem = settingsshare.write("myplugin:v1:serialized-settings", function(code, err)
    if err ~= nil then
        log("Export failed: ", err)
        return
    end
    log("Share this code: ", code)
end)

if pendingCode == nil then
    log("Export could not start: ", problem)
end
```

The UUID is generated locally and returned before any upload response. The
callback receives the same code after the server confirms it was stored. Treat
the immediate return as pending; offer it for sharing only after confirmation.

## Import settings

```lua
local started, problem = settingsshare.read("123e4567-e89b-42d3-a456-426614174000", function(data, err)
    if err ~= nil then
        log("Import failed: ", err)
        return
    end
    -- Validate your format/version and contents before applying settings.
    log("Received ", #data, " bytes of settings")
end)

if started == nil then
    log("Import could not start: ", problem)
end
```

`read` trims surrounding whitespace and lowercases the code before sending it.
An empty settings string is a valid successful result.

New share codes are client-generated UUID-format strings, such as
`123e4567-e89b-42d3-a456-426614174000`, rather than 24-digit numbers. The backend
still accepts an unexpired legacy 24-digit code for retrieval. A live code's
contents cannot be overwritten. Every successful read atomically renews its TTL
to seven days; a missing or expired code cannot be revived by reading it.

## Sync settings across devices

Use a **registered, case-sensitive plugin name** and the player's stable ID as a
**string**. `PluginDev` is the shared testing name. Other names must be registered
with the service operator before use. Different plugins using `PluginDev` with
the same player ID will overwrite the same record.

```lua
local started, problem = settingsshare.sync.save("PluginDev", playerIdString, serializedSettings, function(saved, err, info)
    if err then
        log("Sync failed: ", err)
        if info and info.code == "rate_limited" then
            -- Retry your newest pending settings after info.retryAfterSeconds.
        end
        return
    end
    log("Saved; expires in ", info.expiresInSeconds, " seconds")
end)

if not started then
    log("Sync could not start: ", problem)
end
```

```lua
local started, problem = settingsshare.sync.fetch("PluginDev", playerIdString, function(data, err, info)
    if err then
        -- Keep local settings when the cloud record is missing or expired.
        log("Could not load synced settings: ", err)
        return
    end
    -- Deserialize, validate, and apply data.
end)

if not started then
    log("Sync retrieval could not start: ", problem)
end
```

Saves replace the previous string; last accepted save wins. A successful save or
fetch sets expiry to 604800 seconds (seven days). The default cap is **64 KiB**.
The service permits **one successful save per player/plugin pair every 60
seconds**, six fetches per pair per minute, plus ten saves and 60 fetches per IP
per minute. Rejected requests do not update data or extend expiry.

Save locally immediately, coalesce changes to the newest pending string, and
schedule uploads around the cooldown. The library does not schedule retries or
repeat network fetches automatically. Its internal Logic handler only checks
completion of requests already started. Fetch on plugin opening or an explicit user request.

`playerIdString` must contain 1–128 ASCII letters, digits, underscores, or hyphens.
Preserve the original ID as a string; converting a large ID through a floating-point
number can lose precision. The service does not verify PID ownership: anyone
knowing the same player ID and plugin name can read or replace the record. The
name registry controls namespaces, not caller identity.

## Create a one-use download

```lua
local started, problem = settingsshare.dump.create(serializedSettings, function(code, err, info)
    if err then
        log("Could not create dump: ", err)
        return
    end
    log("Download page: ", info.downloadUrl)
    log("Dump code: ", code)
end)

if not started then
    log("Dump could not start: ", problem)
end
```

The server generates the dump code, so it arrives in the callback. `dump.create`
returns `true` when the request starts. Visit **https://settings.rs3.dev/dump**,
enter the code, and click **Download file**. It downloads `settings-dump.txt`.
The code works once and expires after 24 hours if unused. Redemption removes the
active record before delivery; if the download fails, create a new dump.

The default cap is **256 KiB**, with one creation and ten download attempts per
IP per minute. The library creates dumps; the website handles their redemption.

## API behavior

- `write` returns a locally generated pending UUID when the upload is queued.
  Its callback confirms the same code was stored.
- `read`, `sync.save`, `sync.fetch`, and `dump.create` return `true` when queued.
  Dump codes are delivered through the application callback.
- Immediate failures return `nil, problem` without invoking the callback.
- Optional callbacks receive `(value, nil, metadata)` on success or
  `(nil, problem, metadata)` on failure. The third argument is additive: existing
  callbacks can keep accepting two arguments. Check the immediate return as
  well as the callback. Metadata may be absent on transport or malformed-response
  errors. API error metadata contains `code`, `retryable`, and, for rate limits,
  `retryAfterSeconds`.
- Callback exceptions are caught, so handle your own settings validation and
  application errors inside the callback.

Share and dump strings are limited to 256 KiB by default. Share creation is
limited to one request per IP per minute, with 60 fetches per IP per minute.

Anyone with a share or dump code can retrieve its contents. The client share-code
generator is not a cryptographic random generator; these codes are not suitable
for protecting secrets. Share ordinary preferences only, without passwords or
tokens, and validate imported settings before applying them. Dump codes are still
generated cryptographically on the server. The backend accepts client UUIDs and
can also allocate a share UUID when a direct API caller omits the code.

The API HMACs codes and sync lookup identifiers before database storage. Settings
strings are not end-to-end encrypted; service administrators can access them.
API expiry and dump redemption remove access to active data. Prior data may remain
in SQLite files, journals, snapshots, or backups; backup retention is configured
by the operator. See the
[current privacy notice](https://settings.rs3.dev/privacy) for hosting, retention,
and contact information.

## HTTP routes

All requests use JSON bodies with the `https://settings.rs3.dev` base URL:

- `write(data, callback)` → `POST /api/v1/settings-share/create` with `{code,data}`;
  the response must echo the client-generated `code`.
- `read(code, callback)` → `POST /api/v1/settings-share/fetch` with `{code}`.
- `sync.save(name, playerId, data, callback)` → `POST /api/v1/settings-sync/save`
  with `{pluginName,playerId,data}`.
- `sync.fetch(name, playerId, callback)` → `POST /api/v1/settings-sync/fetch` with
  `{pluginName,playerId}`.
- `dump.create(data, callback)` → `POST /api/v1/settings-dump/create` with `{data}`.

The download page submits `POST /api/v1/settings-dump/download` with `{code}`.
GET requests and query strings never redeem a dump.

## Development

With Node.js 22 or newer, run all six Lua tests in the bundled Lua 5.4 WebAssembly
runtime:

```sh
npm ci
npm test
```

Run the tests from the repository root with Lua 5.4, using a fresh process for
each file, if you prefer a native Lua installation:

```sh
lua5.4 tests/json_test.lua
lua5.4 tests/main_export_test.lua
lua5.4 tests/extended_api_test.lua
lua5.4 tests/transport_polling_test.lua
lua5.4 tests/uuid_test.lua
lua5.4 tests/debug_example_test.lua
```

Tests mock the client bindings and verify that native HTTP receives no callbacks,
responses dispatch only on Logic updates, active requests stay alive, and queued
callbacks are delivered once. Native client crash behavior still needs in-client verification.

To check the actual Lua helper against the live URL declared in `plugin.json`:

```sh
npm run test:live
```

This opt-in test sends real HTTPS requests through a Node adapter for the native
HTTP bindings. It verifies share and sync round trips, UUID confirmation, code
normalization, TTL response values, registry errors, cooldown/rate-limit metadata,
and a dump download that succeeds exactly once. It also checks `/healthz`, `/dump`,
and `/privacy`. It never runs automatically in CI.

Each run leaves one synthetic share and one unique `PluginDev` sync record to
expire normally; the synthetic dump is redeemed. The test checks rate limiting
without retrying writes. Wait at least one minute between runs and avoid testing
while someone on the same public IP is creating shares or dumps. Payloads, codes,
and player IDs are not printed. Node and Wasmoon are development tools only and
are excluded from the plugin upload ZIP.

The live compatibility check passed on 28 October 2026 (Pacific). This confirms
the Lua/API contract; it does not exercise RuneScape's native HTTP or UI bindings
or resolve the previously reported native client crash. Seven-day renewal and
expired-record behavior are covered by backend database tests; the live check
asserts the returned TTL without waiting for expiry.

Build an upload ZIP with PowerShell:

```powershell
./tools/package.ps1
```

The output is `artifacts/settingsshare-2.0.0.zip`, with `main.lua`, `plugin.json`,
and `lib/` at the ZIP root as required for submission. Tests and documentation
are excluded from the runtime package.
