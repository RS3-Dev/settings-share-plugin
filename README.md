# Settings Share

A RuneScape dependency library for sharing settings and creating one-use downloads.
Your plugin supplies a string; the library stores and retrieves it through
**https://settings.rs3.dev**. Your plugin handles serialization and validation.

## Install

Put `main.lua`, `plugin.json`, and `lib/` in a plugin folder named `settingsshare`.
Enable its optional `httpAccess` permission. Add this dependency to your plugin's
manifest, keeping any existing dependencies:

```json
{
  "requiredDependencies": {
    "settingsshare": "settingsshare"
  }
}
```

This mapping uses the local folder name; published plugins should use the
registered dependency ID. The library is available as the `settingsshare` global.

## Use it

Every network call requires your plugin name first. It becomes the `User-Agent`
header: use 1-128 printable ASCII characters without surrounding spaces.
Call these methods from your normal plugin actions; the library handles HTTP.

### Create a share code

```lua
local pendingCode, problem = settingsshare.write("MyPlugin", serializedSettings, function(code, err)
    if err then log("Share failed: ", err); return end
    log("Share code: ", code)
end)
if not pendingCode then log("Could not start sharing: ", problem) end
```

The returned UUID is pending until the callback confirms upload success.

### Retrieve shared settings

```lua
local started, problem = settingsshare.read("MyPlugin", shareCode, function(data, err)
    if err then log("Fetch failed: ", err); return end
    -- Deserialize, validate, then apply data.
end)
if not started then log("Could not start retrieval: ", problem) end
```

### Create a one-use download

```lua
local started, problem = settingsshare.dump.create("MyPlugin", serializedSettings, function(code, err)
    if err then log("Dump failed: ", err); return end
    log("Enter this code at https://settings.rs3.dev/dump: ", code)
end)
if not started then log("Could not start dump creation: ", problem) end
```

For separate local generation and upload, use `settingsshare.createCode()` and
`settingsshare.upload("MyPlugin", code, serializedSettings, callback)`.

## Rules

- **Shares:** reusable; expire after one week of inactivity. Each successful fetch
  restarts the week. Create a new code for changed settings.
- **Dumps:** one download; expire after 24 hours if unused. Redemption consumes the
  code before delivery; create another dump if delivery fails.
- **Limits:** 256 KiB per string; one share creation and one dump creation per IP
  per minute. Additional retrieval limits apply. Respect rate-limit errors;
  the helper does not retry automatically.
- **Callbacks:** run on Logic. Check that UI still exists before updating it.
  Errors return immediately or arrive in the callback; optional third-argument
  metadata includes rate-limit retry delays when available.

Anyone with a code can retrieve its contents. Only send non-sensitive settings
and validate imported data. Plugin names identify callers, not authenticated
owners. Read the [privacy notice](https://settings.rs3.dev/privacy) for storage,
retention, and contact information.
