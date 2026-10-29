package.path = "./?.lua;./?/init.lua;" .. package.path

os = nil
local UUID = require("lib/uuid")
local seen = {}
for _ = 1, 1000 do
    local value = UUID.Generate()
    assert(#value == 36)
    assert(value:sub(9, 9) == "-" and value:sub(14, 14) == "-"
        and value:sub(19, 19) == "-" and value:sub(24, 24) == "-")
    assert(string.match(value,
        "^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$") ~= nil)
    assert(seen[value] == nil)
    seen[value] = true
end

print("uuid_test: ok")
