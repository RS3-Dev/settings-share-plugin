local Json = {}

-- Internal wire codec: objects, strings, numbers, booleans, and null.
-- Plugin settings remain opaque strings; this is not a settings serializer.
local function escape(value)
    local replacements = {
        ['\\'] = '\\\\', ['\"'] = '\\\"', ['\b'] = '\\b', ['\f'] = '\\f',
        ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'
    }
    return (string.gsub(value, '[%z\1-\31\\\"]', function(character)
        return replacements[character] or string.format("\\u%04x", string.byte(character))
    end))
end

local function utf8Character(codepoint)
    if utf8 ~= nil and type(utf8.char) == "function" then
        return utf8.char(codepoint)
    end
    if codepoint <= 0x7F then return string.char(codepoint) end
    if codepoint <= 0x7FF then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    end
    if codepoint <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

function Json.encode(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("JSON numbers must be finite")
        end
        return tostring(value)
    end
    if kind == "string" then return "\"" .. escape(value) .. "\"" end
    if kind ~= "table" then error("unsupported JSON value: " .. kind) end

    local parts = {}
    for key, child in pairs(value) do
        parts[#parts + 1] = Json.encode(tostring(key)) .. ":" .. Json.encode(child)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function decodeError(index, message)
    error("invalid JSON at byte " .. tostring(index) .. ": " .. message)
end

function Json.decode(source)
    if type(source) ~= "string" then error("JSON source must be a string") end
    local index = 1
    local length = #source

    local function skipSpace()
        while index <= length and string.match(string.sub(source, index, index), "[ \t\r\n]") do
            index = index + 1
        end
    end

    local parseValue
    local function parseString()
        index = index + 1
        local parts = {}
        while index <= length do
            local character = string.sub(source, index, index)
            if character == "\"" then
                index = index + 1
                return table.concat(parts)
            end
            if character == "\\" then
                local escaped = string.sub(source, index + 1, index + 1)
                local substitutions = {
                    ['\"'] = '\"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'
                }
                if substitutions[escaped] ~= nil then
                    parts[#parts + 1] = substitutions[escaped]
                    index = index + 2
                elseif escaped == "u" then
                    local hex = string.sub(source, index + 2, index + 5)
                    local codepoint = #hex == 4 and not hex:find("[^%x]") and tonumber(hex, 16) or nil
                    if codepoint == nil then decodeError(index, "invalid unicode escape") end
                    index = index + 6
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                        if string.sub(source, index, index + 1) ~= "\\u" then
                            decodeError(index, "missing low surrogate")
                        end
                        local lowHex = string.sub(source, index + 2, index + 5)
                        local low = #lowHex == 4 and not lowHex:find("[^%x]") and tonumber(lowHex, 16) or nil
                        if low == nil or low < 0xDC00 or low > 0xDFFF then
                            decodeError(index, "invalid low surrogate")
                        end
                        codepoint = 0x10000 + ((codepoint - 0xD800) * 0x400) + (low - 0xDC00)
                        index = index + 6
                    elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                        decodeError(index, "unexpected low surrogate")
                    end
                    parts[#parts + 1] = utf8Character(codepoint)
                else
                    decodeError(index, "unsupported string escape")
                end
            else
                if string.byte(character) < 32 then decodeError(index, "unescaped control character") end
                parts[#parts + 1] = character
                index = index + 1
            end
        end
        decodeError(index, "unterminated string")
    end

    local function parseObject()
        index = index + 1
        local result = {}
        skipSpace()
        if string.sub(source, index, index) == "}" then index = index + 1 return result end
        while true do
            skipSpace()
            if string.sub(source, index, index) ~= "\"" then
                decodeError(index, "expected object key")
            end
            local key = parseString()
            skipSpace()
            if string.sub(source, index, index) ~= ":" then decodeError(index, "expected ':'") end
            index = index + 1
            result[key] = parseValue()
            skipSpace()
            local character = string.sub(source, index, index)
            if character == "}" then index = index + 1 return result end
            if character ~= "," then decodeError(index, "expected ',' or '}'") end
            index = index + 1
        end
    end

    function parseValue()
        skipSpace()
        local character = string.sub(source, index, index)
        if character == "\"" then return parseString() end
        if character == "{" then return parseObject() end
        local tail = string.sub(source, index)
        if string.sub(tail, 1, 4) == "true" then index = index + 4 return true end
        if string.sub(tail, 1, 5) == "false" then index = index + 5 return false end
        if string.sub(tail, 1, 4) == "null" then index = index + 4 return nil end
        local numberText = string.match(tail, "^-?%d+%.?%d*[eE]?[+-]?%d*")
        if numberText ~= nil and numberText ~= "" then
            local integer, fraction, exponent = numberText:match("^(-?%d+)(%.?%d*)([eE]?.*)$")
            local digits = integer:gsub("^-", "")
            local value = tonumber(numberText)
            if (#digits > 1 and digits:sub(1, 1) == "0")
                or (fraction ~= "" and not fraction:match("^%.%d+$"))
                or (exponent ~= "" and not exponent:match("^[eE][+-]?%d+$"))
                or value == nil or value == math.huge or value == -math.huge then
                decodeError(index, "invalid number")
            end
            index = index + #numberText
            return value
        end
        decodeError(index, "unexpected value")
    end

    local result = parseValue()
    skipSpace()
    if index <= length then decodeError(index, "trailing content") end
    return result
end

return Json
