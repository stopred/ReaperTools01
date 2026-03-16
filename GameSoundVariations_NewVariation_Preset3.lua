local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*[\\/])") or ""

_G.__GAME_SOUND_VARIATIONS_HELPER__ = true
local ok, core = pcall(dofile, script_dir .. "GameSoundVariations.lua")
_G.__GAME_SOUND_VARIATIONS_HELPER__ = nil

if not ok then
  reaper.ShowMessageBox("Failed to load GameSoundVariations.lua:\n\n" .. tostring(core), "Sound Variation Generator", 0)
  return
end

core.run_preset_new_variation(3)
