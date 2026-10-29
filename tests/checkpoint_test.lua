package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local Checkpoint = require("lib/checkpoint")
local storage, writes = {}, 0
local key = "settingsshare:transport-checkpoint:v1"
PersistentDB = {
    GetStructuredData = function(_, name) return storage[name] end,
    SetStructuredData = function(_, name, value)
        assert(name == key)
        local count = 0
        for field, child in pairs(value) do
            assert(field == "version" or field == "phase" or field == "state")
            assert(type(child) == "string")
            count = count + 1
        end
        assert(count == 3, "checkpoints must not contain settings, codes, IDs, or native handles")
        storage[name], writes = value, writes + 1
        return true
    end,
}
local recorder = Checkpoint.new("test")
assert(not recorder.mark("post", "before") and writes == 0, "recording must be opt-in")
assert(recorder.enable())
assert(recorder.mark("post", "before"))
local savedWrites = writes
for _ = 1, 1000 do assert(recorder.mark("post", "before")) end
assert(writes == savedWrites, "repeated pending ticks must not repeatedly write storage")
local restarted = Checkpoint.new("test")
local saved = restarted.read()
assert(saved.phase == "post" and saved.state == "before", "a fresh instance must recover the previous checkpoint")
assert(writes == savedWrites, "reading after restart must not erase or rearm the checkpoint")

local function expect(phase)
    local current = storage[key]
    assert(current.phase == phase and current.state == "before", "save checkpoint before entering " .. phase)
end
local tick, request, code, permissionCalls = nil, nil, nil, 0
PluginPermissions = { httpAccess = {} }
Plugin = { urls = { service = {} }, HasPermission = function()
    permissionCalls = permissionCalls + 1
    expect(permissionCalls == 1 and "queue-permission" or "permission")
    return true
end }
Event = { Logic = { Subscribe = function(_, fn) expect("queue-subscribe"); tick = fn end } }
HTTPRequest = { new = function()
    expect("construct")
    request = setmetatable({}, { __index = function(_, field)
        if field == "finished" then expect("wait"); return true end
        if field == "successful" then expect("response"); return true end
        if field == "data" then expect("response"); return Json.encode({ code = code }) end
    end })
    function request:AddHeader() expect("header") end
    function request:Post(body, completion, progress, ...)
        expect("post")
        assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        assert(Json.decode(body).code == code)
    end
    return request
end }
local api = dofile("main.lua")
assert(api.diagnostics.armCrashLog())
code = assert(api.createCode())
local completed = false
assert(api.upload(code, "opaque settings", function(value, problem)
    expect("dispatch")
    completed = value == code and problem == nil
end))
for _ = 1, 7 do tick() end
assert(completed and storage[key].phase == "dispatch" and storage[key].state == "after")
local beforeRead = writes
assert(api.diagnostics.lastCheckpoint().phase == "dispatch")
assert(writes == beforeRead)

PersistentDB.SetStructuredData = function() return false end
local unavailable = Checkpoint.new("test")
assert(not unavailable.enable())
assert(not unavailable.mark("post", "before"), "failed storage must not remain armed")
print("checkpoint_test: ok")
