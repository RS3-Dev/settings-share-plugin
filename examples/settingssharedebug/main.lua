-- All network requests go through the installed settingsshare dependency.
local window, panel, payloadInput, codeInput, statusText
local stopped, busy = false, false
local requestID = 0
local sharedString
local probing = false
local crashLogArmed = false

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
    if probing then status("HTTP probe is active. Reload both plugins before regular API tests."); return end
    if busy then status("A request is still pending. Wait for its result."); return end
    if type(settingsshare) ~= "table" then status("Enable the settingsshare 2.0.3 dependency first."); return end
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
        status(label .. ": " .. (ok and tostring(problem) or "Helper call failed; install settingsshare 2.0.3."))
    else
        return started
    end
end

local function teardown()
    requestID = requestID + 1 -- Ignore completions belonging to an old/destroyed panel.
    busy = false
    if window ~= nil then pcall(function() window:Destroy() end) end
    window, panel, payloadInput, codeInput, statusText = nil, nil, nil, nil, nil
end

local function build()
    if prettyui == nil then error("Settings Share Debug requires PrettyUI.") end
    if settingsshare ~= nil and type(settingsshare.setDebugLogging) == "function" then
        settingsshare.setDebugLogging(false)
    end
    startup("finding game area")
    local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if root == nil then error("Enter the game, then reload settingssharedebug.") end
    -- Use the same standalone window setup as Taint Check.
    startup("creating PrettyUI window")
    window = prettyui.Window.new(root, {
        title = "Settings Share Debug",
        x = -228, y = -184, xAnchor = 0.5, yAnchor = 0.5,
        width = 456, height = 368,
        minWidth = 456, maxWidth = 456, minHeight = 368, maxHeight = 368,
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

    button("Probe HTTP step", 12, 0, 132, function()
        if busy then status("A request is still pending. Reload both plugins before probing."); return end
        local probe = type(settingsshare) == "table" and settingsshare.diagnostics or nil
        if type(probe) ~= "table" or type(probe.step) ~= "function" then
            status("Install settingsshare 2.0.4 to use the manual HTTP probe."); return
        end
        probing = true
        local code, payload
        if probe.nextStep() == "Send POST" then
            code = readInput(codeInput, "code field")
            payload = readInput(payloadInput, "payload field")
        end
        startup("probe: " .. probe.nextStep())
        local passed, message, nextStep = probe.step(code, payload)
        status((passed and "PASS: " or "STOP: ") .. tostring(message) .. " Next: " .. tostring(nextStep))
    end)
    button("Prepare loop", 154, 0, 110, function()
        if busy then status("Reload both plugins before preparing a fresh upload loop."); return end
        local probe = type(settingsshare) == "table" and settingsshare.diagnostics or nil
        if type(probe) ~= "table" or type(probe.prepareTransport) ~= "function" then
            status("Install settingsshare 2.0.7 for the real upload-loop test."); return
        end
        local prepared, problem = probe.prepareTransport()
        if not prepared then status(problem); return end
        crashLogArmed = true
        status("Normal upload loop prepared. No HTTP request queued or sent.")
    end)
    button("Upload no callback", 274, 0, 154, function()
        if not crashLogArmed then status("Click Prepare loop first to isolate registration and arm checkpoints."); return end
        if busy then status("A request is still pending. Reload the debug panel before this test."); return end
        local probe = type(settingsshare) == "table" and settingsshare.diagnostics or nil
        if probing and (type(probe) ~= "table" or probe.nextStep() ~= "Done") then
            status("Finish the HTTP probe or reload both plugins before this test."); return
        end
        if type(settingsshare) ~= "table" or type(settingsshare.upload) ~= "function" then
            status("Enable settingsshare 2.0.4 before this test."); return
        end
        local code = readInput(codeInput, "code field")
        local sent = readInput(payloadInput, "payload field")
        startup("calling normal upload without an application callback")
        local started, problem = settingsshare.upload(code, sent)
        startup("normal upload returned")
        if not started then status("Upload could not start: " .. tostring(problem)); return end
        busy = true -- Deliberately no callback to clear this; reload the panel after the test.
        status("Upload queued. No application callback or completion UI update. Reload panel after test.")
    end)
    startup("creating payload field")
    text("String to send / fetched result", 12, 36, 416, 20)
    payloadInput = input(57, "Hello from Settings Share Debug", 2048)
    text("Share or dump code (select and copy this field)", 12, 94, 416, 20)
    startup("creating code field")
    codeInput = input(115, "", 128)
    startup("creating action buttons")
    button("Generate code", 12, 154, 202, function()
        if busy then status("A request is still pending. Wait for its result."); return end
        if type(settingsshare) ~= "table" or type(settingsshare.createCode) ~= "function" then
            status("Install settingsshare 2.0.3 for local-only code generation."); return
        end
        local code, problem = settingsshare.createCode()
        if not code then status(problem); return end
        codeInput:SetText(code)
        sharedString = nil
        status("Code generated locally. No HTTP or events used. Use Probe HTTP step to isolate upload.")
    end)
    button("Upload share", 226, 154, 202, function()
        if type(settingsshare) ~= "table" or type(settingsshare.upload) ~= "function" then
            status("Enable the settingsshare 2.0.3 dependency first."); return
        end
        local code = readInput(codeInput, "code field")
        local sent = readInput(payloadInput, "payload field")
        run("Upload share", function(done) return settingsshare.upload(code, sent, done) end, function(_, info)
            sharedString = sent
            -- The code is already displayed by the separate Generate code step.
            -- Upload confirmation must not rewrite the native input field.
            status("Share created; code is in the field above" .. ttl(info))
        end)
    end)
    button("Fetch share", 12, 192, 202, function()
        local code = readInput(codeInput, "code field")
        run("Fetch share", function(done) return settingsshare.read(code, done) end, function(data, info)
            payloadInput:SetText(data)
            local match = sharedString and (data == sharedString and " | MATCH" or " | DIFFERENT from last sent") or ""
            status("Share fetched: " .. #data .. " bytes" .. match .. ttl(info))
        end)
    end)
    button("Create one-use dump", 226, 192, 202, function()
        local sent = readInput(payloadInput, "payload field")
        run("Create dump", function(done) return settingsshare.dump.create(sent, done) end, function(code, info)
            codeInput:SetText(code)
            status("Dump created. Open settings.rs3.dev/dump and paste this code." .. ttl(info))
        end)
    end)
    statusText = text("Ready. Generate code first, then Upload share.", 12, 238, 416, 62)
    statusText.maxLines = 4
    local helperVersion = type(settingsshare) == "table" and settingsshare.version or "unknown"
    text("Loaded Helper " .. tostring(helperVersion) .. " | Debug 1.1.0", 12, 300, 416, 20)
    startup("showing window")
    window:Show()
    status("Ready. Debug 1.1.0 | Helper " .. tostring(helperVersion) .. ". Empty native callbacks; response work stays on Logic.")
    local probe = type(settingsshare) == "table" and settingsshare.diagnostics or nil
    if type(probe) == "table" and type(probe.lastCheckpoint) == "function" then
        local saved = probe.lastCheckpoint()
        if saved then
            status("Saved checkpoint from previous attempt: " .. saved.version .. " | " .. saved.phase .. " | " .. saved.state)
        end
    end
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
