addon.name      = 'balloon'
addon.author    = 'Originally by Hando, English support added by Yuki & Kenshi, themes added by Ghosty, ported to Ashita v4 by onimitch.'
addon.version   = '4.3.2-input15'
addon.desc      = 'Displays NPC chat logs in a UI Balloon, similar to FFXIV.'
addon.link      = 'https://github.com/onimitch/ffxi-balloon-ashitav4'

-- Ashita libs
require('common')
-- Attribute this addon's event callbacks to AddonWatch when timing is enabled.
do
    local ok, profiler = pcall(require, 'addonwatch_meter')
    if ok then
        local installed, err = pcall(profiler.install, 'balloon')
        if not installed then print('[AddonWatch] Timing unavailable: ' .. tostring(err)) end
    end
end

local chat = require('chat')
local settings = require('settings')
local encoding = require('gdifonts.encoding')
local ffi = require('ffi')

-- Windower lua libs
texts = require('wlibs.texts')
images = require('wlibs.images')
require('wlibs.sets')

-- Balloon files
local default_settings = require('defaults')
local theme = require('theme')
local ui = require('ui')
local tests = require('tests')
local defines = require('defines')
local helpers = require('helpers')
local cinematic_ui = require('cinematic').new(helpers)
local exception_chat_route = require('npc_chat_route').new()


local chat_modes = defines.chat_modes
local chat_color_codes = defines.chat_color_codes

local balloon = {
    debug = 'off',
    debug_closing = false,
    waiting_to_close = false,
    dialogue_dismissed = false,
    close_timer = 0,
    last_text = '',
    last_mode = 0,
    processing_message = false,
    lang_code = 'en',
    settings = {},
    last_frame_time = 0,
    theme_options = nil,
    move_check_sensitivity = 0.01,
    in_mog_menu = false,
    in_menu = false,
    drag_offset = nil,
    accepted_chat_modes = {},
    auto_hide_game_ui = false,
    fancychat_hidden = false,
    last_native_message_hidden = false,
    status_server = nil,
    auto_hide_after = 0,
    auto_hide_delay = 0.5,
    in_cinematic = false,
    cutscene_ui_active = false,
    in_event = false,
    last_known_target = nil,
    cinematic_ignore_targets = {
        'Emblazoned Reliquary', 'Treasure Chest', 'Treasure Coffer',
        'Treasure Casket', 'Sturdy Pyxis', 'Aurum Strongbox', 'Armoury Crate',
        -- Service menus work best with their original chat and native UI.
        'Gorpa-Masorpa', 'Affi', 'Dremi',
    },
    limit_fps_enabled = false,
    limit_fps_restore = 2,
}

-- FancyChat owns its own windows, so the native interface flag cannot hide
-- them. Send an explicit state change instead of emulating Shift+C, which
-- could invert the user's existing manual hide preference.
balloon.sync_fancychat = function(hidden, restore_chat)
    -- Slash is an explicit request to see chat. Always send its restore,
    -- even if our last queued state already says visible.
    if not restore_chat and balloon.fancychat_hidden == hidden then return end
    balloon.fancychat_hidden = hidden
    AshitaCore:GetChatManager():QueueCommand(-1,
        restore_chat and '/fchat cinematic restore' or
        (hidden and '/fchat cinematic on' or '/fchat cinematic off'))
end

-- parses a string into char[hex bytecode]
local function parse_codes(str)
	return (str:gsub('.', function (c)
		return string.format('[%02X]', string.byte(c))
	end))
end

-- TODO: Move into a lib/helpers file: game menu, event system, interface hidden, user camera.

-------------------------------------------------------------------------------

balloon.initialize = function(new_settings)
    -- Get game language
    local lang = AshitaCore:GetConfigurationManager():GetInt32('boot', 'ashita.language', 'playonline', 2)
    balloon.lang_code = lang == 1 and 'ja' or 'en'

    balloon.load_chat_mode_settings()

    -- Remove old filter setting
    if balloon.settings.filter ~= nil then
        balloon.settings.filter = nil
    end

	balloon.load_theme()

    if balloon.theme_options ~= nil and new_settings == nil then
        print(chat.header(addon.name):append(chat.message('Theme "%s" (%s)'):format(balloon.settings.theme, balloon.lang_code)))
    end

    if not helpers.stepdialog.available and balloon.settings.cinematic then
        print(chat.header(addon.name):append(chat.error('Unable to load stepdialog pointers for cinematic mode.')))
    end
end

balloon.load_chat_mode_settings = function()
    -- Default chat modes that are always on
    balloon.accepted_chat_modes = S{
        chat_modes.message,
        -- Note that although we have a setting to disable system messages, because some system messages appear
        -- during cutscenes and we always show those, we always accept them here first and filter out later.
        chat_modes.system,
    }

    -- System messages like Home Point etc
    if balloon.settings.system_messages then
        balloon.accepted_chat_modes:add(chat_modes.system)
    end

    -- Get additional chat modes from settings
    local additional_chat_modes = balloon.settings.additional_chat_modes or {}
    for _, v in ipairs(additional_chat_modes) do
        balloon.accepted_chat_modes:add(v)
    end

    -- local chat_mode_list = balloon.accepted_chat_modes:concat(' ')
    -- print(chat.header(addon.name):append(chat.message('chat modes: %s'):format(chat_mode_list)))
end

balloon.load_theme = function()
    -- Load the theme
    balloon.theme_options = theme.load(balloon.settings.theme, balloon.lang_code)
    if balloon.theme_options == nil then
        return
    end

    -- Load UI
	ui:load(balloon.settings, balloon.theme_options)
    ui:position(balloon.settings.position.x, balloon.settings.position.y)

    -- Display balloon if we changed theme while open
	if not ui:hidden() then
		balloon.process_balloon(balloon.last_text, balloon.last_mode)
	end
end

balloon.update_timer = function()
    if not balloon.waiting_to_close then
        return
    end
    if balloon.close_timer >= 0 then
        balloon.close_timer = math.max(0, balloon.close_timer - 1)
        ui.timer_text:text(string.rep('.', math.min(3, math.max(0, math.ceil(balloon.close_timer)))))
    end

    if balloon.close_timer <= 0 then
        if balloon.debug_closing then print('Closing from timer') end
        balloon.close()
    else
        ashita.tasks.once(1, balloon.update_timer)
    end
end

