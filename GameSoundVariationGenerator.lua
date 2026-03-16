-- Game Sound Variation Generator v1.0
-- Reaper ReaScript (Lua)
-- Generates game-audio item variations from selected media items.
--
-- Usage:
-- 1. Select one or more media items in REAPER.
-- 2. Run this script from Actions.
-- 3. Configure the variation settings in the GUI.
-- 4. Use Preview to inspect the plan or Generate to create the items.
--
-- Requirements: REAPER v7.0+
-- Related workflow: GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Variation Generator v1.0"
local EXT_SECTION = "GameSoundVariationGen"

local DEFAULTS = {
  variation_count = 5,
  pitch_enabled = true,
  pitch_range_cents = 100,
  pitch_distribution = "gaussian",
  volume_enabled = true,
  volume_range_db = 3.0,
  start_offset_enabled = true,
  start_offset_max_ms = 50,
  time_stretch_enabled = false,
  time_stretch_range_percent = 5.0,
  time_stretch_preserve_pitch = true,
  tone_enabled = false,
  tone_shelf_gain_db = 2.0,
  reverse_enabled = false,
  reverse_probability_percent = 0.0,
  gap_seconds = 0.0,
  placement = "same_track",
  auto_regions = true,
  random_seed = 0,
  run_mode = "generate",
}

local HUMAN_PLACEMENT = {
  same_track = "Same track (sequential)",
  new_tracks = "New tracks (vertical)",
  new_track = "New track (sequential)",
}

