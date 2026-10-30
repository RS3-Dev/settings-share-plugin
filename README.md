# Short Share Codes

A RuneScape dependency library for sharing settings and creating
one-use downloads. Its runtime name and global are
`settingsshare`.

Your plugin supplies the UI and converts its settings into a string. This library
transports that string without interpreting it. Your plugin owns serialization,
format/version validation, and applying retrieved settings.

The two services have separate rules:

- **Share:** `write` and `read` use reusable UUID codes. Codes expire after one
  week of inactivity; every successful retrieval resets expiry to one week.
- **Dump:** `dump.create` returns a code for a one-use file download. Unused codes
  expire after 24 hours; redemption deletes the active record.

All services use **https://settings.rs3.dev**, backed by the self-hosted SQLite
service. Cloudflare provides the public HTTPS proxy.
The current privacy notice is **https://settings.rs3.dev/privacy**. The download
page is **https://settings.rs3.dev/dump**. The manifest declares `service` and
`privacy` URL aliases; all HTTP API calls use the same `service` base URL with
different endpoint paths.

Start with the [plugin integration guide](USAGE.md) for setup and copyable examples.
The ready-to-paste plugin listing is in [DESCRIPTION.md](DESCRIPTION.md).

For a small in-game test panel, install the
[Settings Share Debug example](examples/settingssharedebug/README.md). It exercises
the share and dump utilities through the actual dependency.

## Installation

Copy `main.lua`, `plugin.json`, and `lib/` into a folder named `settingsshare`
inside your client's plugin directory.

The dependency can load before HTTP access is granted. Enable its optional
`httpAccess` permission before making requests; otherwise each helper returns
`nil, "Settings Share requires HTTP access."` without starting a request.
Release **1.0.0** generates share UUIDs locally and processes HTTP results on
Logic. Empty native completion/progress callbacks preserve the workaround for
the client's nil-function error. Automated tests and live API checks pass; the
current build still needs an in-game smoke test after upgrading.

For local testing, run these console commands in order:

```text
prf
pon settingsshare
ppe settingsshare httpAccess
pon settingssharedebug
```

Use `prl settingssharedebug` to reopen an already loaded debug panel. If the
client reports a dependency failure, run `plist` and check that the local
`settingsshare` entry is enabled; a dependency error alone does not identify
the underlying cause.

## Required caller name

Every network method requires your plugin name as its **first argument**:

```lua
settingsshare.write("MyPlugin", serializedSettings, callback)
settingsshare.read("MyPlugin", shareCode, callback)
settingsshare.upload("MyPlugin", shareCode, serializedSettings, callback)
settingsshare.dump.create("MyPlugin", serializedSettings, callback)
```

The name is sent unchanged as the HTTP `User-Agent` header. Use a stable name of
1-128 printable ASCII characters with no leading/trailing spaces or control
characters. Internal spaces are allowed. Invalid names fail immediately with
`nil, problem`, without starting a request or invoking the callback.

Add your plugin name to every network call.
`createCode()` is local and still takes no arguments. Names identify callers;
they are self-reported, not authentication or a registry. Share codes remain
readable by anyone holding the code, regardless of the caller's name. The helper
uses POST for both uploads and retrievals; names are headers, not JSON fields.

## Integrating a consuming plugin

For a local consuming plugin, add this entry to its `plugin.json`
`requiredDependencies` (keep any existing dependencies):

```json
"requiredDependencies": {
  "settingsshare": "settingsshare"
}
```

Run `prf` after changing a manifest, then reload the consuming plugin.
The client exposes the API as the `settingsshare` global. A published plugin may
need the registered dependency ID in place of the local `"settingsshare"` value.
HTTP permission belongs to the `settingsshare` dependency; a consuming plugin
using only this helper does not need its own HTTP requests or service URL alias.

Use the examples below from a normal plugin action, such as a button click:

- Serialize settings into a string before calling the helper.
- Check the immediate return for validation, permission, or queue errors. These
  errors return `nil, problem` and do not invoke your callback.
- Supply an application callback to receive the eventual result or request error.
  These callbacks are supported; you do not need empty callbacks in your plugin.
- Treat a returned share code as pending until upload confirmation. Keep local
  settings if retrieval fails, and validate retrieved data before applying it.
- Disable duplicate actions while pending. Respect rate-limit delays; do not
  repeatedly call the helper from your own update loop or wait in a busy loop.
- If a callback updates UI, check that the panel still exists and the result
  belongs to its current request. Closing or reloading UI does not cancel an
  already queued request. The debug example demonstrates this lifetime guard.

The helper owns request creation, completion polling, and callback dispatch.
Your plugin needs no extra Logic subscription, native HTTP callbacks, coroutine,
thread, or blocking wait to use these methods.

## HTTP execution

Requests run in order with one active request and a maximum of 32 queued/active
entries. The helper creates requests, polls completion, reads responses, and
invokes application callbacks on separate `Event.Logic` updates. The network
request runs in the background; there is no blocking wait or coroutine handler.
The request stays alive until its result is delivered.

