package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local requests, onLogic, subscriptions = {}, nil, 0
local inLogic, frame, nativeFrame, nativeGroup, responseFrame = false, 0, -1, nil, -1
log = function() error("runtime must not log or inspect requests from native callbacks") end
PersistentDB = setmetatable({}, { __index = function() error("runtime must not access checkpoint storage") end })
local function operation(group)
    assert(inLogic, "native operations must run on Logic")
    assert(frame ~= nativeFrame or (group == "response" and nativeGroup == "response"),
        "native phases must never be combined in one Logic update")
    nativeFrame, nativeGroup = frame, group
end
PluginPermissions = { httpAccess = {} }
Plugin = { urls = { service = {} }, HasPermission = function() return true end }
Event = { Logic = { Subscribe = function(name, callback)
    assert(name == "settingsshare.http")
    subscriptions, onLogic = subscriptions + 1, callback
end } }
HTTPRequest = { new = function(_, path)
    operation("construct")
    local state = { finished = false }
    local request = setmetatable({ path = path }, {
        __index = function(_, key)
            if key == "finished" then
                operation("finished")
                assert(state.postFrame and frame > state.postFrame, "never poll before POST or in its update")
                if state.finished then state.finishedFrame = frame end
            elseif key == "successful" or key == "data" or key == "errorInfo" then
                operation("response")
                assert(state.finishedFrame and frame > state.finishedFrame, "read response on a later update than finished")
                responseFrame = frame
                if key == "data" then
                    assert(state.dataReadFrame ~= frame, "read the native body only once")
                    state.dataReadFrame = frame
                end
            end
            return state[key]
        end,
        __newindex = function(_, key, value) state[key] = value end,
    })
    function request:AddHeader() operation("header") end
    function request:Post(body, completion, progress, ...)
        operation("post")
        assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        state.completion, state.progress = completion, progress
        state.body, state.postFrame = Json.decode(body), frame
    end
    function request:Cancel() operation("cancel"); state.cancelled = true end
    requests[#requests + 1] = request
    return request
end }
local function tick(count)
    for _ = 1, count or 1 do
        frame, inLogic = frame + 1, true
        onLogic()
        inLogic = false
    end
end
local api = dofile("main.lua")
assert(subscriptions == 0, "loading must not subscribe or initialize HTTP")
local pendingCode, calls = nil, 0
pendingCode = api.write("settings", function(code, problem)
    assert(inLogic and frame > responseFrame, "dispatch must follow response reading on a separate update")
    assert(code == pendingCode and problem == nil)
    calls = calls + 1
end)
assert(type(pendingCode) == "string" and #pendingCode == 36 and #requests == 0)
tick()
assert(#requests == 0, "the first update only rechecks permission")
tick()
assert(#requests == 1 and requests[1].body == nil, "construction must not POST")
tick()
assert(requests[1].body == nil, "header setup must not POST")
tick()
assert(requests[1].body.code == pendingCode and subscriptions == 1)
local forbidden = function() error("native callbacks must not inspect the request") end
local unreadable = setmetatable({}, {
    __index = forbidden, __newindex = forbidden, __pairs = forbidden,
    __len = forbidden, __tostring = forbidden, __call = forbidden,
})
-- Simulate native callbacks outside Logic, including absent request data.
for _, callback in ipairs({ requests[1].progress, requests[1].completion }) do
    for _ = 1, 20 do callback(unreadable); callback(nil) end
end
assert(calls == 0, "native callbacks must not dispatch application results")

tick()
assert(calls == 0)
requests[1].finished, requests[1].successful, requests[1].data = true, true, Json.encode({ code = pendingCode })
assert(calls == 0, "network completion must not invoke Lua callbacks")
tick()
assert(calls == 0, "finished observation must not dispatch")
tick()
assert(calls == 0, "response reading must not dispatch")
tick()
assert(calls == 1)
tick()
assert(calls == 1)

-- A callback may enqueue another request or recursively invoke Logic safely.
local order = {}
assert(api.read("first", function(data)
    order[#order + 1] = data
    assert(api.read("second", function(nextData) order[#order + 1] = nextData end))
    onLogic()
end))
tick(4)
local first = requests[#requests]
first.finished, first.successful, first.data = true, true, '{"data":"first"}'
tick(3)
assert(#order == 1 and order[1] == "first")
tick(4)
local second = requests[#requests]
second.finished, second.successful, second.data = true, true, '{"data":"second"}'
tick(3)
assert(#order == 2 and order[2] == "second" and subscriptions == 1)

local failed
assert(api.read("timeout", function(value, err) failed = value == nil and err == "Timed out" end))
tick(4)
local timedOut = requests[#requests]
timedOut.finished, timedOut.successful, timedOut.errorInfo = true, false, "Timed out"
tick(3)
assert(failed)

-- Retain native requests until completion, then release after dispatch.
local weak = setmetatable({}, { __mode = "v" })
assert(api.read("keep-alive"))
tick(4)
weak[1] = requests[#requests]
table.remove(requests)
collectgarbage("collect")
assert(weak[1] ~= nil)
weak[1].finished, weak[1].successful, weak[1].data = true, true, '{"data":"ok"}'
tick(3)
collectgarbage("collect")
assert(weak[1] == nil)

-- FIFO: at most one active request, with 32 total queued/active entries.
local beforeBatch = #requests
for _ = 1, 32 do assert(api.read("pending")) end
tick(4)
assert(#requests == beforeBatch + 1)
local started, problem = api.read("overflow")
assert(started == nil and problem:find("too many pending", 1, true))
for index = 1, 32 do
    local active = requests[#requests]
    active.finished, active.successful = true, false
    tick(3)
    if index < 32 then tick(4) end
end
assert(api.read("slot-reclaimed"))

-- Never replace an unavailable Logic loop with response handling in native callbacks.
Event = nil
local unsupported = dofile("main.lua")
local count = #requests
started, problem = unsupported.write("settings")
assert(started == nil and problem:find("Logic event", 1, true) and #requests == count)
Event = { Logic = { Subscribe = function() error("unavailable") end } }
unsupported = dofile("main.lua")
started, problem = unsupported.read("code")
assert(started == nil and problem:find("could not subscribe", 1, true) and #requests == count)
print("transport_polling_test: ok")
