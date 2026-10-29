local UUID = {}

-- A sandbox-compatible identifier generator, not a cryptographic RNG.
-- Draw every byte from the client's RNG instead of expanding a small private
-- seed. Do not reseed math.random or perform any work when this module loads.

function UUID.Generate()
    local bytes = {}
    for index = 1, 16 do bytes[index] = math.random(0, 255) end

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
