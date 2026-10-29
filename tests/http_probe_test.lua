package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local calls, onLogic, request, inLogic = {}, nil, nil, false
PluginPermissions = { httpAccess = {} }
local allowed = false
Plugin = { urls = { service = {} }, HasPermission = function(permission)
    assert(permission == PluginPermissions.httpAccess)
    calls[#calls + 1] = "permission"
    return allowed
end }
Event = { Logic = { Subscribe = function(name, fn)
    assert(name == "settingsshare.probe")
    calls[#calls + 1] = "subscribe"
    onLogic = fn
end } }
HTTPRequest = { new = function(base, path)
    assert(inLogic and base == Plugin.urls.service and path == "/api/v1/settings-share/create")
    calls[#calls + 1] = "construct"
    request = { finished = false }
    function request:AddHeader(name, value)
        assert(inLogic and name == "Content-Type" and value == "application/json")
        calls[#calls + 1] = "header"
    end
    function request:Post(body, completion, progress, ...)
        assert(inLogic and type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        calls[#calls + 1] = "post"
        self.body = Json.decode(body)
    end
    return request
end }
local function tick()
    inLogic = true
    onLogic()
    inLogic = false
end
local api = dofile("main.lua")
local probe = api.diagnostics
assert(#calls == 0 and probe.nextStep() == "Check HTTP permission")
local ok, message, nextStep = probe.step()
assert(not ok and message == "Settings Share requires HTTP access.")
assert(#calls == 1 and onLogic == nil)
allowed = true
assert(probe.step())
assert(#calls == 2 and probe.nextStep() == "Subscribe to Logic")
assert(probe.step())
assert(#calls == 3 and request == nil)
for _ = 1, 5 do tick() end
assert(#calls == 3, "probe subscription must never advance or send HTTP on its own")

local function advance(code, data, expected)
    local before = #calls
    assert(probe.step(code, data))
    assert(#calls == before and probe.nextStep() == "Read step result")
    tick()
    local after = #calls
    tick()
    assert(#calls == after, "a queued operation must execute once")
    local passed, detail, nextLabel = probe.step()
    assert(nextLabel == expected, detail)
    return passed, detail
end
assert(advance(nil, nil, "Add JSON header"))
assert(calls[#calls] == "construct")
assert(advance(nil, nil, "Send POST"))
assert(calls[#calls] == "header")
local count = #calls
ok, message = advance("bad-code", "payload", "Send POST")
assert(not ok and #calls == count, "invalid codes must not send HTTP")
local code = assert(api.createCode())
assert(advance(code, "test payload", "Read finished flag"))
assert(request.body.code == code and request.body.data == "test payload")
assert(advance(nil, nil, "Read finished flag")) -- Pending: never auto-poll.
request.finished, request.successful, request.data = true, true, Json.encode({ code = code })
assert(advance(nil, nil, "Read response"))
ok, message = advance(nil, nil, "Done")
assert(ok and message == "Share upload confirmed. Probe complete.")
count = #calls
assert(not probe.step())
tick()
assert(#calls == count, "completed probes must never resend")
print("http_probe_test: ok")
