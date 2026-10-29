package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local requests = {}
local logicUpdate
Event = { Logic = { Subscribe = function(_, callback) logicUpdate = callback end } }
PluginPermissions = { httpAccess = {} }
Plugin = { urls = { service = {} }, HasPermission = function() return true end }
HTTPRequest = { new = function(base, path)
    local request = { baseURL = base, path = path, finished = false }
    function request:AddHeader(name, value) self.header = { name, value } end
    function request:Post(body, ...)
        assert(select("#", ...) == 0, "native HTTP callbacks must not be used")
        self.body = Json.decode(body)
    end
    requests[#requests + 1] = request
    return request
end }
local before = {}
for key, value in pairs(_G) do before[key] = value end
local api = dofile("main.lua")
for key, value in pairs(_G) do assert(before[key] == value, "unexpected global: " .. key) end
local value, problem, metadata, calls
local function callback(result, err, info) value, problem, metadata, calls = result, err, info, (calls or 0) + 1 end
local function finish(response, successful)
    logicUpdate() -- Start a newly queued request before simulating its response.
    local request = requests[#requests]
    value, problem, metadata, calls = nil, nil, nil, 0
    request.successful, request.data, request.finished = successful ~= false, Json.encode(response), true
    assert(calls == 0)
    logicUpdate()
    assert(calls == 1)
end

assert(api.sync.save("PluginDev", "9007199254740993", "settings", callback) == true)
logicUpdate()
local request = requests[#requests]
assert(request.path == "/api/v1/settings-sync/save" and request.baseURL == Plugin.urls.service)
assert(request.body.pluginName == "PluginDev" and request.body.playerId == "9007199254740993" and request.body.data == "settings")
assert(request.header[1] == "Content-Type" and request.header[2] == "application/json")
finish({ expiresInSeconds = 604800 })
assert(value == true and problem == nil and metadata.expiresInSeconds == 604800)

assert(api.sync.fetch("PluginDev", "player-1", callback) == true)
logicUpdate()
request = requests[#requests]
assert(request.path == "/api/v1/settings-sync/fetch" and request.body.playerId == "player-1" and request.body.data == nil)
finish({ data = "", expiresInSeconds = 604800 })
assert(value == "" and problem == nil and metadata.expiresInSeconds == 604800)

local code = "123e4567-e89b-42d3-a456-426614174000"
assert(api.dump.create("dump contents", callback) == true)
logicUpdate()
request = requests[#requests]
assert(request.path == "/api/v1/settings-dump/create" and request.body.data == "dump contents" and request.body.code == nil)
finish({ code = code, expiresInSeconds = 86400, downloadUrl = "https://settings.rs3.dev/dump" })
assert(value == code and problem == nil and metadata.downloadUrl == "https://settings.rs3.dev/dump")

-- Existing callbacks can ignore metadata; new callers can schedule retries from it.
api.sync.save("PluginDev", "player-1", "newest", callback)
finish({ error = { code = "rate_limited", message = "Wait", retryable = true, retryAfterSeconds = 45 } }, false)
assert(value == nil and problem == "Wait" and metadata.code == "rate_limited" and metadata.retryAfterSeconds == 45)
api.sync.fetch("Unknown", "player-1", callback)
finish({ error = { code = "unregistered_plugin", message = "Not registered", retryable = false } }, false)
assert(value == nil and problem == "Not registered" and metadata.retryable == false)
api.sync.fetch("PluginDev", "player-1", callback)
finish({ error = { code = "not_found_or_expired", message = "Missing" } }, false)
assert(value == nil and problem == "Missing" and metadata.code == "not_found_or_expired")
-- Some transports report successful completion even for a structured API error.
api.dump.create("dump", callback)
finish({ error = { code = "at_capacity", message = "Full" } })
assert(value == nil and problem == "Full" and metadata.code == "at_capacity")

for _, response in ipairs({ {}, { expiresInSeconds = "604800" }, { expiresInSeconds = -1 } }) do
    api.sync.save("PluginDev", "player-1", "settings", callback)
    finish(response)
    assert(value == nil and problem == "Settings Sync returned invalid data.")
end
for _, response in ipairs({ {}, { code = "wrong" }, { code = 123 }, { code = "123e4567e-89b-42d3-a456-426614174000" } }) do
    api.dump.create("dump", callback)
    finish(response)
    assert(value == nil and problem == "Settings Dump returned an invalid code.")
end

local count = #requests
calls = 0
assert(api.sync.save("", "player-1", "settings", callback) == nil)
assert(api.sync.save("PluginDev", 123, "settings", callback) == nil)
assert(api.sync.save("PluginDev", "player-1", {}, callback) == nil)
for _, player in ipairs({ "", "with spaces", "bad/slash", string.rep("x", 129) }) do
    assert(api.sync.fetch("PluginDev", player, callback) == nil)
end
assert(api.sync.fetch("PluginDev", "player-1", {}) == nil)
assert(api.dump.create({}, callback) == nil)
assert(api.dump.create("dump", true) == nil)
Plugin.HasPermission = function() return false end
assert(api.sync.save("PluginDev", "player-1", "settings", callback) == nil)
assert(api.sync.fetch("PluginDev", "player-1", callback) == nil)
assert(api.dump.create("dump", callback) == nil)
assert(#requests == count and calls == 0)
Plugin.HasPermission = function() return true end
for _, call in ipairs({
    function() return api.sync.save("PluginDev", "player-1", "settings", callback) end,
    function() return api.sync.fetch("PluginDev", "player-1", callback) end,
    function() return api.dump.create("dump", callback) end,
}) do
    HTTPRequest.new = function() error("transport setup failed") end
    value, problem, calls = nil, nil, 0
    local started, err = call()
    assert(started == true and err == nil)
    logicUpdate() -- Native setup fails on the update, not the calling UI stack.
    logicUpdate()
    assert(calls == 1 and value == nil and problem == "Settings Share could not start the HTTP request.")
end
print("extended_api_test: ok")
