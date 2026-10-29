-- All network requests go through the installed settingsshare dependency.
local window, panel, payloadInput, codeInput, playerInput, statusText
local stopped, busy = false, false
local requestID = 0
local sharedString, syncedString, syncedPlayer

local function startup(stage)
    if type(log) == "function" then log("[Settings Share Debug] UI: ", stage) end
end

local function status(message)
    if stopped then return end
    if type(log) == "function" then log("[Settings Share Debug] ", message) end
    if statusText ~= nil then statusText.content = message end
end

local function readInput(field, name)
    startup("reading " .. name)
    local value = field:GetText()
    startup("read " .. name)
    return value
end

local function ttl(info)
    return info and info.expiresInSeconds and (" | TTL " .. tostring(info.expiresInSeconds) .. "s") or ""
end

local function run(label, start, success)
    if busy then status("A request is still pending. Wait for its result."); return end
    if type(settingsshare) ~= "table" then status("Enable the settingsshare 2.0.0 dependency first."); return end
    requestID = requestID + 1
    local current = requestID
    busy = true
    status(label .. ": waiting for response...")
    local function finished(value, problem, info)
        if stopped or current ~= requestID then return end
        busy = false
        if problem ~= nil then
            local detail = info and info.code and (" [" .. tostring(info.code) .. "]") or ""
            local retry = info and info.retryAfterSeconds and (" | Retry in " .. tostring(info.retryAfterSeconds) .. "s") or ""
            status(label .. ": " .. tostring(problem) .. detail .. retry)
            return
        end
        success(value, info)
    end
    startup(label .. ": entering helper call")
    local ok, started, problem = pcall(start, finished)
    startup(label .. ": helper call returned")
    if not ok or not started then
        busy = false
        status(label .. ": " .. (ok and tostring(problem) or "Helper call failed; install settingsshare 2.0.0."))
    else
        return started
    end
end

local function teardown()
    requestID = requestID + 1 -- Ignore completions belonging to an old/destroyed panel.
    busy = false
    if window ~= nil then pcall(function() window:Destroy() end) end
    window, panel, payloadInput, codeInput, playerInput, statusText = nil, nil, nil, nil, nil, nil
end

local function build()
    if prettyui == nil then error("Settings Share Debug requires PrettyUI.") end
    if settingsshare ~= nil and type(settingsshare.setDebugLogging) == "function" then
        settingsshare.setDebugLogging(true)
    end
    startup("finding game area")
    local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if root == nil then error("Enter the game, then reload settingssharedebug.") end
    -- Use the same standalone window setup as Taint Check.
    startup("creating PrettyUI window")
    window = prettyui.Window.new(root, {
        title = "Settings Share Debug",
        x = -228, y = -232, xAnchor = 0.5, yAnchor = 0.5,
        width = 456, height = 464,
        minWidth = 456, maxWidth = 456, minHeight = 464, maxHeight = 464,
        scrollable = false, destroyOnClose = true,
        onClose = function()
            stopped, busy = true, false
            requestID = requestID + 1
        end,
    })
    panel = window.content
    local function text(value, x, y, width, height)
        return prettyui.Text.new(panel, {
            text = value, x = x, y = y, width = width, height = height,
            font = id.Font.MUSEO_SANS_11PT_REGULAR, colour = 0xEEEEEEFF,
        })
    end
    local function input(y, value, maxLength)
        return prettyui.TextField.new(panel, {
            text = value, x = 12, y = y, width = 416, height = 30,
            maxLength = maxLength,
        })
    end
    local function button(label, x, y, width, action)
        return prettyui.SimpleButton.new(panel, label, function()
            startup("click " .. label .. ": entered")
            local ok, problem = pcall(action)
            if not ok then
                if type(log) == "function" then log("[Settings Share Debug] Action failed: ", tostring(problem)) end
            else
                startup("click " .. label .. ": returned")
            end
        end, {
            x = x, y = y, width = width, height = 30,
        })
    end

    button("Check click", 12, 0, 202, function()
        startup("click check complete; no fields or helper used")
    end)
    button("Check input", 226, 0, 202, function()
        local value = readInput(payloadInput, "payload field")
        status("Input check passed: " .. #value .. " bytes. No request sent.")
        startup("input check complete; no helper used")
    end)
    startup("creating payload field")
    text("String to send / fetched result", 12, 36, 416, 20)
    payloadInput = input(57, "Hello from Settings Share Debug", 2048)
    text("Share or dump code (select and copy this field)", 12, 94, 416, 20)
    startup("creating code field")
    codeInput = input(115, "", 128)
    text("Test player ID for PluginDev sync", 12, 152, 416, 20)
    startup("creating player field")
    playerInput = input(173, "settingsshare-debug", 128)

    startup("creating action buttons")
    button("Create share", 12, 216, 202, function()
        local sent = readInput(payloadInput, "payload field")
        local pendingCode = run("Create share", function(done) return settingsshare.write(sent, done) end, function(code, info)
            sharedString = sent
            codeInput:SetText(code)
            status("Share created; code is in the field above" .. ttl(info))
        end)
        if type(pendingCode) == "string" then
            codeInput:SetText(pendingCode)
            status("Pending code shown; waiting for upload confirmation.")
        end
    end)
    button("Fetch share", 226, 216, 202, function()
        local code = readInput(codeInput, "code field")
        run("Fetch share", function(done) return settingsshare.read(code, done) end, function(data, info)
            payloadInput:SetText(data)
            local match = sharedString and (data == sharedString and " | MATCH" or " | DIFFERENT from last sent") or ""
            status("Share fetched: " .. #data .. " bytes" .. match .. ttl(info))
        end)
    end)
    button("Save sync", 12, 254, 202, function()
        local sent, player = readInput(payloadInput, "payload field"), readInput(playerInput, "player field")
        run("Save sync", function(done) return settingsshare.sync.save("PluginDev", player, sent, done) end, function(_, info)
            syncedString, syncedPlayer = sent, player
            status("Sync saved under PluginDev" .. ttl(info))
        end)
    end)
    button("Fetch sync", 226, 254, 202, function()
        local player = readInput(playerInput, "player field")
        run("Fetch sync", function(done) return settingsshare.sync.fetch("PluginDev", player, done) end, function(data, info)
            payloadInput:SetText(data)
            local match = syncedPlayer == player and (data == syncedString and " | MATCH" or " | DIFFERENT from last sent") or ""
            status("Sync fetched: " .. #data .. " bytes" .. match .. ttl(info))
        end)
    end)
    button("Create one-use dump", 12, 292, 416, function()
        local sent = readInput(payloadInput, "payload field")
        run("Create dump", function(done) return settingsshare.dump.create(sent, done) end, function(code, info)
            codeInput:SetText(code)
            status("Dump created. Open settings.rs3.dev/dump and paste this code." .. ttl(info))
        end)
    end)
    statusText = text("Ready. Type a string, then Create share.", 12, 334, 416, 62)
    statusText.maxLines = 4
    text("PluginDev test data | Creates/saves have a 60s limit", 12, 396, 416, 20)
    startup("showing window")
    window:Show()
    status("Ready. Type a string, then Create share.")
end

function PluginShutdown()
    stopped = true
    teardown()
end

local ok, problem = pcall(build)
if not ok then
    teardown()
    if type(log) == "function" then log("[Settings Share Debug] Could not create UI: ", tostring(problem)) end
end