local HUMAN_DISTRIBUTION = {
  uniform = "Uniform",
  gaussian = "Gaussian",
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
end

local function is_blank(value)
  return trim_string(value) == ""
end

local function clamp_number(value, min_value, max_value)
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

local function format_signed(value, decimals, suffix)
  local rounded = round_to(value, decimals)
  local fmt = "%+." .. tostring(decimals or 0) .. "f%s"
  return string.format(fmt, rounded, suffix or "")
end

local function bool_to_string(value)
  return value and "y" or "n"
end

local function parse_boolean(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "1" or lowered == "y" or lowered == "yes" or lowered == "true" or lowered == "on" then
    return true
  end
  if lowered == "0" or lowered == "n" or lowered == "no" or lowered == "false" or lowered == "off" then
    return false
  end
  return default_value
end

local function split_delimited(value, separator, expected_count)
  local parts = {}
  local text = tostring(value or "")
  local start_index = 1

  while true do
    local found_index = text:find(separator, start_index, true)
    if not found_index then
      parts[#parts + 1] = text:sub(start_index)
      break
    end

    parts[#parts + 1] = text:sub(start_index, found_index - 1)
    start_index = found_index + #separator
  end

  while #parts < expected_count do
    parts[#parts + 1] = ""
  end
  return parts
end

local function db_to_linear(db_value)
  return 10 ^ (tonumber(db_value or 0) / 20)
end

local function pad_number(value, width)
  return string.format("%0" .. tostring(width or 2) .. "d", value)
end

local function strip_extension(name)
  local value = trim_string(name)
  return value:gsub("%.[^%.\\/]+$", "")
end

local function sanitize_base_name(name, fallback_index)
  local value = strip_extension(name)
  value = trim_string(value)
  if value == "" then
    value = "Item_" .. pad_number(fallback_index or 1, 2)
  end
  return value
end

local function get_take_name_or_fallback(take, fallback_index)
  if not take then
    return sanitize_base_name("", fallback_index)
  end

  local take_name = trim_string(reaper.GetTakeName(take))
  if take_name ~= "" then
    return sanitize_base_name(take_name, fallback_index)
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if source then
    local source_name = trim_string(reaper.GetMediaSourceFileName(source))
    if source_name ~= "" then
      local basename = source_name:match("([^\\/]+)$") or source_name
      return sanitize_base_name(basename, fallback_index)
    end
  end

  return sanitize_base_name("", fallback_index)
end

local function set_take_name(take, name)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
  end
end

local function set_track_name(track, name)
  if track then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(name or ""), true)
  end
end

local function random_uniform(min_value, max_value)
  return min_value + math.random() * (max_value - min_value)
end

local function random_gaussian(mean, std_dev)
  local u1 = math.max(math.random(), 1e-12)
  local u2 = math.random()
  local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
  return mean + z * std_dev
end

local function random_gaussian_clamped(range_value, std_dev_ratio)
  local std_dev = range_value * (std_dev_ratio or 0.33)
  local value = random_gaussian(0.0, std_dev)
  return clamp_number(value, -range_value, range_value)
end

local function sample_pitch_cents(settings)
  if settings.pitch_enabled == false then
    return 0.0
  end

  local range_value = tonumber(settings.pitch_range_cents or 0) or 0
  if range_value <= 0 then
    return 0.0
  end

  if settings.pitch_distribution == "uniform" then
    return random_uniform(-range_value, range_value)
  end

  return random_gaussian_clamped(range_value, 0.33)
end

local function sample_volume_db(settings)
  if settings.volume_enabled == false then
    return 0.0
  end

  local range_value = tonumber(settings.volume_range_db or 0) or 0
  if range_value <= 0 then
    return 0.0
  end
  return random_uniform(-range_value, range_value)
end

local function sample_offset_ms(settings)
  if settings.start_offset_enabled == false then
    return 0.0
  end

  local max_value = tonumber(settings.start_offset_max_ms or 0) or 0
  if max_value <= 0 then
    return 0.0
  end
  return random_uniform(0.0, max_value)
end

local function sample_time_stretch_percent(settings)
  if settings.time_stretch_enabled == false then
    return 0.0
  end

  local range_value = tonumber(settings.time_stretch_range_percent or 0) or 0
  if range_value <= 0 then
    return 0.0
  end

  return random_uniform(-range_value, range_value)
end

local function sample_tone_variation(settings)
  if settings.tone_enabled == false then
    return nil, 0.0
  end

  local range_value = tonumber(settings.tone_shelf_gain_db or 0) or 0
  if range_value <= 0 then
    return nil, 0.0
  end

  local band = math.random() < 0.5 and "low" or "high"
  local gain_db = random_uniform(-range_value, range_value)
  return band, gain_db
end

local function sample_reverse_flag(settings)
  if settings.reverse_enabled == false then
    return false
  end

  local probability_percent = tonumber(settings.reverse_probability_percent or 0) or 0
  if probability_percent <= 0 then
    return false
  end

  return math.random() < clamp_number(probability_percent / 100.0, 0.0, 1.0)
end

local function regenerate_chunk_guids(chunk)
  local lines = {}

  for line in tostring(chunk or ""):gmatch("[^\r\n]+") do
    local prefix = line:match("^([A-Z]*GUID)%s+")
    if prefix then
      lines[#lines + 1] = prefix .. " " .. reaper.genGuid()
    else
      lines[#lines + 1] = line
    end
  end

  return table.concat(lines, "\n")
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
    return nil, "Failed to create duplicated media item."
  end

  if not reaper.SetItemStateChunk(new_item, regenerate_chunk_guids(chunk), false) then
    reaper.DeleteTrackMediaItem(dest_track, new_item)
    return nil, "Failed to apply duplicated item state chunk."
  end

  reaper.SetMediaItemSelected(new_item, false)
  return new_item
end

local function get_track_end_position(track)
  local max_end = 0.0
  local item_count = reaper.CountTrackMediaItems(track)

  for index = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, index)
    if item then
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = position + length
      if item_end > max_end then
        max_end = item_end
      end
    end
  end

  return max_end
end

local function sort_source_items(items)
  table.sort(items, function(left, right)
    if left.track_number ~= right.track_number then
      return left.track_number < right.track_number
    end
    if left.position ~= right.position then
      return left.position < right.position
    end
    return left.source_index < right.source_index
  end)
end

local function collect_selected_source_items()
  local items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)
  local skipped_empty = 0

  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    local take = item and reaper.GetActiveTake(item) or nil

    if item and take then
      local track = reaper.GetMediaItemTrack(item)
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local track_number = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))

      items[#items + 1] = {
        item = item,
        take = take,
        track = track,
        track_number = track_number,
        position = position,
        length = length,
        end_position = position + length,
        base_name = get_take_name_or_fallback(take, index + 1),
        source_index = index + 1,
      }
    else
      skipped_empty = skipped_empty + 1
    end
  end

  sort_source_items(items)
  return items, skipped_empty
end

local function parse_distribution(value)
  local lowered = trim_string(value):lower()
  if lowered == "uniform" or lowered == "u" then
    return "uniform"
  end
  if lowered == "gaussian" or lowered == "gauss" or lowered == "normal" or lowered == "g" then
    return "gaussian"
  end
  return nil
end

local function parse_placement(value)
  local lowered = trim_string(value):lower()
  if lowered == "same_track" or lowered == "same track" or lowered == "a" then
    return "same_track"
  end
  if lowered == "new_tracks" or lowered == "new tracks" or lowered == "vertical" or lowered == "b" then
    return "new_tracks"
  end
  if lowered == "new_track" or lowered == "new track" or lowered == "c" then
    return "new_track"
  end
  return nil
end

local function parse_run_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "generate" or lowered == "g" then
    return "generate"
  end
  if lowered == "preview" or lowered == "p" then
    return "preview"
  end
  return nil
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function load_settings()
  local settings = {}

  settings.variation_count = tonumber(get_ext_state("variation_count", tostring(DEFAULTS.variation_count))) or DEFAULTS.variation_count
  settings.pitch_enabled = parse_boolean(get_ext_state("pitch_enabled", bool_to_string(DEFAULTS.pitch_enabled)), DEFAULTS.pitch_enabled)
  settings.pitch_range_cents = tonumber(get_ext_state("pitch_range_cents", tostring(DEFAULTS.pitch_range_cents))) or DEFAULTS.pitch_range_cents
  settings.pitch_distribution = parse_distribution(get_ext_state("pitch_distribution", DEFAULTS.pitch_distribution)) or DEFAULTS.pitch_distribution
  settings.volume_enabled = parse_boolean(get_ext_state("volume_enabled", bool_to_string(DEFAULTS.volume_enabled)), DEFAULTS.volume_enabled)
  settings.volume_range_db = tonumber(get_ext_state("volume_range_db", tostring(DEFAULTS.volume_range_db))) or DEFAULTS.volume_range_db
  settings.start_offset_enabled = parse_boolean(get_ext_state("start_offset_enabled", bool_to_string(DEFAULTS.start_offset_enabled)), DEFAULTS.start_offset_enabled)
  settings.start_offset_max_ms = tonumber(get_ext_state("start_offset_max_ms", tostring(DEFAULTS.start_offset_max_ms))) or DEFAULTS.start_offset_max_ms
  settings.time_stretch_enabled = parse_boolean(get_ext_state("time_stretch_enabled", bool_to_string(DEFAULTS.time_stretch_enabled)), DEFAULTS.time_stretch_enabled)
  settings.time_stretch_range_percent = tonumber(get_ext_state("time_stretch_range_percent", tostring(DEFAULTS.time_stretch_range_percent))) or DEFAULTS.time_stretch_range_percent
  settings.time_stretch_preserve_pitch = parse_boolean(get_ext_state("time_stretch_preserve_pitch", bool_to_string(DEFAULTS.time_stretch_preserve_pitch)), DEFAULTS.time_stretch_preserve_pitch)
  settings.tone_enabled = parse_boolean(get_ext_state("tone_enabled", bool_to_string(DEFAULTS.tone_enabled)), DEFAULTS.tone_enabled)
  settings.tone_shelf_gain_db = tonumber(get_ext_state("tone_shelf_gain_db", tostring(DEFAULTS.tone_shelf_gain_db))) or DEFAULTS.tone_shelf_gain_db
  settings.reverse_enabled = parse_boolean(get_ext_state("reverse_enabled", bool_to_string(DEFAULTS.reverse_enabled)), DEFAULTS.reverse_enabled)
  settings.reverse_probability_percent = tonumber(get_ext_state("reverse_probability_percent", tostring(DEFAULTS.reverse_probability_percent))) or DEFAULTS.reverse_probability_percent
  settings.gap_seconds = tonumber(get_ext_state("gap_seconds", tostring(DEFAULTS.gap_seconds))) or DEFAULTS.gap_seconds
  settings.placement = parse_placement(get_ext_state("placement", DEFAULTS.placement)) or DEFAULTS.placement
  settings.auto_regions = parse_boolean(get_ext_state("auto_regions", bool_to_string(DEFAULTS.auto_regions)), DEFAULTS.auto_regions)
  settings.random_seed = tonumber(get_ext_state("random_seed", tostring(DEFAULTS.random_seed))) or DEFAULTS.random_seed
  settings.run_mode = parse_run_mode(get_ext_state("run_mode", DEFAULTS.run_mode)) or DEFAULTS.run_mode

  return settings
end

local function save_settings(settings)
  reaper.SetExtState(EXT_SECTION, "variation_count", tostring(settings.variation_count), true)
  reaper.SetExtState(EXT_SECTION, "pitch_enabled", bool_to_string(settings.pitch_enabled ~= false), true)
  reaper.SetExtState(EXT_SECTION, "pitch_range_cents", tostring(settings.pitch_range_cents), true)
  reaper.SetExtState(EXT_SECTION, "pitch_distribution", tostring(settings.pitch_distribution), true)
  reaper.SetExtState(EXT_SECTION, "volume_enabled", bool_to_string(settings.volume_enabled ~= false), true)
  reaper.SetExtState(EXT_SECTION, "volume_range_db", tostring(settings.volume_range_db), true)
  reaper.SetExtState(EXT_SECTION, "start_offset_enabled", bool_to_string(settings.start_offset_enabled ~= false), true)
  reaper.SetExtState(EXT_SECTION, "start_offset_max_ms", tostring(settings.start_offset_max_ms), true)
  reaper.SetExtState(EXT_SECTION, "time_stretch_enabled", bool_to_string(settings.time_stretch_enabled == true), true)
  reaper.SetExtState(EXT_SECTION, "time_stretch_range_percent", tostring(settings.time_stretch_range_percent), true)
  reaper.SetExtState(EXT_SECTION, "time_stretch_preserve_pitch", bool_to_string(settings.time_stretch_preserve_pitch ~= false), true)
  reaper.SetExtState(EXT_SECTION, "tone_enabled", bool_to_string(settings.tone_enabled == true), true)
  reaper.SetExtState(EXT_SECTION, "tone_shelf_gain_db", tostring(settings.tone_shelf_gain_db), true)
  reaper.SetExtState(EXT_SECTION, "reverse_enabled", bool_to_string(settings.reverse_enabled == true), true)
  reaper.SetExtState(EXT_SECTION, "reverse_probability_percent", tostring(settings.reverse_probability_percent), true)
  reaper.SetExtState(EXT_SECTION, "gap_seconds", tostring(settings.gap_seconds), true)
  reaper.SetExtState(EXT_SECTION, "placement", tostring(settings.placement), true)
  reaper.SetExtState(EXT_SECTION, "auto_regions", bool_to_string(settings.auto_regions), true)
  reaper.SetExtState(EXT_SECTION, "random_seed", tostring(settings.random_seed), true)
  reaper.SetExtState(EXT_SECTION, "run_mode", tostring(settings.run_mode), true)
end

local function normalize_settings(raw_settings)
  local settings = {}

  settings.variation_count = math.floor((tonumber(raw_settings.variation_count) or DEFAULTS.variation_count) + 0.5)
  settings.pitch_enabled = raw_settings.pitch_enabled ~= false
  settings.pitch_range_cents = tonumber(raw_settings.pitch_range_cents) or DEFAULTS.pitch_range_cents
  settings.pitch_distribution = parse_distribution(raw_settings.pitch_distribution) or DEFAULTS.pitch_distribution
  settings.volume_enabled = raw_settings.volume_enabled ~= false
  settings.volume_range_db = tonumber(raw_settings.volume_range_db) or DEFAULTS.volume_range_db
  settings.start_offset_enabled = raw_settings.start_offset_enabled ~= false
  settings.start_offset_max_ms = tonumber(raw_settings.start_offset_max_ms) or DEFAULTS.start_offset_max_ms
  settings.time_stretch_enabled = raw_settings.time_stretch_enabled == true
  settings.time_stretch_range_percent = tonumber(raw_settings.time_stretch_range_percent) or DEFAULTS.time_stretch_range_percent
  settings.time_stretch_preserve_pitch = raw_settings.time_stretch_preserve_pitch ~= false
  settings.tone_enabled = raw_settings.tone_enabled == true
  settings.tone_shelf_gain_db = tonumber(raw_settings.tone_shelf_gain_db) or DEFAULTS.tone_shelf_gain_db
  settings.reverse_enabled = raw_settings.reverse_enabled == true
  settings.reverse_probability_percent = tonumber(raw_settings.reverse_probability_percent) or DEFAULTS.reverse_probability_percent
  settings.gap_seconds = tonumber(raw_settings.gap_seconds) or DEFAULTS.gap_seconds
  settings.placement = parse_placement(raw_settings.placement) or DEFAULTS.placement
  if raw_settings.auto_regions == nil then
    settings.auto_regions = DEFAULTS.auto_regions
  else
    settings.auto_regions = raw_settings.auto_regions == true
  end
  settings.random_seed = math.floor((tonumber(raw_settings.random_seed) or DEFAULTS.random_seed) + 0.5)
  settings.run_mode = parse_run_mode(raw_settings.run_mode) or DEFAULTS.run_mode

  if settings.variation_count < 1 or settings.variation_count > 50 then
    return nil, "Number of variations must be between 1 and 50."
  end
  if not settings.pitch_range_cents or settings.pitch_range_cents < 0 or settings.pitch_range_cents > 2400 then
    return nil, "Pitch range must be between 0 and 2400 cents."
  end
  if not settings.pitch_distribution then
    return nil, "Pitch distribution must be uniform or gaussian."
  end
  if not settings.volume_range_db or settings.volume_range_db < 0 or settings.volume_range_db > 24 then
    return nil, "Volume range must be between 0 and 24 dB."
  end
  if not settings.start_offset_max_ms or settings.start_offset_max_ms < 0 or settings.start_offset_max_ms > 5000 then
    return nil, "Start offset max must be between 0 and 5000 ms."
  end
  if not settings.time_stretch_range_percent or settings.time_stretch_range_percent < 0 or settings.time_stretch_range_percent > 95 then
    return nil, "Time stretch range must be between 0 and 95 percent."
  end
  if not settings.tone_shelf_gain_db or settings.tone_shelf_gain_db < 0 or settings.tone_shelf_gain_db > 24 then
    return nil, "Tone shelf gain range must be between 0 and 24 dB."
  end
  if not settings.reverse_probability_percent or settings.reverse_probability_percent < 0 or settings.reverse_probability_percent > 100 then
    return nil, "Reverse probability must be between 0 and 100 percent."
  end
  if not settings.gap_seconds or settings.gap_seconds < 0 or settings.gap_seconds > 60 then
    return nil, "Gap between items must be between 0 and 60 seconds."
  end
  if not settings.placement then
    return nil, "Placement must be same_track, new_tracks, or new_track."
  end
  if settings.random_seed < 0 or settings.random_seed > 2147483646 then
    return nil, "Random seed must be between 0 and 2147483646."
  end
  if not settings.run_mode then
    return nil, "Run mode must be generate or preview."
  end

  settings.pitch_range_cents = round_to(settings.pitch_range_cents, 3)
  settings.volume_range_db = round_to(settings.volume_range_db, 3)
  settings.start_offset_max_ms = round_to(settings.start_offset_max_ms, 3)
  settings.time_stretch_range_percent = round_to(settings.time_stretch_range_percent, 3)
  settings.tone_shelf_gain_db = round_to(settings.tone_shelf_gain_db, 3)
  settings.reverse_probability_percent = round_to(settings.reverse_probability_percent, 3)
  settings.gap_seconds = round_to(settings.gap_seconds, 6)

  return settings
end

local function prompt_for_settings(current)
  local captions = table.concat({
    "extrawidth=240",
    "separator=|",
    "Number of Variations (1-50)",
    "Pitch Range (+/- cent, 0=off)",
    "Pitch Distribution (uniform/gaussian)",
    "Volume Range (+/- dB, 0=off)",
    "Start Offset Max (ms, 0=off)",
    "Gap Between Items (sec)",
    "Placement (same_track/new_tracks/new_track)",
    "Auto-create Regions (y/n)",
    "Random Seed (0=random)",
    "Run Mode (generate/preview)",
  }, ",")

  local defaults = table.concat({
    tostring(current.variation_count),
    tostring(current.pitch_range_cents),
    tostring(current.pitch_distribution),
    tostring(current.volume_range_db),
    tostring(current.start_offset_max_ms),
    tostring(current.gap_seconds),
    tostring(current.placement),
    bool_to_string(current.auto_regions),
    tostring(current.random_seed),
    tostring(current.run_mode),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 10, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 10)
  local settings = {}

  settings.variation_count = math.floor((tonumber(parts[1]) or -1) + 0.5)
  settings.pitch_enabled = true
  settings.pitch_range_cents = tonumber(parts[2])
  settings.pitch_distribution = parse_distribution(parts[3])
  settings.volume_enabled = true
  settings.volume_range_db = tonumber(parts[4])
  settings.start_offset_enabled = true
  settings.start_offset_max_ms = tonumber(parts[5])
  settings.gap_seconds = tonumber(parts[6])
  settings.placement = parse_placement(parts[7])
  settings.auto_regions = parse_boolean(parts[8], nil)
  settings.random_seed = math.floor((tonumber(parts[9]) or -1) + 0.5)
  settings.run_mode = parse_run_mode(parts[10])

  if settings.auto_regions == nil then
    return nil, "Auto-create Regions must be y or n."
  end
  return normalize_settings(settings)
end

local function create_random_seed(user_seed)
  if user_seed and user_seed > 0 then
    return user_seed
  end

  local seed = math.floor(reaper.time_precise() * 1000000) % 2147483646
  if seed <= 0 then
    seed = 1
  end
  return seed
end

local function seed_random(seed)
  math.randomseed(seed)
  math.random()
  math.random()
  math.random()
end

local function build_variation_plan(source_items, settings, actual_seed)
  seed_random(actual_seed)

  local plan = {
    seed = actual_seed,
    source_items = {},
    total_variations = 0,
  }

  for source_index, source in ipairs(source_items) do
    local source_plan = {
      source = source,
      variations = {},
    }

    for variation_index = 1, settings.variation_count do
      local pitch_cents = sample_pitch_cents(settings)
      local volume_db = sample_volume_db(settings)
      local requested_offset_ms = sample_offset_ms(settings)
      local applied_offset_ms = get_applied_offset_ms(source.take, source.length, requested_offset_ms)
      local stretch_percent = sample_time_stretch_percent(settings)
      local tone_band, tone_gain_db = sample_tone_variation(settings)
      local reverse_flag = sample_reverse_flag(settings)
      local variation_name = string.format("%s_Var%s", source.base_name, pad_number(variation_index, 2))

      source_plan.variations[#source_plan.variations + 1] = {
        index = variation_index,
        name = variation_name,
        pitch_cents = pitch_cents,
        volume_db = volume_db,
        requested_offset_ms = requested_offset_ms,
        applied_offset_ms = applied_offset_ms,
        stretch_percent = stretch_percent,
        stretch_preserve_pitch = settings.time_stretch_preserve_pitch == true,
        tone_band = tone_band,
        tone_gain_db = tone_gain_db,
        reverse = reverse_flag,
      }
    end

    plan.source_items[source_index] = source_plan
    plan.total_variations = plan.total_variations + #source_plan.variations
  end

  return plan
end

local function describe_variation(variation, settings)
  local parts = {}

  if settings.pitch_enabled ~= false then
    parts[#parts + 1] = string.format("Pitch %s cent", format_signed(variation.pitch_cents, 1, ""))
  end
  if settings.volume_enabled ~= false then
    parts[#parts + 1] = string.format("Vol %s dB", format_signed(variation.volume_db, 2, ""))
  end
  if settings.start_offset_enabled ~= false then
    parts[#parts + 1] = string.format("Offset +%.1f ms", round_to(variation.applied_offset_ms or variation.requested_offset_ms or 0.0, 1))
  end
  if settings.time_stretch_enabled == true then
    parts[#parts + 1] = string.format("Stretch %s%%", format_signed(variation.stretch_percent or 0.0, 2, ""))
  end
  if settings.tone_enabled == true and variation.tone_band and math.abs(variation.tone_gain_db or 0.0) > 0.0001 then
    parts[#parts + 1] = string.format("%s shelf %s dB",
      variation.tone_band == "low" and "Low" or "High",
      format_signed(variation.tone_gain_db or 0.0, 2, "")
    )
  end
  if settings.reverse_enabled == true and variation.reverse then
    parts[#parts + 1] = "Reverse"
  end

  if #parts == 0 then
    return "No parameter changes"
  end

  return table.concat(parts, " | ")
end

local function print_preview(plan, settings, skipped_empty)
  reaper.ClearConsole()

  for _, source_plan in ipairs(plan.source_items) do
    log_line(string.format('=== Preview: "%s" (%d variations) ===', source_plan.source.base_name, #source_plan.variations))
    for _, variation in ipairs(source_plan.variations) do
      log_line(string.format("%s: %s", variation.name, describe_variation(variation, settings)))
    end
    log_line("")
  end

  log_line("-------------------------------------------")
  log_line("Preview Complete")
  log_line("-------------------------------------------")
  log_line(string.format("Source Items:    %d", #plan.source_items))
  log_line(string.format("Variations Each: %d", settings.variation_count))
  log_line(string.format("Total Planned:   %d", plan.total_variations))
  log_line(string.format("Placement:       %s", HUMAN_PLACEMENT[settings.placement] or settings.placement))
  log_line(string.format("Pitch:           %s", settings.pitch_enabled ~= false
    and string.format("+/-%.1f cent (%s)", settings.pitch_range_cents, HUMAN_DISTRIBUTION[settings.pitch_distribution] or settings.pitch_distribution)
    or "Off"))
  log_line(string.format("Volume:          %s", settings.volume_enabled ~= false
    and string.format("+/-%.2f dB", settings.volume_range_db)
    or "Off"))
  log_line(string.format("Offset:          %s", settings.start_offset_enabled ~= false
    and string.format("0-%.1f ms", settings.start_offset_max_ms)
    or "Off"))
  log_line(string.format("Stretch:         %s", settings.time_stretch_enabled == true
    and string.format("+/-%.2f%% (%s)", settings.time_stretch_range_percent, settings.time_stretch_preserve_pitch and "preserve pitch" or "pitch coupled")
    or "Off"))
  log_line(string.format("Tone:            %s", settings.tone_enabled == true
    and string.format("+/-%.2f dB shelf", settings.tone_shelf_gain_db)
    or "Off"))
  log_line(string.format("Reverse:         %s", settings.reverse_enabled == true
    and string.format("%.1f%% probability", settings.reverse_probability_percent)
    or "Off"))
  log_line(string.format("Regions:         %s", settings.auto_regions and "Auto-create" or "Disabled"))
  log_line(string.format("Seed:            %d", plan.seed))
  if skipped_empty > 0 then
    log_line(string.format("Skipped empty items: %d", skipped_empty))
  end
end

local function get_track_insertion_start_index(source_track, inserted_below_counts)
  local track_number = math.floor(reaper.GetMediaTrackInfo_Value(source_track, "IP_TRACKNUMBER"))
  local already_inserted = inserted_below_counts[source_track] or 0
  return track_number + already_inserted
end

local function insert_tracks_below(source_track, count, inserted_below_counts)
  local tracks = {}
  local start_index = get_track_insertion_start_index(source_track, inserted_below_counts)

  for offset = 0, count - 1 do
    local insert_index = start_index + offset
    reaper.InsertTrackAtIndex(insert_index, false)
    tracks[#tracks + 1] = reaper.GetTrack(0, insert_index)
  end

  inserted_below_counts[source_track] = (inserted_below_counts[source_track] or 0) + count
  return tracks
end

local function create_region_for_item(item, name)
  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  reaper.AddProjectMarker2(0, true, position, position + length, tostring(name or ""), -1, 0)
end

local function select_only_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local ENVELOPE_SHAPE_SQUARE = 1
local LOW_SHELF_API_BANDTYPE = 1
local HIGH_SHELF_API_BANDTYPE = 4
local EQ_GAIN_PARAMTYPE = 1
local EQ_FREQ_PARAMTYPE = 0
local LOW_SHELF_FREQ_HZ = 180.0
local HIGH_SHELF_FREQ_HZ = 5500.0
local ENVELOPE_TIME_EPSILON = 0.0001

local function find_reaeq_param_index(track, fx_index, bandtype, band_index, paramtype)
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)

  for param_index = 0, param_count - 1 do
    local ok, current_bandtype, current_band_index, current_paramtype = reaper.TrackFX_GetEQParam(track, fx_index, param_index)
    if ok and current_bandtype == bandtype and current_band_index == band_index and current_paramtype == paramtype then
      return param_index
    end
  end

  return nil
end

local function create_tone_context(track, cache)
  if cache[track] ~= nil then
    return cache[track]
  end

  local fx_index = -1
  local candidates = {
    "ReaEQ",
    "VST: ReaEQ (Cockos)",
    "VST3: ReaEQ (Cockos)",
  }

  for _, candidate in ipairs(candidates) do
    fx_index = reaper.TrackFX_AddByName(track, candidate, false, -1)
    if fx_index >= 0 then
      break
    end
  end

  if fx_index < 0 then
    cache[track] = false
    return nil
  end

  reaper.TrackFX_SetEQBandEnabled(track, fx_index, LOW_SHELF_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQBandEnabled(track, fx_index, HIGH_SHELF_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQParam(track, fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_FREQ_PARAMTYPE, LOW_SHELF_FREQ_HZ, false)
  reaper.TrackFX_SetEQParam(track, fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_FREQ_PARAMTYPE, HIGH_SHELF_FREQ_HZ, false)
  reaper.TrackFX_SetEQParam(track, fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)
  reaper.TrackFX_SetEQParam(track, fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)

  local low_gain_param = find_reaeq_param_index(track, fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE)
  local high_gain_param = find_reaeq_param_index(track, fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE)

  if not low_gain_param or not high_gain_param then
    cache[track] = false
    return nil
  end

  local low_gain_env = reaper.GetFXEnvelope(track, fx_index, low_gain_param, true)
  local high_gain_env = reaper.GetFXEnvelope(track, fx_index, high_gain_param, true)
  if not low_gain_env or not high_gain_env then
    cache[track] = false
    return nil
  end

  local context = {
    track = track,
    fx_index = fx_index,
    low_gain_param = low_gain_param,
    high_gain_param = high_gain_param,
    low_gain_env = low_gain_env,
    high_gain_env = high_gain_env,
    low_baseline_norm = reaper.TrackFX_GetParamNormalized(track, fx_index, low_gain_param),
    high_baseline_norm = reaper.TrackFX_GetParamNormalized(track, fx_index, high_gain_param),
  }

  cache[track] = context
  return context
end

local function tone_gain_db_to_normalized(context, band, gain_db)
  if band == "low" then
    reaper.TrackFX_SetEQParam(context.track, context.fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, gain_db, false)
    return reaper.TrackFX_GetParamNormalized(context.track, context.fx_index, context.low_gain_param)
  end

  reaper.TrackFX_SetEQParam(context.track, context.fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, gain_db, false)
  return reaper.TrackFX_GetParamNormalized(context.track, context.fx_index, context.high_gain_param)
end

local function insert_square_envelope_point(envelope, time_position, value)
  reaper.InsertEnvelopePoint(
    envelope,
    time_position,
    value,
    ENVELOPE_SHAPE_SQUARE,
    0,
    false,
    true
  )
end

local function apply_tone_segments(context, segments)
  if not context or not segments or #segments == 0 then
    return
  end

  table.sort(segments, function(left, right)
    if left.start_pos ~= right.start_pos then
      return left.start_pos < right.start_pos
    end
    return left.end_pos < right.end_pos
  end)

  local first_start = segments[1].start_pos
  local baseline_time = math.max(0.0, first_start - ENVELOPE_TIME_EPSILON)
  local last_end = segments[#segments].end_pos + ENVELOPE_TIME_EPSILON

  reaper.DeleteEnvelopePointRange(context.low_gain_env, baseline_time, last_end + ENVELOPE_TIME_EPSILON)
  reaper.DeleteEnvelopePointRange(context.high_gain_env, baseline_time, last_end + ENVELOPE_TIME_EPSILON)

  insert_square_envelope_point(context.low_gain_env, baseline_time, context.low_baseline_norm)
  insert_square_envelope_point(context.high_gain_env, baseline_time, context.high_baseline_norm)

  for index, segment in ipairs(segments) do
    local segment_start = segment.start_pos
    local segment_end = math.max(segment.end_pos, segment_start + ENVELOPE_TIME_EPSILON)
    local next_segment = segments[index + 1]

    local low_target = context.low_baseline_norm
    local high_target = context.high_baseline_norm
    if segment.tone_band == "low" then
      low_target = tone_gain_db_to_normalized(context, "low", segment.tone_gain_db)
      reaper.TrackFX_SetEQParam(context.track, context.fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)
      high_target = context.high_baseline_norm
    elseif segment.tone_band == "high" then
      reaper.TrackFX_SetEQParam(context.track, context.fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)
      low_target = context.low_baseline_norm
      high_target = tone_gain_db_to_normalized(context, "high", segment.tone_gain_db)
    end

    insert_square_envelope_point(context.low_gain_env, segment_start, low_target)
    insert_square_envelope_point(context.high_gain_env, segment_start, high_target)
    insert_square_envelope_point(context.low_gain_env, segment_end, low_target)
    insert_square_envelope_point(context.high_gain_env, segment_end, high_target)

    if not next_segment or next_segment.start_pos > segment_end + ENVELOPE_TIME_EPSILON then
      local reset_time = segment_end + ENVELOPE_TIME_EPSILON
      insert_square_envelope_point(context.low_gain_env, reset_time, context.low_baseline_norm)
      insert_square_envelope_point(context.high_gain_env, reset_time, context.high_baseline_norm)
    end
  end

  reaper.TrackFX_SetEQParam(context.track, context.fx_index, LOW_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)
  reaper.TrackFX_SetEQParam(context.track, context.fx_index, HIGH_SHELF_API_BANDTYPE, 0, EQ_GAIN_PARAMTYPE, 0.0, false)
  reaper.Envelope_SortPoints(context.low_gain_env)
  reaper.Envelope_SortPoints(context.high_gain_env)
end

local function reverse_generated_items(items_to_reverse)
  if not items_to_reverse or #items_to_reverse == 0 then
    return
  end

  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items_to_reverse) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end

  reaper.Main_OnCommand(41051, 0)
end

local function get_applied_offset_ms(take, current_length, requested_offset_ms)
  if requested_offset_ms <= 0 then
    return 0.0
  end

  local current_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = math.max(0.0001, reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
  local source = reaper.GetMediaItemTake_Source(take)

  local available_source_span = current_length * playrate
  if source then
    local source_length, length_is_qn = reaper.GetMediaSourceLength(source)
    if not length_is_qn then
      available_source_span = math.min(available_source_span, math.max(0.0, source_length - current_offset))
    end
  end

  local max_offset_source_sec = available_source_span * 0.8
  local max_project_trim = math.max(0.0, current_length - 0.01)
  max_offset_source_sec = math.min(max_offset_source_sec, max_project_trim * playrate)
  local requested_offset_sec = requested_offset_ms / 1000.0
  local applied_offset_sec = clamp_number(requested_offset_sec, 0.0, max_offset_source_sec)

  return applied_offset_sec * 1000.0
end

local function apply_offset_and_trim(item, take, requested_offset_ms)
  local current_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local playrate = math.max(0.0001, reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
  local current_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local applied_offset_ms = get_applied_offset_ms(take, current_length, requested_offset_ms)
  local applied_offset_sec = applied_offset_ms / 1000.0

  if applied_offset_sec <= 0 then
    return 0.0
  end

  local project_trim = applied_offset_sec / playrate
  local new_length = current_length - project_trim
  if new_length <= 0.01 then
    project_trim = math.max(0.0, current_length - 0.01)
    applied_offset_sec = project_trim * playrate
    new_length = current_length - project_trim
  end

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", current_offset + applied_offset_sec)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)

  return applied_offset_sec * 1000.0
end

local function apply_variation_to_item(item, variation)
  local take = reaper.GetActiveTake(item)
  if not take then
    return nil, "Duplicated item has no active take."
  end

  local base_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
  local base_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
  local base_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local base_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", base_pitch + (variation.pitch_cents / 100.0))
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", base_volume * db_to_linear(variation.volume_db))

  local stretch_percent = variation.stretch_percent or 0.0
  local stretch_multiplier = clamp_number(1.0 + (stretch_percent / 100.0), 0.05, 20.0)
  if math.abs(stretch_percent) > 0.0001 then
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", variation.stretch_preserve_pitch and 1 or 0)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", base_playrate * stretch_multiplier)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0.01, base_length / stretch_multiplier))
  end

  local applied_offset_ms = apply_offset_and_trim(item, take, variation.requested_offset_ms or 0.0)

  set_take_name(take, variation.name)
  return {
    take = take,
    applied_offset_ms = applied_offset_ms,
    final_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
  }
end

local function run_generation(plan, settings)
  local created_items = {}
  local created_count = 0
  local track_end_cache = {}
  local inserted_below_counts = {}
  local items_to_reverse = {}
  local tone_segments_by_track = {}
  local tone_context_cache = {}

  reaper.ClearConsole()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, err = pcall(function()
    for source_plan_index, source_plan in ipairs(plan.source_items) do
      local source = source_plan.source
      log_line(string.format('[Variation Generator] Processing item %d/%d: "%s"', source_plan_index, #plan.source_items, source.base_name))

      if settings.placement == "same_track" then
        local dest_track = source.track
        local cursor = track_end_cache[dest_track]
        if not cursor then
          cursor = get_track_end_position(dest_track)
        end
        cursor = math.max(cursor, source.end_position) + settings.gap_seconds

        for _, variation in ipairs(source_plan.variations) do
          local new_item, duplicate_err = duplicate_item_to_track(source.item, dest_track)
          if not new_item then
            error(duplicate_err or "Failed to duplicate item.")
          end

          reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", cursor)
          local result, apply_err = apply_variation_to_item(new_item, variation)
          if not result then
            error(apply_err or "Failed to apply variation.")
          end

          created_items[#created_items + 1] = new_item
          created_count = created_count + 1
          log_line(string.format(
            '[Variation Generator]   -> Created %s: %s',
            variation.name,
            describe_variation({
              pitch_cents = variation.pitch_cents,
              volume_db = variation.volume_db,
              applied_offset_ms = result.applied_offset_ms,
              stretch_percent = variation.stretch_percent,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
              reverse = variation.reverse,
            }, settings)
          ))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
          end

          if settings.reverse_enabled == true and variation.reverse then
            items_to_reverse[#items_to_reverse + 1] = new_item
          end
          if settings.tone_enabled == true and variation.tone_band and math.abs(variation.tone_gain_db or 0.0) > 0.0001 then
            tone_segments_by_track[dest_track] = tone_segments_by_track[dest_track] or {}
            tone_segments_by_track[dest_track][#tone_segments_by_track[dest_track] + 1] = {
              start_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION"),
              end_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + result.final_length,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
            }
          end

          cursor = cursor + result.final_length + settings.gap_seconds
          track_end_cache[dest_track] = cursor - settings.gap_seconds
        end
      elseif settings.placement == "new_track" then
        local dest_track = insert_tracks_below(source.track, 1, inserted_below_counts)[1]
        set_track_name(dest_track, source.base_name .. "_Variations")

        local cursor = source.position
        for _, variation in ipairs(source_plan.variations) do
          local new_item, duplicate_err = duplicate_item_to_track(source.item, dest_track)
          if not new_item then
            error(duplicate_err or "Failed to duplicate item.")
          end

          reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", cursor)
          local result, apply_err = apply_variation_to_item(new_item, variation)
          if not result then
            error(apply_err or "Failed to apply variation.")
          end

          created_items[#created_items + 1] = new_item
          created_count = created_count + 1
          log_line(string.format(
            '[Variation Generator]   -> Created %s: %s',
            variation.name,
            describe_variation({
              pitch_cents = variation.pitch_cents,
              volume_db = variation.volume_db,
              applied_offset_ms = result.applied_offset_ms,
              stretch_percent = variation.stretch_percent,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
              reverse = variation.reverse,
            }, settings)
          ))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
          end

          if settings.reverse_enabled == true and variation.reverse then
            items_to_reverse[#items_to_reverse + 1] = new_item
          end
          if settings.tone_enabled == true and variation.tone_band and math.abs(variation.tone_gain_db or 0.0) > 0.0001 then
            tone_segments_by_track[dest_track] = tone_segments_by_track[dest_track] or {}
            tone_segments_by_track[dest_track][#tone_segments_by_track[dest_track] + 1] = {
              start_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION"),
              end_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + result.final_length,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
            }
          end

          cursor = cursor + result.final_length + settings.gap_seconds
        end
      else
        local dest_tracks = insert_tracks_below(source.track, #source_plan.variations, inserted_below_counts)

        for variation_index, variation in ipairs(source_plan.variations) do
          local dest_track = dest_tracks[variation_index]
          set_track_name(dest_track, variation.name)

          local new_item, duplicate_err = duplicate_item_to_track(source.item, dest_track)
          if not new_item then
            error(duplicate_err or "Failed to duplicate item.")
          end

          reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", source.position)
          local result, apply_err = apply_variation_to_item(new_item, variation)
          if not result then
            error(apply_err or "Failed to apply variation.")
          end

          created_items[#created_items + 1] = new_item
          created_count = created_count + 1
          log_line(string.format(
            '[Variation Generator]   -> Created %s: %s',
            variation.name,
            describe_variation({
              pitch_cents = variation.pitch_cents,
              volume_db = variation.volume_db,
              applied_offset_ms = result.applied_offset_ms,
              stretch_percent = variation.stretch_percent,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
              reverse = variation.reverse,
            }, settings)
          ))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
          end

          if settings.reverse_enabled == true and variation.reverse then
            items_to_reverse[#items_to_reverse + 1] = new_item
          end
          if settings.tone_enabled == true and variation.tone_band and math.abs(variation.tone_gain_db or 0.0) > 0.0001 then
            tone_segments_by_track[dest_track] = tone_segments_by_track[dest_track] or {}
            tone_segments_by_track[dest_track][#tone_segments_by_track[dest_track] + 1] = {
              start_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION"),
              end_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + result.final_length,
              tone_band = variation.tone_band,
              tone_gain_db = variation.tone_gain_db,
            }
          end
        end
      end
    end

    if settings.tone_enabled == true then
      for track, segments in pairs(tone_segments_by_track) do
        local tone_context = create_tone_context(track, tone_context_cache)
        if tone_context then
          apply_tone_segments(tone_context, segments)
        else
          log_line("[Variation Generator]   -> Tone variation skipped: ReaEQ could not be created or mapped on a destination track.")
        end
      end
    end

    if settings.reverse_enabled == true then
      reverse_generated_items(items_to_reverse)
    end

    reaper.TrackList_AdjustWindows(false)
    select_only_items(created_items)
  end)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock("Generate Sound Variations", -1)
    return true, {
      created_items = created_items,
      created_count = created_count,
    }
  end

  reaper.Undo_EndBlock("Generate Sound Variations (failed)", -1)
  return false, err
end

local function print_summary(plan, settings, skipped_empty, created_count)
  log_line("")
  log_line("===========================================")
  log_line(settings.run_mode == "preview" and "Variation Preview Complete!" or "Variation Generation Complete!")
  log_line("===========================================")
  log_line(string.format("Source Items:      %d", #plan.source_items))
  log_line(string.format("Variations Each:   %d", settings.variation_count))
  if settings.run_mode == "preview" then
    log_line(string.format("Total Planned:     %d", plan.total_variations))
  else
    log_line(string.format("Total Created:     %d", created_count or 0))
  end
  log_line("-------------------------------------------")
  log_line("Parameters Used:")
  if settings.pitch_enabled ~= false then
    log_line(string.format("  Pitch:   +/-%.1f cent (%s)", settings.pitch_range_cents, HUMAN_DISTRIBUTION[settings.pitch_distribution] or settings.pitch_distribution))
  else
    log_line("  Pitch:   Off")
  end
  if settings.volume_enabled ~= false then
    log_line(string.format("  Volume:  +/-%.2f dB", settings.volume_range_db))
  else
    log_line("  Volume:  Off")
  end
  if settings.start_offset_enabled ~= false then
    log_line(string.format("  Offset:  0-%.1f ms", settings.start_offset_max_ms))
  else
    log_line("  Offset:  Off")
  end
  if settings.time_stretch_enabled == true then
    log_line(string.format("  Stretch: +/-%.2f%% (%s)", settings.time_stretch_range_percent, settings.time_stretch_preserve_pitch and "Preserve Pitch" or "Pitch Coupled"))
  else
    log_line("  Stretch: Off")
  end
  if settings.tone_enabled == true then
    log_line(string.format("  Tone:    +/-%.2f dB shelf", settings.tone_shelf_gain_db))
  else
    log_line("  Tone:    Off")
  end
  if settings.reverse_enabled == true then
    log_line(string.format("  Reverse: %.1f%% probability", settings.reverse_probability_percent))
  else
    log_line("  Reverse: Off")
  end
  log_line(string.format("  Gap:     %.3f sec", settings.gap_seconds))
  log_line(string.format("  Place:   %s", HUMAN_PLACEMENT[settings.placement] or settings.placement))
  log_line(string.format("  Region:  %s", settings.auto_regions and "On" or "Off"))
  if DEFAULTS.random_seed == 0 and settings.random_seed == 0 then
    log_line(string.format("  Seed:    Random (%d)", plan.seed))
  else
    log_line(string.format("  Seed:    %d", plan.seed))
  end
  if skipped_empty > 0 then
    log_line(string.format("Skipped Empty Items: %d", skipped_empty))
  end
  log_line("===========================================")
end

local GUI_WINDOW_W = 760
local GUI_WINDOW_H = 780

local GUI_COLORS = {
  background = { 0.08, 0.09, 0.10, 1.0 },
  panel = { 0.12, 0.14, 0.16, 1.0 },
  panel_border = { 0.21, 0.25, 0.29, 1.0 },
  accent = { 0.17, 0.56, 0.46, 1.0 },
  accent_soft = { 0.10, 0.34, 0.29, 1.0 },
  text = { 0.95, 0.96, 0.97, 1.0 },
  text_muted = { 0.69, 0.73, 0.77, 1.0 },
  input = { 0.10, 0.11, 0.13, 1.0 },
  input_border = { 0.25, 0.29, 0.33, 1.0 },
  button = { 0.16, 0.18, 0.20, 1.0 },
  button_hover = { 0.19, 0.22, 0.25, 1.0 },
  button_primary = { 0.17, 0.56, 0.46, 1.0 },
  button_primary_hover = { 0.20, 0.65, 0.53, 1.0 },
  danger = { 0.52, 0.22, 0.22, 1.0 },
}

local GUI_FIELD_SPECS = {
  { key = "variation_count", kind = "int", decimals = 0 },
  { key = "random_seed", kind = "int", decimals = 0 },
  { key = "pitch_range_cents", kind = "float", decimals = 1 },
  { key = "volume_range_db", kind = "float", decimals = 2 },
  { key = "start_offset_max_ms", kind = "float", decimals = 1 },
  { key = "time_stretch_range_percent", kind = "float", decimals = 2 },
  { key = "tone_shelf_gain_db", kind = "float", decimals = 2 },
  { key = "reverse_probability_percent", kind = "float", decimals = 1 },
  { key = "gap_seconds", kind = "float", decimals = 3 },
}

local GUI_FIELD_ORDER = {
  "variation_count",
  "random_seed",
  "pitch_range_cents",
  "volume_range_db",
  "start_offset_max_ms",
  "time_stretch_range_percent",
  "tone_shelf_gain_db",
  "reverse_probability_percent",
  "gap_seconds",
}

local GUI_FIELD_SPEC_BY_KEY = {}
for _, spec in ipairs(GUI_FIELD_SPECS) do
  GUI_FIELD_SPEC_BY_KEY[spec.key] = spec
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function set_color(color)
  gfx.set(color[1], color[2], color[3], color[4] or 1.0)
end

local function draw_text(text, x, y, color)
  if color then
    set_color(color)
  end
  gfx.x = x
  gfx.y = y
  gfx.drawstr(text)
end

local function copy_table(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

local function trim_numeric_string(value)
  local text = tostring(value or "")
  if text:find("%.", 1, true) then
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
  end
  return text
end

local function format_field_value(key, value)
  local spec = GUI_FIELD_SPEC_BY_KEY[key]
  local number_value = tonumber(value) or 0
  if not spec then
    return tostring(value or "")
  end

  if spec.kind == "int" then
    return tostring(math.floor(number_value + 0.5))
  end

  return trim_numeric_string(string.format("%." .. tostring(spec.decimals) .. "f", number_value))
end

local function sync_gui_from_settings(gui, settings)
  gui.settings = copy_table(settings)
  gui.buffers = {
    variation_count = format_field_value("variation_count", settings.variation_count),
    random_seed = format_field_value("random_seed", settings.random_seed),
    pitch_range_cents = format_field_value("pitch_range_cents", settings.pitch_range_cents),
    volume_range_db = format_field_value("volume_range_db", settings.volume_range_db),
    start_offset_max_ms = format_field_value("start_offset_max_ms", settings.start_offset_max_ms),
    time_stretch_range_percent = format_field_value("time_stretch_range_percent", settings.time_stretch_range_percent),
    tone_shelf_gain_db = format_field_value("tone_shelf_gain_db", settings.tone_shelf_gain_db),
    reverse_probability_percent = format_field_value("reverse_probability_percent", settings.reverse_probability_percent),
    gap_seconds = format_field_value("gap_seconds", settings.gap_seconds),
  }
end

local function create_gui_state(settings)
  local gui = {
    settings = {},
    buffers = {},
    active_field = nil,
    prev_mouse_down = false,
    hit_regions = {},
    pending_action = nil,
    status = "Select media items, then Preview or Generate.",
    should_close = false,
  }

  sync_gui_from_settings(gui, settings)
  return gui
end

local function register_hit_region(gui, kind, x, y, w, h, data)
  gui.hit_regions[#gui.hit_regions + 1] = {
    kind = kind,
    x = x,
    y = y,
    w = w,
    h = h,
    data = data,
  }
end

local function draw_section_frame(title, x, y, w, h)
  set_color(GUI_COLORS.panel)
  gfx.rect(x, y, w, h, true)
  set_color(GUI_COLORS.panel_border)
  gfx.rect(x, y, w, h, false)
  set_color(GUI_COLORS.accent_soft)
  gfx.rect(x, y, 5, h, true)
  draw_text(title, x + 14, y + 10, GUI_COLORS.text)
end

local function draw_checkbox(gui, x, y, key, label)
  local size = 16
  local checked = gui.settings[key] == true

  set_color(GUI_COLORS.input)
  gfx.rect(x, y, size, size, true)
  set_color(checked and GUI_COLORS.accent or GUI_COLORS.input_border)
  gfx.rect(x, y, size, size, false)

  if checked then
    set_color(GUI_COLORS.accent)
    gfx.rect(x + 4, y + 4, size - 8, size - 8, true)
  end

  draw_text(label, x + size + 8, y - 1, GUI_COLORS.text)
  local label_w = gfx.measurestr(label)
  register_hit_region(gui, "checkbox", x, y, size + 8 + label_w, size, { key = key })
end

local function draw_radio(gui, x, y, group_key, option_value, label)
  local size = 16
  local selected = gui.settings[group_key] == option_value

  set_color(GUI_COLORS.input)
  gfx.rect(x, y, size, size, true)
  set_color(selected and GUI_COLORS.accent or GUI_COLORS.input_border)
  gfx.rect(x, y, size, size, false)

  if selected then
    set_color(GUI_COLORS.accent)
    gfx.rect(x + 4, y + 4, size - 8, size - 8, true)
  end

  draw_text(label, x + size + 8, y - 1, GUI_COLORS.text)
  local label_w = gfx.measurestr(label)
  register_hit_region(gui, "radio", x, y, size + 8 + label_w, size, {
    key = group_key,
    value = option_value,
  })

  return x + size + 8 + label_w + 18
end

local function draw_input_field(gui, x, y, label, key, width, suffix, label_offset)
  draw_text(label, x, y + 4, GUI_COLORS.text)

  local field_x = x + (label_offset or 300)
  local field_y = y
  local field_h = 26
  local active = gui.active_field == key

  set_color(GUI_COLORS.input)
  gfx.rect(field_x, field_y, width, field_h, true)
  set_color(active and GUI_COLORS.accent or GUI_COLORS.input_border)
  gfx.rect(field_x, field_y, width, field_h, false)

  draw_text(gui.buffers[key] or "", field_x + 8, field_y + 5, GUI_COLORS.text)
  if suffix then
    draw_text(suffix, field_x + width + 10, field_y + 4, GUI_COLORS.text_muted)
  end

  register_hit_region(gui, "field", field_x, field_y, width, field_h, { key = key })
end

local function draw_button(gui, x, y, w, h, label, action, primary, danger)
  local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, y, w, h)
  local color = GUI_COLORS.button

  if primary then
    color = hovered and GUI_COLORS.button_primary_hover or GUI_COLORS.button_primary
  elseif danger then
    color = hovered and { 0.60, 0.25, 0.25, 1.0 } or GUI_COLORS.danger
  elseif hovered then
    color = GUI_COLORS.button_hover
  end

  set_color(color)
  gfx.rect(x, y, w, h, true)
  set_color(primary and GUI_COLORS.button_primary_hover or GUI_COLORS.input_border)
  gfx.rect(x, y, w, h, false)

  local text_w, text_h = gfx.measurestr(label)
  draw_text(label, x + ((w - text_w) * 0.5), y + ((h - text_h) * 0.5), GUI_COLORS.text)
  register_hit_region(gui, "button", x, y, w, h, { action = action })
end

local function focus_next_field(gui)
  if not gui.active_field then
    gui.active_field = GUI_FIELD_ORDER[1]
    return
  end

  for index, key in ipairs(GUI_FIELD_ORDER) do
    if key == gui.active_field then
      gui.active_field = GUI_FIELD_ORDER[(index % #GUI_FIELD_ORDER) + 1]
      return
    end
  end

  gui.active_field = GUI_FIELD_ORDER[1]
end

local function is_allowed_field_char(key, char)
  local spec = GUI_FIELD_SPEC_BY_KEY[key]
  if not spec then
    return false
  end

  if char:match("%d") then
    return true
  end

  if spec.kind == "float" and char == "." then
    return true
  end

  return false
end

local function handle_gui_key(gui, char)
  if char <= 0 then
    return
  end

  if char == 9 then
    focus_next_field(gui)
    return
  end

  if char == 13 then
    if gui.active_field then
      gui.active_field = nil
    else
      gui.pending_action = "generate"
    end
    return
  end

  if char == 8 then
    if gui.active_field then
      local current = gui.buffers[gui.active_field] or ""
      gui.buffers[gui.active_field] = current:sub(1, math.max(0, #current - 1))
    end
    return
  end

  if char == string.byte("p") or char == string.byte("P") then
    if not gui.active_field then
      gui.pending_action = "preview"
      return
    end
  end

  if gui.active_field and char >= 32 and char <= 126 then
    local text = gui.buffers[gui.active_field] or ""
    local input_char = string.char(char)

    if is_allowed_field_char(gui.active_field, input_char) then
      if input_char ~= "." or not text:find("%.", 1, true) then
        gui.buffers[gui.active_field] = text .. input_char
      end
    end
  end
end

local function handle_gui_mouse(gui)
  local mouse_down = (gfx.mouse_cap % 2) == 1
  local just_pressed = mouse_down and not gui.prev_mouse_down

  if just_pressed then
    local hit = nil
    for index = #gui.hit_regions, 1, -1 do
      local region = gui.hit_regions[index]
      if point_in_rect(gfx.mouse_x, gfx.mouse_y, region.x, region.y, region.w, region.h) then
        hit = region
        break
      end
    end

    if hit then
      if hit.kind == "checkbox" then
        gui.settings[hit.data.key] = not gui.settings[hit.data.key]
      elseif hit.kind == "radio" then
        gui.settings[hit.data.key] = hit.data.value
      elseif hit.kind == "field" then
        gui.active_field = hit.data.key
      elseif hit.kind == "button" then
        gui.pending_action = hit.data.action
      end
    else
      gui.active_field = nil
    end
  end

  gui.prev_mouse_down = mouse_down
end

local function build_settings_from_gui(gui, run_mode)
  return normalize_settings({
    variation_count = gui.buffers.variation_count,
    pitch_enabled = gui.settings.pitch_enabled,
    pitch_range_cents = gui.buffers.pitch_range_cents,
    pitch_distribution = gui.settings.pitch_distribution,
    volume_enabled = gui.settings.volume_enabled,
    volume_range_db = gui.buffers.volume_range_db,
    start_offset_enabled = gui.settings.start_offset_enabled,
    start_offset_max_ms = gui.buffers.start_offset_max_ms,
    time_stretch_enabled = gui.settings.time_stretch_enabled,
    time_stretch_range_percent = gui.buffers.time_stretch_range_percent,
    time_stretch_preserve_pitch = gui.settings.time_stretch_preserve_pitch,
    tone_enabled = gui.settings.tone_enabled,
    tone_shelf_gain_db = gui.buffers.tone_shelf_gain_db,
    reverse_enabled = gui.settings.reverse_enabled,
    reverse_probability_percent = gui.buffers.reverse_probability_percent,
    gap_seconds = gui.buffers.gap_seconds,
    placement = gui.settings.placement,
    auto_regions = gui.settings.auto_regions,
    random_seed = gui.buffers.random_seed,
    run_mode = run_mode,
  })
end

local function perform_gui_action(gui, action)
  if action == "cancel" then
    gui.should_close = true
    return
  end

  local settings, settings_err = build_settings_from_gui(gui, action)
  if not settings then
    gui.status = settings_err or "Invalid settings."
    return
  end

  save_settings(settings)
  sync_gui_from_settings(gui, settings)

  local source_items, skipped_empty = collect_selected_source_items()
  if #source_items == 0 then
    gui.status = "No selected media items with active takes were found."
    return
  end

  local actual_seed = create_random_seed(settings.random_seed)
  local plan = build_variation_plan(source_items, settings, actual_seed)

  if action == "preview" then
    settings.run_mode = "preview"
    print_preview(plan, settings, skipped_empty)
    print_summary(plan, settings, skipped_empty, 0)
    gui.status = string.format("Preview ready. %d items, seed %d.", #source_items, plan.seed)
    return
  end

  settings.run_mode = "generate"
  local ok, result_or_err = run_generation(plan, settings)
  if not ok then
    gui.status = "Generation failed."
    reaper.ShowMessageBox("Variation generation failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Variation Generator] ERROR: " .. tostring(result_or_err))
    return
  end

  print_summary(plan, settings, skipped_empty, result_or_err.created_count)
  gui.status = string.format("Generated %d variations.", result_or_err.created_count)
  gui.should_close = true
end

local function draw_gui(gui)
  gui.hit_regions = {}

  set_color(GUI_COLORS.background)
  gfx.rect(0, 0, GUI_WINDOW_W, GUI_WINDOW_H, true)
  gfx.setfont(1, "Segoe UI", 18)
  draw_text("Game Sound Variation Generator", 22, 18, GUI_COLORS.text)
  gfx.setfont(1, "Segoe UI", 13)
  draw_text("Phase 3 UI", 22, 45, GUI_COLORS.text_muted)
  draw_text(string.format("Selected items: %d", reaper.CountSelectedMediaItems(0)), 560, 21, GUI_COLORS.text_muted)

  local x = 20
  local w = GUI_WINDOW_W - 40
  local y = 74
  local gutter = 16
  local col_w = math.floor((w - gutter) / 2)
  local right_x = x + col_w + gutter

  draw_section_frame("General", x, y, w, 92)
  draw_input_field(gui, x + 16, y + 34, "Number of Variations", "variation_count", 86, nil)
  draw_input_field(gui, x + 16, y + 60, "Random Seed", "random_seed", 110, "0 = random")

  local left_y = y + 104
  local right_y = y + 104

  draw_section_frame("Pitch Shift", x, left_y, col_w, 116)
  draw_checkbox(gui, x + 16, left_y + 38, "pitch_enabled", "Enable")
  draw_input_field(gui, x + 16, left_y + 34, "Range", "pitch_range_cents", 90, "cent", 170)
  draw_text("Distribution", x + 16, left_y + 72, GUI_COLORS.text)
  local next_x = draw_radio(gui, x + 170, left_y + 71, "pitch_distribution", "uniform", "Uniform")
  draw_radio(gui, next_x, left_y + 71, "pitch_distribution", "gaussian", "Gaussian")

  left_y = left_y + 128
  draw_section_frame("Volume", x, left_y, col_w, 66)
  draw_checkbox(gui, x + 16, left_y + 38, "volume_enabled", "Enable")
  draw_input_field(gui, x + 16, left_y + 34, "Range", "volume_range_db", 90, "dB", 170)

  left_y = left_y + 78
  draw_section_frame("Start Offset", x, left_y, col_w, 66)
  draw_checkbox(gui, x + 16, left_y + 38, "start_offset_enabled", "Enable")
  draw_input_field(gui, x + 16, left_y + 34, "Max", "start_offset_max_ms", 90, "ms", 170)

  left_y = left_y + 78
  draw_section_frame("Time Stretch", x, left_y, col_w, 92)
  draw_checkbox(gui, x + 16, left_y + 38, "time_stretch_enabled", "Enable")
  draw_input_field(gui, x + 16, left_y + 34, "Range", "time_stretch_range_percent", 90, "%", 170)
  draw_checkbox(gui, x + 16, left_y + 64, "time_stretch_preserve_pitch", "Preserve Pitch")

  draw_section_frame("Tone (EQ)", right_x, right_y, col_w, 66)
  draw_checkbox(gui, right_x + 16, right_y + 38, "tone_enabled", "Enable")
  draw_input_field(gui, right_x + 16, right_y + 34, "Shelf Gain", "tone_shelf_gain_db", 90, "dB", 170)

  right_y = right_y + 78
  draw_section_frame("Reverse", right_x, right_y, col_w, 66)
  draw_checkbox(gui, right_x + 16, right_y + 38, "reverse_enabled", "Enable")
  draw_input_field(gui, right_x + 16, right_y + 34, "Probability", "reverse_probability_percent", 90, "%", 170)

  right_y = right_y + 78
  draw_section_frame("Placement", right_x, right_y, col_w, 138)
  draw_text("Mode", right_x + 16, right_y + 38, GUI_COLORS.text)
  draw_radio(gui, right_x + 170, right_y + 37, "placement", "same_track", "Same track")
  draw_radio(gui, right_x + 170, right_y + 63, "placement", "new_tracks", "New tracks")
  draw_radio(gui, right_x + 170, right_y + 89, "placement", "new_track", "New track")
  draw_input_field(gui, right_x + 16, right_y + 104, "Gap Between Items", "gap_seconds", 90, "sec", 170)

  right_y = right_y + 150
  draw_section_frame("Output", right_x, right_y, col_w, 58)
  draw_checkbox(gui, right_x + 16, right_y + 24, "auto_regions", "Auto-create regions")

  local footer_y = GUI_WINDOW_H - 74
  draw_text(gui.status, 24, footer_y - 8, GUI_COLORS.text_muted)
  draw_button(gui, GUI_WINDOW_W - 296, GUI_WINDOW_H - 50, 84, 30, "Preview", "preview", false, false)
  draw_button(gui, GUI_WINDOW_W - 202, GUI_WINDOW_H - 50, 84, 30, "Generate", "generate", true, false)
  draw_button(gui, GUI_WINDOW_W - 108, GUI_WINDOW_H - 50, 84, 30, "Cancel", "cancel", false, true)
end

local function main()
  local gui = create_gui_state(load_settings())
  gfx.init(SCRIPT_TITLE, GUI_WINDOW_W, GUI_WINDOW_H, 0)
  gfx.setfont(1, "Segoe UI", 13)

  local function run_gui()
    local char = gfx.getchar()
    if char < 0 or char == 27 or gui.should_close then
      gfx.quit()
      return
    end

    handle_gui_key(gui, char)
    draw_gui(gui)
    handle_gui_mouse(gui)

    if gui.pending_action then
      local action = gui.pending_action
      gui.pending_action = nil
      perform_gui_action(gui, action)
    end

    gfx.update()
    if gui.should_close then
      gfx.quit()
      return
    end

    reaper.defer(run_gui)
  end

  run_gui()
end

main()
