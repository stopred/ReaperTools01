-- Game Sound Auto Doppler v1.0
-- Reaper ReaScript (Lua)
-- Automatic Doppler pass-by builder using RMS peak detection.
--
-- Usage:
-- 1. Select one or more items, or select track(s)/folder track(s).
-- 2. Optionally define a time selection to limit the batch.
-- 3. Run this script and adjust the Doppler controls.
-- 4. Use Apply to write automation, Render to print to a new take.
--
-- Doppler components in phase 2:
--   Pitch   - take Playrate envelope with ReaPitch fallback
--   Volume  - take Volume envelope
--   Filter  - managed ReaEQ low-pass automation
--   Pan     - take Pan envelope
--   Peak    - snap offset or RMS peak detection
--
-- Requirements: REAPER v7.0+

local SCRIPT_TITLE = "Game Sound Auto Doppler v1.0"
local EXT_SECTION = "GameSoundAutoDoppler"
local HELPER_BOOTSTRAP_FLAG = "__GAME_SOUND_AUTODOPPLER_HELPER__"
local SETTINGS_VERSION = 4
local NEG_INF_DB = -150.0
local WINDOW_W = 820
local WINDOW_H = 960
local WINDOW_PADDING = 18
local BUTTON_H = 32
local SLIDER_W = 300
local ACTIVE_CONTROL_NONE = ""
local PRESET_SLOT_COUNT = 5

local HAS_IMGUI = false
local ImGui = nil

if reaper.ImGui_GetBuiltinPath then
  local ok, library = pcall(function()
    package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
    return require("imgui")("0.9")
  end)
  if ok and library then
    HAS_IMGUI = true
    ImGui = library
  end
end

local TAKE_EXT_APPLIED = "P_EXT:GameSoundAutoDopplerApplied"
local TAKE_EXT_PLAYRATE_BACKUP = "P_EXT:GameSoundAutoDopplerPlayrateBackup"
local TAKE_EXT_VOLUME_BACKUP = "P_EXT:GameSoundAutoDopplerVolumeBackup"
local TAKE_EXT_PAN_BACKUP = "P_EXT:GameSoundAutoDopplerPanBackup"
local TAKE_EXT_PRESERVE_PITCH = "P_EXT:GameSoundAutoDopplerPreservePitch"
local TAKE_EXT_PITCH_ENGINE = "P_EXT:GameSoundAutoDopplerPitchEngine"
local TAKE_EXT_REAPITCH_GUID = "P_EXT:GameSoundAutoDopplerReaPitchGUID"
local TAKE_EXT_REAEQ_GUID = "P_EXT:GameSoundAutoDopplerReaEQGUID"
local TAKE_EXT_PEAK_SOURCE = "P_EXT:GameSoundAutoDopplerPeakSource"
local ITEM_EXT_TRACKFX_BACKUP = "P_EXT:GameSoundAutoDopplerTrackFXBackup"
local ITEM_EXT_SNAPOFFSET_BACKUP = "P_EXT:GameSoundAutoDopplerSnapOffsetBackup"

math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
math.random()
math.random()
math.random()

local M = {}

local DEFAULTS = {
  pitch_enabled = true,
  speed = 0.50,
  intensity = 0.30,
  volume_enabled = true,
  volume_range = 12.0,
  distance = 0.30,
  peak_detection = true,
  use_snap_offsets = true,
  auto_set_snap_offset = true,
  offset = 0.0,
  direction = 1,
  randomize = false,
  randomize_amount = 0.20,
  pitch_engine = "auto",
  analysis_window_sec = 0.05,
  analysis_hop_sec = 0.01,
  point_density = 36,
  unlink_playrate = false,
  playrate_curve = 1.0,
  lpf_enabled = false,
  lpf_min_freq = 2000.0,
  lpf_max_freq = 20000.0,
  pan_enabled = false,
  pan_width = 0.8,
  selected_plugin = "builtin",
  write_fx_params = false,
  fallback_to_builtin = true,
  split_takes_after_render = false,
}

local function safe_imgui_symbol(name)
  if not ImGui then
    return nil
  end

  local symbol = nil
  local ok = pcall(function()
    symbol = ImGui[name]
  end)
  if not ok then
    return nil
  end
  return symbol
end

local PLUGIN_ORDER = {
  "builtin",
  "waves_doppler",
  "sp_doppler",
  "grm_doppler",
}

local PLUGIN_LABELS = {
  builtin = "Built-in (ReaEQ + Playrate)",
  waves_doppler = "Waves Doppler",
  sp_doppler = "Sound Particles Doppler",
  grm_doppler = "GRM Doppler",
}

