"""Offline LuaJIT regression checks; no FFXI process is accessed."""
from pathlib import Path
import re
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
lua = LuaRuntime(unpack_returned_tuples=True)
for path in ROOT.glob('*.lua'):
    # Upstream's visual sample file contains legacy Japanese bytes.
    lua.execute('assert(loadstring(...))', path.read_bytes())
lua.globals().Cinematic = lua.execute((ROOT / 'cinematic.lua').read_text(encoding='utf-8'))
lua.execute('''
    hidden, visible, typing, options, event_active = false, true, false, false, true
    advances, closes, fps = 0, 0, 1
    player, entity = {isZoning=false}, {StatusServer=4}
    helpers={
        is_game_interface_hidden=function() return hidden end,
        set_game_interface_hidden=function(value) hidden=value; return true end,
        is_event_system_active=function() return event_active end,
        is_dialog_option_open=function() return options end,
        is_chat_open=function() return typing end,
        is_user_camera_enabled=function() return false end,
        get_fps_divisor=function() return fps end,
        set_fps_divisor=function(value) fps=value end,
        stepdialog={available=true,run=function() advances=advances+1; return true end},
    }
    cinematic_ui=Cinematic.new(helpers)
    AshitaCore={GetMemoryManager=function() return {GetPlayer=function() return player end} end}
    GetPlayerEntity=function() return entity end
    ui={hidden=function() return not visible end}
    balloon={settings={cinematic=true,display_mode=2,control_fps=true},
        last_text='NPC: current page',last_mode=150,cinematic_ignore_targets={},
        in_event=true,limit_fps_enabled=false,limit_fps_restore=2,
        process_balloon=function() visible=true end,
        close=function() visible=false; closes=closes+1 end}
    saved=0
    settings={save=function() saved=saved+1 end}
    addon={name='balloon'}
    chat={header=function() return {append=function(self,text) return self end} end,
          message=function(text) return text end,success=function(text) return text end}
    print=function() end
    getmetatable('').__index.any=function(self,...)
        for _,v in ipairs({...}) do if self==v then return true end end return false
    end
    getmetatable('').__index.args=function(self)
        local words={}; for word in self:gmatch('%S+') do words[#words+1]=word end; return words
    end
    callbacks={}
    ashita={events={register=function(name,id,fn) callbacks[name]=fn end}}
''')
source = (ROOT / 'Balloon.lua').read_text(encoding='utf-8')
start = source.index('balloon.update_cinematic_ui = function()')
end = source.index('balloon.process_incoming_message = function(e)', start)
lua.execute(source[start:end])
start = source.index("ashita.events.register('command', 'balloon_command_cb'")
end = source.index("ashita.events.register('load', 'balloon_load'", start)
lua.execute(source[start:end])
start = source.index("ashita.events.register('key_data', 'balloon_key_data'")
lua.execute(source[start:])
lua.execute('''
    function command(text) callbacks.command({command=text}) end
    balloon.update_cinematic_ui(); assert(hidden)
    local e={}; balloon.handle_button_continue(e)
    assert(e.blocked and advances==1 and visible and closes==0)
    e={}; balloon.handle_button_continue(e); assert(e.blocked and advances==2)
    visible=false; e={}; balloon.handle_button_continue(e); assert(e.blocked and advances==3)
    visible=true
    for i=1,4 do
        callbacks.key_data({down=true,key=0x01})
        assert(not hidden and not visible and cinematic_ui.suspended)
        typing=true; command('/balloon cinematic on')
        assert(not hidden and visible and not cinematic_ui.suspended)
        typing=false; balloon.update_cinematic_ui(); assert(hidden)
    end
    local slash={down=true,key=0x35}; callbacks.key_data(slash)
    assert(not hidden and not slash.blocked and cinematic_ui.suspended)
    balloon.update_cinematic_ui(); assert(not hidden)
    command('/bl cinematic on'); assert(hidden)
    options=true; balloon.update_cinematic_ui(); assert(not hidden)
    e={}; balloon.handle_button_continue(e); assert(not e.blocked and advances==3)
    options=false; balloon.update_cinematic_ui(); assert(hidden)
    hidden=false; balloon.update_cinematic_ui(); assert(hidden)
    typing=true; balloon.update_cinematic_ui(); assert(not hidden)
    typing=false; balloon.update_cinematic_ui(); assert(hidden)
    command('/balloon cinematic off'); assert(not hidden and not balloon.settings.cinematic)
    command('/balloon cinematic'); assert(hidden and balloon.settings.cinematic)
    helpers.stepdialog.run=function() return false end
    balloon.handle_button_continue({}); assert(not hidden and cinematic_ui.suspended)
    balloon.update_cinematic_ui(); assert(not hidden)
    command('/balloon cinematic on'); assert(hidden and not cinematic_ui.suspended)
    helpers.stepdialog.available=false; balloon.update_cinematic_ui(); assert(not hidden)
    helpers.stepdialog.available=true; balloon.update_cinematic_ui(); assert(hidden)
    command('/balloon 0'); assert(not hidden)
    command('/balloon 2'); assert(hidden)
    command('/balloon status')
    player.isZoning=true; balloon.update_cinematic_ui(); assert(not hidden)
    player.isZoning=false; balloon.update_cinematic_ui(); assert(hidden)
    event_active=false; entity.StatusServer=0; balloon.update_cinematic_ui(); assert(not hidden)
    event_active=true; balloon.update_cinematic_ui(); assert(hidden)
    cinematic_ui:restore(); assert(not hidden)
    -- Preserve an independently hidden native UI after the event ends.
    hidden=true; balloon.update_cinematic_ui()
    options=true; balloon.update_cinematic_ui(); assert(not hidden)
    event_active=false; balloon.update_cinematic_ui(); assert(hidden)
    options=false; hidden=false
    -- Verify the inherited FPS alias actually changes and applies its setting.
    balloon.limit_fps(true); assert(fps==2)
    command('/balloon fps'); assert(not balloon.settings.control_fps and fps==1)
    command('/balloon control_fps'); assert(balloon.settings.control_fps)
''')
assert 'imgui.SetNextWindowFocus()' not in (ROOT / 'ui.lua').read_text(encoding='utf-8')
assert 'text:bold(text_options.bold)' in (ROOT / 'ui.lua').read_text(encoding='utf-8')
assert 'balloon.settings.cinematic = false' not in source
assert 'not balloon.settings.system_messages then' in source
print('PASS: LuaJIT syntax and cinematic/input regressions, repeated re-enable, native restoration, settings, FPS alias and inherited font support.')