balloon.open = function(timed)
    balloon.dialogue_dismissed = false
	if timed then
		balloon.close_timer = balloon.settings.no_prompt_close_delay
		ui.timer_text:text(string.rep('.', math.min(3, math.max(0, math.ceil(balloon.close_timer)))))
    else 
        balloon.close_timer = 0
        balloon.waiting_to_close = false
	end

	ui:show(timed)

    if timed and not balloon.waiting_to_close then
        balloon.waiting_to_close = true
        ashita.tasks.once(1, balloon.update_timer)
    end
end

balloon.close = function()
    balloon.dialogue_dismissed = false
	ui:hide()

    balloon.waiting_to_close = false
    balloon.close_timer = 0
    balloon.in_mog_menu = false
    balloon.in_menu = false
end

-- Cancel dismisses only the presentation; native confirm remains available
-- while waiting for the next line, even if a press only finishes a page.
balloon.dismiss_dialogue = function()
    if not ui:hidden() then
        balloon.dialogue_dismissed = true
        balloon.waiting_to_close = false
        balloon.close_timer = 0
        ui:hide()
    end
end

balloon.handle_player_movement = function(player_entity)
    local new_player_pos = {
        player_entity.Movement.LocalPosition.X,
        player_entity.Movement.LocalPosition.Y,
        player_entity.Movement.LocalPosition.Z,
    }

    if not ui:hidden() and balloon.settings.move_close then
        if balloon.player_pos == nil then
            if balloon.debug_closing then print('Closing from move') end
            balloon.close()
        else
            local moved = {
                new_player_pos[1] - balloon.player_pos[1],
                new_player_pos[2] - balloon.player_pos[2],
                new_player_pos[3] - balloon.player_pos[3],
            }
            for _, v in ipairs(moved) do
                if math.abs(v) > balloon.move_check_sensitivity then
                    if balloon.debug_closing then print('Closing from move') end
                    balloon.close()
                    break
                end
            end
        end
    end

    balloon.player_pos = new_player_pos
end

-- One exclusion list governs Balloon presentation and temporary native routing.
balloon.is_ignored_target = function(name)
    if type(name) ~= 'string' then return false end
    name = name:lower()
    for _, ignored in pairs(balloon.cinematic_ignore_targets) do
        if name == ignored:lower() then return true end
    end
    return false
end

-- Resolve the current target before processing text; the render callback may
-- not have seen it yet. Retain the last target only while an event is active.
balloon.is_ignored_interaction = function()
    local target = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
    local entity = tonumber(target) and tonumber(target) > 0 and GetEntity(tonumber(target)) or nil
    local name = entity and entity.Name or nil
    if name == nil or name == '' then
        local player = GetPlayerEntity()
        if helpers.is_event_system_active() or (player and player.StatusServer == 4) then
            name = balloon.last_known_target
        end
    else
        balloon.last_known_target = name
    end
    if type(name) ~= 'string' then return false end
    name = name:lower()
    return balloon.is_ignored_target(name), name
end

balloon.handle_cinematics = function(player_ent, delta_time)
    -- Ignore certain cinematics by checking the player's last known target
    local ignore = balloon.is_ignored_interaction()

    -- Detect if player is in a cinematic
    if not ignore and player_ent.StatusServer == 4 then
        -- In an event
        balloon.in_event = true

        if balloon.status_server ~= player_ent.StatusServer then
            -- Small delay to wait for StatusEvent to be updated
            balloon.auto_hide_after = balloon.auto_hide_delay
            -- TODO: Figure out which packet updates StatusEvent so we can listen for that instead
            balloon.status_server = player_ent.StatusServer
        elseif balloon.auto_hide_after > 0 then
            balloon.auto_hide_after = balloon.auto_hide_after - delta_time
            if balloon.auto_hide_after <= 0 then
                balloon.auto_hide_after = 0
            end
        elseif not helpers.is_user_camera_enabled() then
            -- In a cutscene
            balloon.in_cinematic = true
            balloon.limit_fps(true)

            -- Native UI visibility is maintained independently below.
        else
            -- Not in a cutscene
            balloon.in_cinematic = false
            balloon.limit_fps(false)


        end
    else
        balloon.in_cinematic = false
        balloon.in_event = false
        balloon.limit_fps(false)


    end
end

-- NPC events can run without the strict server-status/camera combination.
-- Use the event flag, and keep the native UI flag current before rendering.
balloon.update_cinematic_ui = function()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local entity = GetPlayerEntity()
    local valid = player ~= nil and not player.isZoning and entity ~= nil
    local ignored, interaction_name = balloon.is_ignored_interaction()
    local gathering_name = interaction_name and interaction_name:gsub(' #%d+$', '')
    local garden_gathering = gathering_name == 'mineral vein' or gathering_name == 'arboreal grove'
    local enabled = balloon.settings.cinematic == true and (balloon.settings.display_mode or 0) > 0
    local camera_enabled
    if valid and enabled and not ignored then
        local ok, value = pcall(helpers.is_user_camera_enabled)
        if ok then camera_enabled = value end
    end

    -- A scripted camera can start before event flags or the first dialogue.
    -- Require an explicit false: an unavailable camera pointer is not a cutscene.
    local scripted_camera = camera_enabled == false
    local active = valid and (helpers.is_event_system_active() or
        entity.StatusServer == 4 or scripted_camera)
    if not enabled or not active or ignored then
        balloon.cutscene_ui_active = false
        balloon.dialogue_dismissed = false
    elseif scripted_camera then
        -- Once a full cutscene starts, retain UI hiding for the event's lifetime,
        -- including silent shots and brief returns of user camera control.
        balloon.cutscene_ui_active = true
    end
    local native_input = valid and helpers.is_quantity_input_open()
    local native_options = valid and helpers.is_dialog_option_open()
    exception_chat_route:update(valid, active, ignored, native_input, native_options)
    if exception_chat_route.active then helpers.show_native_input_chat(2) end
    cinematic_ui:update({
        enabled = enabled,
        active = active,
        ignore = ignored,
        native_input = native_input,
        options = native_options,
        typing = valid and helpers.is_chat_open(),
        ready = (not ui:hidden() or balloon.dialogue_dismissed or balloon.cutscene_ui_active) and
            helpers.stepdialog.available,
    })
    balloon.auto_hide_game_ui = cinematic_ui.hidden
    -- Numeric/text entry belongs to the normal FFXI chat window, not FancyChat.
    -- Garden gathering keeps FancyChat visible, including quantity prompts.
    -- Other NPC number-entry controls continue to use native chat only.
    balloon.sync_fancychat(not garden_gathering and (cinematic_ui.hidden or native_input))
    if native_input then
        helpers.show_native_input_chat()
        balloon.native_input_started = balloon.native_input_started or os.clock()
        -- The menu may open a frame after mode 1 replaced its preceding prompt.
        -- Restore that one line locally, without dialogue-advance control bytes.
        if balloon.last_native_message_hidden and balloon.last_text ~= '' and
            os.clock() - balloon.native_input_started >= 0.10 then
            balloon.last_native_message_hidden = false
            local text = balloon.last_text:gsub(defines.auto_prompt_chars_pattern, '')
                :gsub(defines.prompt_chars_pattern, '')
            AshitaCore:GetChatManager():AddChatMessage(152, false, text)
        end
    else
        balloon.native_input_started = nil
    end
