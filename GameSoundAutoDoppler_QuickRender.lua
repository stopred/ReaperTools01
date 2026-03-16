local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*[\\/])") or ""

_G.__GAME_SOUND_AUTODOPPLER_HELPER__ = true
local ok, core = pcall(dofile, script_dir .. "GameSoundAutoDoppler.lua")
_G.__GAME_SOUND_AUTODOPPLER_HELPER__ = nil

if not ok then
  reaper.ShowMessageBox(
    "Failed to load GameSoundAutoDoppler.lua:\n\n" .. tostring(core),
    "Game Sound Auto Doppler",
    0
  )
  return
end

local settings = core.load_last_settings()
local render_ok, result_or_message = core.quick_render(settings)
if not render_ok then
  reaper.ShowMessageBox(tostring(result_or_message), core.SCRIPT_TITLE, 0)
end
