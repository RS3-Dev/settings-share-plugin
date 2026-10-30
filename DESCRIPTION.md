Short Share Codes is a dependency library that lets plugins share settings between accounts and create one-use downloads.

The library is format agnostic: your plugin converts its settings into a string, and Short Share Codes stores that string on the backend service. Your plugin handles serialization, validation, and applying retrieved settings.

- **Share settings:** the library generates a temporary UUID share code locally and uploads the string under that code. Another account can retrieve the original string after upload succeeds. Codes expire after **one week of inactivity**. Each successful retrieval resets expiry to one week from that retrieval.
- **Download a dump:** create a server-generated code for a **one-use download** at [settings.rs3.dev/dump](https://settings.rs3.dev/dump). Unused codes expire after **24 hours**.

**Not so subtle disclaimer:** I'm providing the storage service for this library for free to help the community share settings within the restrictions we currently face. Please use it responsibly. If I see abuse or any attempt to exploit the service, I'll shut down access immediately and without notice, so please don't ruin a good thing.

Once declared as a dependency, the library is available through the `settingsshare` global. `write` returns a locally generated pending code immediately; its callback confirms the upload.

Every network call requires your plugin name as its first argument. The name is sent as the `User-Agent` header: use a stable name of 1-128 printable ASCII characters, without leading/trailing spaces or control characters. This identifies the caller and does not authenticate it.

Call the helper from a normal plugin action and supply a callback for the result. The library handles HTTP and completion polling internally, then invokes your callback from the normal Logic update. Check both the immediate return and callback errors. You do not need your own HTTP request, update-loop subscription, or blocking wait. If a callback updates UI, first check that the panel is still open and the result belongs to its current request.

### Create a share code

Pass your serialized settings to `write`. The callback receives the code once the upload succeeds.

```lua
local pendingCode, problem = settingsshare.write("MyPlugin", "your serialized settings", function(code, err)
    if err then
        log("Could not share settings: ", err)
        return
    end
    log("Share code: ", code)
end)

if not pendingCode then
    log("Could not start sharing: ", problem)
end
```

The returned code is pending until the callback confirms success. New codes are UUID strings rather than 24-digit numbers. Local UUID generation is not cryptographically secure; use this service only for settings without sensitive information.

### Retrieve shared settings

```lua
local started, problem = settingsshare.read("MyPlugin", "share-code-here", function(data, err)
    if err then
        log("Could not retrieve settings: ", err)
        return
    end
    -- Deserialize and validate data, then apply the settings.
end)

if not started then
    log("Could not start retrieval: ", problem)
end
```

### Create a one-use download

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

The dump code arrives in the callback. Enter it at [settings.rs3.dev/dump](https://settings.rs3.dev/dump) to download a text file. Redemption consumes the code before delivery; if delivery fails, create a new dump.

Share and dump strings have a default **256 KiB** cap. Share and dump creation are each limited to one request per IP per minute. Additional retrieval limits apply; respect rate-limit errors and avoid continuous polling.

Anyone with a share or dump code can retrieve its contents. Only send non-sensitive settings, and validate all retrieved data before applying it.

The service runs on self-hosted infrastructure using SQLite, with Cloudflare providing the public HTTPS proxy. API expiry and redemption remove access to active records, but prior data may remain in database files or backups. Read the [privacy notice](https://settings.rs3.dev/privacy) for retention and contact information.
