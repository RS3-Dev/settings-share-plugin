local Json = require("lib/json")
local UUID = require("lib/uuid")
local pendingRequests = {}
local subscribed = false
local processing = false
local maxPendingRequests = 32
local debugLogging = false

local function trace(stage)
    if debugLogging and type(log) == "function" then
        pcall(log, "[Settings Share HTTP] ", stage)
    end
end

local function traceContext(stage)
    if not debugLogging then return end
    local context = "unavailable"
    if type(coroutine) == "table" and type(coroutine.running) == "function" then
        local ok, thread, isMain = pcall(coroutine.running)
        if ok then
            if isMain == true or thread == nil then context = "main thread"
            elseif isMain == false then context = "coroutine"
            else context = "unknown" end
        end
    end
    trace("Lua context at " .. stage .. ": " .. context)
end

local function validUUID(value)
    return type(value) == "string" and #value == 36
        and value:sub(9, 9) == "-" and value:sub(14, 14) == "-"
        and value:sub(19, 19) == "-" and value:sub(24, 24) == "-"
        and value:match("^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$") ~= nil
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
    if type(request.data) ~= "string" or request.data == "" then return nil end
    local ok, value = pcall(Json.decode, request.data)
    return ok and type(value) == "table" and value or nil
end

local function complete(request, callback, mode, expectedCode)
    local response = decode(request)
    if request.successful ~= true or (response ~= nil and response.error ~= nil) then
        local problem = response ~= nil and response.error or nil
        local message = type(problem) == "table" and problem.message or nil
        if type(message) ~= "string" or message == "" then message = request.errorInfo end
        if type(message) ~= "string" or message == "" then
            message = "Settings Share request failed."
        end
        reply(callback, nil, message, type(problem) == "table" and problem or nil)
    elseif mode == "share" then
        if response ~= nil and validUUID(response.code) and response.code == expectedCode then
            reply(callback, response.code, nil, response)
        else
            reply(callback, nil, "Settings Share returned an invalid code.")
        end
    elseif mode == "save" then
        local ttl = response ~= nil and response.expiresInSeconds or nil
        if type(ttl) == "number" and ttl > 0 and ttl < math.huge then
            reply(callback, true, nil, response)
        else
            reply(callback, nil, "Settings Sync returned invalid data.")
        end
    elseif mode == "dump" then
        local dumpCode = response ~= nil and response.code or nil
        if validUUID(dumpCode) then
            reply(callback, dumpCode, nil, response)
        else
            reply(callback, nil, "Settings Dump returned an invalid code.")
        end
    elseif response ~= nil and type(response.data) == "string" then
        reply(callback, response.data, nil, response)
    else
        reply(callback, nil, "Settings Share returned invalid data.")
    end
end

