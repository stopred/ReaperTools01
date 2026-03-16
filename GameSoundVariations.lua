-- Sound Variation Generator v1.0
-- Reaper ReaScript (Lua)
-- Advanced variation generator for selected REAPER media items.
--
-- Usage:
-- 1. Select one or more media items.
-- 2. Run this script.
-- 3. Adjust the GUI controls.
-- 4. Press Apply (or Enter) to generate variations.
-- 5. Use Ctrl+Z if you want to undo and try different settings.
--
-- Requirements: REAPER v7.0+
-- Recommended: ReaImGui for the full UI. Falls back to gfx when unavailable.

local SCRIPT_TITLE = "Sound Variation Generator v1.0"
local EXT_SECTION = "GameSoundVariations"
local PRESET_SLOT_COUNT = 5
local HELPER_BOOTSTRAP_FLAG = "__GAME_SOUND_VARIATIONS_HELPER__"
local SETTINGS_VERSION = 3

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

math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
math.random()
math.random()
math.random()

local M = {}

local DEFAULTS = {
  main = {
    ripple = "off",
    copy_automation = false,
    crossfade = true,
    ripple_markers = false,
  },
  variations = {
    amount = 5,
    mode = "default",
    difference = 0,
    limit_source_offset = true,
  },
  pitch = {
    amount = 0.0,
    envelope = 0.0,
    mode = "shift",
    round_to_semitone = false,
    split_range = false,
    up_amount = 0.0,
    down_amount = 0.0,
  },
  position = {
    space = 0.0,
    offset = 0.0,
  },
  volume = {
    amount = 0.0,
    envelope = 0.0,
    mute = 0.0,
  },
  pan = {
    amount = 0.0,
    envelope = 0.0,
  },
  tone = {
    amount = 0.0,
    envelope = 0.0,
  },
  track = {
    amount = 0.0,
  },
  ui = {
    selected_preset = 1,
    window_x = nil,
    window_y = nil,
    window_w = 860,
    window_h = 1020,
  },
  transport = {
    auto_skip = false,
  },
}

local VARIATION_MODES = { "default", "random", "chaos", "loop", "none" }
local VARIATION_MODE_LABELS = {
  default = "Default",
  random = "Random",
  chaos = "Chaos",
  loop = "Loop",
  none = "None",
}

local PITCH_MODES = { "shift", "playrate", "random" }
local PITCH_MODE_LABELS = {
  shift = "Shift",
  playrate = "Playrate",
  random = "Random",
}

local RIPPLE_MODES = { "off", "all", "per_track" }
local RIPPLE_MODE_LABELS = {
  off = "Off",
  all = "All",
  per_track = "Per Track",
}

local WINDOW_W = 840
local WINDOW_H = 1020
local WINDOW_PADDING = 18
local SECTION_GAP = 14
local ROW_HEIGHT = 38
local SLIDER_W = 300
local SLIDER_H = 16
local BUTTON_H = 28

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

local function approx_zero(value)
  return math.abs(tonumber(value) or 0) < 1e-9
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

local function db_to_linear(db_value)
  return 10 ^ ((tonumber(db_value) or 0) / 20.0)
end

local function random_symmetric(max_abs)
  local amount = tonumber(max_abs) or 0
  if amount <= 0 then
    return 0.0
  end
  return (math.random() * 2.0 - 1.0) * amount
end

local function bool_to_string(value)
  return value and "1" or "0"
end

local function string_to_bool(value, default_value)
  if value == "1" or value == "true" or value == "yes" or value == "on" then
    return true
  end
  if value == "0" or value == "false" or value == "no" or value == "off" then
    return false
  end
  return default_value
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function has_mouse_cap(mask)
  return math.floor((gfx.mouse_cap or 0) / mask) % 2 == 1
end

local function normalize_variation_mode(value)
  local lowered = tostring(value or ""):lower()
  for _, mode in ipairs(VARIATION_MODES) do
    if lowered == mode then
      return mode
    end
  end
  return DEFAULTS.variations.mode
end

local function normalize_pitch_mode(value)
  local lowered = tostring(value or ""):lower()
  for _, mode in ipairs(PITCH_MODES) do
    if lowered == mode then
      return mode
    end
  end
  return DEFAULTS.pitch.mode
end

local function normalize_ripple_mode(value)
  local lowered = tostring(value or ""):lower()
  for _, mode in ipairs(RIPPLE_MODES) do
    if lowered == mode then
      return mode
    end
  end
  return DEFAULTS.main.ripple
end