Both native HTTP callbacks are empty functions inside `main.lua`. Supplying them
removed the client's nil-function error in testing. Response processing and your
application callback remain on Logic. The earlier share path passed in-client
testing in client 951-1; automated tests and live API checks complement that test,
but do not prove native behavior after this cleanup.

The runtime contains only `main.lua`, `plugin.json`, `lib/json.lua`, and
`lib/uuid.lua`. It provides share codes and one-use dumps. Each network method
requires a caller name; `createCode()` is local and takes no arguments.

## Export settings

Pass a serialized string owned by your plugin:

```lua
local pendingCode, problem = settingsshare.write("MyPlugin", "myplugin:v1:serialized-settings", function(code, err)
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

If your UI needs separate generation and upload actions:

```lua
local code, problem = settingsshare.createCode() -- No HTTP, events, or permission check.
-- Display/store code locally, then upload explicitly when requested:
if code then
    local queued, uploadProblem = settingsshare.upload("MyPlugin", code, serializedSettings, function(confirmedCode, err, info)
        -- Only confirmation makes the code available to other devices.
    end)
end
```

`createCode()` returns a UUID or `nil, problem`. `upload(pluginName, code, data, callback)`
returns `true` when queued, or `nil, problem` on immediate failure. It sends the
supplied code unchanged and does not generate another UUID. `write` remains the
convenience API that combines these two operations. `settingsshare.version`
identifies the helper actually loaded by the client.

## Import settings

```lua
local started, problem = settingsshare.read("MyPlugin", "123e4567-e89b-42d3-a456-426614174000", function(data, err)
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

Each UUID has 32 hexadecimal characters and four separator hyphens. The client
draws 16 fresh random bytes and sets the UUID version/variant fields. The client's random source is not guaranteed to be cryptographically secure. The server rejects a duplicate
live code instead of overwriting another share. There is no preliminary request
to ask the server to generate a share code.

## Create a one-use download

```lua
local started, problem = settingsshare.dump.create("MyPlugin", serializedSettings, function(code, err, info)
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
- `createCode` generates a UUID locally without HTTP, permissions, or event
  subscriptions. `upload` queues the chosen code and payload separately.
- `read` and `dump.create` return `true` when queued.
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

The API HMACs codes before database storage. Settings
strings are not end-to-end encrypted; service administrators can access them.
API expiry and dump redemption remove access to active data. Prior data may remain
in SQLite files, journals, snapshots, or backups; backup retention is configured
by the operator. See the
[current privacy notice](https://settings.rs3.dev/privacy) for hosting, retention,
and contact information.

## HTTP routes

All requests use JSON bodies with the `https://settings.rs3.dev` base URL:

- `write(pluginName, data, callback)` -> `POST /api/v1/settings-share/create` with `{code,data}`;
  the response must echo the client-generated `code`.
- `read(pluginName, code, callback)` -> `POST /api/v1/settings-share/fetch` with `{code}`.
- `dump.create(pluginName, data, callback)` -> `POST /api/v1/settings-dump/create` with `{data}`.

The download page submits `POST /api/v1/settings-dump/download` with `{code}`.
GET requests and query strings never redeem a dump.

## Development

With Node.js 22 or newer, run the Lua tests in the bundled Lua 5.4 WebAssembly
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
lua5.4 tests/share_stages_test.lua
lua5.4 tests/user_agent_test.lua
```

Tests mock the client bindings and verify that the native callbacks do not inspect
the request, call client APIs, or dispatch results, even outside Logic. Responses
dispatch only on Logic updates, active requests stay alive, and application
callbacks are delivered once. These automated tests complement the manual share
verification above; they cannot establish native client behavior on their own.

To check the actual Lua helper against the live URL declared in `plugin.json`:

```sh
npm run test:live
```

This opt-in test sends real HTTPS requests through a Node adapter for the native
HTTP bindings. It verifies share round trips, UUID confirmation, code
normalization, per-request User-Agent headers, TTL response values, rate-limit metadata,
and a dump download that succeeds exactly once. It also checks `/healthz`, `/dump`,
and `/privacy`. It never runs automatically in CI.

Each run leaves one synthetic share to expire normally; the synthetic dump is
redeemed. The test checks rate limiting
without retrying writes. Wait at least one minute between runs and avoid testing
while someone on the same public IP is creating shares or dumps. Payloads and codes are not printed. Node and Wasmoon are development tools only and
are excluded from the plugin upload ZIP.

The live compatibility check passed on 29 October 2026 (Pacific). This confirms
the Lua/API contract; it does not exercise RuneScape's native HTTP or UI bindings.
The separate manual share verification is described above. Seven-day renewal and
expired-record behavior are covered by backend database tests; the live check
asserts the returned TTL without waiting for expiry.

Build an upload ZIP with PowerShell:

```powershell
./tools/package.ps1
```

The output is `artifacts/settingsshare-1.0.0.zip`, with `main.lua`, `plugin.json`,
and `lib/` at the ZIP root as required for submission. Tests and documentation
are excluded from the runtime package.
