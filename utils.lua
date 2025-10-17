-- utils.lua
local ADDON, ACA = ...
local _G = _G

local tremove, tinsert = table.remove, table.insert
local floor = math.floor

local Utils = {}
ACA.Utils = Utils

function Utils.TruncateString(s, max)
    if not s or #s <= max then return s or "" end
    return s:sub(1, max - 3) .. "..."
end

function Utils.WipeChildren(frame, releaseFn)
    for _, child in ipairs({ frame:GetChildren() }) do
        if releaseFn then
            releaseFn(child)
        else
            child:Hide()
            child:SetParent(nil)
        end
    end
end

-- tiny cached store helper (simple TTL cache)
function Utils.MakeCache()
    local cache = {}
    return {
        get = function(key)
            local e = cache[key]
            if not e then return nil end
            if e.ttl and time() > e.ttl then
                cache[key] = nil
                return nil
            end
            return e.value
        end,
        set = function(key, value, ttlSeconds)
            cache[key] = { value = value, ttl = ttlSeconds and (time() + ttlSeconds) or nil }
        end,
        clear = function() cache = {} end
    }
end

return Utils