local function serialize_settings_v1(settings, include_ui)
  local values = {
    "1",
    tostring(math.floor((settings.variations.amount or 0) + 0.5)),
    normalize_variation_mode(settings.variations.mode),
    string.format("%.6f", tonumber(settings.pitch.amount) or 0),
    normalize_pitch_mode(settings.pitch.mode),
    bool_to_string(settings.pitch.round_to_semitone),
    string.format("%.6f", tonumber(settings.volume.amount) or 0),
    string.format("%.6f", tonumber(settings.volume.mute) or 0),
    string.format("%.6f", tonumber(settings.position.space) or 0),
    string.format("%.6f", tonumber(settings.position.offset) or 0),
  }

  if include_ui then
    values[#values + 1] = tostring(clamp(math.floor((settings.ui.selected_preset or 1) + 0.5), 1, PRESET_SLOT_COUNT))
  end

  return table.concat(values, "|")
end

local function parse_key_value_lines(serialized)
  local map = {}

  for line in tostring(serialized or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
      map[key] = value
    end
  end

  return map
end

local function serialize_settings(settings, include_ui)
  local lines = {
    "version=" .. tostring(SETTINGS_VERSION),
    "main.ripple=" .. normalize_ripple_mode(settings.main.ripple),
    "main.copy_automation=" .. bool_to_string(settings.main.copy_automation),
    "main.crossfade=" .. bool_to_string(settings.main.crossfade),
    "main.ripple_markers=" .. bool_to_string(settings.main.ripple_markers),
    "variations.amount=" .. tostring(clamp(math.floor((settings.variations.amount or 0) + 0.5), 0, 50)),
    "variations.mode=" .. normalize_variation_mode(settings.variations.mode),
    "variations.difference=" .. string.format("%.6f", tonumber(settings.variations.difference) or 0),
    "pitch.amount=" .. string.format("%.6f", tonumber(settings.pitch.amount) or 0),
    "pitch.envelope=" .. string.format("%.6f", tonumber(settings.pitch.envelope) or 0),
    "pitch.mode=" .. normalize_pitch_mode(settings.pitch.mode),
    "pitch.round_to_semitone=" .. bool_to_string(settings.pitch.round_to_semitone),
    "pitch.split_range=" .. bool_to_string(settings.pitch.split_range),
    "pitch.up_amount=" .. string.format("%.6f", tonumber(settings.pitch.up_amount) or 0),
    "pitch.down_amount=" .. string.format("%.6f", tonumber(settings.pitch.down_amount) or 0),
    "position.space=" .. string.format("%.6f", tonumber(settings.position.space) or 0),
    "position.offset=" .. string.format("%.6f", tonumber(settings.position.offset) or 0),
    "variations.limit_source_offset=" .. bool_to_string(settings.variations.limit_source_offset ~= false),
    "track.amount=" .. string.format("%.6f", tonumber(settings.track.amount) or 0),
    "volume.amount=" .. string.format("%.6f", tonumber(settings.volume.amount) or 0),
    "volume.envelope=" .. string.format("%.6f", tonumber(settings.volume.envelope) or 0),
    "volume.mute=" .. string.format("%.6f", tonumber(settings.volume.mute) or 0),
    "pan.amount=" .. string.format("%.6f", tonumber(settings.pan.amount) or 0),
    "pan.envelope=" .. string.format("%.6f", tonumber(settings.pan.envelope) or 0),
    "tone.amount=" .. string.format("%.6f", tonumber(settings.tone.amount) or 0),
    "tone.envelope=" .. string.format("%.6f", tonumber(settings.tone.envelope) or 0),
    "transport.auto_skip=" .. bool_to_string(settings.transport.auto_skip),
  }

  if include_ui then
    lines[#lines + 1] = "ui.selected_preset=" .. tostring(clamp(math.floor((settings.ui.selected_preset or 1) + 0.5), 1, PRESET_SLOT_COUNT))
    lines[#lines + 1] = "ui.window_w=" .. tostring(math.floor(tonumber(settings.ui.window_w) or DEFAULTS.ui.window_w))
    lines[#lines + 1] = "ui.window_h=" .. tostring(math.floor(tonumber(settings.ui.window_h) or DEFAULTS.ui.window_h))
    if settings.ui.window_x ~= nil then
      lines[#lines + 1] = "ui.window_x=" .. string.format("%.6f", tonumber(settings.ui.window_x) or 0)
    end
    if settings.ui.window_y ~= nil then
      lines[#lines + 1] = "ui.window_y=" .. string.format("%.6f", tonumber(settings.ui.window_y) or 0)
    end
  end

  return table.concat(lines, "\n")
end

local function deserialize_settings(serialized, include_ui)
  local settings = deep_copy(DEFAULTS)

  if not serialized or serialized == "" then
    return settings
  end

  if serialized:find("\n", 1, true) or serialized:find("^version=", 1) then
    local map = parse_key_value_lines(serialized)

    settings.main.ripple = normalize_ripple_mode(map["main.ripple"] or settings.main.ripple)
    settings.main.copy_automation = string_to_bool(map["main.copy_automation"], settings.main.copy_automation)
    settings.main.crossfade = string_to_bool(map["main.crossfade"], settings.main.crossfade)
    settings.main.ripple_markers = string_to_bool(map["main.ripple_markers"], settings.main.ripple_markers)

    settings.variations.amount = clamp(math.floor((tonumber(map["variations.amount"]) or settings.variations.amount) + 0.5), 0, 50)
    settings.variations.mode = normalize_variation_mode(map["variations.mode"] or settings.variations.mode)
    settings.variations.difference = clamp(tonumber(map["variations.difference"]) or settings.variations.difference, 0, 10)

    settings.pitch.amount = clamp(tonumber(map["pitch.amount"]) or settings.pitch.amount, 0, 24)
    settings.pitch.envelope = clamp(tonumber(map["pitch.envelope"]) or settings.pitch.envelope, 0, 100)
    settings.pitch.mode = normalize_pitch_mode(map["pitch.mode"] or settings.pitch.mode)
    settings.pitch.round_to_semitone = string_to_bool(map["pitch.round_to_semitone"], settings.pitch.round_to_semitone)
    settings.pitch.split_range = string_to_bool(map["pitch.split_range"], settings.pitch.split_range)
    settings.pitch.up_amount = clamp(tonumber(map["pitch.up_amount"]) or settings.pitch.up_amount, 0, 24)
    settings.pitch.down_amount = clamp(tonumber(map["pitch.down_amount"]) or settings.pitch.down_amount, 0, 24)

    settings.position.space = clamp(tonumber(map["position.space"]) or settings.position.space, -1, 10)
    settings.position.offset = clamp(tonumber(map["position.offset"]) or settings.position.offset, 0, 500)
    settings.variations.limit_source_offset = string_to_bool(map["variations.limit_source_offset"], true)

    settings.track.amount = clamp(tonumber(map["track.amount"]) or settings.track.amount, 0, 100)

    settings.volume.amount = clamp(tonumber(map["volume.amount"]) or settings.volume.amount, 0, 24)
    settings.volume.envelope = clamp(tonumber(map["volume.envelope"]) or settings.volume.envelope, 0, 100)
    settings.volume.mute = clamp(tonumber(map["volume.mute"]) or settings.volume.mute, 0, 100)

    settings.pan.amount = clamp(tonumber(map["pan.amount"]) or settings.pan.amount, 0, 100)
    settings.pan.envelope = clamp(tonumber(map["pan.envelope"]) or settings.pan.envelope, 0, 100)

    settings.tone.amount = clamp(tonumber(map["tone.amount"]) or settings.tone.amount, 0, 12)
    settings.tone.envelope = clamp(tonumber(map["tone.envelope"]) or settings.tone.envelope, 0, 100)
    settings.transport.auto_skip = string_to_bool(map["transport.auto_skip"], settings.transport.auto_skip)

    if include_ui then
      settings.ui.selected_preset = clamp(math.floor((tonumber(map["ui.selected_preset"]) or settings.ui.selected_preset) + 0.5), 1, PRESET_SLOT_COUNT)
      settings.ui.window_w = clamp(math.floor((tonumber(map["ui.window_w"]) or settings.ui.window_w) + 0.5), 640, 1800)
      settings.ui.window_h = clamp(math.floor((tonumber(map["ui.window_h"]) or settings.ui.window_h) + 0.5), 520, 1400)
      settings.ui.window_x = tonumber(map["ui.window_x"])
      settings.ui.window_y = tonumber(map["ui.window_y"])
    end

    return settings
  end

  local parts = split_delimited(serialized, "|")
  local index = 1
  local version = tonumber(parts[index]) or 1
  index = index + 1

  if version >= 1 then
    settings.variations.amount = clamp(math.floor((tonumber(parts[index]) or settings.variations.amount) + 0.5), 0, 50)
    index = index + 1
    settings.variations.mode = normalize_variation_mode(parts[index])
    index = index + 1
    settings.pitch.amount = clamp(tonumber(parts[index]) or settings.pitch.amount, 0, 24)
    index = index + 1
    settings.pitch.mode = normalize_pitch_mode(parts[index])
    index = index + 1
    settings.pitch.round_to_semitone = string_to_bool(parts[index], settings.pitch.round_to_semitone)
    index = index + 1
    settings.volume.amount = clamp(tonumber(parts[index]) or settings.volume.amount, 0, 24)
    index = index + 1
    settings.volume.mute = clamp(tonumber(parts[index]) or settings.volume.mute, 0, 100)
    index = index + 1
    settings.position.space = clamp(tonumber(parts[index]) or settings.position.space, -1, 10)
    index = index + 1
    settings.position.offset = clamp(tonumber(parts[index]) or settings.position.offset, 0, 500)
    index = index + 1
  end

  if include_ui then
    settings.ui.selected_preset = clamp(math.floor((tonumber(parts[index]) or settings.ui.selected_preset) + 0.5), 1, PRESET_SLOT_COUNT)
  end

  return settings
end

local function save_last_settings(settings)
  reaper.SetExtState(EXT_SECTION, "last_settings", serialize_settings(settings, true), true)
end

local function load_last_settings()
  local serialized = reaper.GetExtState(EXT_SECTION, "last_settings")
  return deserialize_settings(serialized, true)
end

local function make_default_item_override()
  return {
    variations = true,
    pitch = true,
    volume = true,
    pan = true,
    tone = true,
    position = true,
    track = true,
    variation_mode_override = nil,
    pitch_mode_override = nil,
  }
end

local function normalize_item_override(override)
  local normalized = make_default_item_override()
  if type(override) ~= "table" then
    return normalized
  end

  for key, value in pairs(override) do
    normalized[key] = value
  end
  normalized.variation_mode_override = override.variation_mode_override and normalize_variation_mode(override.variation_mode_override) or nil
  normalized.pitch_mode_override = override.pitch_mode_override and normalize_pitch_mode(override.pitch_mode_override) or nil
  return normalized
end

local function serialize_item_overrides(overrides)
  local lines = {}

  for guid, override in pairs(overrides or {}) do
    local data = normalize_item_override(override)
    lines[#lines + 1] = table.concat({
      guid,
      bool_to_string(data.variations ~= false),
      bool_to_string(data.pitch ~= false),
      bool_to_string(data.volume ~= false),
      bool_to_string(data.pan ~= false),
      bool_to_string(data.tone ~= false),
      bool_to_string(data.position ~= false),
      bool_to_string(data.track ~= false),
      data.variation_mode_override or "",
      data.pitch_mode_override or "",
    }, "|")
  end

  return table.concat(lines, "\n")
end

local function deserialize_item_overrides(serialized)
  local overrides = {}

  for line in tostring(serialized or ""):gmatch("[^\r\n]+") do
    local parts = split_delimited(line, "|")
    if parts[1] and parts[1] ~= "" then
      overrides[parts[1]] = normalize_item_override({
        variations = string_to_bool(parts[2], true),
        pitch = string_to_bool(parts[3], true),
        volume = string_to_bool(parts[4], true),
        pan = string_to_bool(parts[5], true),
        tone = string_to_bool(parts[6], true),
        position = string_to_bool(parts[7], true),
        track = string_to_bool(parts[8], true),
        variation_mode_override = parts[9] ~= "" and parts[9] or nil,
        pitch_mode_override = parts[10] ~= "" and parts[10] or nil,
      })
    end
  end

  return overrides
end

local function save_item_overrides(overrides)
  reaper.SetExtState(EXT_SECTION, "last_item_overrides", serialize_item_overrides(overrides), true)
end

local function load_item_overrides()
  local serialized = reaper.GetExtState(EXT_SECTION, "last_item_overrides")
  return deserialize_item_overrides(serialized)
end

local function preset_override_key(slot_index)
  return "preset_" .. tostring(slot_index) .. "_item_overrides"
end

function M.save_preset(slot, settings)
  local slot_index = clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)
  local settings_copy = deep_copy(settings or DEFAULTS)
  settings_copy.item_overrides = settings_copy.item_overrides or {}
  reaper.SetExtState(EXT_SECTION, "preset_" .. tostring(slot_index), serialize_settings(settings_copy, false), true)
  reaper.SetExtState(EXT_SECTION, preset_override_key(slot_index), serialize_item_overrides(settings_copy.item_overrides), true)
end

function M.load_preset(slot)
  local slot_index = clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)
  local serialized = reaper.GetExtState(EXT_SECTION, "preset_" .. tostring(slot_index))
  if not serialized or serialized == "" then
    return nil
  end
  local settings = deserialize_settings(serialized, false)
  settings.item_overrides = deserialize_item_overrides(reaper.GetExtState(EXT_SECTION, preset_override_key(slot_index)))
  return settings
end

local function preset_exists(slot)
  local slot_index = clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)
  local serialized = reaper.GetExtState(EXT_SECTION, "preset_" .. tostring(slot_index))
  return serialized ~= nil and serialized ~= ""
end

local function regenerate_chunk_guids(chunk)
  local out_lines = {}

  for line in tostring(chunk or ""):gmatch("[^\r\n]+") do
    local prefix = line:match("^([A-Z]*GUID)%s+")
    if prefix then
      out_lines[#out_lines + 1] = prefix .. " " .. reaper.genGuid()
    else
      out_lines[#out_lines + 1] = line
    end
  end

  return table.concat(out_lines, "\n")
end

local function duplicate_item_to_track(source_item, dest_track)
  if not source_item or not dest_track then
    return nil, "Invalid source item or destination track."
  end

  local ok, chunk = reaper.GetItemStateChunk(source_item, "", false)
  if not ok then
    return nil, "Failed to read source item state chunk."
  end

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  if not new_item then
    return nil, "Failed to create duplicated item."
  end

  if not reaper.SetItemStateChunk(new_item, regenerate_chunk_guids(chunk), false) then
    reaper.DeleteTrackMediaItem(dest_track, new_item)
    return nil, "Failed to apply duplicated item state chunk."
  end

  reaper.SetMediaItemSelected(new_item, false)
  return new_item
end

local function get_track_number(track)
  return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
end

local function get_active_take_index(item)
  local take_count = reaper.CountTakes(item)
  local active_take = reaper.GetActiveTake(item)

  for take_index = 0, take_count - 1 do
    if reaper.GetTake(item, take_index) == active_take then
      return take_index
    end
  end

  return 0
end

local function strip_extension(name)
  local value = tostring(name or "")
  return value:gsub("%.[^%.\\/]+$", "")
end

local function get_take_name_or_fallback(take, fallback_index)
  if take then
    local take_name = tostring(reaper.GetTakeName(take) or "")
    if take_name ~= "" then
      return strip_extension(take_name)
    end

    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      local source_name = tostring(reaper.GetMediaSourceFileName(source, "") or "")
      if source_name ~= "" then
        return strip_extension(source_name:match("([^\\/]+)$") or source_name)
      end
    end
  end

  return string.format("Item_%02d", fallback_index or 1)
end

local function set_take_name(take, name)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
  end
end

local function get_take_guid(take)
  if not take then
    return ""
  end

  local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  return tostring(guid or "")
end

local function get_item_guid(item)
  if not item then
    return ""
  end

  local _, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return tostring(guid or "")
end

local function get_media_item_track(item)
  if not item then
    return nil
  end

  if reaper.GetMediaItem_Track then
    return reaper.GetMediaItem_Track(item)
  end

  return reaper.GetMediaItemTrack and reaper.GetMediaItemTrack(item) or nil
end

local function collect_selected_items()
  local items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)

  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    local take = item and reaper.GetActiveTake(item) or nil
    local track = get_media_item_track(item)

    if item and take and track then
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")

      items[#items + 1] = {
        item = item,
        take = take,
        track = track,
        guid = get_item_guid(item),
        track_number = get_track_number(track),
        position = position,
        length = length,
        end_position = position + length,
        snap_offset = snap_offset,
        start_offset = start_offset,
        active_take_index = get_active_take_index(item),
        take_count = reaper.CountTakes(item),
        base_name = get_take_name_or_fallback(take, index + 1),
      }
    end
  end

  table.sort(items, function(left, right)
    if left.track_number ~= right.track_number then
      return left.track_number < right.track_number
    end
    if left.position ~= right.position then
      return left.position < right.position
    end
    return tostring(left.base_name) < tostring(right.base_name)
  end)

  return items
end

local function get_items_time_range(items)
  local start_pos = math.huge
  local end_pos = -math.huge

  for _, source in ipairs(items) do
    if source.position < start_pos then
      start_pos = source.position
    end
    if source.end_position > end_pos then
      end_pos = source.end_position
    end
  end

  if start_pos == math.huge then
    return 0.0, 0.0
  end

  return start_pos, end_pos
end

local function set_active_take_by_index(item, take_index)
  local take_count = reaper.CountTakes(item)
  if take_count <= 0 then
    return nil
  end

  local bounded_index = clamp(math.floor(take_index or 0), 0, take_count - 1)
  local take = reaper.GetTake(item, bounded_index)
  if take then
    reaper.SetActiveTake(take)
  end
  return take or reaper.GetActiveTake(item)
end

local function choose_variation_take(source_info, target_item, variation_index, mode)
  local take_count = reaper.CountTakes(target_item)
  if take_count <= 0 then
    return nil
  end

  local target_index = source_info.active_take_index or 0

  if mode == "default" and take_count > 1 then
    target_index = (target_index + variation_index) % take_count
  elseif mode == "random" and take_count > 1 then
    target_index = math.random(0, take_count - 1)
  end

  return set_active_take_by_index(target_item, target_index)
end

local function build_selection_signature(items)
  local guids = {}

  for _, item in ipairs(items or {}) do
    guids[#guids + 1] = item.guid or ""
  end

  table.sort(guids)
  return table.concat(guids, ";")
end

local function get_item_override(item_overrides, guid)
  local overrides = item_overrides or {}
  local current = overrides[guid]
  if not current then
    current = make_default_item_override()
    overrides[guid] = current
  end

  local normalized = normalize_item_override(current)
  overrides[guid] = normalized
  return normalized
end

local function should_apply_setting(item_overrides, guid, setting_name)
  local override = get_item_override(item_overrides, guid)
  return override[setting_name] ~= false
end

local function get_resolved_variation_mode(item_overrides, guid, settings)
  local override = get_item_override(item_overrides, guid)
  if override.variation_mode_override then
    return normalize_variation_mode(override.variation_mode_override)
  end
  return normalize_variation_mode(settings.variations.mode)
end

local function get_resolved_pitch_mode(item_overrides, guid, settings)
  local override = get_item_override(item_overrides, guid)
  if override.pitch_mode_override then
    return normalize_pitch_mode(override.pitch_mode_override)
  end
  return normalize_pitch_mode(settings.pitch.mode)
end

local function sample_pitch_semitones(settings)
  local up_amount = clamp(tonumber(settings.pitch.up_amount) or 0, 0, 24)
  local down_amount = clamp(tonumber(settings.pitch.down_amount) or 0, 0, 24)

  if settings.pitch.split_range then
    if up_amount <= 0 and down_amount <= 0 then
      return 0.0
    end
    return random_symmetric(1.0) >= 0
      and ((math.random() * up_amount))
      or (-(math.random() * down_amount))
  end

  return random_symmetric(clamp(tonumber(settings.pitch.amount) or 0, 0, 24))
end

local function apply_pitch_variation(target_item, take, semitones, mode)
  local chosen_mode = mode

  if chosen_mode == "random" then
    if math.random() < 0.5 then
      chosen_mode = "shift"
    else
      chosen_mode = "playrate"
    end
  end

  if approx_zero(semitones) then
    return chosen_mode
  end

  if chosen_mode == "playrate" then
    local current_rate = math.max(0.0001, reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
    local factor = 2 ^ (semitones / 12.0)
    local new_rate = current_rate * factor
    local current_length = reaper.GetMediaItemInfo_Value(target_item, "D_LENGTH")
    local new_length = current_length * (current_rate / new_rate)

    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_rate)
    reaper.SetMediaItemInfo_Value(target_item, "D_LENGTH", math.max(0.01, new_length))
  else
    local current_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", current_pitch + semitones)
  end

  return chosen_mode
end

local function apply_source_offset_mode(target_item, take, source_info, mode, difference_limit, limit_source_offset)
  if mode ~= "chaos" and mode ~= "loop" then
    return
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return
  end

  local source_length, length_is_qn = reaper.GetMediaSourceLength(source)
  if length_is_qn or not source_length or source_length <= 0 then
    return
  end

  local playrate = math.max(0.0001, reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
  local item_length = reaper.GetMediaItemInfo_Value(target_item, "D_LENGTH")
  local max_offset = 0.0
  local min_offset = 0.0

  if mode == "loop" then
    max_offset = math.max(0.0, source_length)
    reaper.SetMediaItemInfo_Value(target_item, "B_LOOPSRC", 1)
  else
    if limit_source_offset == false then
      max_offset = math.max(0.0, source_length)
    else
      max_offset = math.max(0.0, source_length - (item_length * playrate))
    end
    reaper.SetMediaItemInfo_Value(target_item, "B_LOOPSRC", 0)
  end

  local difference = clamp(tonumber(difference_limit) or 0, 0, 10)
  local base_offset = clamp(tonumber(source_info.start_offset) or 0, 0, max_offset)

  if difference > 0 then
    min_offset = clamp(base_offset - difference, 0, max_offset)
    max_offset = clamp(base_offset + difference, min_offset, max_offset)
  end

  local random_offset = min_offset
  if max_offset > min_offset then
    random_offset = min_offset + (math.random() * (max_offset - min_offset))
  end

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", random_offset)
end

local function apply_volume_variation(take, volume_db)
  if approx_zero(volume_db) then
    return
  end

  local current_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", current_volume * db_to_linear(volume_db))
end

local function apply_random_mute(item, mute_probability)
  if (tonumber(mute_probability) or 0) <= 0 then
    return
  end

  if reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1 then
    return
  end

  if math.random(0, 100000) <= ((tonumber(mute_probability) or 0) * 1000.0) then
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
  end
end

local function apply_pan_variation(take, pan_range_percent)
  local amount = clamp(tonumber(pan_range_percent) or 0, 0, 100) / 100.0
  if amount <= 0 then
    return
  end

  local current_pan = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")
  local next_pan = clamp(current_pan + random_symmetric(amount), -1.0, 1.0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", next_pan)
end

local function get_envelope_point_count(envelope_amount)
  return math.max(2, math.floor(2 + ((clamp(tonumber(envelope_amount) or 0, 0, 100) / 100.0) * 10)))
end

local function clear_envelope_points(envelope, start_time, end_time)
  if envelope then
    reaper.DeleteEnvelopePointRange(envelope, start_time, end_time)
  end
end

-- When take envelopes do not exist yet, inject the standard take-envelope
-- aliases into the item state chunk so GetTakeEnvelopeByName can resolve them.
local TAKE_ENVELOPE_CHUNKS = {
  Pitch = {
    chunk_name = "PITCHENV",
    default_value = 0.0,
  },
  Volume = {
    chunk_name = "VOLENV",
    default_value = 1.0,
    extra_lines = {
      "VOLTYPE 1",
    },
  },
  Pan = {
    chunk_name = "PANENV",
    default_value = 0.0,
  },
}

local function split_chunk_lines(chunk)
  local lines = {}
  for line in tostring(chunk or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function make_take_envelope_chunk(definition)
  local lines = {
    "<" .. definition.chunk_name,
    "EGUID " .. reaper.genGuid(),
    "ACT 1 -1",
    "VIS 0 1 1",
    "LANEHEIGHT 0 0",
    "ARM 0",
    "DEFSHAPE 0 -1 -1",
  }

  for _, extra_line in ipairs(definition.extra_lines or {}) do
    lines[#lines + 1] = extra_line
  end

  lines[#lines + 1] = string.format("PT 0 %.10f 0", definition.default_value or 0.0)
  lines[#lines + 1] = ">"
  return lines
end

local function insert_take_envelope_chunk(item, take_guid, definition)
  if not item or take_guid == "" or not definition then
    return false
  end

  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or not chunk or chunk == "" then
    return false
  end

  local lines = split_chunk_lines(chunk)
  local item_depth = -1
  local target_take_found = false
  local insert_at = nil

  for index, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")

    if item_depth == 0 and not target_take_found and trimmed == ("GUID " .. take_guid) then
      target_take_found = true
    elseif target_take_found and item_depth == 0 and (trimmed:match("^TAKE(?:%s.*)?$") or trimmed == ">") then
      insert_at = index
      break
    end

    if trimmed == ">" then
      item_depth = item_depth - 1
    elseif trimmed:sub(1, 1) == "<" then
      item_depth = item_depth + 1
    end
  end

  if not target_take_found or not insert_at then
    return false
  end

  local envelope_lines = make_take_envelope_chunk(definition)
  for offset = #envelope_lines, 1, -1 do
    table.insert(lines, insert_at, envelope_lines[offset])
  end

  local updated_chunk = table.concat(lines, "\n")
  if not reaper.SetItemStateChunk(item, updated_chunk, false) then
    return false
  end

  reaper.UpdateItemInProject(item)
  return true
end

local function find_take_by_guid(item, take_guid)
  if not item or take_guid == "" then
    return nil
  end

  local take_count = reaper.CountTakes(item)
  for take_index = 0, take_count - 1 do
    local take = reaper.GetTake(item, take_index)
    if get_take_guid(take) == take_guid then
      return take
    end
  end

  return nil
end

local function ensure_take_envelope(item, take, envelope_name)
  if not item or not take then
    return nil, take
  end

  local envelope = reaper.GetTakeEnvelopeByName(take, envelope_name)
  if envelope then
    return envelope, take
  end

  local definition = TAKE_ENVELOPE_CHUNKS[envelope_name]
  if not definition then
    return nil, take
  end

  local take_guid = get_take_guid(take)
  if take_guid == "" then
    return nil, take
  end

  if not insert_take_envelope_chunk(item, take_guid, definition) then
    return nil, take
  end

  local refreshed_take = find_take_by_guid(item, take_guid) or take
  return reaper.GetTakeEnvelopeByName(refreshed_take, envelope_name), refreshed_take
end

local function insert_scaled_take_envelope_points(envelope, item_length, value_fn)
  if not envelope then
    return
  end

  local point_count = get_envelope_point_count(item_length.envelope_amount or 0)
  local length = item_length.item_length or 0
  clear_envelope_points(envelope, -1, length + 1)

  for point_index = 0, point_count do
    local time = (point_index / point_count) * length
    reaper.InsertEnvelopePoint(envelope, time, value_fn(), 0, 0, false, true)
  end

  reaper.Envelope_SortPoints(envelope)
end

local function apply_pitch_envelope(take, item, envelope_amount, pitch_range)
  if (tonumber(envelope_amount) or 0) <= 0 or (tonumber(pitch_range) or 0) <= 0 then
    return take
  end

  local pitch_envelope, refreshed_take = ensure_take_envelope(item, take, "Pitch")
  if not pitch_envelope then
    return take
  end

  insert_scaled_take_envelope_points(pitch_envelope, {
    envelope_amount = envelope_amount,
    item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
  }, function()
    return random_symmetric(pitch_range)
  end)

  return refreshed_take or take
end

local function apply_volume_envelope(take, item, envelope_amount, volume_range_db)
  if (tonumber(envelope_amount) or 0) <= 0 or (tonumber(volume_range_db) or 0) <= 0 then
    return take
  end

  local volume_envelope, refreshed_take = ensure_take_envelope(item, take, "Volume")
  if not volume_envelope then
    return take
  end

  insert_scaled_take_envelope_points(volume_envelope, {
    envelope_amount = envelope_amount,
    item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
  }, function()
    return db_to_linear(random_symmetric(volume_range_db))
  end)

  return refreshed_take or take
end

local function apply_pan_envelope(take, item, envelope_amount, pan_range_percent)
  if (tonumber(envelope_amount) or 0) <= 0 or (tonumber(pan_range_percent) or 0) <= 0 then
    return take
  end

  local pan_envelope, refreshed_take = ensure_take_envelope(item, take, "Pan")
  if not pan_envelope then
    return take
  end

  insert_scaled_take_envelope_points(pan_envelope, {
    envelope_amount = envelope_amount,
    item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
  }, function()
    return clamp(random_symmetric(pan_range_percent / 100.0), -1.0, 1.0)
  end)

  return refreshed_take or take
end

local function find_reaeq_gain_params(take, fx_index)
  local gain_params = {}
  local param_count = reaper.TakeFX_GetNumParams(take, fx_index)

  for param_index = 0, param_count - 1 do
    local _, param_name = reaper.TakeFX_GetParamName(take, fx_index, param_index, "")
    local lowered = tostring(param_name or ""):lower()
    if lowered:find("gain", 1, true) then
      gain_params[#gain_params + 1] = param_index
    end
  end

  return gain_params
end

local function param_value_to_normalized(take, fx_index, param_index, raw_value)
  local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, param_index)
  if maximum == minimum then
    return 0.5
  end
  return clamp((raw_value - minimum) / (maximum - minimum), 0.0, 1.0)
end

local function apply_tone_randomization(take, amount_db, envelope_amount)
  if (tonumber(amount_db) or 0) <= 0 then
    return
  end

  local fx_index = reaper.TakeFX_AddByName(take, "ReaEQ", -1)
  if fx_index < 0 then
    return
  end

  local gain_params = find_reaeq_gain_params(take, fx_index)
  if #gain_params == 0 then
    return
  end

  for _, param_index in ipairs(gain_params) do
    local _, minimum, maximum = reaper.TakeFX_GetParamEx(take, fx_index, param_index)
    local gain_value = clamp(random_symmetric(amount_db), minimum, maximum)
    reaper.TakeFX_SetParam(take, fx_index, param_index, gain_value)

    if (tonumber(envelope_amount) or 0) > 0 then
      local envelope = reaper.TakeFX_GetEnvelope(take, fx_index, param_index, true)
      if envelope then
        local item = reaper.GetMediaItemTake_Item(take)
        local item_length = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
        local point_count = get_envelope_point_count(envelope_amount)
        clear_envelope_points(envelope, -1, item_length + 1)

        for point_index = 0, point_count do
          local time = (point_index / point_count) * item_length
          local point_value = clamp(random_symmetric(amount_db), minimum, maximum)
          local normalized = param_value_to_normalized(take, fx_index, param_index, point_value)
          reaper.InsertEnvelopePoint(envelope, time, normalized, 0, 0, false, true)
        end

        reaper.Envelope_SortPoints(envelope)
      end
    end
  end
end

local function apply_randomization_to_item(source_info, target_item, variation_index, settings, item_overrides, rename_take)
  local guid = source_info.guid
  local variation_mode = should_apply_setting(item_overrides, guid, "variations")
    and get_resolved_variation_mode(item_overrides, guid, settings)
    or "none"
  local take = choose_variation_take(source_info, target_item, variation_index, variation_mode)
  if not take then
    return nil, "Target item has no active take."
  end

  local semitones = 0.0
  if should_apply_setting(item_overrides, guid, "pitch") then
    local pitch_amount = settings.pitch.split_range
      and math.max(tonumber(settings.pitch.up_amount) or 0, tonumber(settings.pitch.down_amount) or 0)
      or clamp(tonumber(settings.pitch.amount) or 0, 0, 24)
    semitones = sample_pitch_semitones(settings)
    if settings.pitch.round_to_semitone then
      semitones = round_to(semitones, 0)
    end

    apply_pitch_variation(target_item, take, semitones, get_resolved_pitch_mode(item_overrides, guid, settings))
    take = apply_pitch_envelope(take, target_item, settings.pitch.envelope, pitch_amount) or take
  end

  if variation_mode ~= "none" then
    apply_source_offset_mode(
      target_item,
      take,
      source_info,
      variation_mode,
      settings.variations.difference,
      settings.variations.limit_source_offset
    )
  end

  local volume_db = 0.0
  if should_apply_setting(item_overrides, guid, "volume") then
    local volume_amount = clamp(tonumber(settings.volume.amount) or 0, 0, 24)
    volume_db = random_symmetric(volume_amount)
    apply_volume_variation(take, volume_db)
    take = apply_volume_envelope(take, target_item, settings.volume.envelope, volume_amount) or take
    apply_random_mute(target_item, clamp(tonumber(settings.volume.mute) or 0, 0, 100))
  end

  if should_apply_setting(item_overrides, guid, "pan") then
    apply_pan_variation(take, settings.pan.amount)
    take = apply_pan_envelope(take, target_item, settings.pan.envelope, settings.pan.amount) or take
  end

  if should_apply_setting(item_overrides, guid, "tone") then
    apply_tone_randomization(take, settings.tone.amount, settings.tone.envelope)
  end

  if rename_take then
    set_take_name(reaper.GetActiveTake(target_item), string.format("%s_Var%02d", source_info.base_name, variation_index))
  end

  return {
    item = target_item,
    take = reaper.GetActiveTake(target_item),
    pitch = semitones,
    volume_db = volume_db,
  }
end

local function apply_track_swap(variation_records, swap_probability, source_tracks)
  local probability = clamp(tonumber(swap_probability) or 0, 0, 100)
  if probability <= 0 or #source_tracks < 2 then
    return
  end

  for _, record in ipairs(variation_records) do
    if record.allow_track_swap and math.random(0, 100000) <= (probability * 1000.0) then
      local current_track = get_media_item_track(record.item)
      local alternate_tracks = {}

      for _, track in ipairs(source_tracks) do
        if track ~= current_track then
          alternate_tracks[#alternate_tracks + 1] = track
        end
      end

      if #alternate_tracks > 0 then
        local new_track = alternate_tracks[math.random(1, #alternate_tracks)]
        reaper.MoveMediaItemToTrack(record.item, new_track)
      end
    end
  end
end

local function apply_crossfade(item_a, item_b, overlap_sec)
  if not item_a or not item_b or overlap_sec <= 0 then
    return
  end

  local length_a = reaper.GetMediaItemInfo_Value(item_a, "D_LENGTH")
  local length_b = reaper.GetMediaItemInfo_Value(item_b, "D_LENGTH")
  local fade_length = math.min(overlap_sec, length_a, length_b)
  if fade_length <= 0 then
    return
  end

  reaper.SetMediaItemInfo_Value(item_a, "D_FADEOUTLEN", fade_length)
  reaper.SetMediaItemInfo_Value(item_b, "D_FADEINLEN", fade_length)
end

local function apply_crossfades(created_items, selected_items)
  local created_lookup = {}
  local touched_tracks = {}

  for _, item in ipairs(created_items or {}) do
    created_lookup[item] = true
    touched_tracks[get_media_item_track(item)] = true
  end
  for _, source in ipairs(selected_items or {}) do
    touched_tracks[source.track] = true
  end

  for track in pairs(touched_tracks) do
    local items = {}
    local item_count = reaper.CountTrackMediaItems(track)

    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(track, item_index)
      items[#items + 1] = item
    end

    table.sort(items, function(left, right)
      return reaper.GetMediaItemInfo_Value(left, "D_POSITION") < reaper.GetMediaItemInfo_Value(right, "D_POSITION")
    end)

    for item_index = 1, #items - 1 do
      local current_item = items[item_index]
      local next_item = items[item_index + 1]
      local current_end = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION") + reaper.GetMediaItemInfo_Value(current_item, "D_LENGTH")
      local next_start = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
      local overlap = current_end - next_start

      if overlap > 0 and (created_lookup[current_item] or created_lookup[next_item]) then
        apply_crossfade(current_item, next_item, overlap)
      end
    end
  end
end

local function shift_project_markers_after(start_pos, offset)
  if offset == 0 or not reaper.EnumProjectMarkers3 or not reaper.SetProjectMarkerByIndex2 then
    return
  end

  local updates = {}
  local marker_index = 0

  while true do
    local retval, is_region, position, region_end, name, displayed_id, color =
      reaper.EnumProjectMarkers3(0, marker_index)
    if retval == 0 then
      break
    end

    if position >= start_pos then
      updates[#updates + 1] = {
        marker_index = marker_index,
        is_region = is_region,
        position = position + offset,
        region_end = is_region and (region_end + offset) or region_end,
        displayed_id = displayed_id,
        name = name,
        color = color,
      }
    elseif is_region and region_end > start_pos then
      updates[#updates + 1] = {
        marker_index = marker_index,
        is_region = is_region,
        position = position,
        region_end = region_end + offset,
        displayed_id = displayed_id,
        name = name,
        color = color,
      }
    end

    marker_index = marker_index + 1
  end

  for _, update in ipairs(updates) do
    reaper.SetProjectMarkerByIndex2(
      0,
      update.marker_index,
      update.is_region,
      update.position,
      update.region_end,
      update.displayed_id,
      update.name or "",
      update.color or 0,
      0
    )
  end

  if #updates > 0 then
    reaper.SetProjectMarkerByIndex2(0, -1, false, 0, 0, -1, "", 0, 2)
  end
end

local function apply_ripple(mode, created_items, selected_items, ripple_markers)
  if mode == "off" or #created_items == 0 then
    return
  end

  local excluded = {}
  for _, item in ipairs(created_items or {}) do
    excluded[item] = true
  end
  for _, source in ipairs(selected_items or {}) do
    excluded[source.item] = true
  end

  if mode == "all" then
    local ripple_start = math.huge
    local ripple_end = -math.huge

    for _, item in ipairs(created_items) do
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      ripple_start = math.min(ripple_start, position)
      ripple_end = math.max(ripple_end, item_end)
    end

    local ripple_amount = ripple_end - ripple_start
    if ripple_amount <= 0 then
      return
    end

    local total_items = reaper.CountMediaItems(0)
    for item_index = 0, total_items - 1 do
      local item = reaper.GetMediaItem(0, item_index)
      if not excluded[item] then
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        if position >= ripple_start then
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", position + ripple_amount)
        end
      end
    end

    if ripple_markers then
      shift_project_markers_after(ripple_start, ripple_amount)
    end

    return
  end

  local track_ranges = {}
  for _, item in ipairs(created_items) do
    local track = get_media_item_track(item)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local range = track_ranges[track]
    if not range then
      range = { start_pos = position, end_pos = item_end }
      track_ranges[track] = range
    else
      range.start_pos = math.min(range.start_pos, position)
      range.end_pos = math.max(range.end_pos, item_end)
    end
  end

  for track, range in pairs(track_ranges) do
    local ripple_amount = range.end_pos - range.start_pos
    if ripple_amount > 0 then
      local item_count = reaper.CountTrackMediaItems(track)
      for item_index = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if not excluded[item] then
          local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          if position >= range.start_pos then
            reaper.SetMediaItemInfo_Value(item, "D_POSITION", position + ripple_amount)
          end
        end
      end
    end
  end
end

local function copy_envelope_segment_to_groups(envelope, source_start, source_end, groups)
  if not envelope or #groups == 0 then
    return
  end

  local points = {}
  local point_count = reaper.CountEnvelopePoints(envelope)
  local has_points = point_count > 0
  local start_value = nil
  local end_value = nil

  if has_points and reaper.Envelope_Evaluate then
    local _, value_start = reaper.Envelope_Evaluate(envelope, source_start, 44100, 1)
    local _, value_end = reaper.Envelope_Evaluate(envelope, source_end, 44100, 1)
    start_value = value_start
    end_value = value_end
  end

  for point_index = 0, point_count - 1 do
    local _, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, point_index)
    if time >= source_start and time <= source_end then
      points[#points + 1] = {
        time = time,
        value = value,
        shape = shape,
        tension = tension,
        selected = selected,
      }
    end
  end

  if #points == 0 and start_value == nil then
    return
  end

  for _, group in ipairs(groups) do
    local offset = group.start_pos - source_start

    if start_value ~= nil then
      reaper.InsertEnvelopePoint(envelope, source_start + offset, start_value, 0, 0, false, true)
      reaper.InsertEnvelopePoint(envelope, source_end + offset, end_value or start_value, 0, 0, false, true)
    end

    for _, point in ipairs(points) do
      reaper.InsertEnvelopePoint(
        envelope,
        point.time + offset,
        point.value,
        point.shape or 0,
        point.tension or 0,
        point.selected or false,
        true
      )
    end
  end

  reaper.Envelope_SortPoints(envelope)
end

local function copy_automation_to_variations(selected_items, groups, group_start, group_end)
  if #groups == 0 then
    return
  end

  local visited_tracks = {}
  for _, source in ipairs(selected_items or {}) do
    local track = source.track
    if not visited_tracks[track] then
      visited_tracks[track] = true
      local envelope_count = reaper.CountTrackEnvelopes(track)
      for envelope_index = 0, envelope_count - 1 do
        local envelope = reaper.GetTrackEnvelope(track, envelope_index)
        if envelope then
          copy_envelope_segment_to_groups(envelope, group_start, group_end, groups)
        end
      end
    end
  end
end

local function highlight_variation_groups(groups)
  if #groups == 0 then
    return
  end

  local start_pos = math.huge
  local end_pos = -math.huge

  for _, group in ipairs(groups) do
    start_pos = math.min(start_pos, group.start_pos)
    end_pos = math.max(end_pos, group.end_pos)
  end

  reaper.GetSet_LoopTimeRange(true, false, start_pos, end_pos, false)
end

local function update_playback_auto_skip()
  if not ui_state.settings.transport.auto_skip then
    ui_state.playback_group_index = 0
    return
  end

  local groups = ui_state.last_generated_groups or {}
  if #groups == 0 then
    ui_state.playback_group_index = 0
    return
  end

  local play_state = reaper.GetPlayState and reaper.GetPlayState() or 0
  if (play_state % 2) ~= 1 then
    ui_state.playback_group_index = 0
    return
  end

  local play_position = reaper.GetPlayPosition()
  local current_index = 0

  for group_index, group in ipairs(groups) do
    if play_position >= group.start_pos and play_position < group.end_pos then
      current_index = group_index
      break
    end
  end

  local target_index = current_index
  if target_index == 0 then
    target_index = ui_state.playback_group_index or 0
  end

  if target_index <= 0 or target_index > #groups then
    ui_state.playback_group_index = 0
    return
  end

  local current_group = groups[target_index]
  if target_index < #groups and play_position >= (current_group.end_pos - 0.01) then
    local next_group = groups[target_index + 1]
    reaper.SetEditCurPos(next_group.start_pos, true, true)
    ui_state.playback_group_index = target_index + 1
    return
  end

  ui_state.playback_group_index = current_index > 0 and current_index or target_index
end

local function select_only_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function move_edit_cursor_to_first_item(items)
  local first_position = nil

  for _, item in ipairs(items) do
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if not first_position or position < first_position then
      first_position = position
    end
  end

  if first_position then
    reaper.SetEditCurPos(first_position, true, false)
  end
end

local function run_variation_generation(settings, override_amount, custom_undo_label)
  local effective_settings = deep_copy(settings or DEFAULTS)
  local settings_to_persist = deep_copy(effective_settings)
  local item_overrides = effective_settings.item_overrides or {}
  local selected_items = collect_selected_items()
  local source_tracks = {}
  local seen_tracks = {}
  local variation_amount = effective_settings.variations.amount
  local created_items = {}
  local variation_groups = {}

  if override_amount ~= nil then
    variation_amount = override_amount
  end
  variation_amount = clamp(math.floor((variation_amount or 0) + 0.5), 0, 50)
  effective_settings.variations.amount = variation_amount

  if #selected_items == 0 then
    return false, "No selected media items with active takes were found."
  end

  for _, source in ipairs(selected_items) do
    if not seen_tracks[source.track] then
      seen_tracks[source.track] = true
      source_tracks[#source_tracks + 1] = source.track
    end
  end

  save_last_settings(settings_to_persist)
  save_item_overrides(item_overrides)

  local undo_label = custom_undo_label
  if not undo_label or undo_label == "" then
    if variation_amount == 0 then
      undo_label = "Randomize Selected Items"
    else
      undo_label = "Generate Variations"
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, result_or_err = pcall(function()
    local group_start, group_end = get_items_time_range(selected_items)

    if variation_amount == 0 then
      local group_offset_sec = random_symmetric((tonumber(effective_settings.position.offset) or 0) / 1000.0)
      local direct_items = {}
      local randomized_count = 0

      for _, source in ipairs(selected_items) do
        local result, err = apply_randomization_to_item(source, source.item, 1, effective_settings, item_overrides, false)
        if not result then
          error(err or "Failed to randomize selected item.")
        end
        direct_items[#direct_items + 1] = source.item
        randomized_count = randomized_count + 1

        if should_apply_setting(item_overrides, source.guid, "position") and not approx_zero(group_offset_sec) then
          reaper.SetMediaItemInfo_Value(source.item, "D_POSITION", source.position + group_offset_sec)
        end
      end

      local direct_group_start = math.huge
      local direct_group_end = -math.huge
      for _, item in ipairs(direct_items) do
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        direct_group_start = math.min(direct_group_start, position)
        direct_group_end = math.max(direct_group_end, item_end)
      end
      if direct_group_start == math.huge then
        direct_group_start = group_start
        direct_group_end = group_end
      end

      select_only_items(direct_items)
      move_edit_cursor_to_first_item(direct_items)
      reaper.GetSet_LoopTimeRange(true, false, direct_group_start, direct_group_end, false)

      return {
        created_items = {},
        created_count = 0,
        randomized_existing = randomized_count,
        variation_count = 0,
        groups = {},
      }
    end

    local previous_group_end = group_end
    local space = clamp(tonumber(effective_settings.position.space) or 0, -1, 10)

    for variation_index = 1, variation_amount do
      local group_offset_sec = random_symmetric((tonumber(effective_settings.position.offset) or 0) / 1000.0)
      local scheduled_start = previous_group_end
      if not approx_zero(space) then
        scheduled_start = scheduled_start + space
      end

      local variation_end = scheduled_start
      local variation_start = math.huge
      local variation_records = {}

      for _, source in ipairs(selected_items) do
        local new_item, duplicate_err = duplicate_item_to_track(source.item, source.track)
        if not new_item then
          error(duplicate_err or "Failed to duplicate selected item.")
        end

        local relative_position = source.position - group_start
        local base_group_start = scheduled_start
        if should_apply_setting(item_overrides, source.guid, "position") then
          base_group_start = base_group_start + group_offset_sec
        end
        local item_position = base_group_start + relative_position
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", item_position)

        local result, err = apply_randomization_to_item(source, new_item, variation_index, effective_settings, item_overrides, true)
        if not result then
          error(err or "Failed to apply variation settings.")
        end

        created_items[#created_items + 1] = new_item
        variation_records[#variation_records + 1] = {
          item = new_item,
          source_guid = source.guid,
          allow_track_swap = should_apply_setting(item_overrides, source.guid, "track"),
        }

        item_position = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(new_item, "D_LENGTH")
        local item_end = item_position + item_length
        variation_start = math.min(variation_start, item_position)

        if item_end > variation_end then
          variation_end = item_end
        end
      end

      apply_track_swap(variation_records, effective_settings.track.amount, source_tracks)
      variation_groups[#variation_groups + 1] = {
        index = variation_index,
        start_pos = variation_start,
        end_pos = variation_end,
      }

      previous_group_end = math.max(previous_group_end, variation_end)
    end

    table.sort(variation_groups, function(left, right)
      if left.start_pos ~= right.start_pos then
        return left.start_pos < right.start_pos
      end
      return (left.index or 0) < (right.index or 0)
    end)

    if effective_settings.main.ripple ~= "off" then
      apply_ripple(
        normalize_ripple_mode(effective_settings.main.ripple),
        created_items,
        selected_items,
        effective_settings.main.ripple_markers
      )
    end

    if effective_settings.main.copy_automation
      and effective_settings.main.ripple ~= "off"
      and approx_zero(space) then
      copy_automation_to_variations(selected_items, variation_groups, group_start, group_end)
    end

    if effective_settings.main.crossfade and (tonumber(effective_settings.position.space) or 0) < 0 then
      apply_crossfades(created_items, selected_items)
    end

    select_only_items(created_items)
    move_edit_cursor_to_first_item(created_items)
    highlight_variation_groups(variation_groups)

    return {
      created_items = created_items,
      created_count = #created_items,
      randomized_existing = 0,
      variation_count = variation_amount,
      groups = variation_groups,
    }
  end)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock(undo_label, -1)
    return true, result_or_err
  end

  reaper.Undo_EndBlock(undo_label .. " (failed)", -1)
  return false, result_or_err
end

function M.run_with_settings(settings, override_amount, custom_undo_label)
  return run_variation_generation(settings, override_amount, custom_undo_label)
end

function M.run_preset_randomize(slot)
  local preset = M.load_preset(slot)
  if not preset then
    reaper.ShowMessageBox("Preset " .. tostring(slot) .. " is not configured.", SCRIPT_TITLE, 0)
    return false
  end

  preset.ui.selected_preset = clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)
  local ok, result_or_err = run_variation_generation(
    preset,
    0,
    string.format("Randomize Selected Items (Preset %d)", preset.ui.selected_preset)
  )

  if not ok then
    reaper.ShowMessageBox("Randomize failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
  end

  return ok, result_or_err
end

function M.run_preset_new_variation(slot)
  local preset = M.load_preset(slot)
  if not preset then
    reaper.ShowMessageBox("Preset " .. tostring(slot) .. " is not configured.", SCRIPT_TITLE, 0)
    return false
  end

  preset.ui.selected_preset = clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, PRESET_SLOT_COUNT)
  local ok, result_or_err = run_variation_generation(
    preset,
    1,
    string.format("Generate Variation (Preset %d)", preset.ui.selected_preset)
  )

  if not ok then
    reaper.ShowMessageBox("New Variation failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
  end

  return ok, result_or_err
end

local ui_state = {
  settings = load_last_settings(),
  item_overrides = load_item_overrides(),
  selected_items = {},
  selection_signature = "",
  last_generated_groups = {},
  playback_group_index = 0,
  active_slider = nil,
  prev_left_down = false,
  prev_right_down = false,
  status_text = "Select item(s), tune settings, then press Apply.",
  should_close = false,
  preset_cache = {},
  prev_char = 0,
  imgui_context = nil,
  imgui_open = true,
}

local function refresh_preset_cache()
  for slot = 1, PRESET_SLOT_COUNT do
    ui_state.preset_cache[slot] = preset_exists(slot)
  end
end

local function refresh_selected_items_state()
  local items = collect_selected_items()
  local signature = build_selection_signature(items)
  ui_state.selected_items = items

  if signature ~= ui_state.selection_signature then
    ui_state.selection_signature = signature
    for _, item in ipairs(items) do
      ui_state.item_overrides[item.guid] = get_item_override(ui_state.item_overrides, item.guid)
    end
  end
end

local function persist_ui_state()
  save_last_settings(ui_state.settings)
  save_item_overrides(ui_state.item_overrides)
end

local function cycle_override_mode(current_value, first_mode, second_mode)
  if current_value == first_mode then
    return second_mode
  end
  if current_value == second_mode then
    return nil
  end
  return first_mode
end

local function navigate_variation(direction)
  local groups = ui_state.last_generated_groups or {}
  if #groups == 0 then
    ui_state.status_text = "No generated variation groups to navigate."
    return
  end

  local cursor_position = reaper.GetCursorPosition()
  local target_group = nil

  if direction > 0 then
    for _, group in ipairs(groups) do
      if group.start_pos > (cursor_position + 1e-6) then
        target_group = group
        break
      end
    end
    target_group = target_group or groups[1]
  else
    for group_index = #groups, 1, -1 do
      local group = groups[group_index]
      if group.start_pos < (cursor_position - 1e-6) then
        target_group = group
        break
      end
    end
    target_group = target_group or groups[#groups]
  end

  if target_group then
    reaper.SetEditCurPos(target_group.start_pos, true, false)
    reaper.GetSet_LoopTimeRange(true, false, target_group.start_pos, target_group.end_pos, false)
    ui_state.status_text = string.format("Moved to variation %d.", target_group.index or 1)
  end
end

local function selected_item_summary()
  local selected_count = #ui_state.selected_items
  if selected_count == 0 then
    return "No media items selected."
  end

  if selected_count == 1 then
    return "1 item selected."
  end

  return string.format("%d items selected.", selected_count)
end

local function draw_text(text, x, y, r, g, b, a)
  gfx.set(r or 1.0, g or 1.0, b or 1.0, a or 1.0)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(text)
end

local function draw_rect(x, y, w, h, r, g, b, a, filled)
  gfx.set(r or 1.0, g or 1.0, b or 1.0, a or 1.0)
  gfx.rect(x, y, w, h, filled ~= false)
end

local function button(label, x, y, w, h, highlighted, muted)
  local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, y, w, h)
  local clicked = hovered and (has_mouse_cap(1) and not ui_state.prev_left_down)

  local base_r = 0.16
  local base_g = 0.20
  local base_b = 0.24

  if muted then
    base_r = 0.12
    base_g = 0.12
    base_b = 0.12
  elseif highlighted then
    base_r = 0.20
    base_g = 0.42
    base_b = 0.70
  elseif hovered then
    base_r = 0.24
    base_g = 0.28
    base_b = 0.32
  end

  draw_rect(x, y, w, h, base_r, base_g, base_b, 1.0, true)
  draw_rect(x, y, w, h, 0.08, 0.10, 0.12, 1.0, false)

  local text_w, text_h = gfx.measurestr(label)
  draw_text(label, x + ((w - text_w) * 0.5), y + ((h - text_h) * 0.5), 0.96, 0.96, 0.96, 1.0)

  return clicked
end

local function cycle_value(current_value, options)
  local current_index = 1

  for index, option in ipairs(options) do
    if option == current_value then
      current_index = index
      break
    end
  end

  current_index = current_index + 1
  if current_index > #options then
    current_index = 1
  end

  return options[current_index]
end

local function draw_slider(id, label, value, min_value, max_value, step, formatter, x, y)
  local normalized = 0.0
  local track_y = y + 16
  local value_x = x + SLIDER_W + 20
  local hit_y = track_y - 5
  local hit_h = SLIDER_H + 10

  if max_value > min_value then
    normalized = (value - min_value) / (max_value - min_value)
  end
  normalized = clamp(normalized, 0.0, 1.0)

  local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, hit_y, SLIDER_W, hit_h)

  if hovered and has_mouse_cap(1) and not ui_state.prev_left_down then
    ui_state.active_slider = id
  end

  if ui_state.active_slider == id and has_mouse_cap(1) then
    local drag_normalized = clamp((gfx.mouse_x - x) / SLIDER_W, 0.0, 1.0)
    local raw_value = min_value + ((max_value - min_value) * drag_normalized)
    local stepped_value = round_to(raw_value / step, 0) * step
    value = clamp(stepped_value, min_value, max_value)
  end

  draw_text(label, x, y, 0.94, 0.94, 0.94, 1.0)
  draw_text(formatter(value), value_x, y, 0.90, 0.90, 0.90, 1.0)

  draw_rect(x, track_y, SLIDER_W, SLIDER_H, 0.16, 0.17, 0.18, 1.0, true)
  draw_rect(x, track_y, SLIDER_W, SLIDER_H, 0.08, 0.10, 0.12, 1.0, false)
  draw_rect(x, track_y, SLIDER_W * normalized, SLIDER_H, 0.22, 0.58, 0.88, 1.0, true)

  local handle_x = x + (SLIDER_W * normalized)
  draw_rect(handle_x - 4, track_y - 3, 8, SLIDER_H + 6, 0.96, 0.96, 0.96, 1.0, true)

  return value
end

local function draw_section_header(label, y)
  draw_text(label, WINDOW_PADDING, y, 1.0, 1.0, 1.0, 1.0)
  draw_rect(WINDOW_PADDING + 140, y + 8, WINDOW_W - (WINDOW_PADDING * 2) - 140, 1, 0.26, 0.28, 0.30, 1.0, true)
end

local function apply_from_ui()
  ui_state.settings.item_overrides = deep_copy(ui_state.item_overrides)
  persist_ui_state()
  local ok, result_or_err = run_variation_generation(ui_state.settings, nil, nil)

  if ok then
    ui_state.last_generated_groups = result_or_err.groups or {}
    if result_or_err.variation_count == 0 then
      ui_state.status_text = string.format(
        "Randomized %d selected item(s) in place.",
        result_or_err.randomized_existing or 0
      )
    else
      ui_state.status_text = string.format(
        "Created %d item(s) across %d variation group(s).",
        result_or_err.created_count or 0,
        result_or_err.variation_count or 0
      )
    end
  else
    ui_state.last_generated_groups = {}
    ui_state.status_text = "Error: " .. tostring(result_or_err)
    reaper.ShowMessageBox("Variation generation failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
  end
end

local function reset_ui_settings()
  local current_ui = deep_copy(ui_state.settings.ui or DEFAULTS.ui)
  ui_state.settings = deep_copy(DEFAULTS)
  ui_state.settings.ui = current_ui
  ui_state.item_overrides = {}
  refresh_preset_cache()
  ui_state.status_text = "Settings reset to defaults."
end

local function save_selected_preset()
  local slot = ui_state.settings.ui.selected_preset
  local preset_settings = deep_copy(ui_state.settings)
  preset_settings.item_overrides = deep_copy(ui_state.item_overrides)
  M.save_preset(slot, preset_settings)
  refresh_preset_cache()
  persist_ui_state()
  ui_state.status_text = string.format("Saved current settings to preset %d.", slot)
end

local function load_selected_preset()
  local slot = ui_state.settings.ui.selected_preset
  local preset = M.load_preset(slot)
  if not preset then
    ui_state.status_text = string.format("Preset %d is empty.", slot)
    return
  end

  local current_ui = deep_copy(ui_state.settings.ui or DEFAULTS.ui)
  preset.ui.selected_preset = slot
  preset.ui.window_x = current_ui.window_x
  preset.ui.window_y = current_ui.window_y
  preset.ui.window_w = current_ui.window_w
  preset.ui.window_h = current_ui.window_h
  ui_state.settings = preset
  ui_state.item_overrides = deep_copy(preset.item_overrides or {})
  persist_ui_state()
  ui_state.status_text = string.format("Loaded preset %d.", slot)
end

local function draw_gui()
  local y = WINDOW_PADDING
  local slider_x = WINDOW_PADDING + 16
  local row_y = 0

  draw_rect(0, 0, WINDOW_W, WINDOW_H, 0.09, 0.10, 0.11, 1.0, true)

  gfx.setfont(1, "Verdana", 18)
  draw_text("Sound Variation Generator", WINDOW_PADDING, y, 1.0, 1.0, 1.0, 1.0)
  gfx.setfont(1, "Verdana", 14)
  draw_text(selected_item_summary(), WINDOW_W - 200, y + 3, 0.80, 0.83, 0.86, 1.0)
  y = y + 30

  draw_section_header("Main", y)
  y = y + 22
  draw_text("gfx fallback exposes Phase 3 globals. Item overrides remain easier in ReaImGui.", WINDOW_PADDING + 8, y, 0.70, 0.73, 0.77, 1.0)
  y = y + 24

  draw_text("Ripple", slider_x, y, 0.94, 0.94, 0.94, 1.0)
  if button(
    RIPPLE_MODE_LABELS[ui_state.settings.main.ripple],
    slider_x,
    y + 14,
    140,
    BUTTON_H,
    ui_state.settings.main.ripple ~= "off",
    false
  ) then
    ui_state.settings.main.ripple = cycle_value(ui_state.settings.main.ripple, RIPPLE_MODES)
  end
  if button("Crossfade", slider_x + 170, y + 14, 110, BUTTON_H, ui_state.settings.main.crossfade, false) then
    ui_state.settings.main.crossfade = not ui_state.settings.main.crossfade
  end
  if button("Copy Automation", slider_x + 292, y + 14, 138, BUTTON_H, ui_state.settings.main.copy_automation, false) then
    ui_state.settings.main.copy_automation = not ui_state.settings.main.copy_automation
  end
  y = y + 48

  row_y = y
  if button("Move Markers", slider_x, row_y, 130, BUTTON_H, ui_state.settings.main.ripple_markers, false) then
    ui_state.settings.main.ripple_markers = not ui_state.settings.main.ripple_markers
  end
  if button("Auto Skip", slider_x + 142, row_y, 110, BUTTON_H, ui_state.settings.transport.auto_skip, false) then
    ui_state.settings.transport.auto_skip = not ui_state.settings.transport.auto_skip
  end
  y = y + BUTTON_H + 10

  draw_section_header("Variations", y)
  y = y + 22
  ui_state.settings.variations.amount = draw_slider(
    "variation_amount",
    "Amount",
    ui_state.settings.variations.amount,
    0,
    50,
    1,
    function(current)
      return string.format("%d", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.variations.difference = draw_slider(
    "variation_difference",
    "Difference",
    ui_state.settings.variations.difference,
    0,
    10,
    0.01,
    function(current)
      if approx_zero(current) then
        return "Max"
      end
      return string.format("%.2f s", current)
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  draw_text("Mode", slider_x, y, 0.94, 0.94, 0.94, 1.0)
  if button(
    VARIATION_MODE_LABELS[ui_state.settings.variations.mode],
    slider_x,
    y + 14,
    140,
    BUTTON_H,
    true,
    false
  ) then
    ui_state.settings.variations.mode = cycle_value(ui_state.settings.variations.mode, VARIATION_MODES)
  end
  if button(
    "Limit Source Offset",
    slider_x + 170,
    y + 14,
    160,
    BUTTON_H,
    ui_state.settings.variations.limit_source_offset,
    false
  ) then
    ui_state.settings.variations.limit_source_offset = not ui_state.settings.variations.limit_source_offset
  end
  draw_text("Amount 0 randomizes the originals in place.", slider_x + 340, y + 18, 0.70, 0.73, 0.77, 1.0)
  y = y + 48

  draw_section_header("Pitch", y)
  y = y + 22
  if button("Split Up / Down", slider_x, y, 140, BUTTON_H, ui_state.settings.pitch.split_range, false) then
    ui_state.settings.pitch.split_range = not ui_state.settings.pitch.split_range
  end
  y = y + BUTTON_H + 8

  if ui_state.settings.pitch.split_range then
    ui_state.settings.pitch.up_amount = draw_slider(
      "pitch_up_amount",
      "Pitch Up",
      ui_state.settings.pitch.up_amount,
      0,
      24,
      0.1,
      function(current)
        return string.format("%.1f st", current)
      end,
      slider_x,
      y
    )
    y = y + ROW_HEIGHT

    ui_state.settings.pitch.down_amount = draw_slider(
      "pitch_down_amount",
      "Pitch Down",
      ui_state.settings.pitch.down_amount,
      0,
      24,
      0.1,
      function(current)
        return string.format("%.1f st", current)
      end,
      slider_x,
      y
    )
    y = y + ROW_HEIGHT
  else
    ui_state.settings.pitch.amount = draw_slider(
      "pitch_amount",
      "Amount",
      ui_state.settings.pitch.amount,
      0,
      24,
      0.1,
      function(current)
        return string.format("%.1f st", current)
      end,
      slider_x,
      y
    )
    y = y + ROW_HEIGHT
  end

  ui_state.settings.pitch.envelope = draw_slider(
    "pitch_envelope",
    "Envelope",
    ui_state.settings.pitch.envelope,
    0,
    100,
    1,
    function(current)
      return string.format("%d", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  draw_text("Mode", slider_x, y, 0.94, 0.94, 0.94, 1.0)
  if button(
    PITCH_MODE_LABELS[ui_state.settings.pitch.mode],
    slider_x,
    y + 14,
    140,
    BUTTON_H,
    true,
    false
  ) then
    ui_state.settings.pitch.mode = cycle_value(ui_state.settings.pitch.mode, PITCH_MODES)
  end

  local round_label = ui_state.settings.pitch.round_to_semitone and "Round: On" or "Round: Off"
  if button(round_label, slider_x + 170, y + 14, 140, BUTTON_H, ui_state.settings.pitch.round_to_semitone, false) then
    ui_state.settings.pitch.round_to_semitone = not ui_state.settings.pitch.round_to_semitone
  end
  y = y + 48

  draw_section_header("Position", y)
  y = y + 22
  ui_state.settings.position.space = draw_slider(
    "position_space",
    "Space",
    ui_state.settings.position.space,
    -1,
    10,
    0.01,
    function(current)
      if approx_zero(current) then
        return "Auto"
      end
      return string.format("%.2f s", current)
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.position.offset = draw_slider(
    "position_offset",
    "Offset",
    ui_state.settings.position.offset,
    0,
    500,
    1,
    function(current)
      return string.format("%d ms", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT + 6

  draw_section_header("Track", y)
  y = y + 22
  ui_state.settings.track.amount = draw_slider(
    "track_amount",
    "Swap",
    ui_state.settings.track.amount,
    0,
    100,
    1,
    function(current)
      return string.format("%d%%", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT + 6

  draw_section_header("Volume", y)
  y = y + 22
  ui_state.settings.volume.amount = draw_slider(
    "volume_amount",
    "Amount",
    ui_state.settings.volume.amount,
    0,
    24,
    0.1,
    function(current)
      return string.format("%.1f dB", current)
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.volume.envelope = draw_slider(
    "volume_envelope",
    "Envelope",
    ui_state.settings.volume.envelope,
    0,
    100,
    1,
    function(current)
      return string.format("%d", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.volume.mute = draw_slider(
    "volume_mute",
    "Mute",
    ui_state.settings.volume.mute,
    0,
    100,
    1,
    function(current)
      return string.format("%d%%", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT + 6

  draw_section_header("Pan", y)
  y = y + 22
  ui_state.settings.pan.amount = draw_slider(
    "pan_amount",
    "Amount",
    ui_state.settings.pan.amount,
    0,
    100,
    1,
    function(current)
      return string.format("%d%%", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.pan.envelope = draw_slider(
    "pan_envelope",
    "Envelope",
    ui_state.settings.pan.envelope,
    0,
    100,
    1,
    function(current)
      return string.format("%d", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT + 6

  draw_section_header("Tone", y)
  y = y + 22
  ui_state.settings.tone.amount = draw_slider(
    "tone_amount",
    "Amount",
    ui_state.settings.tone.amount,
    0,
    12,
    0.1,
    function(current)
      return string.format("%.1f dB", current)
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT

  ui_state.settings.tone.envelope = draw_slider(
    "tone_envelope",
    "Envelope",
    ui_state.settings.tone.envelope,
    0,
    100,
    1,
    function(current)
      return string.format("%d", math.floor(current + 0.5))
    end,
    slider_x,
    y
  )
  y = y + ROW_HEIGHT + 6

  draw_section_header("Presets", y)
  y = y + 24

  local preset_x = slider_x
  for slot = 1, PRESET_SLOT_COUNT do
    local label = tostring(slot)
    if ui_state.preset_cache[slot] then
      label = label .. "*"
    end

    if button(label, preset_x, y, 40, BUTTON_H, ui_state.settings.ui.selected_preset == slot, false) then
      ui_state.settings.ui.selected_preset = slot
    end
    preset_x = preset_x + 48
  end

  if button("Save", slider_x + 280, y, 80, BUTTON_H, false, false) then
    save_selected_preset()
  end
  if button("Load", slider_x + 370, y, 80, BUTTON_H, false, false) then
    load_selected_preset()
  end
  if button("Reset", slider_x + 460, y, 80, BUTTON_H, false, false) then
    reset_ui_settings()
  end

  y = y + BUTTON_H + 12
  if button("Prev (D)", slider_x, y, 90, BUTTON_H, false, false) then
    navigate_variation(-1)
  end
  if button("Next (F)", slider_x + 102, y, 90, BUTTON_H, false, false) then
    navigate_variation(1)
  end
  draw_text("Use ReaImGui for per-item override editing.", slider_x + 210, y + 6, 0.70, 0.73, 0.77, 1.0)

  local bottom_y = WINDOW_H - 78
  if button("Apply (Enter)", WINDOW_PADDING, bottom_y, 160, 34, true, false) then
    apply_from_ui()
  end
  if button("Close", WINDOW_PADDING + 172, bottom_y, 100, 34, false, false) then
    ui_state.should_close = true
  end

  draw_text(ui_state.status_text, WINDOW_PADDING, WINDOW_H - 34, 0.84, 0.86, 0.90, 1.0)
end

local function imgui_cycle_button(label, current_value, options, labels)
  if ImGui.Button(ui_state.imgui_context, string.format("%s: %s", label, labels[current_value] or tostring(current_value)), 150, 0) then
    return cycle_value(current_value, options)
  end
  return current_value
end

local function imgui_override_button(label, override, toggle_key, mode_key, first_mode, second_mode)
  local active = override[toggle_key] ~= false
  local display = active and "On" or "Off"

  if mode_key and override[mode_key] then
    if mode_key == "variation_mode_override" then
      display = VARIATION_MODE_LABELS[override[mode_key]] or display
    else
      display = PITCH_MODE_LABELS[override[mode_key]] or display
    end
  end

  if ImGui.SmallButton(ui_state.imgui_context, string.format("%s %s", label, display)) then
    override[toggle_key] = not active
  end

  if mode_key and active and ImGui.IsItemClicked(ui_state.imgui_context, 1) then
    override[mode_key] = cycle_override_mode(override[mode_key], first_mode, second_mode)
  end
end

local function draw_imgui_overrides()
  local table_flags = 0
  if ImGui.TableFlags_Borders then
    table_flags = table_flags | ImGui.TableFlags_Borders
  end
  if ImGui.TableFlags_RowBg then
    table_flags = table_flags | ImGui.TableFlags_RowBg
  end
  if ImGui.TableFlags_SizingStretchProp then
    table_flags = table_flags | ImGui.TableFlags_SizingStretchProp
  end
  local width_stretch = ImGui.TableColumnFlags_WidthStretch or 0

  ImGui.Separator(ui_state.imgui_context)
  ImGui.Text(ui_state.imgui_context, "Item Overrides")
  ImGui.Text(ui_state.imgui_context, "Left click toggles apply. Right click Var/Pitch cycles mode override.")

  if #ui_state.selected_items == 0 then
    ImGui.Text(ui_state.imgui_context, "No selected items.")
    return
  end

  if not ImGui.BeginTable then
    for _, item in ipairs(ui_state.selected_items) do
      local override = get_item_override(ui_state.item_overrides, item.guid)
      ImGui.Text(ui_state.imgui_context, item.base_name)
      ImGui.SameLine(ui_state.imgui_context, 280)
      imgui_override_button("Var", override, "variations", "variation_mode_override", "chaos", "default")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Pit", override, "pitch", "pitch_mode_override", "playrate", "shift")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Vol", override, "volume")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Pan", override, "pan")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Ton", override, "tone")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Pos", override, "position")
      ImGui.SameLine(ui_state.imgui_context)
      imgui_override_button("Trk", override, "track")
    end
    return
  end

  if ImGui.BeginTable(ui_state.imgui_context, "ItemOverrides", 8, table_flags) then
    ImGui.TableSetupColumn(ui_state.imgui_context, "Item", width_stretch)
    ImGui.TableSetupColumn(ui_state.imgui_context, "Var")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Pit")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Vol")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Pan")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Ton")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Pos")
    ImGui.TableSetupColumn(ui_state.imgui_context, "Trk")
    ImGui.TableHeadersRow(ui_state.imgui_context)

    for _, item in ipairs(ui_state.selected_items) do
      local override = get_item_override(ui_state.item_overrides, item.guid)
      ImGui.PushID(ui_state.imgui_context, item.guid)
      ImGui.TableNextRow(ui_state.imgui_context)
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 0)
      ImGui.Text(ui_state.imgui_context, item.base_name)
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 1)
      imgui_override_button("Var", override, "variations", "variation_mode_override", "chaos", "default")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 2)
      imgui_override_button("Pit", override, "pitch", "pitch_mode_override", "playrate", "shift")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 3)
      imgui_override_button("Vol", override, "volume")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 4)
      imgui_override_button("Pan", override, "pan")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 5)
      imgui_override_button("Ton", override, "tone")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 6)
      imgui_override_button("Pos", override, "position")
      ImGui.TableSetColumnIndex(ui_state.imgui_context, 7)
      imgui_override_button("Trk", override, "track")
      ImGui.PopID(ui_state.imgui_context)
    end

    ImGui.EndTable(ui_state.imgui_context)
  end
end

local function draw_imgui_gui()
  local ctx = ui_state.imgui_context

  ImGui.Text(ctx, selected_item_summary())
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, HAS_IMGUI and "ReaImGui" or "gfx fallback")
  ImGui.Separator(ctx)

  ui_state.settings.main.ripple = imgui_cycle_button("Ripple", ui_state.settings.main.ripple, RIPPLE_MODES, RIPPLE_MODE_LABELS)
  ImGui.SameLine(ctx)
  local crossfade_changed
  crossfade_changed, ui_state.settings.main.crossfade = ImGui.Checkbox(ctx, "Crossfade overlapping", ui_state.settings.main.crossfade)
  ImGui.SameLine(ctx)
  local markers_changed
  markers_changed, ui_state.settings.main.ripple_markers = ImGui.Checkbox(ctx, "Move markers", ui_state.settings.main.ripple_markers)
  local copy_automation_changed
  copy_automation_changed, ui_state.settings.main.copy_automation = ImGui.Checkbox(ctx, "Copy automation", ui_state.settings.main.copy_automation)
  local auto_skip_changed
  auto_skip_changed, ui_state.settings.transport.auto_skip = ImGui.Checkbox(ctx, "Auto skip playback", ui_state.settings.transport.auto_skip)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Variations")
  local changed
  changed, ui_state.settings.variations.amount = ImGui.SliderInt(ctx, "Amount", ui_state.settings.variations.amount, 0, 50)
  changed, ui_state.settings.variations.difference = ImGui.SliderDouble(ctx, "Difference", ui_state.settings.variations.difference, 0, 10, "%.2f s")
  if approx_zero(ui_state.settings.variations.difference) then
    ImGui.Text(ctx, "Difference: Max")
  end
  changed, ui_state.settings.variations.limit_source_offset = ImGui.Checkbox(ctx, "Limit source offset to source length", ui_state.settings.variations.limit_source_offset)
  ui_state.settings.variations.mode = imgui_cycle_button("Mode", ui_state.settings.variations.mode, VARIATION_MODES, VARIATION_MODE_LABELS)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Pitch")
  changed, ui_state.settings.pitch.split_range = ImGui.Checkbox(ctx, "Split Up / Down", ui_state.settings.pitch.split_range)
  if ui_state.settings.pitch.split_range then
    changed, ui_state.settings.pitch.up_amount = ImGui.SliderDouble(ctx, "Pitch Up", ui_state.settings.pitch.up_amount, 0, 24, "%.1f st")
    changed, ui_state.settings.pitch.down_amount = ImGui.SliderDouble(ctx, "Pitch Down", ui_state.settings.pitch.down_amount, 0, 24, "%.1f st")
  else
    changed, ui_state.settings.pitch.amount = ImGui.SliderDouble(ctx, "Pitch Amount", ui_state.settings.pitch.amount, 0, 24, "%.1f st")
  end
  changed, ui_state.settings.pitch.envelope = ImGui.SliderDouble(ctx, "Pitch Envelope", ui_state.settings.pitch.envelope, 0, 100, "%.0f")
  ui_state.settings.pitch.mode = imgui_cycle_button("Pitch Mode", ui_state.settings.pitch.mode, PITCH_MODES, PITCH_MODE_LABELS)
  changed, ui_state.settings.pitch.round_to_semitone = ImGui.Checkbox(ctx, "Round to semitone", ui_state.settings.pitch.round_to_semitone)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Position / Track")
  changed, ui_state.settings.position.space = ImGui.SliderDouble(ctx, "Space", ui_state.settings.position.space, -1, 10, "%.2f s")
  if approx_zero(ui_state.settings.position.space) then
    ImGui.Text(ctx, "Space: Auto")
  end
  changed, ui_state.settings.position.offset = ImGui.SliderDouble(ctx, "Offset", ui_state.settings.position.offset, 0, 500, "%.0f ms")
  changed, ui_state.settings.track.amount = ImGui.SliderDouble(ctx, "Track Swap", ui_state.settings.track.amount, 0, 100, "%.0f%%")

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Volume / Pan / Tone")
  changed, ui_state.settings.volume.amount = ImGui.SliderDouble(ctx, "Volume Amount", ui_state.settings.volume.amount, 0, 24, "%.1f dB")
  changed, ui_state.settings.volume.envelope = ImGui.SliderDouble(ctx, "Volume Envelope", ui_state.settings.volume.envelope, 0, 100, "%.0f")
  changed, ui_state.settings.volume.mute = ImGui.SliderDouble(ctx, "Mute", ui_state.settings.volume.mute, 0, 100, "%.0f%%")
  changed, ui_state.settings.pan.amount = ImGui.SliderDouble(ctx, "Pan Amount", ui_state.settings.pan.amount, 0, 100, "%.0f%%")
  changed, ui_state.settings.pan.envelope = ImGui.SliderDouble(ctx, "Pan Envelope", ui_state.settings.pan.envelope, 0, 100, "%.0f")
  changed, ui_state.settings.tone.amount = ImGui.SliderDouble(ctx, "Tone Amount", ui_state.settings.tone.amount, 0, 12, "%.1f dB")
  changed, ui_state.settings.tone.envelope = ImGui.SliderDouble(ctx, "Tone Envelope", ui_state.settings.tone.envelope, 0, 100, "%.0f")

  draw_imgui_overrides()

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Presets")
  for slot = 1, PRESET_SLOT_COUNT do
    if slot > 1 then
      ImGui.SameLine(ctx)
    end

    local label = tostring(slot)
    if ui_state.preset_cache[slot] then
      label = label .. "*"
    end

    if ImGui.Button(ctx, label, 32, 0) then
      ui_state.settings.ui.selected_preset = slot
    end
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save", 60, 0) then
    save_selected_preset()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Load", 60, 0) then
    load_selected_preset()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reset", 60, 0) then
    reset_ui_settings()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Prev (D)", 80, 0) then
    navigate_variation(-1)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Next (F)", 80, 0) then
    navigate_variation(1)
  end

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Apply", 120, 0) then
    apply_from_ui()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Close", 120, 0) then
    ui_state.imgui_open = false
    ui_state.should_close = true
  end

  ImGui.Text(ctx, ui_state.status_text)
end

local function imgui_loop()
  refresh_selected_items_state()

  local ctx = ui_state.imgui_context
  if not ctx then
    return
  end

  ImGui.SetNextWindowSize(ctx, ui_state.settings.ui.window_w or DEFAULTS.ui.window_w, ui_state.settings.ui.window_h or DEFAULTS.ui.window_h, ImGui.Cond_FirstUseEver)
  if ui_state.settings.ui.window_x and ui_state.settings.ui.window_y then
    ImGui.SetNextWindowPos(ctx, ui_state.settings.ui.window_x, ui_state.settings.ui.window_y, ImGui.Cond_FirstUseEver)
  end

  local visible, open = ImGui.Begin(ctx, SCRIPT_TITLE, ui_state.imgui_open)
  ui_state.imgui_open = open

  if visible then
    draw_imgui_gui()
    local window_x, window_y = ImGui.GetWindowPos(ctx)
    local window_w, window_h = ImGui.GetWindowSize(ctx)
    ui_state.settings.ui.window_x = window_x
    ui_state.settings.ui.window_y = window_y
    ui_state.settings.ui.window_w = math.floor(window_w + 0.5)
    ui_state.settings.ui.window_h = math.floor(window_h + 0.5)
  end

  ImGui.End(ctx)
  update_playback_auto_skip()

  if not open or ui_state.should_close then
    persist_ui_state()
    if ImGui.DestroyContext then
      ImGui.DestroyContext(ctx)
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
  elseif char == 100 or char == 68 then
    navigate_variation(-1)
  elseif char == 102 or char == 70 then
    navigate_variation(1)
  elseif char == 32 then
    reaper.Main_OnCommand(40044, 0)
  elseif char >= 49 and char <= (48 + PRESET_SLOT_COUNT) then
    ui_state.settings.ui.selected_preset = char - 48
  end
end

local function gui_loop()
  refresh_selected_items_state()
  local char = gfx.getchar()

  if char < 0 then
    persist_ui_state()
    return
  end

  if char > 0 and char ~= ui_state.prev_char then
    handle_keyboard_shortcuts(char)
  end
  draw_gui()
  update_playback_auto_skip()

  if not has_mouse_cap(1) then
    ui_state.active_slider = nil
  end

  ui_state.prev_left_down = has_mouse_cap(1)
  ui_state.prev_right_down = has_mouse_cap(2)

  gfx.update()

  if ui_state.should_close then
    persist_ui_state()
    return
  end

  ui_state.prev_char = char
  reaper.defer(gui_loop)
end

function M.main()
  refresh_preset_cache()
  ui_state.settings = load_last_settings()
  ui_state.item_overrides = load_item_overrides()
  ui_state.should_close = false
  ui_state.last_generated_groups = {}
  refresh_selected_items_state()

  if HAS_IMGUI and ImGui then
    ui_state.imgui_context = ImGui.CreateContext(SCRIPT_TITLE)
    ui_state.imgui_open = true
    imgui_loop()
    return
  end

  gfx.init(SCRIPT_TITLE, WINDOW_W, WINDOW_H)
  gfx.setfont(1, "Verdana", 14)
  gui_loop()
end

if rawget(_G, HELPER_BOOTSTRAP_FLAG) then
  return M
end

M.main()
return M
