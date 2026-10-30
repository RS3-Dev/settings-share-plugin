local Json = require("lib/json")
local UUID = require("lib/uuid")
-- Supply both callbacks to avoid the observed nil-function error; Logic owns results.
local function onHttpComplete(_request) end
local function onHttpProgress(_request) end
local pendingRequests = {}
local subscribed = false
local processing = false
local maxPendingRequests = 32

local function validUUID(value)
    return type(value) == "string" and #value == 36
        and value:sub(9, 9) == "-" and value:sub(14, 14) == "-"
        and value:sub(19, 19) == "-" and value:sub(24, 24) == "-"
        and value:match("^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$") ~= nil
end

local function pluginNameProblem(name)
    if type(name) ~= "string" or #name < 1 or #name > 128
        or name:find("[^ -~]") or name:match("^ ") or name:match(" $") then
        return "Settings Share requires a plugin name of 1-128 printable ASCII characters without surrounding spaces."
    end
end

local function httpProblem()
    if PluginPermissions == nil or PluginPermissions.httpAccess == nil
        or Plugin == nil or type(Plugin.HasPermission) ~= "function" then
        return "Settings Share requires HTTP access."
    end
    local checked, granted = pcall(Plugin.HasPermission, PluginPermissions.httpAccess)
    if not checked or not granted then return "Settings Share requires HTTP access." end
    if HTTPRequest == nil or type(HTTPRequest.new) ~= "function" then
        return "Settings Share HTTP requests are unavailable."
    end
    -- The client resolves URL aliases; the resolved value need not be a string.
    if Plugin.urls == nil or Plugin.urls.service == nil then
        return "Settings Share service URL is not configured."
    end
end

local function reply(callback, value, problem, metadata)
    if type(callback) == "function" then pcall(callback, value, problem, metadata) end
end

local function decode(request)
    local body = request.data
    if type(body) ~= "string" or body == "" then return nil end
    local ok, value = pcall(Json.decode, body)
    return ok and type(value) == "table" and value or nil
end

local function readResult(request, mode, expectedCode)
    local successful = request.successful
    local response = decode(request)
    if successful ~= true or (response ~= nil and response.error ~= nil) then
        local problem = response ~= nil and response.error or nil
        local message = type(problem) == "table" and problem.message or nil
        if type(message) ~= "string" or message == "" then message = request.errorInfo end
        if type(message) ~= "string" or message == "" then
            message = "Settings Share request failed."
        end
        return nil, message, type(problem) == "table" and problem or nil
    elseif mode == "share" then
        if response ~= nil and validUUID(response.code) and response.code == expectedCode then
            return response.code, nil, response
        else
            return nil, "Settings Share returned an invalid code."
        end
    elseif mode == "dump" then
        local dumpCode = response ~= nil and response.code or nil
        if validUUID(dumpCode) then
            return dumpCode, nil, response
        else
            return nil, "Settings Dump returned an invalid code."
        end
    elseif response ~= nil and type(response.data) == "string" then
        return response.data, nil, response
    else
        return nil, "Settings Share returned invalid data."
    end
end

local function processPending()
    if processing then return end
    local entry = pendingRequests[1]
    if entry == nil then return end
    processing = true
    -- One queued request, one phase per Logic update. Never combine constructor,
    -- header, POST, finished-flag reading, response reading, or caller dispatch.
    local phase = entry.phase
    local ok = pcall(function()
        if phase == "permission" then
            entry.problem = httpProblem()
            entry.phase = entry.problem and "dispatch" or "construct"
        elseif phase == "construct" then
            entry.request = HTTPRequest.new(Plugin.urls.service, entry.path)
            entry.phase = "header"
        elseif phase == "header" then
            entry.request:AddHeader("Content-Type", "application/json")
            entry.phase = "user-agent"
        elseif phase == "user-agent" then
            entry.request:AddHeader("User-Agent", entry.pluginName)
            entry.phase = "post"
        elseif phase == "post" then
            entry.request:Post(entry.body, onHttpComplete, onHttpProgress)
            entry.phase = "wait"
        elseif phase == "wait" then
            if entry.request.finished == true then
                entry.phase = "response"
            end
        elseif phase == "response" then
            entry.value, entry.problem, entry.metadata = readResult(entry.request, entry.mode, entry.expectedCode)
            entry.phase = "dispatch"
        elseif phase == "cancel" then
            pcall(function() entry.request:Cancel() end)
            entry.phase = "dispatch"
        elseif phase == "dispatch" then
            -- Remove before the caller can queue work or recursively trigger Logic.
            table.remove(pendingRequests, 1)
            reply(entry.callback, entry.value, entry.problem, entry.metadata)
        end
    end)
    if not ok then
        entry.problem = (phase == "wait" or phase == "response")
            and "Settings Share could not read the HTTP response."
            or "Settings Share could not start the HTTP request."
        entry.phase = entry.request ~= nil and "cancel" or "dispatch"
    end
    processing = false