local function processPending()
    if processing then return end
    processing = true
    local completed = {}
    -- Remove finished requests before callbacks, so callbacks can safely queue new work.
    for index = #pendingRequests, 1, -1 do
        local entry = pendingRequests[index]
        local ok, finished = true, false
        if entry.request ~= nil then ok, finished = pcall(function() return entry.request.finished end) end
        if entry.problem ~= nil or not ok or finished == true then
            table.remove(pendingRequests, index)
            completed[#completed + 1] = { entry = entry, readable = ok }
        end
    end
    -- Starting native HTTP from a UI hook is avoided too. This subscription is
    -- created lazily, only when the first request is queued.
    for _, entry in ipairs(pendingRequests) do
        if entry.request == nil then
            local ok = pcall(function()
                local problem = httpProblem()
                if problem ~= nil then entry.problem = problem; return end
                traceContext("HTTP construction")
                trace("constructing request")
                entry.request = HTTPRequest.new(Plugin.urls.service, entry.path)
                trace("adding header")
                entry.request:AddHeader("Content-Type", "application/json")
                trace("calling Post without callbacks")
                entry.request:Post(entry.body)
                trace("Post returned; waiting for finished")
            end)
            if not ok then
                pcall(function() if entry.request ~= nil then entry.request:Cancel() end end)
                entry.problem = "Settings Share could not start the HTTP request."
                trace("request setup failed")
            end
        end
    end
    for index = #completed, 1, -1 do
        local item = completed[index]
        local entry = item.entry
        trace("dispatching result on Logic")
        if entry.problem ~= nil then
            reply(entry.callback, nil, entry.problem)
        elseif item.readable then
            local ok = pcall(complete, entry.request, entry.callback, entry.mode, entry.expectedCode)
            if not ok then reply(entry.callback, nil, "Settings Share could not read the HTTP response.") end
        else
            reply(entry.callback, nil, "Settings Share could not read the HTTP response.")
        end
    end
    processing = false
end

local function ensureUpdateLoop()
    if subscribed then return true end
    if Event == nil or Event.Logic == nil or type(Event.Logic.Subscribe) ~= "function" then
        return nil, "Settings Share requires the client Logic event to process HTTP responses."
    end
    traceContext("Logic subscription")
    trace("subscribing to Logic")
    local ok = pcall(Event.Logic.Subscribe, "settingsshare.http", processPending)
    if not ok then return nil, "Settings Share could not subscribe to the client Logic event." end
    trace("Logic subscription returned")
    subscribed = true
    return true
end

local function post(path, payload, callback, mode)
    if callback ~= nil and type(callback) ~= "function" then
        return nil, "Settings Share callback must be a function."
    end
    trace("checking HTTP access")
    local problem = httpProblem()
    if problem ~= nil then return nil, problem end
    if #pendingRequests >= maxPendingRequests then
        return nil, "Settings Share has too many pending requests. Try again after they finish."
    end
    local updateReady, updateProblem = ensureUpdateLoop()
    if not updateReady then return nil, updateProblem end
    -- No native request is constructed or started on the caller's UI stack.
    -- The queue strongly retains the body, callback, and then the native request.
    local entry = { path = path, body = Json.encode(payload), callback = callback, mode = mode,
        expectedCode = mode == "share" and payload.code or nil }
    pendingRequests[#pendingRequests + 1] = entry
    trace("queued for next Logic update")
    return entry
end

local function write(data, callback)
    if type(data) ~= "string" then return nil, "Settings Share requires a string." end
    local code = UUID.Generate()
    local request, problem = post(
        "/api/v1/settings-share/create",
        { code = code, data = data },
        callback,
        "share"
    )
    if request == nil then return nil, problem end
    return code
end

local function read(code, callback)
    if type(code) ~= "string" then return nil, "Settings Share requires a code." end
    local request, problem = post(
        "/api/v1/settings-share/fetch",
        { code = string.lower(string.match(code, "^%s*(.-)%s*$")) },
        callback,
        "read"
    )
    if request == nil then return nil, problem end
    return true
end

local function pairProblem(pluginName, playerId)
    if type(pluginName) ~= "string" or pluginName == "" then
        return "Settings Sync requires a registered plugin name."
    end
    if type(playerId) ~= "string" or #playerId < 1 or #playerId > 128
        or playerId:find("[^A-Za-z0-9_%-]") then
        return "Settings Sync requires a string player ID of 1–128 letters, digits, underscores, or hyphens."
    end
end

local function save(pluginName, playerId, data, callback)
    local problem = pairProblem(pluginName, playerId)
    if problem ~= nil then return nil, problem end
    if type(data) ~= "string" then return nil, "Settings Sync requires a string." end
    local request
    request, problem = post("/api/v1/settings-sync/save",
        { pluginName = pluginName, playerId = playerId, data = data }, callback, "save")
    if request == nil then return nil, problem end
    return true
end

local function fetch(pluginName, playerId, callback)
    local problem = pairProblem(pluginName, playerId)
    if problem ~= nil then return nil, problem end
    local request
    request, problem = post("/api/v1/settings-sync/fetch",
        { pluginName = pluginName, playerId = playerId }, callback, "read")
    if request == nil then return nil, problem end
    return true
end

local function createDump(data, callback)
    if type(data) ~= "string" then return nil, "Settings Dump requires a string." end
    local request, problem = post("/api/v1/settings-dump/create", { data = data }, callback, "dump")
    if request == nil then return nil, problem end
    return true
end

return {
    read = read, write = write, sync = { save = save, fetch = fetch }, dump = { create = createDump },
    setDebugLogging = function(enabled) debugLogging = enabled == true end,
}