end

-- Explicitly enabling cinematic mode also cancels slash suspension and can
-- reopen the last dialogue after the balloon was dismissed.
balloon.rearm_cinematic = function()
    cinematic_ui:resume()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local entity = GetPlayerEntity()
    local active = player ~= nil and not player.isZoning and entity ~= nil and
        (helpers.is_event_system_active() or entity.StatusServer == 4)
    if active and (balloon.settings.display_mode or 0) > 0 and
        ui:hidden() and balloon.last_text ~= '' then
        balloon.process_balloon(balloon.last_text, balloon.last_mode)
    end
end

-- Release a native quantity box before its first input, even between render frames.
-- This is a temporary control exception, not a suspension of the whole NPC event.
balloon.release_quantity_input = function()
    if not helpers.is_quantity_input_open() then return false end
    balloon.drag_offset = nil
    balloon.mouse_advance_pending = nil
    balloon.update_cinematic_ui()
    return true
end

balloon.handle_button_continue = function(e, force_step)
    if e.blocked then return end
    if balloon.release_quantity_input() or helpers.is_chat_open() or helpers.is_dialog_option_open() then
        return
    end

    if helpers.is_game_interface_hidden() or force_step then
        -- The balloon can be dismissed without disabling subsequent confirms.
        if helpers.is_event_system_active() or balloon.in_event or balloon.cutscene_ui_active then
            local ok, advanced = pcall(helpers.stepdialog.run)
            if ok and advanced then
                e.blocked = true
            elseif balloon.cutscene_ui_active and ui:hidden() and not balloon.dialogue_dismissed then
                -- A silent camera shot may have no native message to advance.
                -- Keep cutscene hiding; slash still provides recovery.
                e.blocked = true
            else
                balloon.dialogue_dismissed = false
                cinematic_ui:suspend()
                balloon.auto_hide_game_ui = false
                balloon.sync_fancychat(false)
            end
        end
        return
    end

    -- With native UI visible, let the normal game input handle the press.
    if not ui:hidden() then balloon.close() end
end

balloon.handle_button_cancel = function(e, toggle_balloon)
    if e.blocked then return end
    if balloon.release_quantity_input() or helpers.is_chat_open() or helpers.is_dialog_option_open() then return end
    if helpers.is_game_interface_hidden() and
        (helpers.is_event_system_active() or balloon.in_event or balloon.cutscene_ui_active) then
        if toggle_balloon and balloon.dialogue_dismissed and balloon.last_text ~= '' then
            -- Restore the current presentation locally, without advancing NPC dialogue.
            balloon.dialogue_dismissed = false
            balloon.process_balloon(balloon.last_text, balloon.last_mode)
            e.blocked = true
        elseif not ui:hidden() or balloon.dialogue_dismissed then
            balloon.dismiss_dialogue()
            e.blocked = true
        end
        return
    end
    -- When chat/native UI is visible, Cancel belongs entirely to FFXI.
    -- Do not hide Balloon or consume the press; the game closes chat lines.
end

-- Ashita reports keyboard input through both one-shot and held-key paths.
-- Capture Escape only while Balloon owns cinematic hiding; native inputs and
-- the slash recovery remain available.
balloon.capture_cinematic_escape = function()
    return balloon.settings.cinematic == true and
        (balloon.settings.display_mode or 0) > 0 and
        not cinematic_ui.suspended and
        (balloon.cutscene_ui_active or balloon.in_event or helpers.is_event_system_active()) and
        (cinematic_ui.hidden or helpers.is_game_interface_hidden()) and
        not helpers.is_chat_open() and not helpers.is_dialog_option_open() and
        not helpers.is_quantity_input_open()
end

balloon.limit_fps = function(enabled)
    enabled = enabled and balloon.settings.control_fps
    if balloon.limit_fps_enabled ~= enabled then
        if enabled then
            balloon.limit_fps_restore = helpers.get_fps_divisor()
            helpers.set_fps_divisor(2) -- 30fps
        else
            helpers.set_fps_divisor(balloon.limit_fps_restore)
        end
        balloon.limit_fps_enabled = enabled
    end
end

