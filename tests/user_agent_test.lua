package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local requests, tick, nativeCalls = {}, nil, 0
PluginPermissions = { httpAccess = 1 }
Plugin = { urls = { service = {} }, HasPermission = function() nativeCalls = nativeCalls + 1; return true end }
Event = { Logic = { Subscribe = function(_, fn) nativeCalls = nativeCalls + 1; tick = fn end } }
HTTPRequest = { new = function(_, path)
    nativeCalls = nativeCalls + 1
    local request = { path = path, headers = {}, finished = false }
    function request:AddHeader(name, value) self.headers[name] = value end
    function request:Post(body) self.body = Json.decode(body) end
    requests[#requests + 1] = request
    return request
end }
local api = dofile("main.lua")
local code = "123e4567-e89b-42d3-a456-426614174000"
local callbacks = 0
local function callback() callbacks = callbacks + 1 end
local random = math.random
math.random = function() error("invalid names must fail before UUID generation") end
local function invalid(name)
    for _, call in ipairs({
        function() return api.write(name, "settings", callback) end,
        function() return api.read(name, code, callback) end,
        function() return api.upload(name, code, "settings", callback) end,
        function() return api.dump.create(name, "settings", callback) end,
    }) do
        local started, problem = call()
        assert(started == nil and problem:find("plugin name", 1, true))
    end
end
invalid(nil)
for _, name in ipairs({ false, 123, {}, "", " ", " Name", "Name ", "Name\t", "Name\r\nX-Test: injected", "Name\0", "Name\127", "Name\255", string.rep("x", 129) }) do
    invalid(name)
end
math.random = random
assert(nativeCalls == 0 and callbacks == 0 and tick == nil, "bad names must not reach native APIs or callbacks")
-- Old signatures cannot silently send an unnamed request.
assert(api.write("payload", callback) == nil)
assert(api.read(code, callback) == nil)
assert(api.upload(code, "payload", callback) == nil)
assert(api.dump.create("payload", callback) == nil)
assert(nativeCalls == 0)

-- Different consumers may queue requests concurrently; each keeps its own name.
local pending = assert(api.write("AlphaPlugin/1.2", "alpha"))
assert(api.read("Beta Plugin", code))
assert(api.upload(string.rep("x", 128), code, "gamma"))
assert(api.dump.create("DeltaPlugin", "delta"))
local expected = {
    { "AlphaPlugin/1.2", "/api/v1/settings-share/create", { code = pending, data = "alpha" } },
    { "Beta Plugin", "/api/v1/settings-share/fetch", { code = code } },
    { string.rep("x", 128), "/api/v1/settings-share/create", { code = code, data = "gamma" } },
    { "DeltaPlugin", "/api/v1/settings-dump/create", { data = "delta" } },
}
for i, item in ipairs(expected) do
    for _ = 1, 5 do tick() end
    local request = requests[i]
    assert(#requests == i and request.path == item[2])
    assert(request.headers["Content-Type"] == "application/json")
    assert(request.headers["User-Agent"] == item[1], "queued names must not bleed between plugins")
    for key, value in pairs(item[3]) do assert(request.body[key] == value) end
    for key in pairs(request.body) do assert(item[3][key] ~= nil, "plugin names belong in headers, not payloads") end
    request.successful, request.finished = true, true
    request.data = Json.encode({ code = request.body.code or code, data = "settings", expiresInSeconds = 604800 })
    for _ = 1, 3 do tick() end
end
assert(callbacks == 0)
print("user_agent_test: ok")
