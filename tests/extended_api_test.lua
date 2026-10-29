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
    function request:Post(body, completion, progress, ...)
        assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
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
local function advance(count) for _ = 1, count do logicUpdate() end end
local function finish(response, successful)
    advance(4) -- Permission, constructor, header, then POST on separate ticks.
    local request = requests[#requests]
    value, problem, metadata, calls = nil, nil, nil, 0
    request.successful, request.data, request.finished = successful ~= false, Json.encode(response), true
    assert(calls == 0)
    advance(3) -- Finished flag, response snapshot, then callback dispatch.
    assert(calls == 1)
end

local code = "123e4567-e89b-42d3-a456-426614174000"
assert(api.dump.create("dump contents", callback) == true)
advance(4)
local request = requests[#requests]
assert(request.path == "/api/v1/settings-dump/create" and request.body.data == "dump contents" and request.body.code == nil)
finish({ code = code, expiresInSeconds = 86400, downloadUrl = "https://settings.rs3.dev/dump" })
assert(value == code and problem == nil and metadata.downloadUrl == "https://settings.rs3.dev/dump")

-- Existing callbacks can ignore metadata; new callers can schedule retries from it.
api.dump.create("newest", callback)
finish({ error = { code = "rate_limited", message = "Wait", retryable = true, retryAfterSeconds = 45 } }, false)
assert(value == nil and problem == "Wait" and metadata.code == "rate_limited" and metadata.retryAfterSeconds == 45)
api.read("missing-code", callback)
finish({ error = { code = "not_found_or_expired", message = "Missing" } }, false)
assert(value == nil and problem == "Missing" and metadata.code == "not_found_or_expired")
-- Some transports report successful completion even for a structured API error.
api.dump.create("dump", callback)
finish({ error = { code = "at_capacity", message = "Full" } })
assert(value == nil and problem == "Full" and metadata.code == "at_capacity")

for _, response in ipairs({ {}, { code = "wrong" }, { code = 123 }, { code = "123e4567e-89b-42d3-a456-426614174000" } }) do
    api.dump.create("dump", callback)
    finish(response)
    assert(value == nil and problem == "Settings Dump returned an invalid code.")
end

local count = #requests
calls = 0
assert(api.dump.create({}, callback) == nil)
assert(api.dump.create("dump", true) == nil)
Plugin.HasPermission = function() return false end
assert(api.read("missing-code", callback) == nil)
assert(api.dump.create("dump", callback) == nil)
assert(#requests == count and calls == 0)
Plugin.HasPermission = function() return true end
for _, call in ipairs({
    function() return api.read("missing-code", callback) end,
    function() return api.dump.create("dump", callback) end,
}) do
    HTTPRequest.new = function() error("transport setup failed") end
    value, problem, calls = nil, nil, 0
    local started, err = call()
    assert(started == true and err == nil)
    logicUpdate() -- Native setup fails on the update, not the calling UI stack.
    logicUpdate()
    logicUpdate()
    assert(calls == 1 and value == nil and problem == "Settings Share could not start the HTTP request.")
end
print("extended_api_test: ok")