balloon.process_incoming_message = function(e)
    -- Leave excluded NPC/container dialogue untouched in chat, including display mode 1.
    local ignored = balloon.is_ignored_interaction()
    if ignored then
        local mode = bit.band(e.mode, 0xFF)
        if (mode == 150 or mode == 151 or mode == 152) and exception_chat_route:start() then
            -- A native force-window-1 flag would bypass the log configuration.
            -- Keep the message category, prompt controls and all other mode flags.
            e.mode_modified = bit.band(e.mode_modified or e.mode, bit.bnot(0x8000))
        end
        balloon.last_native_message_hidden = false
        balloon.close()
        balloon.in_event = false
        balloon.in_cinematic = false
        balloon.limit_fps(false)
        balloon.update_cinematic_ui()
        return
    end

    -- Obtain the chat mode..
    local mode = bit.band(e.mode, 0x000000FF)

	-- log debug info
	if S{'mode', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Mode: ' .. mode .. ' Text: ' .. e.message) end

	-- Check this message is one of the ones we're interested in
    if not balloon.accepted_chat_modes[mode] then
        if S{'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', ('Not accepted mode: %d'):format(mode)) end
        return
    end

    -- We handle system messsages in a special way here
    -- If the user has turned off system messages, we will ignore them but only when not in a cutscene.
    -- In other words cutscene system message are always displayed. This is mainly because they can be 
    -- easily missed if the user also has the UI hidden duuring cutscenes.
    if mode == chat_modes.system then
        if not balloon.in_cinematic and not balloon.settings.system_messages then
            return
        end
    end

    -- Auto-advancing garden/NPC text can still contain real dialogue.
    -- Only an empty (possibly color-coded) automatic prompt clears the balloon.
    local auto_prompt_start = e.message:find(defines.auto_prompt_chars_pattern .. '$')
    local blank_auto_prompt = auto_prompt_start and
        e.message:sub(1, auto_prompt_start - 1):gsub('[\30\31].', ''):match('^%s*$') ~= nil
	if blank_auto_prompt then
        if balloon.debug_closing then 
            print('Closing from auto prompt chars')
            LogManager:Log(5, 'Balloon', 'Closed from ending with Auto prompt characters: ' .. parse_codes(e.message))
        end
		balloon.close()
		return
	end

	if balloon.settings.display_mode >= 1 then
        -- Do we need to check if the player is in combat?
        -- We only check if the player is engaged (has weapon out) but this should be enough for our use case.
        if not balloon.settings.in_combat and not helpers.is_event_system_active() then
            local entity = AshitaCore:GetMemoryManager():GetEntity()
            local party = AshitaCore:GetMemoryManager():GetParty()
            if entity ~= nil and party ~= nil then
                local player_index = party:GetMemberTargetIndex(0)
                if player_index ~= nil and entity:GetStatus(player_index) == 1 then
                    return
                end
            end
        end

        local native_quantity = helpers.is_quantity_input_open()
        e.message_modified = balloon.process_balloon(e.message, mode)
        balloon.last_native_message_hidden = not native_quantity and e.message_modified ~= e.message
        if native_quantity then
            -- Keep the original native prompt while entering a number, including in mode 1.
            e.message_modified = e.message
            balloon.update_cinematic_ui()
        end
    end
end

balloon.process_balloon = function(message, mode)
	balloon.last_text = message
	balloon.last_mode = mode

	-- detect whether messages have a prompt button
    local ends_with_prompt = false
    for _, v in ipairs(defines.PROMPT_CHARS) do
        ends_with_prompt = message:endswith(v)
        if ends_with_prompt then
            break
        end
    end
    local timed = (not balloon.in_menu and not ends_with_prompt)

	-- Extract speaker name
    local npc_prefix_start, npc_prefix_end = message:find('.- : ')
	local npc_prefix = ''
    if npc_prefix_start ~= nil then
        if npc_prefix_end < 32 and npc_prefix_start > 0 then
            npc_prefix = message:sub(npc_prefix_start, npc_prefix_end)
        end
	end
	local npc_name = npc_prefix:sub(0, #npc_prefix-2)
	npc_name = npc_name:trimex()

    -- pass through the original message for the log
    local result = message

	-- mode 1, blank log lines and visible balloon
	if balloon.settings.display_mode == 1 then
        -- Preserve ending prompt chars
        local end_of_text_pos = #message
        for _, prompt_chars in ipairs(defines.PROMPT_CHARS) do
            local prompt_pos, _ = message:find(prompt_chars, -4, true)
            if prompt_pos ~= nil then
                end_of_text_pos = prompt_pos
                break
            end
        end
        result = npc_prefix
        if npc_prefix ~= '' then
            result = result .. '...'
        end
        -- Preserve prompt chars
        if end_of_text_pos == #message then
            -- Empty message
        else
            result = result .. message:sub(end_of_text_pos)
        end
	end

    -- strip the NPC name from the start of the message
    if npc_prefix ~= '' then
        message = message:sub(npc_prefix_end)
    end

    -- log debug info
    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'message: ' .. message) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'codes: ' .. parse_codes(message)) end
    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'end codes shiftjis: ' .. parse_codes(message:sub(-4))) end

    -- Convert message to utf8
	message = balloon.convert_shiftjis_to_utf8(message)

	if S{'message+', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-process: ' .. message) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'end codes utf8: ' .. parse_codes(message:sub(-4))) end

    -- TODO: Check if this is necessary (this was probably an issue with windower text color tags and opening with a \cr tag)
	-- strip the default color code from the start of messages,
	-- it causes the first part of the message to get cut off somehow
	local default_color = chat_color_codes.standard
	if string.sub(message, 1, #default_color) == default_color then
		message = string.sub(message, #default_color + 1)
	end

    -- Strip out prompt characters
    message = message:gsub(defines.auto_prompt_chars_pattern, '')
    message = message:gsub(defines.prompt_chars_pattern, '')

    message = message:gsub(chat_color_codes.standard, '[BL_c1]') --color code 1 (black/reset)
    message = message:gsub(chat_color_codes.item, '[BL_c2]') --color code 2 (green/regular items)
    message = message:gsub(chat_color_codes.key_item, '[BL_c3]') --color code 3 (blue/key items)
    message = message:gsub(chat_color_codes.blue, '[BL_c4]') --color code 4 (blue/???)
    message = message:gsub(chat_color_codes.magenta, '[BL_c5]') --color code 5 (magenta/equipment?)
    message = message:gsub(chat_color_codes.cyan, '[BL_c6]') --color code 6 (cyan/???)
    message = message:gsub(chat_color_codes.yellow, '[BL_c7]') --color code 7 (yellow/???)
    message = message:gsub(chat_color_codes.orange, '[BL_c8]') --color code 8 (orange/RoE objectives?)
    message = message:gsub(chat_color_codes.emote, '') --cutscene emote color code (handled by the message type instead)

    message = message:gsub('^?([%w%.\'(<“])', '%1')
    message = message:gsub('%f[-]%-%-%f[^-]', '—') --replace -- with em dashes

    message = message:gsub('%[BL_c1]', '\\cr')
    message = message:gsub('%[BL_c2]', '\\cs('..ui._type.items..')')
    message = message:gsub('%[BL_c3]', '\\cs('..ui._type.keyitems..')')
    message = message:gsub('%[BL_c4]', '\\cs('..ui._type.keyitems..')')
    message = message:gsub('%[BL_c5]', '\\cs('..ui._type.gear..')')
    message = message:gsub('%[BL_c6]', '\\cs(0,159,173)')
    message = message:gsub('%[BL_c7]', '\\cs(156,149,19)')
    message = message:gsub('%[BL_c8]', '\\cs('..ui._type.roe..')')
    --TODO: theme settings for these element colors
    message = message:gsub('%[BL_Fire]', '\\cs(255,0,0)Fire \\cr')
    message = message:gsub('%[BL_Ice]', '\\cs(0,255,255)Ice \\cr')
    message = message:gsub('%[BL_Wind]', '\\cs(0,255,0)Wind \\cr')
    message = message:gsub('%[BL_Earth]', '\\cs(153,76,0)Earth \\cr')
    message = message:gsub('%[BL_Lightning]', '\\cs(127,0,255)Lightning \\cr')
    message = message:gsub('%[BL_Water]', '\\cs(0,76,153)Water \\cr')
    message = message:gsub('%[BL_Light]', '\\cs(224,224,224)Light \\cr')
    message = message:gsub('%[BL_Dark]', '\\cs(82,82,82)Dark \\cr')
    -- Mid message line breaks
    message = message:gsub(string.char(0x07), '\n')


    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'codes end: ' .. parse_codes(message:sub(-4))) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Final: ' .. encoding:UTF8_To_ShiftJIS(message)) end


    if not ui:set_character(npc_name) then
		ui:set_type(mode)
	end
	-- Change only the rendered dialogue during cutscenes; keep the native chat text intact.
	if balloon.cutscene_ui_active or balloon.in_cinematic then
		message = message:gsub('%f[%w]Randoomdude%f[%W]', 'Aldwin')
	end
	ui:set_message(message:trimex())
	balloon.open(timed)

	return result
end

balloon.convert_shiftjis_to_utf8 = function(str)
    str = balloon.sub_chars_pre_utf8(str)
	str = encoding:ShiftJIS_To_UTF8(str)
    str = balloon.sub_chars_post_utf8(str)
    return str
end

balloon.sub_chars_pre_utf8 = function(str)
	local new_str = str
	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-charsub pre-shift: ' .. new_str) end

	new_str = string.gsub(new_str, string.char(0x81, 0x40), '    ') -- tab
	new_str = string.gsub(new_str, string.char(0x81, 0xF4), '[BL_note]') -- musical note
	new_str = string.gsub(new_str, string.char(0x81, 0x99), '[BL_bstar]') -- empty star
	new_str = string.gsub(new_str, string.char(0x81, 0x9A), '[BL_wstar]') -- full star
	new_str = string.gsub(new_str, string.char(0x81, 0x60), '[BL_wave]') -- wide tilde
	new_str = string.gsub(new_str, string.char(0x87, 0xB2), '[BL_cldquote]') -- centered left double quote
	new_str = string.gsub(new_str, string.char(0x87, 0xB3), '[BL_crdquote]') -- centered right double quote
	new_str = string.gsub(new_str, string.char(0x88, 0x69), '[BL_e_acute]') -- acute accented e

	-- element symbols
	new_str = string.gsub(new_str, string.char(0xEF,0x1F), '[BL_Fire]')
	new_str = string.gsub(new_str, string.char(0xEF,0x20), '[BL_Ice]')
	new_str = string.gsub(new_str, string.char(0xEF,0x21), '[BL_Wind]')
	new_str = string.gsub(new_str, string.char(0xEF,0x22), '[BL_Earth]')
	new_str = string.gsub(new_str, string.char(0xEF,0x23), '[BL_Lightning]')
	-- extra 0x25 in these two to escape the characters
	new_str = string.gsub(new_str, string.char(0xEF,0x25,0x24), '[BL_Water]')
	new_str = string.gsub(new_str, string.char(0xEF,0x25,0x25), '[BL_Light]')
	new_str = string.gsub(new_str, string.char(0xEF,0x26), '[BL_Dark]')

	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Post-charsub pre-shift: ' .. new_str) end
	return new_str
end

balloon.sub_chars_post_utf8 = function(str)
	local new_str = str
	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-charsub post-shift: ' .. new_str) end

	new_str = string.gsub(new_str, '%[BL_note]', '♪')
	new_str = string.gsub(new_str, '%[BL_bstar]', '☆')
	new_str = string.gsub(new_str, '%[BL_wstar]', '★')
	new_str = string.gsub(new_str, '%[BL_wave]', '~')
	new_str = string.gsub(new_str, '%[BL_cldquote]', '“')
	new_str = string.gsub(new_str, '%[BL_crdquote]', '”')
	new_str = string.gsub(new_str, '%[BL_e_acute]', 'é')

	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Post-charsub post-shift: ' .. new_str) end
	return new_str
end

balloon.print_help = function(isError)
    -- Print the help header..
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/' .. addon.name)))
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')))
    end

    local cmds = T{
        { '/balloon help', 'Displays this help information.' },
        { '/balloon 0', 'Hiding balloon & displaying log.' },
        { '/balloon 1', 'Show balloon & hide log.' },
        { '/balloon 2', 'Show balloon & displaying log.' },
        { '/balloon reset', 'Reset to default settings.' },
        { '/balloon reset pos', 'Reset the balloon position.' },
        { '/balloon theme <theme>', 'Loads the specified theme.' },
        { '/balloon scale <scale>', 'Scales the size of the balloon by a decimal (eg: 1.5).' },
        { '/balloon delay <seconds>', 'Delay before closing promptless balloons.' },
        { '/balloon speed <chars per second>', 'Speed that text is displayed, in characters per second.' },
        { '/balloon portrait', 'Toggle the display of character portraits, if the theme has settings for them.' },
        { '/balloon move_close', 'Toggle balloon auto-close on player movement.' },
        { '/balloon always_on_top', 'Toggle always on top (IMGUI mode).' },
        { '/balloon in_combat', 'Toggle displaying balloon during combat.' },
        { '/balloon system', 'Toggle displaying balloon for system messages (e.g Home Point).' },
        { '/balloon cinematic [on|off]', 'Resume after slash, otherwise toggle or explicitly set cinematic UI hiding.' },
        { '/balloon status', 'Show event detection and native UI visibility.' },
        { '/balloon fps', 'Toggle fps control during cutscenes to prevent lockups in certain cutscenes.' },
        { '/balloon test <name> <lang> <mode>', 'Display a test bubble. Lang: - (auto), en or ja. Mode: 1 (dialogue), 2 (system). "/balloon test" to see the list of available tests.' },
    }

    -- Print the command list..
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])))
    end)
