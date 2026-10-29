package.path = "./?.lua;./?/init.lua;" .. package.path
local callbacks = require("lib/http_callbacks")
local forbidden = function() error("empty native callbacks must not inspect data or call client APIs") end
log = forbidden
Plugin = { HasPermission = forbidden }
Event = { Logic = { Subscribe = forbidden } }
HTTPRequest = { new = forbidden }
local request = setmetatable({}, {
    __index = forbidden, __newindex = forbidden, __pairs = forbidden,
    __len = forbidden, __tostring = forbidden, __call = forbidden,
})
for _, callback in pairs(callbacks) do
    assert(type(callback) == "function")
    for _ = 1, 20 do
        assert(pcall(callback, request))
        assert(pcall(callback, nil))
    end
end
print("http_callbacks_test: ok")
