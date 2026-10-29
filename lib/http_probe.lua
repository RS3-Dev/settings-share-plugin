local Json = require("lib/json")
local NativeCallbacks = require("lib/http_callbacks")
local Probe = {}

-- Opt-in crash isolation. Each click selects at most one native-operation group.
-- HTTP operations run on Logic. Native callbacks are empty; response work stays here.
function Probe.new(validUUID)
    local stage, request, expectedCode, logicTicks = 1, nil, nil, 0
    local queued, result
    local labels = {
        "Check HTTP permission", "Subscribe to Logic", "Construct HTTP request",
        "Add JSON header", "Send POST", "Read finished flag", "Read response", "Done",
    }
    local function advance(code, data)
        if stage == 1 then
            if Plugin == nil or type(Plugin.HasPermission) ~= "function"
                or PluginPermissions == nil or PluginPermissions.httpAccess == nil then
                return nil, "HTTP permission API is unavailable."
            end
            local checked, granted = pcall(Plugin.HasPermission, PluginPermissions.httpAccess)
            if not checked or not granted then return nil, "Settings Share requires HTTP access." end
            stage = 2
            return true, "HTTP permission check passed."
        elseif stage == 2 then
            if Event == nil or Event.Logic == nil or type(Event.Logic.Subscribe) ~= "function" then
                return nil, "Logic subscription API is unavailable."
            end
            Event.Logic.Subscribe("settingsshare.probe", function()
                logicTicks = logicTicks + 1
                if queued then
                    local action = queued
                    queued = nil
                    action()
                end
            end)
            stage = 3
            return true, "Logic subscription returned; its callback only counts ticks."
        elseif stage == 3 then
            if logicTicks == 0 then return nil, "Wait for a normal Logic update, then retry this step." end
            if HTTPRequest == nil or type(HTTPRequest.new) ~= "function"
                or Plugin.urls == nil or Plugin.urls.service == nil then
                return nil, "HTTP constructor or service URL is unavailable."
            end
            request = HTTPRequest.new(Plugin.urls.service, "/api/v1/settings-share/create")
            stage = 4
            return true, "HTTP constructor returned. No headers or POST yet."
        elseif stage == 4 then
            request:AddHeader("Content-Type", "application/json")
            stage = 5
            return true, "JSON header added. No POST yet."
        elseif stage == 5 then
            if not validUUID(code) then return nil, "Generate a local code before sending the POST." end
            if type(data) ~= "string" then return nil, "A string payload is required." end
            expectedCode = code
            request:Post(Json.encode({ code = code, data = data }), NativeCallbacks.completion, NativeCallbacks.progress)
            stage = 6
            return true, "POST returned with empty native callbacks. Response has not been read."
        elseif stage == 6 then
            if request.finished ~= true then return true, "Request is pending; repeat this step later." end
            stage = 7
            return true, "Finished flag is true. Response has not been read."
        elseif stage == 7 then
            -- Mark complete before processing: an API rejection must not resend.
            stage = 8
            local successful, body = request.successful, request.data
            local parsed, response = pcall(Json.decode, body)
            if not parsed or type(response) ~= "table" then return nil, "Response was not a JSON object." end
            if type(response.error) == "table" then
                return nil, "API rejected upload: " .. tostring(response.error.code or "unknown_error")
            end
            if successful ~= true or response.code ~= expectedCode then return nil, "Upload confirmation did not match the local code." end
            return true, "Share upload confirmed. Probe complete."
        end
        return nil, "Probe complete. Reload settingsshare before starting a new probe."
    end
    local function execute(code, data)
        local label = labels[stage]
        local ok, passed, message = pcall(advance, code, data)
        if not ok then return nil, "Lua error during " .. label .. "." end
        return passed, message
    end
    local function nextStep()
        return (queued or result) and "Read step result" or labels[stage]
    end
    return {
        nextStep = nextStep,
        step = function(code, data)
            if result then
                local completed = result
                result = nil
                return completed.passed, completed.message, nextStep()
            end
            if queued then return true, "Waiting for the next Logic update.", nextStep() end
            if stage >= 3 and stage <= 7 then
                local label = labels[stage]
                queued = function()
                    local passed, message = execute(code, data)
                    result = { passed = passed, message = message }
                end
                return true, "Queued " .. label .. " for the next Logic update.", nextStep()
            end
            local passed, message = execute(code, data)
            return passed, message, nextStep()
        end,
    }
end

return Probe
