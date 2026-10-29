package.path = "./?.lua;./?/init.lua;" .. package.path

local requests = {}
local logs = {}
local logicUpdate
Event = { Logic = { Subscribe = function(name, callback)
    assert(name == "settingsshare.http")
    logicUpdate = callback
end } }

function log(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring(select(index, ...))
    end
    logs[#logs + 1] = table.concat(parts)
end

PluginPermissions = { httpAccess = {} }
local permissionGranted = false
Plugin = {
    urls = { service = "https://example.test" },
    HasPermission = function(value) return permissionGranted and value == PluginPermissions.httpAccess end,
}
HTTPRequest = {}
function HTTPRequest.new(baseURL, path)
    local request = { baseURL = baseURL, path = path, headers = {}, finished = false }
    function request:AddHeader(name, value) self.headers[name] = value end
    function request:Post(body, completion, progress, ...)
        assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        self.body = body
    end
    requests[#requests + 1] = request
    return request
end

local function finish(request, response)
    request.successful, request.data, request.errorInfo = response.successful, response.data, response.errorInfo
    request.finished = true
    for _ = 1, 3 do logicUpdate() end
end

local globals = {}
for key, value in pairs(_G) do globals[key] = value end
local api = dofile("main.lua")
for key, value in pairs(_G) do assert(globals[key] == value, "unexpected global: " .. key) end
for key, value in pairs(globals) do assert(_G[key] == value, "removed global: " .. key) end
assert(#logs == 0, "loading the dependency must be quiet")
assert(type(api.read) == "function" and type(api.write) == "function")
assert(api.Read == nil and api.Write == nil and api.Poll == nil)
local exported = 0
for _ in pairs(api) do exported = exported + 1 end
assert(exported == 8 and type(api.setDebugLogging) == "function" and api.version == "3.0.0")
assert(type(api.diagnostics.step) == "function" and type(api.diagnostics.nextStep) == "function")
assert(type(api.createCode) == "function" and type(api.upload) == "function")
assert(api.sync == nil, "settings sync is no longer exported")
assert(type(api.dump) == "table" and type(api.dump.create) == "function")

-- The dependency must load before HTTP is granted. All network entry points
-- fail immediately, without subscribing, constructing requests, or callbacks.
local deniedCallbackCalled = false
local function deniedCallback() deniedCallbackCalled = true end
for _, call in ipairs({
    function() return api.write("settings", deniedCallback) end,
    function() return api.read("code", deniedCallback) end,
    function() return api.dump.create("settings", deniedCallback) end,
}) do
    local started, problem = call()
    assert(started == nil and problem == "Settings Share requires HTTP access.")
end
assert(logicUpdate == nil and #requests == 0 and not deniedCallbackCalled)
permissionGranted = true

local function start(fn, ...)
    local started, problem = fn(...)
    if started then for _ = 1, 4 do logicUpdate() end end
    return started, problem
end

local written, writeProblem
local started = start(api.write, "settings", function(value, problem)
    written, writeProblem = value, problem
end)
assert(type(started) == "string" and #started == 36 and written == nil)
local code = started
assert(#requests == 1 and requests[1].path == "/api/v1/settings-share/create")
requests[1].successful = true
requests[1].data = '{"code":"' .. code .. '"}'
assert(written == nil, "native completion must not run Lua")
requests[1].finished = true
for _ = 1, 3 do logicUpdate() end
assert(written == code and writeProblem == nil)

local fetched, readProblem
assert(start(api.read, code, function(value, problem)
    fetched, readProblem = value, problem
end) == true)
assert(#requests == 2 and requests[2].path == "/api/v1/settings-share/fetch")
requests[2].successful = true
requests[2].data = '{"data":"shared settings"}'
requests[2].finished = true
for _ = 1, 3 do logicUpdate() end
assert(fetched == "shared settings" and readProblem == nil)

local Json = require("lib/json")
assert(Json.decode(requests[1].body).data == "settings")
assert(Json.decode(requests[1].body).code == code, "upload must include the client-generated code")
assert(requests[1].headers["Content-Type"] == "application/json")
assert(requests[1].baseURL == Plugin.urls.service)

local function fetchResult(response)
    local value, problem, calls
    calls = 0
    assert(start(api.read, "  ABC-123\n", function(result, err)
        value, problem, calls = result, err, calls + 1
    end))
    local pending = requests[#requests]
    assert(Json.decode(pending.body).code == "abc-123")
    finish(pending, response)
    assert(calls == 1)
    return value, problem
end

local value, problem = fetchResult({ successful = true, data = '{"data":""}' })
assert(value == "" and problem == nil)
for _, body in ipairs({ "", "not json", "null", "true", '{"data":42}' }) do
    value, problem = fetchResult({ successful = true, data = body })
    assert(value == nil and problem == "Settings Share returned invalid data.")
end
value, problem = fetchResult({ successful = false,
    data = '{"error":{"message":"Expired"}}', errorInfo = "transport" })
assert(value == nil and problem == "Expired")
value, problem = fetchResult({ successful = false,
    data = '{"error":{"message":42}}', errorInfo = "transport" })
assert(value == nil and problem == "transport")
value, problem = fetchResult({ successful = false, errorInfo = {} })
assert(value == nil and problem == "Settings Share request failed.")

local failure
assert(start(api.write, "", function(_, err) failure = err end))
finish(requests[#requests], { successful = true, data = '{"code":"wrong"}' })
assert(failure == "Settings Share returned an invalid code.")

-- Confirmation must match the pending code, even if another code is valid.
local otherPending = start(api.write, "settings", function(_, err) failure = err end)
assert(otherPending ~= code)
failure = nil
finish(requests[#requests], { successful = true, data = '{"code":"' .. code .. '"}' })
assert(failure == "Settings Share returned an invalid code.")

-- A caller exception must not escape into the HTTP completion binding.
assert(start(api.read, "code", function() error("caller failure") end))
finish(requests[#requests], { successful = true, data = '{"data":"ok"}' })
assert(start(api.read, "code")) -- The callback remains optional.
finish(requests[#requests], { successful = true, data = '{"data":"ok"}' })

local count = #requests
local callbackCalled = false
local function callback() callbackCalled = true end
assert(start(api.write, {}, callback) == nil)
assert(start(api.read, nil, callback) == nil)
assert(start(api.write, "settings", true) == nil)
assert(start(api.read, "code", {}) == nil)
Plugin.HasPermission = function() return false end
value, problem = start(api.read, "code", callback)
assert(value == nil and problem == "Settings Share requires HTTP access.")
Plugin.HasPermission = function() error("permission unavailable") end
assert(start(api.write, "settings", callback) == nil)
Plugin.HasPermission = function() return true end
Plugin.urls = nil
assert(start(api.read, "code", callback) == nil)
Plugin.urls = { service = {} } -- Resolved URL aliases may be userdata-like values.
local constructor = HTTPRequest.new
for _, method in ipairs({ "AddHeader", "Post" }) do
    HTTPRequest.new = function()
        local pending = { AddHeader = function() end, Post = function() end }
        pending[method] = function() error("setup failure") end
        return pending
    end
    local setupProblem
    value, problem = start(api.read, "code", function(_, err) setupProblem = err end)
    assert(value == true and problem == nil)
    for _ = 1, 2 do logicUpdate() end
    assert(setupProblem == "Settings Share could not start the HTTP request.")
end
HTTPRequest.new = constructor
-- Exercise a resolved URL alias without making assumptions about its type.
assert(start(api.read, "code"))
assert(requests[#requests].baseURL == Plugin.urls.service)
finish(requests[#requests], { successful = true, data = '{"data":"ok"}' })
count = #requests
HTTPRequest.new = function() error("transport unavailable") end
local setupProblem
value, problem = start(api.write, "settings", function(_, err) setupProblem = err end)
assert(type(value) == "string" and problem == nil)
logicUpdate()
assert(setupProblem == "Settings Share could not start the HTTP request.")
HTTPRequest = nil
assert(start(api.read, "code", callback) == nil)
Plugin = nil
assert(start(api.read, "code", callback) == nil)
assert(#requests == count and not callbackCalled)

assert(rawget(_G, "__settingsshare_state") == nil)

print("main_export_test: ok")
