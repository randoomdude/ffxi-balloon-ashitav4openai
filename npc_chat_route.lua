-- Temporary native NPC-log routing. Keep all other chat bits intact.
-- Config getter/setter signatures match Ashita's bundled config addon.
-- Retail mode 150/151/152 -> color 91 -> log bit 9 (verified in FFXiMain).
local bit = require('bit')
local M = {}
local NPC = 0x200

local function native_config()
    local ffi = require('ffi')
    ffi.cdef[[
        typedef int32_t (__cdecl* balloon_config_get_t)(int32_t);
        typedef int32_t (__cdecl* balloon_config_set_t)(int32_t, int32_t);
    ]]
    local get = ashita.memory.find('FFXiMain.dll', 0,
        '8B0D????????85C974??8B44240450E8????????C383C8FFC3', 0, 0)
    local set = ashita.memory.find('FFXiMain.dll', 0,
        '85C974??8B4424088B5424045052E8????????C383C8FFC3', -6, 0)
    if not get or get == 0 or not set or set == 0 then return nil end
    local object = ashita.memory.read_uint32(get + 2)
    if not object or object == 0 or ashita.memory.read_uint32(object) == 0 then return nil end
    return { get = ffi.cast('balloon_config_get_t', get),
        set = ffi.cast('balloon_config_set_t', set) }
end

function M.new(config, clock)
    local self = { active = false }
    local now = clock or os.clock
    local saved, idle_since, saw_event, finished, attempted, layout
    local function read(id)
        return tonumber(config.get(id))
    end
    local function write_bit(id, enabled)
        local current = read(id)
        if current == nil then return false end
        local value = enabled and bit.bor(current, NPC) or bit.band(current, bit.bnot(NPC))
        if value ~= current then config.set(id, value) end
        return (bit.band(read(id), NPC) ~= 0) == enabled
    end

    function self:restore()
        if not saved then return end
        -- Restore only values we changed, and preserve concurrent edits to other bits.
        for _, entry in ipairs(saved) do
            if entry.changed and (bit.band(read(entry.id), NPC) ~= 0) == entry.forced then
                write_bit(entry.id, entry.original)
            end
        end
        if layout == 0 and read(180) == 1 then config.set(180, layout) end
        self.active, saved, idle_since, saw_event, finished = false, nil, nil, false, false
    end

    function self:start()
        if self.active then return true end
        if not config then
            if attempted then return false end
            attempted = true
            config = native_config()
            if not config then
                print('[Balloon] NPC chat routing unavailable: native config signatures not found.')
                return false
            end
        end
        local first, second = read(185), read(187)
        if first == nil or second == nil then return false end
        saved = {
            { id = 185, original = bit.band(first, NPC) ~= 0, forced = false },
            { id = 187, original = bit.band(second, NPC) ~= 0, forced = true },
        }
        self.active, idle_since, saw_event, finished = true, now(), false, false
        layout = read(180)
        if layout == 0 then config.set(180, 1) end
        for _, entry in ipairs(saved) do
            entry.changed = entry.original ~= entry.forced
            if not write_bit(entry.id, entry.forced) then self:restore(); return false end
        end
        return true
    end

    function self:finish()
        if self.active then finished = true end
    end

    function self:update(valid, in_event, excluded, native_input, options)
        if not valid then self:restore(); return end
        if not self.active and in_event and excluded then self:start() end
        if not self.active then return end
        if in_event or native_input or options then
            saw_event, idle_since = true, nil
        else
            idle_since = idle_since or now()
            -- Allow the final native line to be delivered before resetting its route.
            -- An outgoing interaction may precede the event flag by several frames.
            local grace = (saw_event or finished) and 0.5 or 3
            if now() - idle_since >= grace then self:restore() end
        end
    end

    return self
end

return M
