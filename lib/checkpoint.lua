local Checkpoint = {}
local key = "settingsshare:transport-checkpoint:v1"

function Checkpoint.new(version)
    local enabled, lastPhase, lastState = false, nil, nil
    local function read()
        if PersistentDB == nil or type(PersistentDB.GetStructuredData) ~= "function" then
            return nil, "Local checkpoint storage is unavailable."
        end
        local ok, value = pcall(function() return PersistentDB:GetStructuredData(key) end)
        if not ok then return nil, "Could not read the local checkpoint." end
        if type(value) ~= "table" or type(value.version) ~= "string"
            or type(value.phase) ~= "string" or type(value.state) ~= "string"
            or #value.version > 32 or #value.phase > 80 or #value.state > 32 then return nil end
        return { version = value.version, phase = value.phase, state = value.state }
    end
    local function mark(phase, state)
        if not enabled then return false end
        if phase == lastPhase and state == lastState then return true end
        local ok, stored = pcall(function()
            return PersistentDB:SetStructuredData(key, { version = version, phase = phase, state = state })
        end)
        if not ok or stored == false then enabled = false; return false end
        lastPhase, lastState = phase, state
        return true
    end
    return {
        read = read,
        mark = mark,
        enable = function()
            if PersistentDB == nil or type(PersistentDB.SetStructuredData) ~= "function" then
                return nil, "Local checkpoint storage is unavailable."
            end
            enabled, lastPhase, lastState = true, nil, nil
            if not mark("armed", "ready") then return nil, "Could not save the local checkpoint." end
            local saved = read()
            if not saved or saved.version ~= version or saved.phase ~= "armed" or saved.state ~= "ready" then
                enabled = false
                return nil, "Could not verify the local checkpoint."
            end
            return true
        end,
    }
end

return Checkpoint