end

-- Ashita events

ashita.events.register('command', 'balloon_command_cb', function(e)
    -- Parse the command arguments..
    local args = e.command:args()
    if (#args == 0 or (args[1] ~= '/bl' and args[1] ~= '/balloon')) then
        return
    end

    -- Block all related commands..
    e.blocked = true

    if (#args == 3 and args[2]:any('cinematic', 'cinema') and args[3]:any('on', 'off')) then
        balloon.settings.cinematic = args[3] == 'on'
        if balloon.settings.cinematic then balloon.rearm_cinematic() end
        balloon.update_cinematic_ui()
        settings.save()
        print(chat.header(addon.name):append(chat.message('Cinematic mode: ' .. args[3])))
        return
    end

    if (#args == 2 and args[2] == 'status') then
        local entity = GetPlayerEntity()
        print(chat.header(addon.name):append(chat.message(
            'cinematic=' .. tostring(balloon.settings.cinematic) ..
            ' mode=' .. tostring(balloon.settings.display_mode) ..
            ' event=' .. tostring(helpers.is_event_system_active()) ..
            ' server=' .. tostring(entity and entity.StatusServer) ..
            ' camera=' .. tostring(helpers.is_user_camera_enabled()) ..
            ' cutscene=' .. tostring(balloon.cutscene_ui_active) ..
            ' choice=' .. tostring(helpers.is_dialog_option_open()) ..
            ' quantity=' .. tostring(helpers.is_quantity_input_open()) ..
            ' input=' .. tostring(AshitaCore:GetChatManager():IsInputOpen()) ..
            ' menu=' .. helpers.get_game_menu_name() ..
            ' typing=' .. tostring(helpers.is_chat_open()) ..
            ' hidden=' .. tostring(helpers.is_game_interface_hidden()) ..
            ' owned=' .. tostring(cinematic_ui.owned) ..
            ' suspended=' .. tostring(cinematic_ui.suspended == true))))
        return
    end

    -- Handle: /balloon help
    if (#args == 2 and args[2]:any('help')) then
        balloon.print_help(false)
        return
    end

    -- Handle: /balloon [0,1,2]
    if (#args == 2 and args[2]:any('0', '1', '2')) then
        balloon.settings.display_mode = tonumber(args[2])
        balloon.update_cinematic_ui()
        local mode_desc = {
            'Hiding balloon & displaying log.',
            'Show balloon & hide log.',
            'Show balloon & displaying log.',
        }
        print(chat.header(addon.name):append(chat.message('Display mode changed: ')):append(chat.success(mode_desc[balloon.settings.display_mode + 1])))
        settings.save()
        return
    end

    -- Handle: /balloon reset
    if (#args >= 2 and args[2]:any('reset')) then
        if #args >= 3 and args[3]:any('pos', 'position') then
            print(chat.header(addon.name):append(chat.message('Resetting position')))
            balloon.settings.position.x = default_settings.position.x
            balloon.settings.position.y = default_settings.position.y
            settings.save()
            ui:position(balloon.settings.position.x, balloon.settings.position.y)
        else
            settings.reset()
        end
        return
    end

    -- Handle: /balloon theme
    if (#args >= 2 and args[2]:any('theme')) then
        if #args > 2 then
            local old_theme = balloon.settings.theme
            local old_theme_options = balloon.theme_options

            balloon.settings.theme = args[3]

            balloon.load_theme()
            if balloon.theme_options ~= nil then
                print(chat.header(addon.name):append(chat.message('Theme changed: ')):append(chat.success(balloon.settings.theme)))
            else
                -- Restore old settings
                balloon.theme_options = old_theme_options
                balloon.settings.theme = old_theme
            end

            settings.save()
        else
            print(chat.header(addon.name):append(chat.message('Theme: ')):append(chat.success(balloon.settings.theme)))
        end
        return
    end

    -- Handle numerical options
    -- Handle: /balloon scale
    -- Handle: /balloon delay
    -- Handle: /balloon speed
    if (#args >= 2 and args[2]:any('scale', 'delay', 'speed')) then
        local setting_key_alias = {
            delay = 'no_prompt_close_delay',
            speed = 'text_speed'
        }
        local setting_names = {
            no_prompt_close_delay = 'Promptless close delay',
            text_speed = 'Text speed',
            scale = 'Scale',
        }
        local setting_fmts = {
            no_prompt_close_delay = '%d',
            text_speed = '%d',
            scale = '%.2f',
        }
        local setting_key = setting_key_alias[args[2]] or args[2]
        local setting_name = setting_names[setting_key] or args[2]
        local setting_fmt = setting_fmts[setting_key] or args[2]

		if #args > 2 then
            local old_val = balloon.settings[setting_key]
			balloon.settings[setting_key] = tonumber(args[3]) or 0

            -- Some additional logic we need to run depending on the setting change
            if setting_key == 'scale' then
                ui:scale(balloon.settings.scale, balloon.settings.position)
            elseif setting_key == 'text_speed' then
                ui:text_speed(balloon.settings.text_speed)
            end

            print(chat.header(addon.name):append(chat.message('%s changed: '):format(setting_name)):append(chat.success('from ' .. setting_fmt .. ' to ' .. setting_fmt):format(old_val, balloon.settings[setting_key])))
            settings.save()
		else
			print(chat.header(addon.name):append(chat.message('%s: '):format(setting_name)):append(chat.success(setting_fmt):format(balloon.settings[setting_key])))
		end
        return
    end

    -- Handle toggle options
    -- Handle: /balloon portrait
    -- Handle: /balloon move_close
    -- Handle: /balloon always_on_top
    -- Handle: /balloon in_combat
    -- Handle: /balloon system
    -- Handle: /balloon cinematic
    -- Handle: /balloon fps
    if (#args == 2 and args[2]:any(
        'portrait', 'portraits',
        'move_closes', 'move_close',
        'always_on_top',
        'in_combat',
        'system', 'system_messages',
        'cinematic', 'cinema',
        'fps')
    ) then
        local setting_key_alias = {
            portrait = 'portraits',
            move_closes = 'move_close',
            cinema = 'cinematic',
            system = 'system_messages',
        }
        local setting_names = {
            portraits = 'Display portraits',
            move_close = 'Close balloons on player movement',
            always_on_top = 'Always on top (IMGUI mode)',
            in_combat = 'Display in combat',
            system_messages = 'Display for system messages',
            cinematic = 'Cinematic mode',
            fps = 'Control fps during cutscenes',
        }
        local setting_key = setting_key_alias[args[2]] or args[2]
        local setting_name = setting_names[setting_key] or args[2]

        local old_val = balloon.settings[setting_key]
        if setting_key == 'cinematic' and old_val and cinematic_ui.suspended then
            -- Slash suspends this event without changing the saved setting.
            -- The bare command should resume it, not toggle the setting off.
            balloon.settings[setting_key] = true
        else
            balloon.settings[setting_key] = not old_val
        end
        if setting_key == 'cinematic' then
            if balloon.settings.cinematic then balloon.rearm_cinematic() end
            balloon.update_cinematic_ui()
        end

        -- Some additional logic we need to run depending on the setting change
        if setting_key == 'portraits' then
            balloon.load_theme()
        elseif setting_key == 'system_messages' then
            balloon.load_chat_mode_settings()
        elseif setting_key == 'fps' then
            balloon.limit_fps(balloon.limit_fps_enabled)
        end

        print(chat.header(addon.name):append(chat.message('%s changed: '):format(setting_name)):append(chat.success(balloon.settings[setting_key] and 'on' or 'off')))
        settings.save()
        return
    end

    -- Handle: /balloon test
    if (#args >= 2 and args[2]:any('test')) then
        local test_name = args[3]

        if test_name == nil then
            local test_names = T{}
            for k, _ in pairs(tests) do
                table.insert(test_names, k)
            end
            print(chat.header(addon.name):append('Available tests: '):append(chat.success(test_names:join(', '))))
            return
        end

        local lang = args[4] or balloon.lang_code
        if lang == '-' then
            lang = balloon.lang_code
        end
        local lang_map = {
            en = 2,
            ja = 3,
        }
        local lang_index = lang_map[lang] or 2

        local test_entry = tests[test_name]
        if test_entry == nil then
            print(chat.header(addon.name):append(chat.error('Invalid test: %s'):format(test_name)))
            return
        end

        local npc_name = test_entry[1]
        print(chat.header(addon.name):append(chat.message('Test: %s (%s)'):format(test_name, lang)))
        local message = test_entry[lang_index]
        local mode = (args[5] == '2' or npc_name == '') and chat_modes.system or chat_modes.message
        local message_prefix = npc_name ~= '' and (npc_name .. ' : ') or ''
        balloon.process_balloon(message_prefix .. message, mode)
        return
    end

    -- Unhandled: Print help information..
    balloon.print_help(true)
end)

ashita.events.register('load', 'balloon_load', function()
    balloon.settings = settings.load(default_settings)
    balloon.last_frame_time = os.clock()

    -- Restore native access on reload, while honoring the saved preference.
    -- Hiding waits for a visible dialogue and an available advance path.
    helpers.set_game_interface_hidden(false)
    balloon.initialize()

    -- Register for settings updates
    settings.register('settings', 'balloon_settings_update', function(s)
        if (s ~= nil) then
            balloon.settings = s
            balloon.initialize(s)
        end
    end)
end)

ashita.events.register('unload', 'balloon_unload', function()
    exception_chat_route:restore()
    cinematic_ui:restore()
    balloon.sync_fancychat(false)
    helpers.set_game_interface_hidden(false)
    balloon.limit_fps(false)
    ui:destroy()
end)

ashita.events.register('packet_in', 'balloon_packet_in', function(e)
    if balloon.theme_options == nil then
        return
    end

	-- Check if player has left a conversation
    if e.id == defines.packets.inc.mog_menu then
        balloon.in_mog_menu = true
    elseif e.id == defines.packets.inc.zone_out then
        exception_chat_route:restore()
        balloon.last_known_target = nil
        balloon.last_native_message_hidden = false
		balloon.close()
    elseif e.id == defines.packets.inc.leave_conversation then
        if balloon.in_mog_menu then
            balloon.in_mog_menu = false
            return
        end
        local type = struct.unpack('b', e.data_modified, 0x04 + 1)
        -- LogManager:Log(5, 'Balloon', 'packets.inc.leave_conversation - type: ' .. tostring(type))
        if tonumber(type) == 0 then
            exception_chat_route:finish()
            if balloon.debug_closing then print('Closing from leave conversation: ' .. type) end
            balloon.close()
        end
	end
end)

ashita.events.register('packet_out', 'balloon_packet_out', function (e)
    if balloon.theme_options == nil then
        return
    end

    -- Route before the first server response, rather than changing the log mid-line.
    if e.id == defines.packets.out.action and not e.blocked then
        local data = e.data_modified or e.data
        if type(data) == 'string' and #data >= 12 then
            local category = struct.unpack('H', data, 0x0A + 1)
            local index = struct.unpack('H', data, 0x08 + 1)
            local target = tonumber(index) and GetEntity(tonumber(index)) or nil
            if tonumber(category) == 0 and target and balloon.is_ignored_target(target.Name) then
                exception_chat_route:start()
            end
        end
    end

    -- Check if player has left a conversation
    -- Since this is outgoing, this comes sooner than the incoming LEAVE_CONVERSATION_PACKET
	if e.id == defines.packets.out.dialogue_option then
        local in_menu = struct.unpack('H', e.data_modified, 0x0E + 1)
        local option_index = struct.unpack('H', e.data_modified, 0x08 + 1)

        if in_menu == 1 then
            balloon.in_menu = true
        else
            balloon.in_menu = false
            if option_index == 0 or option_index == 2 then --if option_index ~= 2 then -- 2 = selected a home point warp
                if balloon.debug_closing then print('Closing from dialogue option') end
                balloon.close()
            end
        end

        -- LogManager:Log(5, 'Balloon', 'packets.out.dialogue_option - option_index: ' .. tostring(option_index) .. ', in_menu: ' .. tostring(in_menu))
    elseif e.id == defines.packets.out.homepoint_map then
        -- User is viewing home point map
        balloon.close()
        -- We're still in the menu
        balloon.in_menu = true
    end
end)

ashita.events.register('text_in', 'balloon_text_in', function(e)
    if balloon.theme_options == nil then
        return
    end
    -- Ignore text in from Ashita addons/plugins
    if e.injected then
        return
    end

    if not balloon.processing_message then
        balloon.processing_message = true

        balloon.process_incoming_message(e)

        balloon.processing_message = false
    end
end)

ashita.events.register('d3d_beginscene', 'balloon_cinematic_beginscene', function()
    balloon.update_cinematic_ui()
end)

ashita.events.register('d3d_present', 'balloon_d3d_present', function()
    balloon.update_cinematic_ui()
    -- Calculate delta time for animations
    local frame_time = os.clock()
    local delta_time = frame_time - balloon.last_frame_time
    balloon.last_frame_time = frame_time

    if balloon.theme_options == nil then
        return
    end

    -- Don't display unless we have a player entity and we're not zoning
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local player_ent = GetPlayerEntity()
    if player == nil or player.isZoning or player_ent == nil then
		return
	end

    -- Check player's last target so we can ignore certain "cutscenes"
    local player_target = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
    local entity = GetEntity(tonumber(player_target))
    local last_known_target = entity and entity.Name or nil
    if last_known_target ~= nil and last_known_target ~= balloon.last_known_target then
        -- print('player_target entity: ' ..last_known_target)
        balloon.last_known_target = last_known_target
    end

    -- Handle movement closes balloon
    balloon.handle_player_movement(player_ent)
    -- Handle cinematics
    balloon.handle_cinematics(player_ent, delta_time)

    if not ui:hidden() and not helpers.is_quantity_input_open() then
        if balloon.settings.always_on_top then
            ui:render_imgui(delta_time)
        else
            ui:render(delta_time)
        end
    end
end)

ashita.events.register('mouse', 'balloon_mouse', function(e)
    -- Respect other input consumers. Never leave a captured gesture latched.
    if e.blocked then
        if e.message == defines.MOUSE_UP then
            balloon.drag_offset = nil
            balloon.mouse_advance_pending = nil
        end
        return
    end

    if balloon.release_quantity_input() then return end

    if e.message == defines.MOUSE_UP and balloon.mouse_advance_pending then
        balloon.mouse_advance_pending = nil
        e.blocked = true
        return
    end

    if balloon.drag_offset ~= nil then
        if e.message ~= 512 and e.message ~= defines.MOUSE_UP then return end
        local drag = balloon.drag_offset
        if ui:hidden() or helpers.is_chat_open() or helpers.is_dialog_option_open() then
            balloon.drag_offset = nil
            e.blocked = true
            return
        end

        local dx, dy = e.x - drag.x, e.y - drag.y
        drag.moved = drag.moved or (dx * dx + dy * dy >= 36)
        if drag.moved then
            local x, y = e.x + drag[1], e.y + drag[2]
            ui:position(x, y, true)
            if e.message == defines.MOUSE_UP then
                local w, h = ui:window_size()
                balloon.settings.position.x = x + w / 2
                balloon.settings.position.y = y + h / 2
                settings.save()
            end
        end

        if e.message == defines.MOUSE_UP then
            balloon.drag_offset = nil
            if not drag.moved and (helpers.is_event_system_active() or balloon.in_event or balloon.cutscene_ui_active) then
                -- The down edge was consumed by the balloon; invoke native advance
                -- once on release, including when the native chat is visible.
                balloon.handle_button_continue(e, true)
            end
        end
        e.blocked = true
        return
    end

    if e.message ~= defines.MOUSE_DOWN or helpers.is_chat_open() or
        helpers.is_dialog_option_open() then return end

    if not ui:hidden() then
        local x, y = ui:position()
        local w, h = ui:window_size()
        if e.x >= x and e.x <= x + w and e.y >= y and e.y <= y + h then
            -- Wait for real movement before treating a press as repositioning.
            balloon.drag_offset = {x - e.x, y - e.y, x = e.x, y = e.y, moved = false}
            e.blocked = true
            return
        end
    end

    -- Hidden native UI cannot process its own mouse confirm. Route clicks
    -- outside the balloon (and while Cancel has dismissed it) through the
    -- same guarded advance helper used by Enter/controller Confirm.
    if helpers.is_game_interface_hidden() and
        (helpers.is_event_system_active() or balloon.in_event or balloon.cutscene_ui_active) then
        balloon.handle_button_continue(e)
        if e.blocked then balloon.mouse_advance_pending = true end
    end
end)

ashita.events.register('key_data', 'balloon_key_data', function(e)
    -- DirectInput key codes http://www.flint.jp/misc/?q=dik
    if balloon.release_quantity_input() then return end
    if e.key == 0x01 and balloon.capture_cinematic_escape() then
        -- Escape dismisses the current balloon, like controller Cancel, but
        -- blocks both press and release so the game cannot flash Chat 1/2.
        if e.down then balloon.handle_button_cancel(e) end
        e.blocked = true
        return
    end
    if not e.down then return end
    if (e.key == 0x35 or e.key == 0xB5) and
        (helpers.is_game_interface_hidden() or cinematic_ui.owned or balloon.fancychat_hidden or
            (balloon.settings.cinematic and
                (balloon.cutscene_ui_active or balloon.in_event or helpers.is_event_system_active()))) then
        -- Restore first, then pass slash through so commands can be typed.
        balloon.dialogue_dismissed = false
        cinematic_ui:suspend()
        balloon.auto_hide_game_ui = false
        balloon.sync_fancychat(false, true)
        return
    end
    if e.key == 0x1C or e.key == 0x9C then
        balloon.handle_button_continue(e)
    end
end)

-- key_data blocks the initial DirectInput event; held keys are read through
-- GetDeviceState separately, so clear Escape there for the same cutscene.
ashita.events.register('key_state', 'balloon_key_state', function(e)
    if not balloon.capture_cinematic_escape() or e.data_raw == nil or
        (e.size ~= nil and e.size <= 0x01) then return end
    ffi.cast('uint8_t*', e.data_raw)[0x01] = 0
end)

-- The game's text-input path also receives Windows Escape messages.
ashita.events.register('key', 'balloon_key', function(e)
    if e.wparam == 0x1B and balloon.capture_cinematic_escape() then
        e.blocked = true
    end
end)

ashita.events.register('dinput_button', 'balloon_dinput_button', function(e)
    -- DirectInput starts at 48: button 2 (49) is this setup's X/Cancel.
    if e.button == 49 and e.state == 128 then
        balloon.handle_button_cancel(e, true)
    elseif defines.DINPUT_CONTROLLER_DISMISS[e.button] ~= nil and e.state == 128 then
        balloon.handle_button_continue(e)
    end
end)

ashita.events.register('xinput_button', 'balloon_xinput_button', function(e)
    if e.button == 13 and e.state == 1 then
        balloon.handle_button_cancel(e, true)
    elseif defines.XINPUT_CONTROLLER_DISMISS[e.button] ~= nil and e.state == 1 then
        balloon.handle_button_continue(e)
    end
end)
