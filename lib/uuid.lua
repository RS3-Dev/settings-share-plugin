local UUID = {}

-- A sandbox-compatible identifier generator, not a cryptographic RNG.
-- Keep its state private so generating codes does not reseed math.random.
local modulus = 2147483647
local counter = 0
local state = 1
local seed = tostring({}) .. ":" .. tostring(math.random())

for index = 1, #seed do
    state = (state * 131 + string.byte(seed, index)) % modulus
end
if state == 0 then state = 1 end

local function byte()
    state = (state * 48271) % modulus
    return state % 256
end

function UUID.Generate()
    counter = counter + 1
    local bytes = {}
    for index = 1, 16 do bytes[index] = byte() end

    local value = counter
    for index = 16, 13, -1 do
        bytes[index] = (bytes[index] + value % 256) % 256
        value = math.floor(value / 256)
    end

    bytes[7] = 0x40 + bytes[7] % 0x10
    bytes[9] = 0x80 + bytes[9] % 0x40

    local hex = {}
    for index = 1, 16 do hex[index] = string.format("%02x", bytes[index]) end
    return table.concat(hex, "", 1, 4)
        .. "-" .. table.concat(hex, "", 5, 6)
        .. "-" .. table.concat(hex, "", 7, 8)
        .. "-" .. table.concat(hex, "", 9, 10)
        .. "-" .. table.concat(hex, "", 11, 16)
end

return UUID
