package.path = "./?.lua;./?/init.lua;" .. package.path

os = nil
local nativeRandom = math.random
local calls = 0
local function forbidReseed() error("UUID generation must not reseed the client's RNG") end
local nativeRandomseed = math.randomseed
math.randomseed = forbidReseed
math.random = function(lower, upper)
    assert(lower == 0 and upper == 255, "each byte must come directly from the client's RNG")
    calls = calls + 1
    return (calls - 1) % 256
end
local UUID = require("lib/uuid")
assert(calls == 0, "loading the UUID library must not use randomness or native APIs")
assert(UUID.Generate() == "00010203-0405-4607-8809-0a0b0c0d0e0f")
assert(calls == 16)
assert(UUID.Generate() == "10111213-1415-4617-9819-1a1b1c1d1e1f")
assert(calls == 32, "each UUID must use fresh random draws")
math.random = nativeRandom
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
math.randomseed = nativeRandomseed

print("uuid_test: ok")
