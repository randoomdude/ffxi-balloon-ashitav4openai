-- Native UI ownership is separate from Balloon's dialogue rendering.
local Cinematic = {}
Cinematic.__index = Cinematic

function Cinematic.new(helpers)
    return setmetatable({ helpers = helpers, owned = false, hidden = false }, Cinematic)
end

function Cinematic:restore()
    if self.owned then
        self.helpers.set_game_interface_hidden(self.previous)
    end
    self.owned, self.hidden, self.previous = false, false, nil
end

function Cinematic:suspend()
    self:restore()
    self.suspended = true
    self.helpers.set_game_interface_hidden(false)
end

function Cinematic:resume()
    self.suspended = false
end

function Cinematic:update(state)
    if not state.active then self.suspended = false end
    if self.suspended then
        self.helpers.set_game_interface_hidden(false)
        self.hidden = false
        return
    end
    if not state.enabled or not state.active or state.ignore or not state.ready then
        self:restore()
        return
    end

    local hide = not state.options and not state.typing
    if not self.owned then
        if not hide then return end
        local previous = self.helpers.is_game_interface_hidden()
        if not self.helpers.set_game_interface_hidden(true) then return end
        self.previous, self.owned = previous, true
    end

    -- Read the actual flag, rather than assuming our last write persisted.
    if self.helpers.is_game_interface_hidden() ~= hide then
        self.helpers.set_game_interface_hidden(hide)
    end
    self.hidden = hide and self.helpers.is_game_interface_hidden()
end

return Cinematic
