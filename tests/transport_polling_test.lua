package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local requests, onLogic, subscriptions = {}, nil, 0
local inLogic = false
local stages = {}
log = function(_, stage) stages[#stages + 1] = stage end
local _, onMainThread = coroutine.running()
local expectedContext = onMainThread and "main thread" or "coroutine"
PluginPermissions = { httpAccess = {} }
Plugin = { urls = { service = {} }, HasPermission = function() return true end }
Event = { Logic = { Subscribe = function(name, callback)
    assert(name == "settingsshare.http")
    subscriptions, onLogic = subscriptions + 1, callback
end } }
HTTPRequest = { new = function(_, path)
    assert(inLogic, "native requests must be constructed on Logic, never on a UI hook")
    local request = { path = path, finished = false }
    function request:AddHeader() end
    function request:Post(body, ...)
        assert(inLogic, "Post must run on Logic")
        assert(select("#", ...) == 0, "neither completion nor progress callback may reach native HTTP")
        self.body = Json.decode(body)
    end
    function request:Cancel() self.cancelled = true end
    requests[#requests + 1] = request
    return request
end }
local api = dofile("main.lua")
assert(subscriptions == 0, "loading the helper must not subscribe to native events")
assert(#stages == 0)
api.setDebugLogging(true)
local pendingCode
local calls = 0
local function callback(code, problem)
    assert(inLogic, "application callbacks must run only in the normal Logic update")
    assert(code == pendingCode and problem == nil)
    calls = calls + 1
end
local function tick()
    inLogic = true
    onLogic()
    inLogic = false
end
pendingCode = api.write("settings", callback)
assert(type(pendingCode) == "string" and #pendingCode == 36)
assert(#requests == 0, "calling a helper must only enqueue the request")
assert(stages[1] == "checking HTTP access")
assert(stages[2] == "Lua context at Logic subscription: " .. expectedContext)
assert(stages[3] == "subscribing to Logic" and stages[4] == "Logic subscription returned")
assert(stages[5] == "queued for next Logic update")
tick()
assert(subscriptions == 1 and requests[1].body.code == pendingCode)
assert(stages[6] == "Lua context at HTTP construction: " .. expectedContext)
assert(stages[7] == "constructing request" and stages[8] == "adding header")
assert(stages[9] == "calling Post without callbacks" and stages[10] == "Post returned; waiting for finished")
api.setDebugLogging(false)
tick()
assert(calls == 0, "unfinished requests must not produce callbacks")
requests[1].data, requests[1].successful, requests[1].finished = Json.encode({ code = pendingCode }), true, true
assert(calls == 0, "setting finished must not invoke an HTTP callback")
tick()
assert(calls == 1)
tick()
assert(calls == 1, "finished requests must be removed before dispatch")

-- Callback reentrancy may queue another request, but never processes it in the same update.
local order = {}
assert(api.read("old-code", function(data)
    order[#order + 1] = data
    assert(api.read("next-code", function(nextData) order[#order + 1] = nextData end))
    onLogic() -- Recursive updates do not redispatch the active batch.
end))
tick()
local first = requests[#requests]
first.data, first.successful, first.finished = '{"data":"first"}', true, true
tick()
assert(#order == 1 and order[1] == "first")
tick()
local second = requests[#requests]
second.data, second.successful, second.finished = '{"data":"second"}', true, true
tick()
assert(#order == 2 and order[2] == "second")
assert(subscriptions == 1, "one subscription serves all requests")

-- Completion without a response is a failure, not a request left pending forever.
local failed
assert(api.read("timeout", function(value, err) failed = value == nil and err == "Timed out" end))
tick()
local timedOut = requests[#requests]
timedOut.finished, timedOut.successful, timedOut.errorInfo = true, false, "Timed out"
tick()
assert(failed)

-- Keep active native requests strongly referenced until the update loop observes completion.
local weak = setmetatable({}, { __mode = "v" })
assert(api.read("keep-alive"))
tick()
weak[1] = requests[#requests]
table.remove(requests)
collectgarbage("collect")
assert(weak[1] ~= nil)
weak[1].finished, weak[1].successful, weak[1].data = true, true, '{"data":"ok"}'
tick()
collectgarbage("collect")
assert(weak[1] == nil)

-- Bound retained native request objects and reclaim slots on completion.
local batchStart = #requests + 1
for _ = 1, 32 do assert(api.read("pending")) end
tick()
local count = #requests
local started, problem = api.read("overflow")
assert(started == nil and problem:find("too many pending", 1, true))
assert(#requests == count)
for index = batchStart, #requests do
    requests[index].finished, requests[index].successful = true, false
end
tick()
assert(api.read("slot-reclaimed"))

-- If normal-update dispatch is unavailable, never fall back to native callbacks.
Event = nil
local unsupported = dofile("main.lua")
count = #requests
started, problem = unsupported.write("settings", callback)
assert(started == nil and problem:find("Logic event", 1, true) and #requests == count)
Event = { Logic = { Subscribe = function() error("unavailable") end } }
unsupported = dofile("main.lua")
started, problem = unsupported.read("code", callback)
assert(started == nil and problem:find("could not subscribe", 1, true) and #requests == count)
print("transport_polling_test: ok")
