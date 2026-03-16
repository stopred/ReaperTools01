local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*[\\/])") or ""

local ok, workflow = pcall(dofile, script_dir .. "GameAudioWorkflow_SHARED.lua")
if not ok then
  reaper.ShowMessageBox("Failed to load GameAudioWorkflow_SHARED.lua:\n\n" .. tostring(workflow), "Game Audio Workflow", 0)
  return
end

workflow.run_mousewheel_pitch()
