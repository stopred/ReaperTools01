-- Game Sound Variation Generator v1.0
-- Reaper ReaScript (Lua)
-- Generates game-audio item variations from selected media items.
--
-- Usage:
-- 1. Select one or more media items in REAPER.
-- 2. Run this script from Actions.
-- 3. Configure the variation settings in the dialog.
-- 4. Use "generate" to create new items or "preview" to print the plan only.
--
-- Requirements: REAPER v7.0+
-- Related workflow: GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Variation Generator v1.0"
local EXT_SECTION = "GameSoundVariationGen"

local DEFAULTS = {
  variation_count = 5,
  pitch_range_cents = 100,
  pitch_distribution = "gaussian",
  volume_range_db = 3.0,
  start_offset_max_ms = 50,
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
  local range_value = tonumber(settings.volume_range_db or 0) or 0
  if range_value <= 0 then
    return 0.0
  end
  return random_uniform(-range_value, range_value)
end

local function sample_offset_ms(settings)
  local max_value = tonumber(settings.start_offset_max_ms or 0) or 0
  if max_value <= 0 then
    return 0.0
  end
  return random_uniform(0.0, max_value)
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
  settings.pitch_range_cents = tonumber(get_ext_state("pitch_range_cents", tostring(DEFAULTS.pitch_range_cents))) or DEFAULTS.pitch_range_cents
  settings.pitch_distribution = parse_distribution(get_ext_state("pitch_distribution", DEFAULTS.pitch_distribution)) or DEFAULTS.pitch_distribution
  settings.volume_range_db = tonumber(get_ext_state("volume_range_db", tostring(DEFAULTS.volume_range_db))) or DEFAULTS.volume_range_db
  settings.start_offset_max_ms = tonumber(get_ext_state("start_offset_max_ms", tostring(DEFAULTS.start_offset_max_ms))) or DEFAULTS.start_offset_max_ms
  settings.gap_seconds = tonumber(get_ext_state("gap_seconds", tostring(DEFAULTS.gap_seconds))) or DEFAULTS.gap_seconds
  settings.placement = parse_placement(get_ext_state("placement", DEFAULTS.placement)) or DEFAULTS.placement
  settings.auto_regions = parse_boolean(get_ext_state("auto_regions", bool_to_string(DEFAULTS.auto_regions)), DEFAULTS.auto_regions)
  settings.random_seed = tonumber(get_ext_state("random_seed", tostring(DEFAULTS.random_seed))) or DEFAULTS.random_seed
  settings.run_mode = parse_run_mode(get_ext_state("run_mode", DEFAULTS.run_mode)) or DEFAULTS.run_mode

  return settings
end

local function save_settings(settings)
  reaper.SetExtState(EXT_SECTION, "variation_count", tostring(settings.variation_count), true)
  reaper.SetExtState(EXT_SECTION, "pitch_range_cents", tostring(settings.pitch_range_cents), true)
  reaper.SetExtState(EXT_SECTION, "pitch_distribution", tostring(settings.pitch_distribution), true)
  reaper.SetExtState(EXT_SECTION, "volume_range_db", tostring(settings.volume_range_db), true)
  reaper.SetExtState(EXT_SECTION, "start_offset_max_ms", tostring(settings.start_offset_max_ms), true)
  reaper.SetExtState(EXT_SECTION, "gap_seconds", tostring(settings.gap_seconds), true)
  reaper.SetExtState(EXT_SECTION, "placement", tostring(settings.placement), true)
  reaper.SetExtState(EXT_SECTION, "auto_regions", bool_to_string(settings.auto_regions), true)
  reaper.SetExtState(EXT_SECTION, "random_seed", tostring(settings.random_seed), true)
  reaper.SetExtState(EXT_SECTION, "run_mode", tostring(settings.run_mode), true)
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
  settings.pitch_range_cents = tonumber(parts[2])
  settings.pitch_distribution = parse_distribution(parts[3])
  settings.volume_range_db = tonumber(parts[4])
  settings.start_offset_max_ms = tonumber(parts[5])
  settings.gap_seconds = tonumber(parts[6])
  settings.placement = parse_placement(parts[7])
  settings.auto_regions = parse_boolean(parts[8], nil)
  settings.random_seed = math.floor((tonumber(parts[9]) or -1) + 0.5)
  settings.run_mode = parse_run_mode(parts[10])

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
  if not settings.gap_seconds or settings.gap_seconds < 0 or settings.gap_seconds > 60 then
    return nil, "Gap between items must be between 0 and 60 seconds."
  end
  if not settings.placement then
    return nil, "Placement must be same_track, new_tracks, or new_track."
  end
  if settings.auto_regions == nil then
    return nil, "Auto-create Regions must be y or n."
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
  settings.gap_seconds = round_to(settings.gap_seconds, 6)

  return settings
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
      local variation_name = string.format("%s_Var%s", source.base_name, pad_number(variation_index, 2))

      source_plan.variations[#source_plan.variations + 1] = {
        index = variation_index,
        name = variation_name,
        pitch_cents = pitch_cents,
        volume_db = volume_db,
        requested_offset_ms = requested_offset_ms,
        applied_offset_ms = applied_offset_ms,
      }
    end

    plan.source_items[source_index] = source_plan
    plan.total_variations = plan.total_variations + #source_plan.variations
  end

  return plan
end

local function describe_variation(variation)
  return string.format(
    "Pitch %s cent | Vol %s dB | Offset +%.1f ms",
    format_signed(variation.pitch_cents, 1, ""),
    format_signed(variation.volume_db, 2, ""),
    round_to(variation.applied_offset_ms or variation.requested_offset_ms or 0.0, 1)
  )
end

local function print_preview(plan, settings, skipped_empty)
  reaper.ClearConsole()

  for _, source_plan in ipairs(plan.source_items) do
    log_line(string.format('=== Preview: "%s" (%d variations) ===', source_plan.source.base_name, #source_plan.variations))
    for _, variation in ipairs(source_plan.variations) do
      log_line(string.format("%s: %s", variation.name, describe_variation(variation)))
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
  log_line(string.format("Pitch:           +/-%.1f cent (%s)", settings.pitch_range_cents, HUMAN_DISTRIBUTION[settings.pitch_distribution] or settings.pitch_distribution))
  log_line(string.format("Volume:          +/-%.2f dB", settings.volume_range_db))
  log_line(string.format("Offset:          0-%.1f ms", settings.start_offset_max_ms))
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

  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", base_pitch + (variation.pitch_cents / 100.0))
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", base_volume * db_to_linear(variation.volume_db))
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
          log_line(string.format('[Variation Generator]   -> Created %s: Pitch %s cent, Vol %s dB, Offset +%.1f ms',
            variation.name,
            format_signed(variation.pitch_cents, 1, ""),
            format_signed(variation.volume_db, 2, ""),
            round_to(result.applied_offset_ms, 1)))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
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
          log_line(string.format('[Variation Generator]   -> Created %s: Pitch %s cent, Vol %s dB, Offset +%.1f ms',
            variation.name,
            format_signed(variation.pitch_cents, 1, ""),
            format_signed(variation.volume_db, 2, ""),
            round_to(result.applied_offset_ms, 1)))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
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
          log_line(string.format('[Variation Generator]   -> Created %s: Pitch %s cent, Vol %s dB, Offset +%.1f ms',
            variation.name,
            format_signed(variation.pitch_cents, 1, ""),
            format_signed(variation.volume_db, 2, ""),
            round_to(result.applied_offset_ms, 1)))

          if settings.auto_regions then
            create_region_for_item(new_item, variation.name)
          end
        end
      end
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
  log_line(string.format("  Pitch:   +/-%.1f cent (%s)", settings.pitch_range_cents, HUMAN_DISTRIBUTION[settings.pitch_distribution] or settings.pitch_distribution))
  log_line(string.format("  Volume:  +/-%.2f dB", settings.volume_range_db))
  log_line(string.format("  Offset:  0-%.1f ms", settings.start_offset_max_ms))
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

local function main()
  local source_items, skipped_empty = collect_selected_source_items()
  if #source_items == 0 then
    reaper.ShowMessageBox("No selected media items with active takes were found.", SCRIPT_TITLE, 0)
    return
  end

  local current_settings = load_settings()
  local settings, prompt_err = prompt_for_settings(current_settings)
  if not settings then
    if prompt_err ~= "User cancelled." then
      reaper.ShowMessageBox(prompt_err or "Invalid settings.", SCRIPT_TITLE, 0)
    end
    return
  end

  save_settings(settings)

  local actual_seed = create_random_seed(settings.random_seed)
  local plan = build_variation_plan(source_items, settings, actual_seed)

  if settings.run_mode == "preview" then
    print_preview(plan, settings, skipped_empty)
    print_summary(plan, settings, skipped_empty, 0)
    return
  end

  local ok, result_or_err = run_generation(plan, settings)
  if not ok then
    reaper.ShowMessageBox("Variation generation failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Variation Generator] ERROR: " .. tostring(result_or_err))
    return
  end

  print_summary(plan, settings, skipped_empty, result_or_err.created_count)
end

main()