local SUPPORTED_PLUGINS = {
  waves_doppler = {
    fx_name_patterns = { "doppler", "wave" },
    param_keywords = {
      track_time = { "track time" },
      center_time = { "center time", "time to peak", "center" },
      pitch = { "pitch" },
      gain = { "gain" },
      pan = { "pan" },
      air_damp = { "air damp", "airdamp", "air" },
    },
  },
  sp_doppler = {
    fx_name_patterns = { "doppler", "particle" },
    param_keywords = {
      source_speed = { "source speed", "velocity", "speed" },
      acceleration = { "acceleration", "accel" },
      distance_attenuation = { "distance attenuation", "dist att", "attenuation" },
      microphone_distance = { "microphone distance", "mic distance", "distance" },
      mic_rotation = { "mic rotation", "rotation" },
      time_to_peak = { "time to peak", "peak" },
    },
  },
  grm_doppler = {
    fx_name_patterns = { "doppler", "grm" },
    param_keywords = {
      time = { "time", "delay", "center" },
      pitch = { "pitch", "shift" },
      gain = { "gain", "level", "distance" },
      pan = { "pan", "stereo", "width" },
      damp = { "damp", "filter", "tone", "air" },
    },
  },
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function clear_console()
  if reaper.ClearConsole then
    reaper.ClearConsole()
  end
end

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
end

local function split_delimited(text, separator)
  local parts = {}
  local source = tostring(text or "")
  local start_index = 1

  while true do
    local found_index = source:find(separator, start_index, true)
    if not found_index then
      parts[#parts + 1] = source:sub(start_index)
      break
    end

    parts[#parts + 1] = source:sub(start_index, found_index - 1)
    start_index = found_index + #separator
  end

  return parts
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deep_copy(child)
  end
  return copy
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function round_to(value, decimals)
  local power = 10 ^ (decimals or 0)
  if value >= 0 then
    return math.floor(value * power + 0.5) / power
  end
  return math.ceil(value * power - 0.5) / power
end

local function log10(value)
  return math.log(value) / math.log(10)
end

local function db_to_linear(db_value)
  return 10 ^ ((tonumber(db_value) or 0.0) / 20.0)
end

local function linear_to_db(linear_value)
  local safe = math.max(math.abs(tonumber(linear_value) or 0.0), 1e-12)
  return 20.0 * log10(safe)
end

local function parse_boolean(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on" or lowered == "y" then
    return true
  end
  if lowered == "0" or lowered == "false" or lowered == "no" or lowered == "off" or lowered == "n" then
    return false
  end
  return default_value
end

local function bool_to_string(value)
  return value and "1" or "0"
end

local function format_seconds(value)
  return string.format("%.3fs", tonumber(value) or 0.0)
end

local function format_db(value)
  if not value or value <= NEG_INF_DB + 0.5 then
    return "-inf"
  end
  return string.format("%.1f dB", value)
end

local function format_percent01(value)
  return string.format("%.0f%%", clamp((tonumber(value) or 0.0) * 100.0, 0.0, 100.0))
end

local function show_error(message)
  local text = tostring(message or "Unknown error.")
  reaper.ShowMessageBox(text, SCRIPT_TITLE, 0)
end

local function get_take_ext_string(take, key)
  local ok, value = reaper.GetSetMediaItemTakeInfo_String(take, key, "", false)
  if not ok then
    return ""
  end
  return value or ""
end

local function set_take_ext_string(take, key, value)
  reaper.GetSetMediaItemTakeInfo_String(take, key, tostring(value or ""), true)
end

local function clear_take_ext_string(take, key)
  reaper.GetSetMediaItemTakeInfo_String(take, key, "", true)
end

local function get_item_ext_string(item, key)
  local ok, value = reaper.GetSetMediaItemInfo_String(item, key, "", false)
  if not ok then
    return ""
  end
  return value or ""
end

local function set_item_ext_string(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, key, tostring(value or ""), true)
end

local function clear_item_ext_string(item, key)
  reaper.GetSetMediaItemInfo_String(item, key, "", true)
end

local function serialize_settings(settings)
  local values = {
    tostring(SETTINGS_VERSION),
    bool_to_string(settings.pitch_enabled),
    string.format("%.6f", tonumber(settings.speed) or DEFAULTS.speed),
    string.format("%.6f", tonumber(settings.intensity) or DEFAULTS.intensity),
    bool_to_string(settings.volume_enabled),
    string.format("%.6f", tonumber(settings.volume_range) or DEFAULTS.volume_range),
    string.format("%.6f", tonumber(settings.distance) or DEFAULTS.distance),
    bool_to_string(settings.peak_detection),
    bool_to_string(settings.use_snap_offsets),
    bool_to_string(settings.auto_set_snap_offset),
    string.format("%.6f", tonumber(settings.offset) or DEFAULTS.offset),
    tostring(settings.direction == -1 and -1 or 1),
    bool_to_string(settings.randomize),
    string.format("%.6f", tonumber(settings.randomize_amount) or DEFAULTS.randomize_amount),
    tostring(settings.pitch_engine or DEFAULTS.pitch_engine),
    string.format("%.6f", tonumber(settings.analysis_window_sec) or DEFAULTS.analysis_window_sec),
    string.format("%.6f", tonumber(settings.analysis_hop_sec) or DEFAULTS.analysis_hop_sec),
    tostring(math.floor((tonumber(settings.point_density) or DEFAULTS.point_density) + 0.5)),
    bool_to_string(settings.unlink_playrate),
    string.format("%.6f", tonumber(settings.playrate_curve) or DEFAULTS.playrate_curve),
    bool_to_string(settings.lpf_enabled),
    string.format("%.6f", tonumber(settings.lpf_min_freq) or DEFAULTS.lpf_min_freq),
    string.format("%.6f", tonumber(settings.lpf_max_freq) or DEFAULTS.lpf_max_freq),
    bool_to_string(settings.pan_enabled),
    string.format("%.6f", tonumber(settings.pan_width) or DEFAULTS.pan_width),
    tostring(settings.selected_plugin or DEFAULTS.selected_plugin),
    bool_to_string(settings.write_fx_params),
    bool_to_string(settings.fallback_to_builtin),
    bool_to_string(settings.split_takes_after_render),
  }

  return table.concat(values, "|")
end

local function deserialize_settings(serialized)
  local settings = deep_copy(DEFAULTS)
  if not serialized or serialized == "" then
    return settings
  end

  local parts = split_delimited(serialized, "|")
  local version = tonumber(parts[1]) or 1
  local index = 2

  if version >= 1 then
    settings.pitch_enabled = parse_boolean(parts[index], settings.pitch_enabled)
    index = index + 1
    settings.speed = clamp(tonumber(parts[index]) or settings.speed, 0.0, 1.0)
    index = index + 1
    settings.intensity = clamp(tonumber(parts[index]) or settings.intensity, 0.0, 1.0)
    index = index + 1
    settings.volume_enabled = parse_boolean(parts[index], settings.volume_enabled)
    index = index + 1
    settings.volume_range = clamp(tonumber(parts[index]) or settings.volume_range, 0.0, 24.0)
    index = index + 1
    settings.distance = clamp(tonumber(parts[index]) or settings.distance, 0.02, 1.0)
    index = index + 1
    settings.peak_detection = parse_boolean(parts[index], settings.peak_detection)
    index = index + 1
    settings.use_snap_offsets = parse_boolean(parts[index], settings.use_snap_offsets)
    index = index + 1
    settings.auto_set_snap_offset = parse_boolean(parts[index], settings.auto_set_snap_offset)
    index = index + 1
    settings.offset = tonumber(parts[index]) or settings.offset
    index = index + 1
    settings.direction = tonumber(parts[index]) == -1 and -1 or 1
    index = index + 1
    settings.randomize = parse_boolean(parts[index], settings.randomize)
    index = index + 1
    settings.randomize_amount = clamp(tonumber(parts[index]) or settings.randomize_amount, 0.0, 1.0)
    index = index + 1
    settings.pitch_engine = trim_string(parts[index]) ~= "" and trim_string(parts[index]) or settings.pitch_engine
    index = index + 1
    settings.analysis_window_sec = clamp(tonumber(parts[index]) or settings.analysis_window_sec, 0.01, 0.25)
    index = index + 1
    settings.analysis_hop_sec = clamp(tonumber(parts[index]) or settings.analysis_hop_sec, 0.005, 0.1)
    index = index + 1
    settings.point_density = clamp(math.floor((tonumber(parts[index]) or settings.point_density) + 0.5), 12, 96)
    index = index + 1
    settings.unlink_playrate = parse_boolean(parts[index], settings.unlink_playrate)
    index = index + 1
    settings.playrate_curve = clamp(tonumber(parts[index]) or settings.playrate_curve, 0.25, 3.0)
    index = index + 1
  end

  if version >= 2 then
    settings.lpf_enabled = parse_boolean(parts[index], settings.lpf_enabled)
    index = index + 1
    settings.lpf_min_freq = clamp(tonumber(parts[index]) or settings.lpf_min_freq, 200.0, 24000.0)
    index = index + 1
    settings.lpf_max_freq = clamp(tonumber(parts[index]) or settings.lpf_max_freq, settings.lpf_min_freq, 24000.0)
    index = index + 1
    settings.pan_enabled = parse_boolean(parts[index], settings.pan_enabled)
    index = index + 1
    settings.pan_width = clamp(tonumber(parts[index]) or settings.pan_width, 0.0, 1.0)
    index = index + 1
    if version >= 4 then
      settings.selected_plugin = trim_string(parts[index]) ~= "" and trim_string(parts[index]) or settings.selected_plugin
      index = index + 1
      settings.write_fx_params = parse_boolean(parts[index], settings.write_fx_params)
      index = index + 1
      settings.fallback_to_builtin = parse_boolean(parts[index], settings.fallback_to_builtin)
      index = index + 1
    end
    settings.split_takes_after_render = parse_boolean(parts[index], settings.split_takes_after_render)
  end

  if version >= 3 then
    settings.direction = tonumber(settings.direction) == -1 and -1 or 1
  end

  return settings
end

function M.clone_settings(settings)
  return deep_copy(settings or DEFAULTS)
end

function M.load_last_settings()
  return deserialize_settings(reaper.GetExtState(EXT_SECTION, "LastSettings"))
end

function M.save_last_settings(settings)
  reaper.SetExtState(EXT_SECTION, "LastSettings", serialize_settings(settings or DEFAULTS), true)
end

local function get_preset_key(slot)
  return string.format("Preset%d", clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT))
end

local function get_selected_preset_slot()
  local slot = tonumber(reaper.GetExtState(EXT_SECTION, "SelectedPreset")) or 1
  return clamp(math.floor(slot + 0.5), 1, PRESET_SLOT_COUNT)
end

local function set_selected_preset_slot(slot)
  reaper.SetExtState(EXT_SECTION, "SelectedPreset", tostring(clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)), true)
end

local function save_preset(slot, settings)
  reaper.SetExtState(EXT_SECTION, get_preset_key(slot), serialize_settings(settings or DEFAULTS), true)
  set_selected_preset_slot(slot)
end

local function load_preset(slot)
  local serialized = reaper.GetExtState(EXT_SECTION, get_preset_key(slot))
  if serialized == nil or serialized == "" then
    return nil
  end
  set_selected_preset_slot(slot)
  return deserialize_settings(serialized)
end

local function preset_exists(slot)
  local serialized = reaper.GetExtState(EXT_SECTION, get_preset_key(slot))
  return serialized ~= nil and serialized ~= ""
end

local function cycle_plugin_mode(current_value)
  local current_index = 1
  for index = 1, #PLUGIN_ORDER do
    if PLUGIN_ORDER[index] == current_value then
      current_index = index
      break
    end
  end
  current_index = current_index + 1
  if current_index > #PLUGIN_ORDER then
    current_index = 1
  end
  return PLUGIN_ORDER[current_index]
end

local function random_symmetric(max_abs)
  local amount = tonumber(max_abs) or 0.0
  if amount <= 0.0 then
    return 0.0
  end
  return (math.random() * 2.0 - 1.0) * amount
end

local function randomize_settings(settings, amount)
  local random_amount = clamp(tonumber(amount) or 0.0, 0.0, 1.0)
  local copy = deep_copy(settings)
  copy.speed = clamp(copy.speed + random_symmetric(0.20 * random_amount), 0.0, 1.0)
  copy.intensity = clamp(copy.intensity + random_symmetric(0.20 * random_amount), 0.0, 1.0)
  copy.volume_range = clamp(copy.volume_range + random_symmetric(6.0 * random_amount), 0.0, 24.0)
  copy.distance = clamp(copy.distance + random_symmetric(0.18 * random_amount), 0.02, 1.0)
  copy.pan_width = clamp(copy.pan_width + random_symmetric(0.20 * random_amount), 0.0, 1.0)
  copy.lpf_min_freq = clamp(copy.lpf_min_freq + random_symmetric(3000.0 * random_amount), 200.0, 22000.0)
  copy.lpf_max_freq = clamp(copy.lpf_max_freq + random_symmetric(4000.0 * random_amount), copy.lpf_min_freq + 500.0, 24000.0)

  if copy.use_snap_offsets then
    copy.offset = clamp(copy.offset + random_symmetric(0.25 * random_amount), -1.0, 1.0)
  else
    copy.offset = clamp(copy.offset + random_symmetric(0.18 * random_amount), -0.5, 0.5)
  end

  return copy
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function set_color_rgba(r, g, b, a)
  gfx.set(r / 255.0, g / 255.0, b / 255.0, (a or 255) / 255.0)
end

local function draw_rect(x, y, w, h, filled, r, g, b, a)
  set_color_rgba(r, g, b, a)
  gfx.rect(x, y, w, h, filled and 1 or 0)
end

local function draw_text(text, x, y, r, g, b, a, font, size)
  gfx.setfont(1, font or "Segoe UI", size or 14)
  set_color_rgba(r, g, b, a)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function draw_text_right(text, right_x, y, r, g, b, a, font, size)
  local content = tostring(text or "")
  gfx.setfont(1, font or "Segoe UI", size or 14)
  local text_w = gfx.measurestr(content)
  draw_text(content, right_x - text_w, y, r, g, b, a, font, size)
end

local function has_mouse_cap(mask)
  return math.floor((gfx.mouse_cap or 0) / mask) % 2 == 1
end

local function get_take_name_safe(take)
  if not take then
    return "Untitled"
  end

  local ok, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if ok and trim_string(take_name) ~= "" then
    return trim_string(take_name)
  end

  return "Untitled"
end

local function get_item_name(item)
  local take = reaper.GetActiveTake(item)
  return get_take_name_safe(take)
end

local function get_active_audio_take(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return nil
  end
  return take
end

local function get_time_selection()
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if start_time == end_time then
    return nil
  end
  return start_time, end_time
end

local function get_child_tracks(folder_track)
  local children = {}
  if not folder_track then
    return children
  end

  local folder_index = math.floor(reaper.GetMediaTrackInfo_Value(folder_track, "IP_TRACKNUMBER")) - 1
  if folder_index < 0 then
    return children
  end

  local track_count = reaper.CountTracks(0)
  local depth = 1
  for track_index = folder_index + 1, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    if not track then
      break
    end

    children[#children + 1] = track
    depth = depth + math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
    if depth <= 0 then
      break
    end
  end

  return children
end

local function track_is_folder(track)
  return track and math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")) == 1
end

local function remove_outliers(values)
  if #values <= 2 then
    return values
  end

  local copy = {}
  for index = 1, #values do
    copy[index] = values[index]
  end

  table.sort(copy)
  local q1_index = math.floor((#copy - 1) * 0.25) + 1
  local q3_index = math.floor((#copy - 1) * 0.75) + 1
  local q1 = copy[q1_index]
  local q3 = copy[q3_index]
  local iqr = q3 - q1
  local lower = q1 - 1.5 * iqr
  local upper = q3 + 1.5 * iqr
  local filtered = {}

  for index = 1, #copy do
    local value = copy[index]
    if value >= lower and value <= upper then
      filtered[#filtered + 1] = value
    end
  end

  if #filtered == 0 then
    return copy
  end
  return filtered
end

local function apply_peak_offset(base_peak, item_length, offset_value, use_snap_offsets)
  if use_snap_offsets then
    return clamp(base_peak + (tonumber(offset_value) or 0.0), 0.0, item_length)
  end
  return clamp(base_peak + (item_length * (tonumber(offset_value) or 0.0)), 0.0, item_length)
end

local function get_target_point_count(item_length, settings)
  local density = clamp(math.floor((tonumber(settings.point_density) or DEFAULTS.point_density) + 0.5), 12, 96)
  local length_based = math.floor((math.max(item_length, 0.1) / 0.03) + 0.5)
  return clamp(math.max(density, length_based), 16, 96)
end

local function get_item_relative_peak_ratio(item_length, peak_time)
  if item_length <= 0 then
    return 0.5
  end
  return clamp(peak_time / item_length, 0.02, 0.98)
end

local function get_normalized_position(t, peak_ratio)
  if t <= peak_ratio then
    return (t - peak_ratio) / math.max(peak_ratio, 1e-6)
  end
  return (t - peak_ratio) / math.max(1.0 - peak_ratio, 1e-6)
end

local function generate_pitch_points(item_length, peak_time, settings)
  local points = {}
  local point_count = get_target_point_count(item_length, settings)
  local peak_ratio = get_item_relative_peak_ratio(item_length, peak_time)
  local curve_scale = settings.unlink_playrate and clamp(settings.playrate_curve, 0.25, 3.0) or 1.0
  local steepness = (2.0 + (settings.speed * 10.0)) * curve_scale
  local max_pitch_shift = settings.intensity * 12.0

  for point_index = 0, point_count do
    local t = point_index / point_count
    local time = t * item_length
    local normalized = get_normalized_position(t, peak_ratio)
    local semitones = -max_pitch_shift * math.tanh(normalized * steepness)
    points[#points + 1] = {
      time = time,
      semitones = semitones,
      playrate = 2 ^ (semitones / 12.0),
    }
  end

  return points
end

local function generate_volume_points(item_length, peak_time, settings)
  local points = {}
  local point_count = get_target_point_count(item_length, settings)
  local peak_ratio = get_item_relative_peak_ratio(item_length, peak_time)
  local min_distance = math.max(settings.distance, 0.02)

  for point_index = 0, point_count do
    local t = point_index / point_count
    local time = t * item_length
    local normalized = math.abs(get_normalized_position(t, peak_ratio))
    local attenuation = 1.0 / (1.0 + ((normalized / min_distance) ^ 2))
    local volume_db = settings.volume_range * (attenuation - 1.0)
    points[#points + 1] = {
      time = time,
      volume = db_to_linear(volume_db),
      volume_db = volume_db,
    }
  end

  return points
end

local function generate_pan_points(item_length, settings)
  local points = {}
  local point_count = get_target_point_count(item_length, settings)
  local direction = settings.direction == -1 and -1 or 1

  for point_index = 0, point_count do
    local t = point_index / point_count
    local time = t * item_length
    local pan = clamp((t * 2.0 - 1.0) * settings.pan_width * direction, -1.0, 1.0)
    points[#points + 1] = {
      time = time,
      pan = pan,
    }
  end

  return points
end

local function frequency_to_reaeq_normalized(freq)
  local clamped = clamp(tonumber(freq) or 20000.0, 20.0, 24000.0)
  return math.log(clamped / 20.0) / math.log(24000.0 / 20.0)
end

local function generate_lpf_points(item_length, peak_time, settings)
  local points = {}
  local point_count = get_target_point_count(item_length, settings)
  local peak_ratio = get_item_relative_peak_ratio(item_length, peak_time)
  local min_freq = clamp(settings.lpf_min_freq, 20.0, 22000.0)
  local max_freq = clamp(settings.lpf_max_freq, min_freq, 24000.0)

  for point_index = 0, point_count do
    local t = point_index / point_count
    local time = t * item_length
    local normalized = math.abs(get_normalized_position(t, peak_ratio))
    local freq = max_freq - ((max_freq - min_freq) * normalized)
    points[#points + 1] = {
      time = time,
      freq = freq,
      normalized = frequency_to_reaeq_normalized(freq),
    }
  end

  return points
end

local function generate_custom_param_points(item, peak_time, settings)
  local points = {}
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local point_count = get_target_point_count(item_length, settings)
  local peak_ratio = get_item_relative_peak_ratio(item_length, peak_time)
  local min_distance = math.max(settings.distance, 0.02)

  for point_index = 0, point_count do
    local t = point_index / point_count
    local normalized = math.abs(get_normalized_position(t, peak_ratio))
    local value = 1.0 / (1.0 + ((normalized / min_distance) ^ 2))
    points[#points + 1] = {
      time = item_position + (t * item_length),
      normalized = clamp(value, 0.0, 1.0),
    }
  end

  return points
end

local function serialize_envelope_points(envelope, start_time, end_time)
  if not envelope then
    return ""
  end

  local point_count = reaper.CountEnvelopePoints(envelope)
  if point_count <= 0 then
    return ""
  end

  local parts = {}
  for point_index = 0, point_count - 1 do
    local ok, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, point_index)
    if ok and time >= (start_time - 1e-9) and time <= (end_time + 1e-9) then
      parts[#parts + 1] = string.format(
        "%.10f,%.10f,%d,%.10f,%d",
        time,
        value,
        shape or 0,
        tension or 0.0,
        selected and 1 or 0
      )
    end
  end

  return table.concat(parts, ";")
end

local function restore_envelope_points(envelope, serialized, start_time, end_time)
  if not envelope then
    return
  end

  reaper.DeleteEnvelopePointRange(envelope, start_time, end_time)
  if not serialized or serialized == "" then
    return
  end

  for entry in string.gmatch(serialized, "[^;]+") do
    local fields = split_delimited(entry, ",")
    local time = tonumber(fields[1])
    local value = tonumber(fields[2])
    local shape = tonumber(fields[3]) or 0
    local tension = tonumber(fields[4]) or 0.0
    local selected = tonumber(fields[5]) == 1

    if time and value then
      reaper.InsertEnvelopePoint(envelope, time, value, shape, tension, selected, true)
    end
  end

  reaper.Envelope_SortPoints(envelope)
end

local function find_take_fx_by_guid(take, guid)
  if not take or trim_string(guid) == "" then
    return -1
  end

  local fx_count = reaper.TakeFX_GetCount(take)
  for fx_index = 0, fx_count - 1 do
    local fx_guid = reaper.TakeFX_GetFXGUID(take, fx_index)
    if fx_guid == guid then
      return fx_index
    end
  end

  return -1
end

local function find_track_by_guid(track_guid)
  if trim_string(track_guid) == "" then
    return nil
  end

  local master_track = reaper.GetMasterTrack(0)
  if master_track and reaper.GetTrackGUID(master_track) == track_guid then
    return master_track
  end

  local track_count = reaper.CountTracks(0)
  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    if track and reaper.GetTrackGUID(track) == track_guid then
      return track
    end
  end

  return nil
end

local function find_track_fx_by_guid(track, guid)
  if not track or trim_string(guid) == "" then
    return -1
  end

  local fx_count = reaper.TrackFX_GetCount(track)
  for fx_index = 0, fx_count - 1 do
    local fx_guid = reaper.TrackFX_GetFXGUID(track, fx_index)
    if fx_guid == guid then
      return fx_index
    end
  end

  return -1
end

local function remove_managed_reapitch(take)
  local fx_guid = get_take_ext_string(take, TAKE_EXT_REAPITCH_GUID)
  if fx_guid == "" then
    return
  end

  local fx_index = find_take_fx_by_guid(take, fx_guid)
  if fx_index >= 0 then
    reaper.TakeFX_Delete(take, fx_index)
  end
  clear_take_ext_string(take, TAKE_EXT_REAPITCH_GUID)
end

local function remove_managed_reaeq(take)
  local fx_guid = get_take_ext_string(take, TAKE_EXT_REAEQ_GUID)
  if fx_guid == "" then
    return
  end

  local fx_index = find_take_fx_by_guid(take, fx_guid)
  if fx_index >= 0 then
    reaper.TakeFX_Delete(take, fx_index)
  end
  clear_take_ext_string(take, TAKE_EXT_REAEQ_GUID)
end

local function backup_take_state_if_needed(item, take, item_length)
  if get_take_ext_string(take, TAKE_EXT_APPLIED) == "1" then
    return
  end

  local playrate_env = reaper.GetTakeEnvelopeByName(take, "Playrate")
  local volume_env = reaper.GetTakeEnvelopeByName(take, "Volume")
  local pan_env = reaper.GetTakeEnvelopeByName(take, "Pan")
  set_take_ext_string(take, TAKE_EXT_PLAYRATE_BACKUP, serialize_envelope_points(playrate_env, -1.0, item_length + 1.0))
  set_take_ext_string(take, TAKE_EXT_VOLUME_BACKUP, serialize_envelope_points(volume_env, -1.0, item_length + 1.0))
  set_take_ext_string(take, TAKE_EXT_PAN_BACKUP, serialize_envelope_points(pan_env, -1.0, item_length + 1.0))
  set_take_ext_string(
    take,
    TAKE_EXT_PRESERVE_PITCH,
    tostring(math.floor((reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH") or 0.0) + 0.5))
  )
  set_item_ext_string(item, ITEM_EXT_SNAPOFFSET_BACKUP, string.format("%.10f", reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET") or 0.0))
end

local function clear_current_doppler_take_state(take, item_length)
  local playrate_env = reaper.GetTakeEnvelopeByName(take, "Playrate")
  local volume_env = reaper.GetTakeEnvelopeByName(take, "Volume")
  local pan_env = reaper.GetTakeEnvelopeByName(take, "Pan")

  if playrate_env then
    reaper.DeleteEnvelopePointRange(playrate_env, -1.0, item_length + 1.0)
    reaper.Envelope_SortPoints(playrate_env)
  end
  if volume_env then
    reaper.DeleteEnvelopePointRange(volume_env, -1.0, item_length + 1.0)
    reaper.Envelope_SortPoints(volume_env)
  end
  if pan_env then
    reaper.DeleteEnvelopePointRange(pan_env, -1.0, item_length + 1.0)
    reaper.Envelope_SortPoints(pan_env)
  end

  local original_preserve_pitch = tonumber(get_take_ext_string(take, TAKE_EXT_PRESERVE_PITCH))
  if original_preserve_pitch ~= nil then
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", original_preserve_pitch > 0 and 1 or 0)
  end

  remove_managed_reapitch(take)
  remove_managed_reaeq(take)
end

local function restore_take_state(item, take, item_length)
  local playrate_env = reaper.GetTakeEnvelopeByName(take, "Playrate")
  local volume_env = reaper.GetTakeEnvelopeByName(take, "Volume")
  local pan_env = reaper.GetTakeEnvelopeByName(take, "Pan")
  local playrate_backup = get_take_ext_string(take, TAKE_EXT_PLAYRATE_BACKUP)
  local volume_backup = get_take_ext_string(take, TAKE_EXT_VOLUME_BACKUP)
  local pan_backup = get_take_ext_string(take, TAKE_EXT_PAN_BACKUP)
  local preserve_pitch = tonumber(get_take_ext_string(take, TAKE_EXT_PRESERVE_PITCH))
  local snap_offset_backup = tonumber(get_item_ext_string(item, ITEM_EXT_SNAPOFFSET_BACKUP))

  restore_envelope_points(playrate_env, playrate_backup, -1.0, item_length + 1.0)
  restore_envelope_points(volume_env, volume_backup, -1.0, item_length + 1.0)
  restore_envelope_points(pan_env, pan_backup, -1.0, item_length + 1.0)

  if preserve_pitch ~= nil then
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preserve_pitch > 0 and 1 or 0)
  end
  if snap_offset_backup ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", snap_offset_backup)
  end

  remove_managed_reapitch(take)
  remove_managed_reaeq(take)

  clear_take_ext_string(take, TAKE_EXT_APPLIED)
  clear_take_ext_string(take, TAKE_EXT_PLAYRATE_BACKUP)
  clear_take_ext_string(take, TAKE_EXT_VOLUME_BACKUP)
  clear_take_ext_string(take, TAKE_EXT_PAN_BACKUP)
  clear_take_ext_string(take, TAKE_EXT_PRESERVE_PITCH)
  clear_take_ext_string(take, TAKE_EXT_PITCH_ENGINE)
  clear_take_ext_string(take, TAKE_EXT_REAEQ_GUID)
  clear_take_ext_string(take, TAKE_EXT_PEAK_SOURCE)
  clear_item_ext_string(item, ITEM_EXT_SNAPOFFSET_BACKUP)
end

local function write_scaled_take_envelope(take, envelope_name, item_length, points, raw_key)
  local envelope = reaper.GetTakeEnvelopeByName(take, envelope_name)
  if not envelope then
    return false, envelope_name .. " take envelope is unavailable."
  end

  local scale_mode = reaper.GetEnvelopeScalingMode(envelope)
  reaper.DeleteEnvelopePointRange(envelope, -1.0, item_length + 1.0)

  for index = 1, #points do
    local point = points[index]
    local raw_value = point[raw_key]
    local scaled = reaper.ScaleToEnvelopeMode(scale_mode, raw_value)
    reaper.InsertEnvelopePoint(envelope, point.time, scaled, 0, 0.0, false, true)
  end

  reaper.Envelope_SortPoints(envelope)
  return true
end

local function ensure_managed_reaeq(take)
  local existing_guid = get_take_ext_string(take, TAKE_EXT_REAEQ_GUID)
  if existing_guid ~= "" then
    local existing_index = find_take_fx_by_guid(take, existing_guid)
    if existing_index >= 0 then
      return existing_index
    end
  end

  local candidates = {
    "ReaEQ",
    "VST3: ReaEQ (Cockos)",
    "VST: ReaEQ (Cockos)",
  }

  for index = 1, #candidates do
    local fx_index = reaper.TakeFX_AddByName(take, candidates[index], -1)
    if fx_index >= 0 then
      set_take_ext_string(take, TAKE_EXT_REAEQ_GUID, reaper.TakeFX_GetFXGUID(take, fx_index) or "")
      return fx_index
    end
  end

  return -1
end

local function find_reaeq_param_index(take, fx_index, keyword, band_hint)
  local best_index = -1
  local best_score = -100000
  local param_count = reaper.TakeFX_GetNumParams(take, fx_index)

  for param_index = 0, param_count - 1 do
    local _, param_name = reaper.TakeFX_GetParamName(take, fx_index, param_index, "")
    local lowered = tostring(param_name or ""):lower()
    local score = -1000

    if lowered:find(keyword, 1, true) then
      score = 100
      if band_hint and lowered:find(band_hint, 1, true) then
        score = score + 50
      end
      if lowered:find("band 1", 1, true) or lowered:find("1 ", 1, true) or lowered:find("1:", 1, true) then
        score = score + 30
      end
      if lowered:find("wet", 1, true) or lowered:find("dry", 1, true) then
        score = score - 100
      end
    end

    if score > best_score then
      best_score = score
      best_index = param_index
    end
  end

  if best_score < 100 then
    return -1
  end
  return best_index
end

local function find_formatted_param_normalized_value(take, fx_index, param_index, text_fragment)
  local lowered_fragment = tostring(text_fragment or ""):lower()
  local step_size = nil
  if reaper.TakeFX_GetParameterStepSizes then
    local _, detected_step = reaper.TakeFX_GetParameterStepSizes(take, fx_index, param_index)
    step_size = detected_step
  end
  local divisions = 64
  if not reaper.TakeFX_FormatParamValueNormalized then
    return nil
  end

  if step_size and step_size > 0.0 then
    divisions = math.max(8, math.floor((1.0 / step_size) + 0.5))
  end

  for step = 0, divisions do
    local normalized = step / divisions
    local _, display = reaper.TakeFX_FormatParamValueNormalized(take, fx_index, param_index, normalized, "")
    local lowered = tostring(display or ""):lower()
    if lowered:find(lowered_fragment, 1, true) then
      return normalized
    end
  end

  return nil
end

local function configure_managed_reaeq_lpf(take, fx_index)
  local type_param = find_reaeq_param_index(take, fx_index, "type", "band 1")
  local freq_param = find_reaeq_param_index(take, fx_index, "freq", "band 1")
  if type_param < 0 or freq_param < 0 then
    return false, "ReaEQ band 1 parameters could not be identified."
  end

  local low_pass_normalized = find_formatted_param_normalized_value(take, fx_index, type_param, "low pass")
  if low_pass_normalized == nil then
    low_pass_normalized = find_formatted_param_normalized_value(take, fx_index, type_param, "low-pass")
  end
  if low_pass_normalized ~= nil then
    reaper.TakeFX_SetParamNormalized(take, fx_index, type_param, low_pass_normalized)
  else
    local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, type_param)
    if maximum and maximum >= 8.0 then
      reaper.TakeFX_SetParam(take, fx_index, type_param, clamp(8.0, minimum or 0.0, maximum))
    else
      reaper.TakeFX_SetParamNormalized(take, fx_index, type_param, 1.0)
    end
  end

  reaper.TakeFX_SetParamNormalized(take, fx_index, freq_param, 1.0)
  return true, {
    type_param = type_param,
    freq_param = freq_param,
  }
end

local function param_value_to_normalized(take, fx_index, param_index, raw_value)
  local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, param_index)
  if maximum == minimum then
    return 0.5
  end
  return clamp((raw_value - minimum) / (maximum - minimum), 0.0, 1.0)
end

local function ensure_managed_reapitch(take)
  local existing_guid = get_take_ext_string(take, TAKE_EXT_REAPITCH_GUID)
  if existing_guid ~= "" then
    local existing_index = find_take_fx_by_guid(take, existing_guid)
    if existing_index >= 0 then
      return existing_index
    end
  end

  local candidates = {
    "ReaPitch",
    "VST3: ReaPitch (Cockos)",
    "VST: ReaPitch (Cockos)",
  }

  for index = 1, #candidates do
    local fx_index = reaper.TakeFX_AddByName(take, candidates[index], -1)
    if fx_index >= 0 then
      set_take_ext_string(take, TAKE_EXT_REAPITCH_GUID, reaper.TakeFX_GetFXGUID(take, fx_index) or "")
      return fx_index
    end
  end

  return -1
end

local function find_reapitch_shift_param(take, fx_index)
  local best_index = -1
  local best_score = -100000
  local param_count = reaper.TakeFX_GetNumParams(take, fx_index)

  for param_index = 0, param_count - 1 do
    local _, param_name = reaper.TakeFX_GetParamName(take, fx_index, param_index, "")
    local lowered = tostring(param_name or ""):lower()
    local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, param_index)
    local range = (maximum or 0.0) - (minimum or 0.0)
    local score = -1000

    if lowered:find("shift", 1, true) then
      score = 100
      if lowered:find("semi", 1, true) then
        score = score + 50
      end
      if lowered:find("range", 1, true) then
        score = score + 20
      end
      if minimum <= 0.0 and maximum >= 0.0 then
        score = score + 20
      end
      score = score + math.min(range, 200.0)
    end

    if score > best_score then
      best_score = score
      best_index = param_index
    end
  end

  if best_score < 100 then
    return -1
  end
  return best_index
end

local function tune_reapitch_defaults(take, fx_index)
  local param_count = reaper.TakeFX_GetNumParams(take, fx_index)

  for param_index = 0, param_count - 1 do
    local _, param_name = reaper.TakeFX_GetParamName(take, fx_index, param_index, "")
    local lowered = tostring(param_name or ""):lower()
    local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, param_index)

    if lowered:find("dry", 1, true) then
      reaper.TakeFX_SetParam(take, fx_index, param_index, minimum)
    elseif lowered:find("wet", 1, true) and minimum <= 0.0 and maximum >= 0.0 then
      reaper.TakeFX_SetParam(take, fx_index, param_index, 0.0)
    end
  end
end

local function write_playrate_pitch(take, item_length, points)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
  return write_scaled_take_envelope(take, "Playrate", item_length, points, "playrate")
end

local function write_reapitch_pitch(take, item_length, points)
  local fx_index = ensure_managed_reapitch(take)
  if fx_index < 0 then
    return false, "ReaPitch is unavailable, and Playrate envelope could not be used."
  end

  tune_reapitch_defaults(take, fx_index)

  local param_index = find_reapitch_shift_param(take, fx_index)
  if param_index < 0 then
    return false, "ReaPitch shift parameter could not be identified."
  end

  local envelope = reaper.TakeFX_GetEnvelope(take, fx_index, param_index, true)
  if not envelope then
    return false, "Unable to create a ReaPitch automation envelope."
  end

  reaper.DeleteEnvelopePointRange(envelope, -1.0, item_length + 1.0)

  for index = 1, #points do
    local point = points[index]
    local normalized = param_value_to_normalized(take, fx_index, param_index, point.semitones)
    reaper.InsertEnvelopePoint(envelope, point.time, normalized, 0, 0.0, false, true)
  end

  reaper.Envelope_SortPoints(envelope)
  return true
end

local function write_reaeq_lpf(take, item_length, points)
  local fx_index = ensure_managed_reaeq(take)
  if fx_index < 0 then
    return false, "ReaEQ is unavailable."
  end

  local ok, data_or_message = configure_managed_reaeq_lpf(take, fx_index)
  if not ok then
    return false, data_or_message
  end

  local freq_param = data_or_message.freq_param
  local envelope = reaper.TakeFX_GetEnvelope(take, fx_index, freq_param, true)
  if not envelope then
    return false, "Unable to create a ReaEQ frequency automation envelope."
  end

  reaper.DeleteEnvelopePointRange(envelope, -1.0, item_length + 1.0)
  for index = 1, #points do
    local point = points[index]
    reaper.InsertEnvelopePoint(envelope, point.time, point.normalized, 0, 0.0, false, true)
  end
  reaper.Envelope_SortPoints(envelope)
  return true
end

local function detect_rms_peak(item, settings)
  local take = get_active_audio_take(item)
  if not take then
    return nil, nil, "center"
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil, nil, "center"
  end

  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  if sample_rate <= 0 then
    sample_rate = 44100
  end

  local channels = math.max(1, reaper.GetMediaSourceNumChannels(source))
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if item_length <= 0 then
    return nil, nil, "center"
  end

  local window_sec = clamp(math.min(settings.analysis_window_sec, item_length), 0.01, math.max(item_length, 0.01))
  local hop_sec = clamp(math.min(settings.analysis_hop_sec, window_sec), 0.005, window_sec)
  local samples_per_window = math.max(1, math.floor((window_sec * sample_rate) + 0.5))
  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    return nil, nil, "center"
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local accessor_start = math.max(item_position, reaper.GetAudioAccessorStartTime(accessor))
  local accessor_end = math.min(item_position + item_length, reaper.GetAudioAccessorEndTime(accessor))
  if accessor_end <= accessor_start then
    accessor_start = item_position
    accessor_end = item_position + item_length
  end

  local buffer = reaper.new_array(samples_per_window * channels)
  local best_rms = -1.0
  local best_peak_time = item_length * 0.5
  local position = accessor_start
  local done = false

  while not done do
    local remaining = accessor_end - position
    local block_duration = math.min(window_sec, remaining)
    local sample_count = math.max(1, math.floor((block_duration * sample_rate) + 0.5))
    buffer.clear()
    local ok = reaper.GetAudioAccessorSamples(accessor, sample_rate, channels, position, sample_count, buffer)

    if ok ~= 1 and ok ~= true then
      break
    end

    local total = sample_count * channels
    local sum_sq = 0.0
    for sample_index = 1, total do
      local sample = buffer[sample_index] or 0.0
      sum_sq = sum_sq + (sample * sample)
    end

    local rms = math.sqrt(sum_sq / math.max(total, 1))
    if rms > best_rms then
      best_rms = rms
      best_peak_time = clamp((position - item_position) + (block_duration * 0.5), 0.0, item_length)
    end

    if (position + hop_sec + 1e-9) >= accessor_end then
      done = true
    else
      position = position + hop_sec
    end
  end

  reaper.DestroyAudioAccessor(accessor)

  if best_rms < 0.0 then
    return item_length * 0.5, nil, "center"
  end

  return best_peak_time, best_rms, "rms"
end

local function resolve_item_peak(item, settings, absolute_folder_peak)
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

  if absolute_folder_peak then
    return clamp(absolute_folder_peak - item_position, 0.0, item_length), nil, "folder"
  end

  local snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
  if settings.use_snap_offsets and snap_offset > 0.0 and snap_offset < item_length then
    return snap_offset, nil, "snap"
  end

  if settings.peak_detection then
    local peak_time, rms, source = detect_rms_peak(item, settings)
    if peak_time then
      if settings.auto_set_snap_offset then
        reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", peak_time)
      end
      return peak_time, rms, source
    end
  end

  return item_length * 0.5, nil, "center"
end

local function get_folder_peak_absolute(track, settings)
  local candidates = {}
  local tracks = { track }
  local children = get_child_tracks(track)

  for index = 1, #children do
    tracks[#tracks + 1] = children[index]
  end

  for track_index = 1, #tracks do
    local child_track = tracks[track_index]
    local item_count = reaper.CountTrackMediaItems(child_track)
    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(child_track, item_index)
      local peak_time = resolve_item_peak(item, settings, nil)
      local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      candidates[#candidates + 1] = item_position + peak_time
    end
  end

  if #candidates == 0 then
    return nil
  end

  local filtered = remove_outliers(candidates)
  local sum = 0.0
  for index = 1, #filtered do
    sum = sum + filtered[index]
  end

  return sum / #filtered
end

local function add_target(targets, seen, item, folder_peak_absolute)
  if not item then
    return
  end

  local key = tostring(item)
  if seen[key] then
    return
  end

  seen[key] = true
  targets[#targets + 1] = {
    item = item,
    folder_peak_absolute = folder_peak_absolute,
  }
end

local function add_track_targets(track, targets, seen, settings)
  if not track then
    return
  end

  local related_tracks = { track }
  local folder_peak_absolute = nil

  if track_is_folder(track) then
    local children = get_child_tracks(track)
    for index = 1, #children do
      related_tracks[#related_tracks + 1] = children[index]
    end
    folder_peak_absolute = get_folder_peak_absolute(track, settings)
  end

  for track_index = 1, #related_tracks do
    local source_track = related_tracks[track_index]
    local item_count = reaper.CountTrackMediaItems(source_track)
    for item_index = 0, item_count - 1 do
      add_target(targets, seen, reaper.GetTrackMediaItem(source_track, item_index), folder_peak_absolute)
    end
  end
end

local function filter_targets_by_time_selection(targets)
  local selection_start, selection_end = get_time_selection()
  if not selection_start then
    return targets
  end

  local filtered = {}
  for index = 1, #targets do
    local target = targets[index]
    local item = target.item
    local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = item_position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_position < selection_end and item_end > selection_start then
      filtered[#filtered + 1] = target
    end
  end

  return filtered
end

local function get_target_items(settings)
  local targets = {}
  local seen = {}
  local selected_item_count = reaper.CountSelectedMediaItems(0)

  if selected_item_count > 0 then
    for item_index = 0, selected_item_count - 1 do
      add_target(targets, seen, reaper.GetSelectedMediaItem(0, item_index), nil)
    end
    return filter_targets_by_time_selection(targets)
  end

  local selected_track_count = reaper.CountSelectedTracks(0)
  for track_index = 0, selected_track_count - 1 do
    add_track_targets(reaper.GetSelectedTrack(0, track_index), targets, seen, settings)
  end

  return filter_targets_by_time_selection(targets)
end

local function summarize_selection()
  local selected_item_count = reaper.CountSelectedMediaItems(0)
  if selected_item_count > 0 then
    return string.format("%d selected item(s)", selected_item_count)
  end

  local selected_track_count = reaper.CountSelectedTracks(0)
  if selected_track_count > 0 then
    return string.format("%d selected track(s) / folder(s)", selected_track_count)
  end

  return "No target items selected."
end

local backup_track_fx_actions_if_needed
local restore_track_fx_backups
local build_plugin_track_fx_actions

local function apply_item_doppler(target, settings)
  local item = target.item
  local take = get_active_audio_take(item)
  if not take then
    return false, "Item has no active audio take."
  end

  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if item_length <= 0.0 then
    return false, "Item length is zero."
  end

  backup_take_state_if_needed(item, take, item_length)
  clear_current_doppler_take_state(take, item_length)

  local item_settings = settings.randomize and randomize_settings(settings, settings.randomize_amount) or settings
  local base_peak, peak_rms, peak_source = resolve_item_peak(item, item_settings, target.folder_peak_absolute)
  local peak_time = apply_peak_offset(base_peak, item_length, item_settings.offset, item_settings.use_snap_offsets)
  local pitch_engine = "none"
  local lpf_written = false
  local pan_written = false
  local track_fx_written = false
  local plugin_note = nil
  local pitch_points = (item_settings.pitch_enabled or item_settings.write_fx_params) and generate_pitch_points(item_length, peak_time, item_settings) or nil
  local volume_points = (item_settings.volume_enabled or item_settings.write_fx_params) and generate_volume_points(item_length, peak_time, item_settings) or nil
  local pan_points = (item_settings.pan_enabled or item_settings.write_fx_params) and generate_pan_points(item_length, item_settings) or nil
  local lpf_points = (item_settings.lpf_enabled or item_settings.write_fx_params) and generate_lpf_points(item_length, peak_time, item_settings) or nil
  local builtin_enabled = item_settings.pitch_enabled or item_settings.volume_enabled or item_settings.lpf_enabled or item_settings.pan_enabled
  local plugin_actions = {}

  if item_settings.write_fx_params and item_settings.selected_plugin ~= "builtin" then
    local actions, message = build_plugin_track_fx_actions(item, item_settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
    if actions == nil or #actions == 0 then
      if not builtin_enabled or item_settings.fallback_to_builtin == false then
        return false, message or "Mapped Doppler plugin parameters were not found."
      end
      plugin_note = message
    else
      plugin_actions = actions
    end
  end

  if not builtin_enabled and #plugin_actions == 0 then
    return false, "No Doppler engines are enabled."
  end

  if item_settings.pitch_enabled then
    local pitch_ok, pitch_message = write_playrate_pitch(take, item_length, pitch_points)
    if pitch_ok then
      pitch_engine = "playrate"
    else
      pitch_ok, pitch_message = write_reapitch_pitch(take, item_length, pitch_points)
      if pitch_ok then
        pitch_engine = "reapitch"
      else
        return false, pitch_message
      end
    end
  end

  if item_settings.volume_enabled then
    local volume_ok, volume_message = write_scaled_take_envelope(take, "Volume", item_length, volume_points, "volume")
    if not volume_ok then
      return false, volume_message
    end
  end

  if item_settings.lpf_enabled then
    local lpf_ok, lpf_message = write_reaeq_lpf(take, item_length, lpf_points)
    if not lpf_ok then
      return false, lpf_message
    end
    lpf_written = true
  end

  if item_settings.pan_enabled then
    local pan_ok, pan_message = write_scaled_take_envelope(take, "Pan", item_length, pan_points, "pan")
    if not pan_ok then
      return false, pan_message
    end
    pan_written = true
  end

  if #plugin_actions > 0 then
    backup_track_fx_actions_if_needed(item, plugin_actions)
    local plugin_ok, plugin_message = apply_track_fx_actions(plugin_actions)
    if not plugin_ok then
      return false, plugin_message
    end
    track_fx_written = true
  end

  set_take_ext_string(take, TAKE_EXT_APPLIED, "1")
  set_take_ext_string(take, TAKE_EXT_PITCH_ENGINE, pitch_engine)
  set_take_ext_string(take, TAKE_EXT_PEAK_SOURCE, peak_source)

  return true, {
    peak_time = peak_time,
    peak_rms = peak_rms,
    pitch_engine = pitch_engine,
    peak_source = peak_source,
    lpf_written = lpf_written,
    pan_written = pan_written,
    track_fx_written = track_fx_written,
    plugin_note = plugin_note,
  }
end

local function remove_item_doppler(target)
  local item = target.item
  local take = get_active_audio_take(item)
  if not take then
    return false, "Item has no active audio take."
  end

  if get_take_ext_string(take, TAKE_EXT_APPLIED) ~= "1" then
    return false, "Item was not processed by Auto Doppler."
  end

  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  restore_take_state(item, take, item_length)
  restore_track_fx_backups(item)
  return true, { removed = true }
end

local function log_item_result(index, total_count, item, ok, details_or_message)
  local item_name = get_item_name(item)
  if ok then
    local details = details_or_message or {}
    if details.removed then
      log_line(string.format("[%d/%d] %s - removed", index, total_count, item_name))
      return
    end
    local rms_text = details.peak_rms and string.format(" rms %s", format_db(linear_to_db(details.peak_rms))) or ""
    local extras = {}
    if details.lpf_written then
      extras[#extras + 1] = "lpf"
    end
    if details.pan_written then
      extras[#extras + 1] = "pan"
    end
    if details.track_fx_written then
      extras[#extras + 1] = "fx"
    end
    local extra_text = #extras > 0 and (" [" .. table.concat(extras, ", ") .. "]") or ""
    local plugin_note = details.plugin_note and (" (" .. details.plugin_note .. ")") or ""
    log_line(string.format(
      "[%d/%d] %s - peak @ %s via %s, pitch=%s%s%s%s",
      index,
      total_count,
      item_name,
      format_seconds(details.peak_time),
      tostring(details.peak_source or "center"),
      tostring(details.pitch_engine or "none"),
      rms_text,
      extra_text,
      plugin_note
    ))
  else
    log_line(string.format("[%d/%d] %s - skipped: %s", index, total_count, item_name, tostring(details_or_message)))
  end
end

local function process_targets(targets, settings, options)
  if #targets == 0 then
    return false, "Select item(s) or track(s) first."
  end

  options = options or {}
  local action_name = options.undo_name or "Auto Doppler"
  local operation = options.operation or apply_item_doppler
  local clear_console_before = options.clear_console_before ~= false
  local successful = 0
  local failed = 0
  local results = {}

  if clear_console_before then
    clear_console()
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for index = 1, #targets do
    local target = targets[index]
    local ok, details_or_message = operation(target, settings)
    if ok then
      successful = successful + 1
      results[#results + 1] = { item = target.item, details = details_or_message }
    else
      failed = failed + 1
    end
    log_item_result(index, #targets, target.item, ok, details_or_message)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(action_name, -1)

  return true, {
    total = #targets,
    successful = successful,
    failed = failed,
    results = results,
    targets = targets,
  }
end

function M.process_selection(settings)
  local resolved_settings = deep_copy(settings or M.load_last_settings())
  M.save_last_settings(resolved_settings)
  local targets = get_target_items(resolved_settings)
  return process_targets(targets, resolved_settings, {
    undo_name = "Auto Doppler - Apply",
    operation = apply_item_doppler,
  })
end

function M.remove_selection(settings)
  local targets = get_target_items(settings or DEFAULTS)
  return process_targets(targets, settings or DEFAULTS, {
    undo_name = "Auto Doppler - Remove",
    operation = remove_item_doppler,
  })
end

local function capture_selected_items()
  local items = {}
  local item_count = reaper.CountSelectedMediaItems(0)
  for item_index = 0, item_count - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, item_index)
  end
  return items
end

local function restore_selected_items(items)
  reaper.SelectAllMediaItems(0, false)
  for index = 1, #items do
    local item = items[index]
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
  reaper.UpdateArrange()
end

local function select_target_items(targets)
  reaper.SelectAllMediaItems(0, false)
  for index = 1, #targets do
    local item = targets[index].item
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
  reaper.UpdateArrange()
end

local function split_rendered_items_at_boundaries(targets)
  local boundaries_by_track = {}
  local split_count = 0

  for index = 1, #targets do
    local item = targets[index].item
    local track = reaper.GetMediaItem_Track(item)
    local track_key = tostring(track)
    local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = item_position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    boundaries_by_track[track_key] = boundaries_by_track[track_key] or { track = track, points = {} }
    local point_list = boundaries_by_track[track_key].points
    point_list[#point_list + 1] = item_position
    point_list[#point_list + 1] = item_end
  end

  local selected_count = reaper.CountSelectedMediaItems(0)
  for item_index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, item_index)
    local track = reaper.GetMediaItem_Track(item)
    local track_info = boundaries_by_track[tostring(track)]
    if track_info then
      table.sort(track_info.points, function(left, right)
        return left > right
      end)

      local current_item = item
      for point_index = 1, #track_info.points do
        local split_point = track_info.points[point_index]
        local item_position = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION")
        local item_end = item_position + reaper.GetMediaItemInfo_Value(current_item, "D_LENGTH")
        if split_point > (item_position + 0.0005) and split_point < (item_end - 0.0005) then
          local new_item = reaper.SplitMediaItem(current_item, split_point)
          if new_item then
            split_count = split_count + 1
          end
        end
      end
    end
  end

  return split_count
end

function M.quick_render(settings)
  local ok, result_or_message = M.process_selection(settings)
  if not ok then
    return false, result_or_message
  end

  local summary = result_or_message
  if summary.successful <= 0 then
    return false, "No items were processed."
  end

  local previous_selection = capture_selected_items()
  select_target_items(summary.targets)
  reaper.Main_OnCommand(40209, 0)
  if settings and settings.split_takes_after_render then
    split_rendered_items_at_boundaries(summary.targets)
  end
  restore_selected_items(previous_selection)

  return true, summary
end

local function write_track_fx_param_points(track, fx_index, param_index, points, clear_start, clear_end)
  local envelope = reaper.GetFXEnvelope(track, fx_index, param_index, true)
  if not envelope then
    return false, "Unable to create the target FX parameter envelope."
  end

  reaper.DeleteEnvelopePointRange(envelope, clear_start, clear_end)
  for index = 1, #points do
    local point = points[index]
    reaper.InsertEnvelopePoint(envelope, point.time, point.normalized, 0, 0.0, false, true)
  end

  reaper.Envelope_SortPoints(envelope)
  return true
end

local function make_track_fx_backup_line(track_guid, fx_guid, param_index, start_time, end_time, serialized_points)
  return table.concat({
    "env",
    track_guid,
    fx_guid,
    tostring(param_index),
    string.format("%.10f", start_time),
    string.format("%.10f", end_time),
    serialized_points or "",
  }, "\t")
end

local function build_track_fx_action(track, fx_index, param_index, start_time, end_time, points)
  return {
    track = track,
    fx_index = fx_index,
    param_index = param_index,
    start_time = start_time,
    end_time = end_time,
    points = points,
  }
end

backup_track_fx_actions_if_needed = function(item, actions)
  if get_item_ext_string(item, ITEM_EXT_TRACKFX_BACKUP) ~= "" then
    return
  end

  local lines = {}
  local seen = {}

  for index = 1, #actions do
    local action = actions[index]
    local track = action.track
    if track then
      local track_guid = reaper.GetTrackGUID(track)
      local fx_guid = reaper.TrackFX_GetFXGUID(track, action.fx_index)
      local key = table.concat({ track_guid, fx_guid, tostring(action.param_index), string.format("%.4f", action.start_time), string.format("%.4f", action.end_time) }, "|")
      if not seen[key] then
        local envelope = reaper.GetFXEnvelope(track, action.fx_index, action.param_index, true)
        local serialized = serialize_envelope_points(envelope, action.start_time, action.end_time)
        lines[#lines + 1] = make_track_fx_backup_line(track_guid, fx_guid, action.param_index, action.start_time, action.end_time, serialized)
        seen[key] = true
      end
    end
  end

  if #lines > 0 then
    set_item_ext_string(item, ITEM_EXT_TRACKFX_BACKUP, table.concat(lines, "\n"))
  end
end

local function apply_track_fx_actions(actions)
  for index = 1, #actions do
    local action = actions[index]
    local ok, message = write_track_fx_param_points(
      action.track,
      action.fx_index,
      action.param_index,
      action.points,
      action.start_time,
      action.end_time
    )
    if not ok then
      return false, message
    end
  end

  return true
end

restore_track_fx_backups = function(item)
  local serialized = get_item_ext_string(item, ITEM_EXT_TRACKFX_BACKUP)
  if serialized == "" then
    return
  end

  for line in serialized:gmatch("[^\r\n]+") do
    local fields = split_delimited(line, "\t")
    if fields[1] == "env" then
      local track = find_track_by_guid(fields[2] or "")
      if track then
        local fx_index = find_track_fx_by_guid(track, fields[3] or "")
        local param_index = tonumber(fields[4])
        local start_time = tonumber(fields[5]) or 0.0
        local end_time = tonumber(fields[6]) or 0.0
        if fx_index and fx_index >= 0 and param_index then
          local envelope = reaper.GetFXEnvelope(track, fx_index, param_index, true)
          restore_envelope_points(envelope, fields[7] or "", start_time, end_time)
        end
      end
    end
  end

  clear_item_ext_string(item, ITEM_EXT_TRACKFX_BACKUP)
end

local function text_contains_all_patterns(text, patterns)
  local lowered = tostring(text or ""):lower()
  for index = 1, #(patterns or {}) do
    if not lowered:find(patterns[index], 1, true) then
      return false
    end
  end
  return true
end

local function find_supported_plugin_fx(track, plugin_key)
  local plugin = SUPPORTED_PLUGINS[plugin_key]
  if not plugin or not track then
    return -1
  end

  local fx_count = reaper.TrackFX_GetCount(track)
  for fx_index = 0, fx_count - 1 do
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    if text_contains_all_patterns(fx_name, plugin.fx_name_patterns) then
      return fx_index
    end
  end

  return -1
end

local function find_track_fx_param_by_keywords(track, fx_index, keywords)
  if not track or fx_index < 0 or not keywords or #keywords == 0 then
    return -1
  end

  local best_index = -1
  local best_score = -100000
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)

  for param_index = 0, param_count - 1 do
    local _, param_name = reaper.TrackFX_GetParamName(track, fx_index, param_index, "")
    local lowered = tostring(param_name or ""):lower()
    local score = -1000

    for keyword_index = 1, #keywords do
      local keyword = keywords[keyword_index]
      if lowered:find(keyword, 1, true) then
        score = math.max(score, 100 + (#keyword * 3))
      end
    end

    if score > best_score then
      best_score = score
      best_index = param_index
    end
  end

  if best_score < 100 then
    return -1
  end
  return best_index
end

local function track_param_value_to_normalized(track, fx_index, param_index, raw_value)
  local _, minimum, maximum = reaper.TrackFX_GetParamEx(track, fx_index, param_index)
  if maximum == minimum then
    return 0.5
  end
  return clamp((raw_value - minimum) / (maximum - minimum), 0.0, 1.0)
end

local function make_absolute_curve_points(item_position, relative_points, value_fn)
  local points = {}
  for index = 1, #relative_points do
    local point = relative_points[index]
    points[#points + 1] = {
      time = item_position + point.time,
      normalized = clamp(value_fn(point), 0.0, 1.0),
    }
  end
  return points
end

local function make_constant_curve_points(start_time, end_time, normalized_value)
  local clamped = clamp(normalized_value, 0.0, 1.0)
  return {
    { time = start_time, normalized = clamped },
    { time = end_time, normalized = clamped },
  }
end

local function build_constant_param_action(track, fx_index, param_index, start_time, end_time, raw_value)
  local normalized = track_param_value_to_normalized(track, fx_index, param_index, raw_value)
  return build_track_fx_action(track, fx_index, param_index, start_time, end_time, make_constant_curve_points(start_time, end_time, normalized))
end

local function push_action_if_param(actions, track, fx_index, param_index, start_time, end_time, points)
  if param_index >= 0 and points and #points > 0 then
    actions[#actions + 1] = build_track_fx_action(track, fx_index, param_index, start_time, end_time, points)
  end
end

local function build_waves_doppler_actions(item, settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
  local track = reaper.GetMediaItem_Track(item)
  local fx_index = find_supported_plugin_fx(track, "waves_doppler")
  if fx_index < 0 then
    return nil, "Waves Doppler was not found on the item's track."
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_position + item_length
  local plugin = SUPPORTED_PLUGINS.waves_doppler
  local actions = {}

  local track_time_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.track_time)
  local center_time_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.center_time)
  local pitch_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.pitch)
  local gain_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.gain)
  local pan_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.pan)
  local air_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.air_damp)

  if track_time_param >= 0 then
    actions[#actions + 1] = build_constant_param_action(track, fx_index, track_time_param, item_position, item_end, item_length)
  end
  if center_time_param >= 0 then
    actions[#actions + 1] = build_constant_param_action(track, fx_index, center_time_param, item_position, item_end, peak_time)
  end
  if pitch_param >= 0 then
    local normalized = clamp(settings.intensity, 0.0, 1.0)
    push_action_if_param(actions, track, fx_index, pitch_param, item_position, item_end, make_constant_curve_points(item_position, item_end, normalized))
  end
  if gain_param >= 0 and volume_points then
    push_action_if_param(actions, track, fx_index, gain_param, item_position, item_end, make_absolute_curve_points(item_position, volume_points, function(point)
      return clamp(point.volume, 0.0, 1.0)
    end))
  end
  if pan_param >= 0 and pan_points then
    push_action_if_param(actions, track, fx_index, pan_param, item_position, item_end, make_absolute_curve_points(item_position, pan_points, function(point)
      return (point.pan + 1.0) * 0.5
    end))
  end
  if air_param >= 0 and lpf_points then
    push_action_if_param(actions, track, fx_index, air_param, item_position, item_end, make_absolute_curve_points(item_position, lpf_points, function(point)
      return 1.0 - clamp(point.normalized, 0.0, 1.0)
    end))
  end

  return actions
end

local function build_sp_doppler_actions(item, settings, peak_time, pan_points)
  local track = reaper.GetMediaItem_Track(item)
  local fx_index = find_supported_plugin_fx(track, "sp_doppler")
  if fx_index < 0 then
    return nil, "Sound Particles Doppler was not found on the item's track."
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_position + item_length
  local plugin = SUPPORTED_PLUGINS.sp_doppler
  local actions = {}

  local speed_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.source_speed)
  local accel_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.acceleration)
  local distance_att_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.distance_attenuation)
  local mic_distance_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.microphone_distance)
  local rotation_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.mic_rotation)
  local time_to_peak_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.time_to_peak)

  if speed_param >= 0 then
    push_action_if_param(actions, track, fx_index, speed_param, item_position, item_end, make_constant_curve_points(item_position, item_end, clamp(settings.speed, 0.0, 1.0)))
  end
  if accel_param >= 0 then
    push_action_if_param(actions, track, fx_index, accel_param, item_position, item_end, make_constant_curve_points(item_position, item_end, 0.5))
  end
  if distance_att_param >= 0 then
    push_action_if_param(actions, track, fx_index, distance_att_param, item_position, item_end, make_constant_curve_points(item_position, item_end, clamp(settings.volume_range / 24.0, 0.0, 1.0)))
  end
  if mic_distance_param >= 0 then
    push_action_if_param(actions, track, fx_index, mic_distance_param, item_position, item_end, make_constant_curve_points(item_position, item_end, 1.0 - clamp(settings.distance, 0.0, 1.0)))
  end
  if rotation_param >= 0 and pan_points then
    push_action_if_param(actions, track, fx_index, rotation_param, item_position, item_end, make_absolute_curve_points(item_position, pan_points, function(point)
      return (point.pan + 1.0) * 0.5
    end))
  end
  if time_to_peak_param >= 0 then
    actions[#actions + 1] = build_constant_param_action(track, fx_index, time_to_peak_param, item_position, item_end, peak_time)
  end

  return actions
end

local function build_grm_doppler_actions(item, settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
  local track = reaper.GetMediaItem_Track(item)
  local fx_index = find_supported_plugin_fx(track, "grm_doppler")
  if fx_index < 0 then
    return nil, "GRM Doppler was not found on the item's track."
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_position + item_length
  local plugin = SUPPORTED_PLUGINS.grm_doppler
  local actions = {}

  local time_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.time)
  local pitch_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.pitch)
  local gain_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.gain)
  local pan_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.pan)
  local damp_param = find_track_fx_param_by_keywords(track, fx_index, plugin.param_keywords.damp)

  if time_param >= 0 then
    actions[#actions + 1] = build_constant_param_action(track, fx_index, time_param, item_position, item_end, peak_time)
  end
  if pitch_param >= 0 and pitch_points and #pitch_points > 0 then
    local max_shift = math.max(settings.intensity * 12.0, 0.01)
    push_action_if_param(actions, track, fx_index, pitch_param, item_position, item_end, make_absolute_curve_points(item_position, pitch_points, function(point)
      return 0.5 + clamp(point.semitones / (max_shift * 2.0), -0.5, 0.5)
    end))
  end
  if gain_param >= 0 and volume_points then
    push_action_if_param(actions, track, fx_index, gain_param, item_position, item_end, make_absolute_curve_points(item_position, volume_points, function(point)
      return clamp(point.volume, 0.0, 1.0)
    end))
  end
  if pan_param >= 0 and pan_points then
    push_action_if_param(actions, track, fx_index, pan_param, item_position, item_end, make_absolute_curve_points(item_position, pan_points, function(point)
      return (point.pan + 1.0) * 0.5
    end))
  end
  if damp_param >= 0 and lpf_points then
    push_action_if_param(actions, track, fx_index, damp_param, item_position, item_end, make_absolute_curve_points(item_position, lpf_points, function(point)
      return 1.0 - clamp(point.normalized, 0.0, 1.0)
    end))
  end

  return actions
end

build_plugin_track_fx_actions = function(item, settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
  if not settings.write_fx_params or settings.selected_plugin == "builtin" then
    return {}
  end

  if settings.selected_plugin == "waves_doppler" then
    return build_waves_doppler_actions(item, settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
  end
  if settings.selected_plugin == "sp_doppler" then
    return build_sp_doppler_actions(item, settings, peak_time, pan_points)
  end
  if settings.selected_plugin == "grm_doppler" then
    return build_grm_doppler_actions(item, settings, peak_time, pitch_points, volume_points, pan_points, lpf_points)
  end

  return {}
end

function M.run_custom_fx(settings)
  local resolved_settings = deep_copy(settings or M.load_last_settings())
  M.save_last_settings(resolved_settings)

  local touched, track_number, fx_number, param_number = reaper.GetLastTouchedFX()
  if not touched then
    return false, "Touch a track FX parameter first, then run Custom."
  end

  local track = nil
  if track_number == 0 then
    track = reaper.GetMasterTrack(0)
  elseif track_number > 0 then
    track = reaper.GetTrack(0, track_number - 1)
  end

  if not track then
    return false, "Unable to resolve the last-touched FX track."
  end

  local targets = get_target_items(resolved_settings)
  local filtered = {}
  for index = 1, #targets do
    local target = targets[index]
    if reaper.GetMediaItem_Track(target.item) == track then
      filtered[#filtered + 1] = target
    end
  end
  targets = filtered

  if #targets == 0 then
    return false, "No selected target items live on the last-touched FX track."
  end

  clear_console()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local clear_start = math.huge
  local clear_end = -math.huge
  local all_points = {}
  local processed = 0

  for index = 1, #targets do
    local target = targets[index]
    local item = target.item
    local take = get_active_audio_take(item)
    if take then
      local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_settings = resolved_settings.randomize and randomize_settings(resolved_settings, resolved_settings.randomize_amount) or resolved_settings
      local base_peak = resolve_item_peak(item, item_settings, target.folder_peak_absolute)
      local peak_time = apply_peak_offset(base_peak, item_length, item_settings.offset, item_settings.use_snap_offsets)
      local points = generate_custom_param_points(item, peak_time, item_settings)
      local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = item_position + item_length

      clear_start = math.min(clear_start, item_position - 0.001)
      clear_end = math.max(clear_end, item_end + 0.001)
      for point_index = 1, #points do
        all_points[#all_points + 1] = points[point_index]
      end

      processed = processed + 1
      log_line(string.format("[%d/%d] %s - custom curve written", index, #targets, get_item_name(item)))
    else
      log_line(string.format("[%d/%d] %s - skipped: no active audio take", index, #targets, get_item_name(item)))
    end
  end

  local ok, message = true, nil
  if processed <= 0 then
    ok = false
    message = "No audio takes were available for the touched FX track."
  else
    table.sort(all_points, function(left, right)
      return left.time < right.time
    end)
    ok, message = write_track_fx_param_points(track, fx_number, param_number, all_points, clear_start, clear_end)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Auto Doppler - Custom FX", -1)

  if not ok then
    return false, message
  end

  return true, {
    total = #targets,
    successful = processed,
    failed = #targets - processed,
  }
end

local ui_state = {
  settings = nil,
  active_control = ACTIVE_CONTROL_NONE,
  prev_left_down = false,
  status_text = "Ready.",
  should_close = false,
  prev_char = 0,
  imgui_context = nil,
  imgui_open = false,
  selected_preset = 1,
}

local function set_status(message)
  ui_state.status_text = tostring(message or "")
end

local function save_settings_from_ui()
  if ui_state.settings then
    M.save_last_settings(ui_state.settings)
  end
end

local function apply_from_ui()
  local ok, result_or_message = M.process_selection(ui_state.settings)
  if ok then
    set_status(string.format("Applied Doppler to %d item(s), %d failed.", result_or_message.successful, result_or_message.failed))
  else
    set_status(result_or_message)
    show_error(result_or_message)
  end
end

local function render_from_ui()
  local ok, result_or_message = M.quick_render(ui_state.settings)
  if ok then
    set_status(string.format("Rendered %d processed item(s) as new take(s).", result_or_message.successful))
  else
    set_status(result_or_message)
    show_error(result_or_message)
  end
end

local function remove_from_ui()
  local ok, result_or_message = M.remove_selection(ui_state.settings)
  if ok then
    set_status(string.format("Removed Doppler from %d item(s), %d failed.", result_or_message.successful, result_or_message.failed))
  else
    set_status(result_or_message)
    show_error(result_or_message)
  end
end

local function custom_from_ui()
  local ok, result_or_message = M.run_custom_fx(ui_state.settings)
  if ok then
    set_status(string.format("Custom curve written for %d item(s).", result_or_message.successful))
  else
    set_status(result_or_message)
    show_error(result_or_message)
  end
end

local function save_selected_preset()
  save_preset(ui_state.selected_preset, ui_state.settings)
  set_status(string.format("Saved preset %d.", ui_state.selected_preset))
end

local function load_selected_preset()
  local preset = load_preset(ui_state.selected_preset)
  if not preset then
    set_status(string.format("Preset %d is empty.", ui_state.selected_preset))
    return
  end
  ui_state.settings = preset
  save_settings_from_ui()
  set_status(string.format("Loaded preset %d.", ui_state.selected_preset))
end

local function draw_panel(x, y, w, h, title)
  draw_rect(x, y, w, h, true, 25, 28, 34, 255)
  draw_rect(x, y, w, h, false, 58, 64, 76, 255)
  draw_text(title, x + 14, y + 10, 235, 238, 245, 255, "Segoe UI Semibold", 15)
end

local function begin_control(id, rect_x, rect_y, rect_w, rect_h)
  local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, rect_x, rect_y, rect_w, rect_h)
  if hovered and ui_state.mouse_pressed then
    ui_state.active_control = id
  end
  return hovered, ui_state.active_control == id
end

local function button(id, label, x, y, w, h, enabled)
  local hovered, active = begin_control(id, x, y, w, h)
  local clicked = false

  if ui_state.mouse_released and active and hovered and enabled ~= false then
    clicked = true
  end

  local bg_r, bg_g, bg_b = 63, 80, 117
  if enabled == false then
    bg_r, bg_g, bg_b = 52, 54, 58
  elseif active and ui_state.left_down then
    bg_r, bg_g, bg_b = 87, 111, 161
  elseif hovered then
    bg_r, bg_g, bg_b = 76, 96, 140
  end

  draw_rect(x, y, w, h, true, bg_r, bg_g, bg_b, 255)
  draw_rect(x, y, w, h, false, 92, 104, 126, 255)
  draw_text(label, x + 14, y + 8, enabled == false and 140 or 240, enabled == false and 140 or 240, enabled == false and 140 or 245, 255, "Segoe UI Semibold", 14)
  return clicked
end

local function checkbox(id, label, x, y, value)
  local box_size = 18
  local width = 28 + gfx.measurestr(label)
  local hovered, active = begin_control(id, x, y, width, box_size)
  local next_value = value

  if ui_state.mouse_released and active and hovered then
    next_value = not value
    save_settings_from_ui()
  end

  draw_rect(x, y, box_size, box_size, true, 18, 20, 24, 255)
  draw_rect(x, y, box_size, box_size, false, hovered and 125 or 96, hovered and 155 or 110, hovered and 206 or 124, 255)
  if next_value then
    draw_rect(x + 4, y + 4, box_size - 8, box_size - 8, true, 96, 170, 255, 255)
  end
  draw_text(label, x + 28, y - 1, 228, 230, 236, 255, "Segoe UI", 14)
  return next_value
end

local function slider(id, label, x, y, min_value, max_value, value, value_text)
  local track_y = y + 24
  local track_h = 6
  local knob_radius = 7
  local hovered, active = begin_control(id, x, track_y - 8, SLIDER_W, 22)
  local next_value = value

  if active and ui_state.left_down then
    local ratio = clamp((gfx.mouse_x - x) / SLIDER_W, 0.0, 1.0)
    next_value = min_value + ((max_value - min_value) * ratio)
    save_settings_from_ui()
  end

  local ratio = 0.0
  if max_value > min_value then
    ratio = clamp((next_value - min_value) / (max_value - min_value), 0.0, 1.0)
  end

  draw_text(label, x, y, 230, 232, 238, 255, "Segoe UI", 14)
  draw_text_right(value_text, x + SLIDER_W + 130, y, 168, 202, 255, 255, "Consolas", 14)
  draw_rect(x, track_y, SLIDER_W, track_h, true, 48, 50, 56, 255)
  draw_rect(x, track_y, math.max(2, ratio * SLIDER_W), track_h, true, 92, 156, 255, 255)
  local knob_x = x + (ratio * SLIDER_W)
  draw_rect(knob_x - knob_radius, track_y - 5, knob_radius * 2, knob_radius * 2, true, hovered and 230 or 208, hovered and 235 or 214, 244, 255)

  return next_value
end

local function draw_selection_info(x, y)
  local selection_text = summarize_selection()
  local ts_start, ts_end = get_time_selection()
  draw_text("Selection", x, y, 235, 238, 245, 255, "Segoe UI Semibold", 15)
  draw_text(selection_text, x, y + 24, 172, 178, 189, 255, "Segoe UI", 14)
  if ts_start then
    draw_text(
      string.format("Time selection: %s - %s", format_seconds(ts_start), format_seconds(ts_end)),
      x,
      y + 46,
      172,
      178,
      189,
      255,
      "Segoe UI",
      14
    )
  else
    draw_text("Time selection: off", x, y + 46, 172, 178, 189, 255, "Segoe UI", 14)
  end
end

local function draw_gui()
  draw_rect(0, 0, WINDOW_W, WINDOW_H, true, 16, 18, 22, 255)
  draw_text(SCRIPT_TITLE, WINDOW_PADDING, 16, 244, 246, 252, 255, "Segoe UI Semibold", 22)
  draw_text("Phase 2: ReaImGui preferred, gfx fallback, LPF and pan enabled", WINDOW_PADDING, 46, 150, 168, 188, 255, "Segoe UI", 13)

  draw_panel(16, 78, 788, 826, "Built-in Engine")
  draw_selection_info(34, 102)

  local y = 170
  draw_text("Pitch", 34, y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  ui_state.settings.pitch_enabled = checkbox("pitch_enabled", "Enable pitch Doppler", 34, y + 26, ui_state.settings.pitch_enabled)
  draw_text("Engine: Playrate envelope first, ReaPitch fallback if needed", 260, y + 26, 150, 165, 184, 255, "Segoe UI", 13)
  ui_state.settings.speed = slider("speed", "Speed", 34, y + 58, 0.0, 1.0, ui_state.settings.speed, string.format("%.2f", ui_state.settings.speed))
  ui_state.settings.intensity = slider("intensity", "Intensity", 34, y + 110, 0.0, 1.0, ui_state.settings.intensity, string.format("%.2f", ui_state.settings.intensity))
  ui_state.settings.unlink_playrate = checkbox("unlink_playrate", "Unlink playrate curve", 34, y + 138, ui_state.settings.unlink_playrate)
  ui_state.settings.playrate_curve = slider("playrate_curve", "Playrate Curve", 34, y + 166, 0.25, 3.0, ui_state.settings.playrate_curve, string.format("%.2f", ui_state.settings.playrate_curve))

  y = y + 234
  draw_text("Volume", 34, y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  ui_state.settings.volume_enabled = checkbox("volume_enabled", "Enable distance attenuation", 34, y + 26, ui_state.settings.volume_enabled)
  ui_state.settings.volume_range = slider("volume_range", "Range", 34, y + 58, 0.0, 24.0, ui_state.settings.volume_range, string.format("%.1f dB", ui_state.settings.volume_range))
  ui_state.settings.distance = slider("distance", "Distance", 34, y + 110, 0.02, 1.0, ui_state.settings.distance, string.format("%.2f", ui_state.settings.distance))

  y = y + 176
  draw_text("Filter", 34, y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  ui_state.settings.lpf_enabled = checkbox("lpf_enabled", "Enable LPF air absorption", 34, y + 26, ui_state.settings.lpf_enabled)
  ui_state.settings.lpf_min_freq = slider("lpf_min_freq", "LPF Min", 34, y + 58, 200.0, 12000.0, ui_state.settings.lpf_min_freq, string.format("%.0f Hz", ui_state.settings.lpf_min_freq))
  ui_state.settings.lpf_max_freq = slider("lpf_max_freq", "LPF Max", 34, y + 110, 2000.0, 24000.0, ui_state.settings.lpf_max_freq, string.format("%.0f Hz", ui_state.settings.lpf_max_freq))

  local right_x = 424
  local right_y = 170
  draw_text("Plugin / Pan", right_x, right_y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  if button("plugin_mode", "Plugin: " .. (PLUGIN_LABELS[ui_state.settings.selected_plugin] or ui_state.settings.selected_plugin), right_x, right_y + 26, 388, BUTTON_H, true) then
    ui_state.settings.selected_plugin = cycle_plugin_mode(ui_state.settings.selected_plugin)
    save_settings_from_ui()
  end
  ui_state.settings.write_fx_params = checkbox("write_fx_params", "Write mapped plugin FX params", right_x, right_y + 68, ui_state.settings.write_fx_params)
  ui_state.settings.fallback_to_builtin = checkbox("fallback_to_builtin", "Fallback to built-in if plugin is missing", right_x, right_y + 96, ui_state.settings.fallback_to_builtin)
  ui_state.settings.pan_enabled = checkbox("pan_enabled", "Enable left/right pass-by pan", right_x, right_y + 124, ui_state.settings.pan_enabled)
  ui_state.settings.pan_width = slider("pan_width", "Pan Width", right_x, right_y + 152, 0.0, 1.0, ui_state.settings.pan_width, string.format("%.2f", ui_state.settings.pan_width))
  local reverse_direction = checkbox("direction", "Reverse direction (R -> L)", right_x, right_y + 208, ui_state.settings.direction == -1)
  ui_state.settings.direction = reverse_direction and -1 or 1

  right_y = right_y + 252
  draw_text("Peak Detection", right_x, right_y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  ui_state.settings.peak_detection = checkbox("peak_detection", "Use RMS peak detection", right_x, right_y + 26, ui_state.settings.peak_detection)
  ui_state.settings.use_snap_offsets = checkbox("use_snap_offsets", "Prefer existing snap offsets", right_x, right_y + 54, ui_state.settings.use_snap_offsets)
  ui_state.settings.auto_set_snap_offset = checkbox("auto_set_snap_offset", "Write detected peak back to snap offset", right_x, right_y + 82, ui_state.settings.auto_set_snap_offset)
  local offset_min = ui_state.settings.use_snap_offsets and -1.0 or -0.5
  local offset_max = ui_state.settings.use_snap_offsets and 1.0 or 0.5
  local offset_text = ui_state.settings.use_snap_offsets
    and string.format("%+.2fs", ui_state.settings.offset)
    or string.format("%+.0f%%", ui_state.settings.offset * 100.0)
  ui_state.settings.offset = slider("offset", "Offset", right_x, right_y + 112, offset_min, offset_max, ui_state.settings.offset, offset_text)

  right_y = right_y + 178
  draw_text("Batch / Render", right_x, right_y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  ui_state.settings.randomize = checkbox("randomize", "Randomize per item", right_x, right_y + 26, ui_state.settings.randomize)
  ui_state.settings.randomize_amount = slider(
    "randomize_amount",
    "Random Amount",
    right_x,
    right_y + 58,
    0.0,
    1.0,
    ui_state.settings.randomize_amount,
    format_percent01(ui_state.settings.randomize_amount)
  )
  ui_state.settings.split_takes_after_render = checkbox("split_takes_after_render", "Split rendered items at source boundaries", right_x, right_y + 118, ui_state.settings.split_takes_after_render)

  draw_text("Presets", right_x, right_y + 148, 220, 224, 232, 255, "Segoe UI Semibold", 14)
  local preset_x = right_x
  for slot = 1, PRESET_SLOT_COUNT do
    local label = tostring(slot)
    if preset_exists(slot) then
      label = label .. "*"
    end
    if slot == ui_state.selected_preset then
      label = "[" .. label .. "]"
    end
    if button("preset_slot_" .. tostring(slot), label, preset_x, right_y + 176, 40, 24, true) then
      ui_state.selected_preset = slot
      set_selected_preset_slot(slot)
    end
    preset_x = preset_x + 46
  end
  if button("preset_save", "Save", right_x + 220, right_y + 176, 70, 24, true) then
    save_selected_preset()
  end
  if button("preset_load", "Load", right_x + 300, right_y + 176, 70, 24, true) then
    load_selected_preset()
  end

  right_y = right_y + 214
  draw_text("Quick Actions", right_x, right_y, 236, 238, 244, 255, "Segoe UI Semibold", 15)
  if button("apply", "Apply", right_x, right_y + 30, 120, BUTTON_H, true) then
    apply_from_ui()
  end
  if button("render", "Render", right_x + 134, right_y + 30, 120, BUTTON_H, true) then
    render_from_ui()
  end
  if button("remove", "Remove", right_x + 268, right_y + 30, 120, BUTTON_H, true) then
    remove_from_ui()
  end
  if button("reset", "Reset", right_x, right_y + 74, 120, BUTTON_H, true) then
    ui_state.settings = deep_copy(DEFAULTS)
    save_settings_from_ui()
    set_status("Settings reset to defaults.")
  end
  if button("custom", "Custom FX", right_x + 134, right_y + 74, 120, BUTTON_H, true) then
    custom_from_ui()
  end
  if button("close", "Close", right_x + 268, right_y + 74, 120, BUTTON_H, true) then
    save_settings_from_ui()
    ui_state.should_close = true
  end

  draw_rect(16, WINDOW_H - 36, 788, 20, true, 20, 22, 26, 255)
  draw_text(ui_state.status_text, 24, WINDOW_H - 33, 190, 198, 210, 255, "Segoe UI", 13)
end

local function imgui_checkbox(ctx, label, value)
  local changed, new_value = ImGui.Checkbox(ctx, label, value)
  if changed then
    save_settings_from_ui()
  end
  return new_value
end

local function imgui_slider_double(ctx, label, value, min_value, max_value, format_string)
  local changed, new_value = ImGui.SliderDouble(ctx, label, value, min_value, max_value, format_string)
  if changed then
    save_settings_from_ui()
  end
  return new_value
end

local function draw_imgui_gui()
  local ctx = ui_state.imgui_context
  local ts_start, ts_end = get_time_selection()

  ImGui.Text(ctx, summarize_selection())
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, "ReaImGui")
  if ts_start then
    ImGui.Text(ctx, string.format("Time selection: %s - %s", format_seconds(ts_start), format_seconds(ts_end)))
  else
    ImGui.Text(ctx, "Time selection: off")
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Pitch")
  ui_state.settings.pitch_enabled = imgui_checkbox(ctx, "Enable pitch Doppler", ui_state.settings.pitch_enabled)
  ui_state.settings.speed = imgui_slider_double(ctx, "Speed", ui_state.settings.speed, 0.0, 1.0, "%.2f")
  ui_state.settings.intensity = imgui_slider_double(ctx, "Intensity", ui_state.settings.intensity, 0.0, 1.0, "%.2f")
  ui_state.settings.unlink_playrate = imgui_checkbox(ctx, "Unlink playrate curve", ui_state.settings.unlink_playrate)
  ui_state.settings.playrate_curve = imgui_slider_double(ctx, "Playrate Curve", ui_state.settings.playrate_curve, 0.25, 3.0, "%.2f")

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Volume / Filter / Pan / Plugin")
  ui_state.settings.volume_enabled = imgui_checkbox(ctx, "Enable distance attenuation", ui_state.settings.volume_enabled)
  ui_state.settings.volume_range = imgui_slider_double(ctx, "Volume Range", ui_state.settings.volume_range, 0.0, 24.0, "%.1f dB")
  ui_state.settings.distance = imgui_slider_double(ctx, "Distance", ui_state.settings.distance, 0.02, 1.0, "%.2f")
  ui_state.settings.lpf_enabled = imgui_checkbox(ctx, "Enable LPF air absorption", ui_state.settings.lpf_enabled)
  ui_state.settings.lpf_min_freq = imgui_slider_double(ctx, "LPF Min", ui_state.settings.lpf_min_freq, 200.0, 12000.0, "%.0f Hz")
  ui_state.settings.lpf_max_freq = imgui_slider_double(ctx, "LPF Max", ui_state.settings.lpf_max_freq, 2000.0, 24000.0, "%.0f Hz")
  ui_state.settings.pan_enabled = imgui_checkbox(ctx, "Enable left/right pass-by pan", ui_state.settings.pan_enabled)
  ui_state.settings.pan_width = imgui_slider_double(ctx, "Pan Width", ui_state.settings.pan_width, 0.0, 1.0, "%.2f")
  local reverse_direction = imgui_checkbox(ctx, "Reverse direction (R -> L)", ui_state.settings.direction == -1)
  ui_state.settings.direction = reverse_direction and -1 or 1
  if ImGui.Button(ctx, "Plugin: " .. (PLUGIN_LABELS[ui_state.settings.selected_plugin] or ui_state.settings.selected_plugin), 260, 0) then
    ui_state.settings.selected_plugin = cycle_plugin_mode(ui_state.settings.selected_plugin)
    save_settings_from_ui()
  end
  ui_state.settings.write_fx_params = imgui_checkbox(ctx, "Write mapped plugin FX params", ui_state.settings.write_fx_params)
  ui_state.settings.fallback_to_builtin = imgui_checkbox(ctx, "Fallback to built-in if plugin is missing", ui_state.settings.fallback_to_builtin)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Peak Detection / Randomize / Render")
  ui_state.settings.peak_detection = imgui_checkbox(ctx, "Use RMS peak detection", ui_state.settings.peak_detection)
  ui_state.settings.use_snap_offsets = imgui_checkbox(ctx, "Prefer existing snap offsets", ui_state.settings.use_snap_offsets)
  ui_state.settings.auto_set_snap_offset = imgui_checkbox(ctx, "Write detected peak back to snap offset", ui_state.settings.auto_set_snap_offset)
  if ui_state.settings.use_snap_offsets then
    ui_state.settings.offset = imgui_slider_double(ctx, "Offset", ui_state.settings.offset, -1.0, 1.0, "%+.2f s")
  else
    ui_state.settings.offset = imgui_slider_double(ctx, "Offset", ui_state.settings.offset, -0.5, 0.5, "%+.2f")
  end
  ui_state.settings.randomize = imgui_checkbox(ctx, "Randomize per item", ui_state.settings.randomize)
  ui_state.settings.randomize_amount = imgui_slider_double(ctx, "Random Amount", ui_state.settings.randomize_amount, 0.0, 1.0, "%.2f")
  ui_state.settings.split_takes_after_render = imgui_checkbox(ctx, "Split rendered items at source boundaries", ui_state.settings.split_takes_after_render)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Folder tracks use outlier-filtered child peak averages. Render applies processed items as new takes.")
  ImGui.Text(ctx, "Presets")
  for slot = 1, PRESET_SLOT_COUNT do
    if slot > 1 then
      ImGui.SameLine(ctx)
    end
    local label = tostring(slot)
    if preset_exists(slot) then
      label = label .. "*"
    end
    if slot == ui_state.selected_preset then
      label = "[" .. label .. "]"
    end
    if ImGui.Button(ctx, label, 38, 0) then
      ui_state.selected_preset = slot
      set_selected_preset_slot(slot)
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save Preset", 90, 0) then
    save_selected_preset()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Load Preset", 90, 0) then
    load_selected_preset()
  end

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Apply", 110, 0) then
    apply_from_ui()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Render", 110, 0) then
    render_from_ui()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Remove", 110, 0) then
    remove_from_ui()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reset", 110, 0) then
    ui_state.settings = deep_copy(DEFAULTS)
    save_settings_from_ui()
    set_status("Settings reset to defaults.")
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Custom FX", 110, 0) then
    custom_from_ui()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Close", 110, 0) then
    ui_state.imgui_open = false
    ui_state.should_close = true
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, ui_state.status_text)
end

local function imgui_loop()
  local ctx = ui_state.imgui_context
  if not ctx then
    return
  end

  local set_next_window_size = safe_imgui_symbol("SetNextWindowSize")
  local cond_first_use_ever = safe_imgui_symbol("Cond_FirstUseEver") or 0
  if set_next_window_size then
    set_next_window_size(ctx, 860, 920, cond_first_use_ever)
  end

  local visible, open = ImGui.Begin(ctx, SCRIPT_TITLE, ui_state.imgui_open)
  ui_state.imgui_open = open

  if visible then
    draw_imgui_gui()
  end

  ImGui.End(ctx)

  if not open or ui_state.should_close then
    save_settings_from_ui()
    local destroy_context = safe_imgui_symbol("DestroyContext")
    if destroy_context then
      destroy_context(ctx)
    end
    ui_state.imgui_context = nil
    return
  end

  reaper.defer(imgui_loop)
end

local function handle_keyboard_shortcuts(char)
  if char == 13 then
    apply_from_ui()
  elseif char == 27 then
    ui_state.should_close = true
  elseif char == 114 or char == 82 then
    render_from_ui()
  elseif char >= 49 and char <= (48 + PRESET_SLOT_COUNT) then
    ui_state.selected_preset = char - 48
    set_selected_preset_slot(ui_state.selected_preset)
  end
end

local function gui_loop()
  local char = gfx.getchar()
  if char < 0 then
    save_settings_from_ui()
    return
  end

  ui_state.left_down = has_mouse_cap(1)
  ui_state.mouse_pressed = ui_state.left_down and not ui_state.prev_left_down
  ui_state.mouse_released = (not ui_state.left_down) and ui_state.prev_left_down

  if char > 0 and char ~= ui_state.prev_char then
    handle_keyboard_shortcuts(char)
  end

  draw_gui()

  if ui_state.mouse_released then
    ui_state.active_control = ACTIVE_CONTROL_NONE
  end

  ui_state.prev_left_down = ui_state.left_down
  ui_state.prev_char = char
  gfx.update()

  if ui_state.should_close then
    save_settings_from_ui()
    return
  end

  reaper.defer(gui_loop)
end

function M.main()
  ui_state.settings = M.load_last_settings()
  ui_state.active_control = ACTIVE_CONTROL_NONE
  ui_state.prev_left_down = false
  ui_state.prev_char = 0
  ui_state.should_close = false
  ui_state.status_text = "Select items or tracks, then Apply."
  ui_state.imgui_open = false
  ui_state.selected_preset = get_selected_preset_slot()

  if HAS_IMGUI and ImGui then
    local create_context = safe_imgui_symbol("CreateContext")
    if create_context then
      ui_state.imgui_context = create_context(SCRIPT_TITLE)
      ui_state.imgui_open = true
      imgui_loop()
      return
    end
  end

  gfx.init(SCRIPT_TITLE, WINDOW_W, WINDOW_H, 0)
  gfx.setfont(1, "Segoe UI", 14)
  gui_loop()
end

M.SCRIPT_TITLE = SCRIPT_TITLE
M.EXT_SECTION = EXT_SECTION
M.DEFAULTS = DEFAULTS

if rawget(_G, HELPER_BOOTSTRAP_FLAG) then
  return M
end

M.main()
return M
