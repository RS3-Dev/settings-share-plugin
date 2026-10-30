package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local nativeCalls = 0
local permission = false
local tick, request
PluginPermissions = { httpAccess = {} }
Plugin = { urls = { service = {} }, HasPermission = function()
    nativeCalls = nativeCalls + 1
    return permission
end }
Event = { Logic = { Subscribe = function(_, fn)
    nativeCalls = nativeCalls + 1
    tick = fn
end } }
HTTPRequest = { new = function(_, path)
    nativeCalls = nativeCalls + 1
    request = { finished = false, path = path }
    function request:AddHeader() end
    function request:Post(body, completion, progress, ...)
        assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        self.body = Json.decode(body)
    end
    return request
end }
local api = dofile("main.lua")
local code = assert(api.createCode())
assert(#code == 36 and nativeCalls == 0 and tick == nil,
    "generating a code must not check permissions, subscribe, or construct HTTP")
local started, problem = api.upload("TestPlugin", code, "payload")
assert(started == nil and problem == "Settings Share requires HTTP access.")
assert(tick == nil and request == nil)

local rng = math.random
math.random = function() error("RNG unavailable") end
permission = true
local calls, confirmed = 0, nil
assert(api.upload("TestPlugin", code, "payload", function(value, err)
    calls, confirmed = calls + 1, value
    assert(err == nil)
end) == true)
assert(request == nil and calls == 0, "upload must queue without generating another code")
for _ = 1, 5 do tick() end
assert(request.path == "/api/v1/settings-share/create")
assert(request.body.code == code and request.body.data == "payload")
request.finished, request.successful, request.data = true, true, Json.encode({ code = code })
for _ = 1, 3 do tick() end
assert(calls == 1 and confirmed == code)
tick()
assert(calls == 1)
local badCode, rngProblem = api.createCode()
assert(badCode == nil and rngProblem:find("generate a local share code", 1, true))
assert(api.write("TestPlugin", "payload") == nil)
math.random = rng
local before = nativeCalls
assert(api.upload("TestPlugin", "not-a-uuid", "payload") == nil)
assert(api.upload("TestPlugin", code, {}) == nil)
assert(nativeCalls == before, "invalid uploads must not reach native code")
print("share_stages_test: ok")
