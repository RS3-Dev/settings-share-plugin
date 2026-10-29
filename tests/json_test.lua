package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("lib/json")

local text = 'Quotes: " \\ \n\t\r\b\f' .. string.char(0, 1, 31) .. " RuneScape"
assert(Json.decode(Json.encode({ data = text })).data == text)
assert(Json.decode('{"data":"\\u0041\\u00e9\\ud83d\\ude00"}').data == "Aé😀")
-- The sandbox may omit Lua's standard UTF-8 library.
utf8 = nil
assert(Json.decode('{"data":"\\u0041\\u00e9\\ud83d\\ude00"}').data == "Aé😀")
assert(Json.decode(' {"value":-1.25e+2,"ok":true,"no":false,"empty":null} ').value == -125)
assert(Json.decode('{"value":0}').value == 0)
assert(Json.decode('{"value":1e-3}').value == 0.001)
for _, source in ipairs({
    '{"value":01}', '{"value":1.}', '{"value":1e}', '{"value":1e+}',
    '{"value":1+2}', '{"value":1e9999}', '{"value":"\\u+123"}',
    '{"value":"\\ud800"}', '{"value":"\\udc00"}', '{"value":"\\q"}',
    '{"value":"unterminated}', '{"value":"raw\nnewline"}',
    '{"value":true,}', '{} trailing', '{"value" 1}', '\v{}',
}) do
    assert(not pcall(Json.decode, source), "must reject: " .. source)
end
assert(not pcall(Json.encode, math.huge))
assert(not pcall(Json.encode, 0 / 0))
print("json_test: ok")
