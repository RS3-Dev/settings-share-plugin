package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")
local manifestFile = assert(io.open("examples/settingssharedebug/plugin.json", "r"))
local manifestSource = manifestFile:read("*a")
manifestFile:close()
assert(not manifestSource:find('"dependencies"%s*:'), "client dependencies belong in requiredDependencies")
-- The helper's wire codec handles objects, not the manifest's permission arrays.
local dependencies = Json.decode(assert(manifestSource:match('"requiredDependencies"%s*:%s*(%b{})')))
assert(dependencies.settingsshare == "settingsshare")
assert(dependencies.prettyui == "prettyui")
local logic, requests = {}, {}
local events = {
    Logic = { Subscribe = function(name, fn) logic[name] = fn end, Unsubscribe = function(name) logic[name] = nil end },
}
local function tick()
    local snapshot = {}
    for _, fn in pairs(logic) do snapshot[#snapshot + 1] = fn end
    for _, fn in ipairs(snapshot) do fn() end
end
local helperEnv = setmetatable({
    Event = events,
    PluginPermissions = { httpAccess = 1 },
    Plugin = { urls = { service = {} }, HasPermission = function() return true end },
    HTTPRequest = { new = function(_, path)
        local request = { path = path, finished = false, headers = {} }
        function request:AddHeader(name, value) self.headers[name] = value end
        function request:Post(body, completion, progress, ...)
            assert(type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
            self.body = Json.decode(body)
        end
        requests[#requests + 1] = request
        return request
    end },
}, { __index = _G })
local helper = assert(loadfile("main.lua", "t", helperEnv))()
local inButtonHook = false
local nativeConstructor = helperEnv.HTTPRequest.new
helperEnv.HTTPRequest.new = function(...)
    assert(not inButtonHook, "button hooks must not start native HTTP")
    return nativeConstructor(...)
end
local inputs, buttons, texts, all, staleAccesses = {}, {}, {}, {}, 0
local function component(kind, parent)
    local data = { kind = kind, children = {}, hooks = {} }
    local methods = {
        SetPos = function() end, SetSize = function() end, Setup = function() end,
        GetText = function() return data.content end,
        SetText = function(_, value) data.writes = (data.writes or 0) + 1; data.content = value end,
        Subscribe = function(_, hook, fn) data.hooks[hook] = fn end,
        Destroy = function()
            local function destroy(record)
                record.dead = true
                for _, child in ipairs(record.children) do destroy(child) end
            end
            destroy(data)
        end,
    }
    local proxy = setmetatable({}, {
        __index = function(_, key)
            if data.dead then staleAccesses = staleAccesses + 1; error("destroyed UI read") end
            return methods[key] or data[key]
        end,
        __newindex = function(_, key, value)
            if data.dead then staleAccesses = staleAccesses + 1; error("destroyed UI write") end
            data[key] = value
        end,
    })
    all[proxy] = data
    if parent and all[parent] then table.insert(all[parent].children, data) end
    if kind == "InputField" then inputs[#inputs + 1] = proxy end
    if kind == "Button" then data.text = {}; buttons[#buttons + 1] = proxy end
    if kind == "Text" then texts[#texts + 1] = proxy end
    return proxy
end
local root = component("root")
local gameAreaID = { 1477, 60 }
local nativeUI = { Interfaces = { GetComponent = function(_, requested, ...)
    assert(requested == gameAreaID and select("#", ...) == 0, "use the named game area component like Taint Check")
    return root
end }, Hook = { ONBUTTONPRESSED = "press" },
    TextContentVisibilityMode = { VISIBLE = 1 }, InputFieldFilterMode = { NONE = 1 } }
for _, kind in ipairs({ "Layer", "Rectangle", "Text", "InputField", "Button" }) do
    local name = kind
    nativeUI[name] = { new = function() error("debug UI must use the installed PrettyUI controls") end }
end
local debugWindow
local prettyUI = { Window = { new = function(parent, options)
    assert(parent == root and options.title == "Settings Share Debug" and options.scrollable == false)
    debugWindow = { content = component("windowContent", parent) }
    function debugWindow:Show() self.shown = true end
    function debugWindow:Destroy() self.content:Destroy() end
    function debugWindow:Close()
        options.onClose()
        if options.destroyOnClose then self:Destroy() end
    end
    return debugWindow
end } }
prettyUI.Text = { new = function(parent, options)
    local label = component("Text", parent)
    label.content = options.text
    return label
end }
prettyUI.TextField = { new = function(parent, options)
    assert(options.stylesheetID == nil, "use PrettyUI's default input style")
    local field = component("InputField", parent)
    field.content = options.text
    return field
end }
prettyUI.SimpleButton = { new = function(parent, label, action, options)
    assert(options.stylesheetID == nil, "use PrettyUI's sprite-backed button")
    local button = component("Button", parent)
    button.text.content = label
    button.hooks.press = action
    return button
end }
local env = setmetatable({ Event = {}, settingsshare = helper, ui = nativeUI, prettyui = prettyUI,
    id = { Component = { TOPLEVEL_V2__GAME_AREA = gameAreaID }, Font = { MUSEO_SANS_11PT_REGULAR = 19 } },
    Vector4 = { new = function(...) return { ... } end },
    log = function() end,
    HTTPRequest = { new = function() error("debug panel must use the dependency") end },
}, { __index = _G })
assert(loadfile("examples/settingssharedebug/main.lua", "t", env))()
assert(#inputs == 2, "debug UI must be created at startup without waiting for a tick")
assert(debugWindow.shown, "the standalone PrettyUI window must be explicitly shown at startup")
assert(next(logic) == nil and #requests == 0, "loading the debug UI must not initialize the HTTP event or transport")
assert(#buttons == 3, "only the three API actions belong in the panel")
for _, button in ipairs(buttons) do
    assert(button.text.content == "Create share" or button.text.content == "Fetch share" or button.text.content == "Create dump")
end
local function click(label)
    for _, button in ipairs(buttons) do
        if button.text.content == label then
            inButtonHook = true
            local before = #requests
            button.hooks.press()
            assert(#requests == before, "clicking a button must only queue HTTP")
            if label == "Create share" and before == 0 then
                assert(type(inputs[2].content) == "string" and #inputs[2].content == 36,
                    "local code must be displayed without native HTTP construction")
            end
            inButtonHook = false
            for _ = 1, 5 do tick() end
            return
        end
    end
    error("Missing button: " .. label)
end
local function finish(response, successful)
    local request = requests[#requests]
    request.data, request.successful, request.finished = Json.encode(response), successful ~= false, true
    for _ = 1, 3 do tick() end
end
local function statusContains(text)
    for _, label in ipairs(texts) do
        if label.content and label.content:find(text, 1, true) then return true end
    end
    return false
end
assert(statusContains("Helper 4.0.0 | Debug 1.3.0"))
inputs[1].content = "debug string"
click("Create share")
local localCode = inputs[2].content
assert(requests[1].headers["User-Agent"] == "SettingsShareDebug")
assert(requests[1].path == "/api/v1/settings-share/create" and requests[1].body.data == "debug string")
assert(type(requests[1].body.code) == "string" and #requests[1].body.code == 36)
assert(requests[1].body.code == localCode and inputs[2].content == localCode and statusContains("waiting for response"))
click("Fetch share") -- Double clicks cannot start another request while pending.
assert(#requests == 1)
local code = requests[1].body.code
local codeWrites = all[inputs[2]].writes
finish({ code = code, expiresInSeconds = 604800 })
assert(inputs[2].content == code and statusContains("Share created"))
assert(all[inputs[2]].writes == codeWrites, "upload confirmation must not rewrite the code field")
inputs[1].content = "changed locally"
click("Fetch share")
assert(requests[2].body.code == code and requests[2].headers["User-Agent"] == "SettingsShareDebug")
finish({ data = "debug string", expiresInSeconds = 604800 })
assert(inputs[1].content == "debug string" and statusContains("MATCH"))
click("Create dump")
finish({ error = { code = "rate_limited", message = "Wait", retryAfterSeconds = 42 } }, false)
assert(statusContains("rate_limited") and statusContains("42s"))
click("Create dump")
assert(requests[4].path == "/api/v1/settings-dump/create" and requests[4].headers["User-Agent"] == "SettingsShareDebug")
finish({ code = code, expiresInSeconds = 86400 })
assert(inputs[2].content == code and statusContains("settings.rs3.dev/dump"))

-- Dependency errors are visible without bypassing the helper with raw HTTP.
env.settingsshare = nil
local count = #requests
click("Create share")
assert(#requests == count and statusContains("Enable the settingsshare"))
env.settingsshare = helper
click("Fetch share")
debugWindow:Close()
finish({ data = "late completion", expiresInSeconds = 604800 })
assert(staleAccesses == 0, "late helper completions must not touch destroyed UI")
-- Immediate failures must clear the busy state so the user can try again.
inputs, buttons, texts = {}, {}, {}
assert(loadfile("examples/settingssharedebug/main.lua", "t", env))()
helperEnv.Plugin.HasPermission = function() return false end
local beforeDenied = #requests
click("Create share")
assert(#requests == beforeDenied and statusContains("requires HTTP access"))
assert(inputs[2].content == "", "failed setup must not present a code")
helperEnv.Plugin.HasPermission = function() return true end
click("Create share")
assert(#requests == beforeDenied + 1)
finish({ code = requests[#requests].body.code, expiresInSeconds = 604800 })
assert(statusContains("Share created"))
debugWindow:Close()
print("debug_example_test: ok")
