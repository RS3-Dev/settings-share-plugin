-- Network requests belong to the settingsshare dependency.
local window, payloadInput, codeInput, statusText
local stopped, busy = false, false
local requestID = 0
local sharedString

local function status(message)
    if stopped then return end
    if type(log) == "function" then log("[Settings Share Debug] ", message) end
    if statusText ~= nil then statusText.content = message end
end

local function ttl(info)
    return info and info.expiresInSeconds and (" | TTL " .. tostring(info.expiresInSeconds) .. "s") or ""
end

local function run(label, start, success)
    if busy then status("A request is still pending. Wait for its result."); return end
    if type(settingsshare) ~= "table" then status("Enable the settingsshare dependency first."); return end
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
        else
            success(value, info)
        end
    end
    local ok, started, problem = pcall(start, finished)
    if not ok or not started then
        busy = false
        status(label .. ": " .. (ok and tostring(problem) or "Could not start request."))
    else
        return started
    end
end

local function build()
    local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if root == nil then error("Enter the game, then reload settingssharedebug.") end
    window = prettyui.Window.new(root, {
        title = "Settings Share Debug",
        x = -228, y = -165, xAnchor = 0.5, yAnchor = 0.5,
        width = 456, height = 330,
        minWidth = 456, maxWidth = 456, minHeight = 330, maxHeight = 330,
        scrollable = false, destroyOnClose = true,
        onClose = function()
            stopped = true
            requestID = requestID + 1
        end,
    })
    local panel = window.content
    local function text(value, y, height)
        return prettyui.Text.new(panel, {
            text = value, x = 12, y = y, width = 416, height = height,
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
            local ok, problem = pcall(action)
            if not ok then status("Action failed: " .. tostring(problem)) end
        end, { x = x, y = y, width = width, height = 30 })
    end

    text("String to send / fetched result", 0, 20)
    payloadInput = input(21, "Hello from Settings Share Debug", 2048)
    text("Share or dump code (select and copy this field)", 58, 20)
    codeInput = input(79, "", 128)
    button("Create share", 12, 118, 202, function()
        local sent = payloadInput:GetText()
        local pending = run("Create share", function(done) return settingsshare.write(sent, done) end, function(_, info)
            sharedString = sent
            status("Share created; code is in the field above" .. ttl(info))
        end)
        if pending then
            codeInput:SetText(pending) -- Generated locally; pending until confirmation.
            sharedString = nil
        end
    end)
    button("Fetch share", 226, 118, 202, function()
        local code = codeInput:GetText()
        run("Fetch share", function(done) return settingsshare.read(code, done) end, function(data, info)
            payloadInput:SetText(data)
            local match = sharedString and (data == sharedString and " | MATCH" or " | DIFFERENT from last sent") or ""
            status("Share fetched: " .. #data .. " bytes" .. match .. ttl(info))
        end)
    end)
    button("Create dump", 12, 156, 416, function()
        local sent = payloadInput:GetText()
        run("Create dump", function(done) return settingsshare.dump.create(sent, done) end, function(code, info)
            codeInput:SetText(code)
            status("Dump created. Open settings.rs3.dev/dump and paste this code." .. ttl(info))
        end)
    end)
    statusText = text("Ready. Type a string, then Create share.", 200, 54)
    statusText.maxLines = 4
    text("Helper " .. tostring(settingsshare.version) .. " | Debug 1.2.0", 258, 20)
    window:Show()
end

function PluginShutdown()
    stopped = true
    requestID = requestID + 1
    if window ~= nil then pcall(function() window:Destroy() end) end
end

local ok, problem = pcall(build)
if not ok then
    if window ~= nil then pcall(function() window:Destroy() end) end
    statusText = nil
    status("Could not create UI: " .. tostring(problem))
end