end

local transportAction, transportCallback
local function ensureUpdateLoop()
    if subscribed then return true end
    if Event == nil or Event.Logic == nil or type(Event.Logic.Subscribe) ~= "function" then
        return nil, "Settings Share requires the client Logic event to process HTTP responses."
    end
    -- Retain the native callback and bind the pump after subscription returns.
    transportCallback = function()
        local action = transportAction
        if action ~= nil then action() end
    end
    local ok = pcall(function()
        Event.Logic.Subscribe("settingsshare.http", transportCallback)
    end)
    if not ok then return nil, "Settings Share could not subscribe to the client Logic event." end
    transportAction = processPending
    subscribed = true
    return true
end

local function post(pluginName, path, payload, callback, mode)
    local problem = pluginNameProblem(pluginName)
    if problem ~= nil then return nil, problem end
    if callback ~= nil and type(callback) ~= "function" then
        return nil, "Settings Share callback must be a function."
    end
    problem = httpProblem()
    if problem ~= nil then return nil, problem end
    if #pendingRequests >= maxPendingRequests then
        return nil, "Settings Share has too many pending requests. Try again after they finish."
    end
    local updateReady, updateProblem = ensureUpdateLoop()
    if not updateReady then return nil, updateProblem end
    -- No native request is constructed or started on the caller's UI stack.
    -- The queue strongly retains the body, callback, and then the native request.
    local entry = { pluginName = pluginName, path = path, body = Json.encode(payload), callback = callback, mode = mode, phase = "permission",
        expectedCode = mode == "share" and payload.code or nil }
    pendingRequests[#pendingRequests + 1] = entry
    return true
end

local function createCode()
    -- Pure Lua: no permission checks, native events, or HTTP calls.
    local ok, code = pcall(UUID.Generate)
    if not ok or not validUUID(code) then
        return nil, "Settings Share could not generate a local share code."
    end
    return code
end

local function upload(pluginName, code, data, callback)
    if not validUUID(code) then return nil, "Settings Share requires a valid UUID code." end
    if type(data) ~= "string" then return nil, "Settings Share requires a string." end
    return post(
        pluginName, "/api/v1/settings-share/create",
        { code = code, data = data },
        callback,
        "share"
    )
end

local function write(pluginName, data, callback)
    local problem = pluginNameProblem(pluginName)
    if problem ~= nil then return nil, problem end
    if type(data) ~= "string" then return nil, "Settings Share requires a string." end
    local code
    code, problem = createCode()
    if code == nil then return nil, problem end
    local started
    started, problem = upload(pluginName, code, data, callback)
    if not started then return nil, problem end
    return code
end

local function read(pluginName, code, callback)
    if type(code) ~= "string" then return nil, "Settings Share requires a code." end
    return post(
        pluginName, "/api/v1/settings-share/fetch",
        { code = string.lower(string.match(code, "^%s*(.-)%s*$")) },
        callback,
        "read"
    )
end

local function createDump(pluginName, data, callback)
    if type(data) ~= "string" then return nil, "Settings Dump requires a string." end
    return post(pluginName, "/api/v1/settings-dump/create", { data = data }, callback, "dump")
end

return {
    version = "4.0.0",
    createCode = createCode, upload = upload,
    read = read, write = write, dump = { create = createDump },
}
