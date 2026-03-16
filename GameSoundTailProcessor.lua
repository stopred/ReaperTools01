-- Game Sound Tail/Silence Processor v1.0
-- Reaper ReaScript (Lua)
-- Batch tail and silence cleanup for game-audio assets.
--
-- Usage:
-- 1. Select one or more media items in REAPER.
-- 2. Run this script from Actions.
-- 3. Review the console analysis report.
-- 4. Use dry-run to preview changes, or process to apply them.
--
-- Requirements: REAPER v7.0+
-- Related workflow: GameSoundVariationGenerator.lua, GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Tail/Silence Processor v1.0"
local EXT_SECTION = "GameSoundTailProcessor"
local REGION_MATCH_TOLERANCE_SEC = 0.01
local NEG_INF_DB = -150.0

local DEFAULTS = {
  threshold_db = -60.0,
  min_silence_ms = 10.0,
  block_size = 1024,
  head_trim_enabled = true,
  pre_roll_ms = 2.0,
  keep_position = false,
  tail_enabled = true,
  tail_mode = "fade",
  post_roll_ms = 5.0,
  fade_length_ms = 50.0,
  fade_curve = "lin",
  target_length_sec = 0.0,
  normalize_mode = "off",
  normalize_target_db = -1.0,
  max_gain_db = 20.0,
  clip_protect = true,
  dry_run = false,
  min_length_ms = 50.0,
  max_trim_ratio = 90.0,
  sync_regions = true,
}

local HUMAN_TAIL_MODE = {
  cut = "Hard Cut",
  fade = "Fade Out",
  target = "Target Length",
}

local HUMAN_NORMALIZE_MODE = {
  off = "Off",
  peak = "Peak",
  rms = "RMS",
}

local HUMAN_FADE_CURVE = {
  lin = "Linear",
  exp = "Exponential",
  scurve = "S-Curve",
}

local FADE_CURVE_PRESETS = {
  lin = { shape = 0, dir = 0.0 },
  exp = { shape = 0, dir = 1.0 },
  scurve = { shape = 0, dir = -1.0 },
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
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
  local safe = math.max(tonumber(linear_value) or 0.0, 1e-12)
  return 20.0 * log10(safe)
end

local function ms_to_sec(value)
  return (tonumber(value) or 0.0) / 1000.0
end

local function strip_extension(name)
  return trim_string(name):gsub("%.[^%.\\/]+$", "")
end

local function truncate_text(value, max_length)
  local text = tostring(value or "")
  if #text <= max_length then
    return text
  end
  if max_length <= 3 then
    return text:sub(1, max_length)
  end
  return text:sub(1, max_length - 3) .. "..."
end

local function format_db(db_value)
  if not db_value or db_value <= NEG_INF_DB + 0.5 then
    return "-inf"
  end
  return string.format("%.1f", db_value)
end

local function format_seconds(seconds)
  return string.format("%.3fs", tonumber(seconds) or 0.0)
end

local function format_ms_from_sec(seconds)
  local milliseconds = (tonumber(seconds) or 0.0) * 1000.0
  if milliseconds >= 1000.0 then
    return string.format("%.2fs", milliseconds / 1000.0)
  end
  return string.format("%.0fms", milliseconds)
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function parse_tail_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "cut" or lowered == "hardcut" or lowered == "hard_cut" then
    return "cut"
  end
  if lowered == "fade" or lowered == "fadeout" or lowered == "fade_out" then
    return "fade"
  end
  if lowered == "target" or lowered == "targetlength" or lowered == "target_length" then
    return "target"
  end
  return nil
end

local function parse_normalize_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "" or lowered == "off" or lowered == "none" or lowered == "n" then
    return "off"
  end
  if lowered == "peak" or lowered == "p" then
    return "peak"
  end
  if lowered == "rms" then
    return "rms"
  end
  return nil
end

local function parse_fade_curve(value)
  local lowered = trim_string(value):lower()
  if lowered == "lin" or lowered == "linear" or lowered == "l" then
    return "lin"
  end
  if lowered == "exp" or lowered == "exponential" or lowered == "log" then
    return "exp"
  end
  if lowered == "scurve" or lowered == "s-curve" or lowered == "s_curve" or lowered == "s" then
    return "scurve"
  end
  return nil
end

local function load_settings()
  local settings = {}

  settings.threshold_db = tonumber(get_ext_state("threshold_db", tostring(DEFAULTS.threshold_db))) or DEFAULTS.threshold_db
  settings.min_silence_ms = tonumber(get_ext_state("min_silence_ms", tostring(DEFAULTS.min_silence_ms))) or DEFAULTS.min_silence_ms
  settings.block_size = tonumber(get_ext_state("block_size", tostring(DEFAULTS.block_size))) or DEFAULTS.block_size
  settings.head_trim_enabled = parse_boolean(get_ext_state("head_trim_enabled", bool_to_string(DEFAULTS.head_trim_enabled)), DEFAULTS.head_trim_enabled)
  settings.pre_roll_ms = tonumber(get_ext_state("pre_roll_ms", tostring(DEFAULTS.pre_roll_ms))) or DEFAULTS.pre_roll_ms
  settings.keep_position = parse_boolean(get_ext_state("keep_position", bool_to_string(DEFAULTS.keep_position)), DEFAULTS.keep_position)
  settings.tail_enabled = parse_boolean(get_ext_state("tail_enabled", bool_to_string(DEFAULTS.tail_enabled)), DEFAULTS.tail_enabled)
  settings.tail_mode = parse_tail_mode(get_ext_state("tail_mode", DEFAULTS.tail_mode)) or DEFAULTS.tail_mode
  settings.post_roll_ms = tonumber(get_ext_state("post_roll_ms", tostring(DEFAULTS.post_roll_ms))) or DEFAULTS.post_roll_ms
  settings.fade_length_ms = tonumber(get_ext_state("fade_length_ms", tostring(DEFAULTS.fade_length_ms))) or DEFAULTS.fade_length_ms
  settings.fade_curve = parse_fade_curve(get_ext_state("fade_curve", DEFAULTS.fade_curve)) or DEFAULTS.fade_curve
  settings.target_length_sec = tonumber(get_ext_state("target_length_sec", tostring(DEFAULTS.target_length_sec))) or DEFAULTS.target_length_sec
  settings.normalize_mode = parse_normalize_mode(get_ext_state("normalize_mode", DEFAULTS.normalize_mode)) or DEFAULTS.normalize_mode
  settings.normalize_target_db = tonumber(get_ext_state("normalize_target_db", tostring(DEFAULTS.normalize_target_db))) or DEFAULTS.normalize_target_db
  settings.max_gain_db = tonumber(get_ext_state("max_gain_db", tostring(DEFAULTS.max_gain_db))) or DEFAULTS.max_gain_db
  settings.clip_protect = parse_boolean(get_ext_state("clip_protect", bool_to_string(DEFAULTS.clip_protect)), DEFAULTS.clip_protect)
  settings.dry_run = parse_boolean(get_ext_state("dry_run", bool_to_string(DEFAULTS.dry_run)), DEFAULTS.dry_run)
  settings.min_length_ms = tonumber(get_ext_state("min_length_ms", tostring(DEFAULTS.min_length_ms))) or DEFAULTS.min_length_ms
  settings.max_trim_ratio = tonumber(get_ext_state("max_trim_ratio", tostring(DEFAULTS.max_trim_ratio))) or DEFAULTS.max_trim_ratio
  settings.sync_regions = parse_boolean(get_ext_state("sync_regions", bool_to_string(DEFAULTS.sync_regions)), DEFAULTS.sync_regions)

  return settings
end

local function save_settings(settings)
  reaper.SetExtState(EXT_SECTION, "threshold_db", tostring(settings.threshold_db), true)
  reaper.SetExtState(EXT_SECTION, "min_silence_ms", tostring(settings.min_silence_ms), true)
  reaper.SetExtState(EXT_SECTION, "block_size", tostring(settings.block_size), true)
  reaper.SetExtState(EXT_SECTION, "head_trim_enabled", bool_to_string(settings.head_trim_enabled), true)
  reaper.SetExtState(EXT_SECTION, "pre_roll_ms", tostring(settings.pre_roll_ms), true)
  reaper.SetExtState(EXT_SECTION, "keep_position", bool_to_string(settings.keep_position), true)
  reaper.SetExtState(EXT_SECTION, "tail_enabled", bool_to_string(settings.tail_enabled), true)
  reaper.SetExtState(EXT_SECTION, "tail_mode", tostring(settings.tail_mode), true)
  reaper.SetExtState(EXT_SECTION, "post_roll_ms", tostring(settings.post_roll_ms), true)
  reaper.SetExtState(EXT_SECTION, "fade_length_ms", tostring(settings.fade_length_ms), true)
  reaper.SetExtState(EXT_SECTION, "fade_curve", tostring(settings.fade_curve), true)
  reaper.SetExtState(EXT_SECTION, "target_length_sec", tostring(settings.target_length_sec), true)
  reaper.SetExtState(EXT_SECTION, "normalize_mode", tostring(settings.normalize_mode), true)
  reaper.SetExtState(EXT_SECTION, "normalize_target_db", tostring(settings.normalize_target_db), true)
  reaper.SetExtState(EXT_SECTION, "max_gain_db", tostring(settings.max_gain_db), true)
  reaper.SetExtState(EXT_SECTION, "clip_protect", bool_to_string(settings.clip_protect), true)
  reaper.SetExtState(EXT_SECTION, "dry_run", bool_to_string(settings.dry_run), true)
  reaper.SetExtState(EXT_SECTION, "min_length_ms", tostring(settings.min_length_ms), true)
  reaper.SetExtState(EXT_SECTION, "max_trim_ratio", tostring(settings.max_trim_ratio), true)
  reaper.SetExtState(EXT_SECTION, "sync_regions", bool_to_string(settings.sync_regions), true)
end

local function prompt_for_settings(current)
  local captions = table.concat({
    "extrawidth=320",
    "separator=|",
    "Threshold (dB)",
    "Min Silence (ms)",
    "Block Size (samples)",
    "Enable Head Trim (y/n)",
    "Head Pre-roll (ms)",
    "Keep item left edge fixed (y/n)",
    "Enable Tail Processing (y/n)",
    "Tail Mode (cut/fade/target)",
    "Tail Post-roll (ms)",
    "Fade Out Length (ms)",
    "Fade Curve (lin/exp/scurve)",
    "Target Length (sec, 0=off)",
    "Normalize Mode (off/peak/rms)",
    "Normalize Target (dB)",
    "Max Gain (dB)",
    "Protect From Clipping (y/n)",
    "Dry Run (y/n)",
    "Min Item Length (ms)",
    "Max Trim Ratio (%)",
    "Sync Matching Regions (y/n)",
  }, ",")

  local defaults = table.concat({
    tostring(current.threshold_db),
    tostring(current.min_silence_ms),
    tostring(current.block_size),
    bool_to_string(current.head_trim_enabled),
    tostring(current.pre_roll_ms),
    bool_to_string(current.keep_position),
    bool_to_string(current.tail_enabled),
    tostring(current.tail_mode),
    tostring(current.post_roll_ms),
    tostring(current.fade_length_ms),
    tostring(current.fade_curve),
    tostring(current.target_length_sec),
    tostring(current.normalize_mode),
    tostring(current.normalize_target_db),
    tostring(current.max_gain_db),
    bool_to_string(current.clip_protect),
    bool_to_string(current.dry_run),
    tostring(current.min_length_ms),
    tostring(current.max_trim_ratio),
    bool_to_string(current.sync_regions),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 20, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 20)
  local settings = {}

  settings.threshold_db = tonumber(parts[1])
  settings.min_silence_ms = tonumber(parts[2])
  settings.block_size = math.floor((tonumber(parts[3]) or -1) + 0.5)
  settings.head_trim_enabled = parse_boolean(parts[4], nil)
  settings.pre_roll_ms = tonumber(parts[5])
  settings.keep_position = parse_boolean(parts[6], nil)
  settings.tail_enabled = parse_boolean(parts[7], nil)
  settings.tail_mode = parse_tail_mode(parts[8])
  settings.post_roll_ms = tonumber(parts[9])
  settings.fade_length_ms = tonumber(parts[10])
  settings.fade_curve = parse_fade_curve(parts[11])
  settings.target_length_sec = tonumber(parts[12])
  settings.normalize_mode = parse_normalize_mode(parts[13])
  settings.normalize_target_db = tonumber(parts[14])
  settings.max_gain_db = tonumber(parts[15])
  settings.clip_protect = parse_boolean(parts[16], nil)
  settings.dry_run = parse_boolean(parts[17], nil)
  settings.min_length_ms = tonumber(parts[18])
  settings.max_trim_ratio = tonumber(parts[19])
  settings.sync_regions = parse_boolean(parts[20], nil)

  if not settings.threshold_db or settings.threshold_db > 0 or settings.threshold_db < -150 then
    return nil, "Threshold must be between -150 and 0 dB."
  end
  if not settings.min_silence_ms or settings.min_silence_ms < 0 or settings.min_silence_ms > 5000 then
    return nil, "Min silence must be between 0 and 5000 ms."
  end
  if not settings.block_size or settings.block_size < 64 or settings.block_size > 65536 then
    return nil, "Block size must be between 64 and 65536 samples."
  end
  if settings.head_trim_enabled == nil then
    return nil, "Enable Head Trim must be y or n."
  end
  if not settings.pre_roll_ms or settings.pre_roll_ms < 0 or settings.pre_roll_ms > 500 then
    return nil, "Head pre-roll must be between 0 and 500 ms."
  end
  if settings.keep_position == nil then
    return nil, "Keep item left edge fixed must be y or n."
  end
  if settings.tail_enabled == nil then
    return nil, "Enable Tail Processing must be y or n."
  end
  if not settings.tail_mode then
    return nil, "Tail mode must be cut, fade, or target."
  end
  if not settings.post_roll_ms or settings.post_roll_ms < 0 or settings.post_roll_ms > 5000 then
    return nil, "Tail post-roll must be between 0 and 5000 ms."
  end
  if not settings.fade_length_ms or settings.fade_length_ms < 0 or settings.fade_length_ms > 10000 then
    return nil, "Fade out length must be between 0 and 10000 ms."
  end
  if not settings.fade_curve then
    return nil, "Fade curve must be lin, exp, or scurve."
  end
  if not settings.target_length_sec or settings.target_length_sec < 0 or settings.target_length_sec > 3600 then
    return nil, "Target length must be between 0 and 3600 seconds."
  end
  if not settings.normalize_mode then
    return nil, "Normalize mode must be off, peak, or rms."
  end
  if not settings.normalize_target_db or settings.normalize_target_db > 6 or settings.normalize_target_db < -150 then
    return nil, "Normalize target must be between -150 and +6 dB."
  end
  if not settings.max_gain_db or settings.max_gain_db < 0 or settings.max_gain_db > 60 then
    return nil, "Max gain must be between 0 and 60 dB."
  end
  if settings.clip_protect == nil then
    return nil, "Protect From Clipping must be y or n."
  end
  if settings.dry_run == nil then
    return nil, "Dry Run must be y or n."
  end
  if not settings.min_length_ms or settings.min_length_ms < 1 or settings.min_length_ms > 10000 then
    return nil, "Min item length must be between 1 and 10000 ms."
  end
  if not settings.max_trim_ratio or settings.max_trim_ratio < 0 or settings.max_trim_ratio >= 100 then
    return nil, "Max trim ratio must be between 0 and less than 100%."
  end
  if settings.sync_regions == nil then
    return nil, "Sync Matching Regions must be y or n."
  end
  if settings.tail_mode == "target" and settings.target_length_sec <= 0 then
    return nil, "Target mode requires Target Length greater than 0."
  end

  settings.block_size = math.floor(settings.block_size)
  settings.threshold_db = round_to(settings.threshold_db, 3)
  settings.min_silence_ms = round_to(settings.min_silence_ms, 3)
  settings.pre_roll_ms = round_to(settings.pre_roll_ms, 3)
  settings.post_roll_ms = round_to(settings.post_roll_ms, 3)
  settings.fade_length_ms = round_to(settings.fade_length_ms, 3)
  settings.target_length_sec = round_to(settings.target_length_sec, 6)
  settings.normalize_target_db = round_to(settings.normalize_target_db, 3)
  settings.max_gain_db = round_to(settings.max_gain_db, 3)
  settings.min_length_ms = round_to(settings.min_length_ms, 3)
  settings.max_trim_ratio = round_to(settings.max_trim_ratio, 3)

  return settings
end

local function get_take_name_or_fallback(take, fallback_index)
  local take_name = trim_string(take and reaper.GetTakeName(take) or "")
  if take_name ~= "" then
    return strip_extension(take_name)
  end

  if take then
    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      local source_name = trim_string(reaper.GetMediaSourceFileName(source))
      if source_name ~= "" then
        return strip_extension(source_name:match("([^\\/]+)$") or source_name)
      end
    end
  end

  return string.format("Item_%02d", fallback_index or 1)
end

local function frame_exceeds_threshold(buffer, frame_index, num_channels, threshold_linear)
  local base_index = frame_index * num_channels
  for channel = 1, num_channels do
    if math.abs(buffer[base_index + channel]) > threshold_linear then
      return true
    end
  end
  return false
end

local function collect_matching_regions(project, start_pos, end_pos)
  local matches = {}
  local count = reaper.GetNumRegionsOrMarkers(project)

  for index = 0, count - 1 do
    local region = reaper.GetRegionOrMarker(project, index, "")
    if region then
      local is_region = reaper.GetRegionOrMarkerInfo_Value(project, region, "B_ISREGION")
      if is_region > 0.5 then
        local region_start = reaper.GetRegionOrMarkerInfo_Value(project, region, "D_STARTPOS")
        local region_end = reaper.GetRegionOrMarkerInfo_Value(project, region, "D_ENDPOS")
        if math.abs(region_start - start_pos) <= REGION_MATCH_TOLERANCE_SEC
          and math.abs(region_end - end_pos) <= REGION_MATCH_TOLERANCE_SEC then
          matches[#matches + 1] = region
        end
      end
    end
  end

  return matches
end

local function analyze_item(item, index, settings)
  local take = reaper.GetActiveTake(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local project = reaper.GetItemProjectContext(item)

  local result = {
    item = item,
    take = take,
    item_index = index,
    item_position = item_pos,
    item_end = item_pos + item_length,
    total_length = item_length,
    take_name = get_take_name_or_fallback(take, index),
    valid = false,
    is_silent = false,
    head_silence = 0.0,
    tail_silence = 0.0,
    content_start = 0.0,
    content_end = item_length,
    peak_db = NEG_INF_DB,
    rms_db = NEG_INF_DB,
    warnings = {},
    region_matches = {},
  }

  if not take then
    result.error = "No active take."
    return result
  end

  if reaper.TakeIsMIDI(take) then
    result.error = "MIDI take is not supported."
    return result
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    result.error = "Missing media source."
    return result
  end

  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local num_channels = math.max(reaper.GetMediaSourceNumChannels(source), 1)
  if sample_rate == nil or sample_rate <= 0 then
    sample_rate = 48000
    result.warnings[#result.warnings + 1] = "Source sample rate unavailable, fell back to 48000 Hz."
  end

  result.sample_rate = sample_rate
  result.num_channels = num_channels
  result.take_start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  result.take_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")

  if item_length <= 0 then
    result.error = "Item length is zero."
    return result
  end

  if settings.sync_regions then
    result.region_matches = collect_matching_regions(project, item_pos, item_pos + item_length)
  end

  local block_size = math.max(64, math.floor(settings.block_size))
  local threshold_linear = db_to_linear(settings.threshold_db)
  local min_silence_frames = math.max(1, math.floor(ms_to_sec(settings.min_silence_ms) * sample_rate + 0.5))
  local total_frames = math.max(1, math.floor(item_length * sample_rate + 0.5))

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    result.error = "Failed to create take audio accessor."
    return result
  end

  local buffer = reaper.new_array(block_size * num_channels)
  local ok, analysis_or_err = pcall(function()
    local first_loud_frame = nil
    local frame_cursor = 0

    while frame_cursor < total_frames and not first_loud_frame do
      local frames_to_read = math.min(block_size, total_frames - frame_cursor)
      buffer.clear()
      local retval = reaper.GetAudioAccessorSamples(
        accessor,
        sample_rate,
        num_channels,
        item_pos + (frame_cursor / sample_rate),
        frames_to_read,
        buffer
      )

      if retval < 0 then
        error("Audio accessor read failed during head scan.")
      end

      if retval ~= 0 then
        for frame_index = 0, frames_to_read - 1 do
          if frame_exceeds_threshold(buffer, frame_index, num_channels, threshold_linear) then
            first_loud_frame = frame_cursor + frame_index
            break
          end
        end
      end

      frame_cursor = frame_cursor + frames_to_read
    end

    if not first_loud_frame then
      return {
        is_silent = true,
        head_silence_sec = item_length,
        tail_silence_sec = item_length,
        content_start_sec = 0.0,
        content_end_sec = 0.0,
        peak_db = NEG_INF_DB,
        rms_db = NEG_INF_DB,
      }
    end

    local last_loud_frame = nil
    frame_cursor = total_frames

    while frame_cursor > 0 and not last_loud_frame do
      local frames_to_read = math.min(block_size, frame_cursor)
      local block_start_frame = frame_cursor - frames_to_read
      buffer.clear()
      local retval = reaper.GetAudioAccessorSamples(
        accessor,
        sample_rate,
        num_channels,
        item_pos + (block_start_frame / sample_rate),
        frames_to_read,
        buffer
      )

      if retval < 0 then
        error("Audio accessor read failed during tail scan.")
      end

      if retval ~= 0 then
        for frame_index = frames_to_read - 1, 0, -1 do
          if frame_exceeds_threshold(buffer, frame_index, num_channels, threshold_linear) then
            last_loud_frame = block_start_frame + frame_index
            break
          end
        end
      end

      frame_cursor = block_start_frame
    end

    if not last_loud_frame then
      last_loud_frame = first_loud_frame
    end

    local head_silence_frames = (first_loud_frame >= min_silence_frames) and first_loud_frame or 0
    local frames_after_last_loud = total_frames - (last_loud_frame + 1)
    local tail_silence_frames = (frames_after_last_loud >= min_silence_frames) and frames_after_last_loud or 0

    local content_start_frame = head_silence_frames
    local content_end_frame_exclusive = total_frames - tail_silence_frames
    if content_end_frame_exclusive <= content_start_frame then
      content_start_frame = first_loud_frame
      content_end_frame_exclusive = math.min(total_frames, last_loud_frame + 1)
    end

    local peak_linear = 0.0
    local sum_squares = 0.0
    local counted_samples = 0
    local stats_cursor = content_start_frame

    while stats_cursor < content_end_frame_exclusive do
      local frames_to_read = math.min(block_size, content_end_frame_exclusive - stats_cursor)
      buffer.clear()
      local retval = reaper.GetAudioAccessorSamples(
        accessor,
        sample_rate,
        num_channels,
        item_pos + (stats_cursor / sample_rate),
        frames_to_read,
        buffer
      )

      if retval < 0 then
        error("Audio accessor read failed during level scan.")
      end

      if retval ~= 0 then
        for frame_index = 0, frames_to_read - 1 do
          local base_index = frame_index * num_channels
          for channel = 1, num_channels do
            local sample = buffer[base_index + channel]
            local abs_sample = math.abs(sample)
            if abs_sample > peak_linear then
              peak_linear = abs_sample
            end
            sum_squares = sum_squares + (sample * sample)
            counted_samples = counted_samples + 1
          end
        end
      end

      stats_cursor = stats_cursor + frames_to_read
    end

    local peak_db = peak_linear > 0.0 and linear_to_db(peak_linear) or NEG_INF_DB
    local rms_linear = counted_samples > 0 and math.sqrt(sum_squares / counted_samples) or 0.0
    local rms_db = rms_linear > 0.0 and linear_to_db(rms_linear) or NEG_INF_DB

    return {
      is_silent = false,
      head_silence_sec = head_silence_frames / sample_rate,
      tail_silence_sec = tail_silence_frames / sample_rate,
      content_start_sec = content_start_frame / sample_rate,
      content_end_sec = content_end_frame_exclusive / sample_rate,
      peak_db = peak_db,
      rms_db = rms_db,
    }
  end)

  reaper.DestroyAudioAccessor(accessor)

  if not ok then
    result.error = tostring(analysis_or_err)
    return result
  end

  result.valid = true
  result.is_silent = analysis_or_err.is_silent
  result.head_silence = analysis_or_err.head_silence_sec
  result.tail_silence = analysis_or_err.tail_silence_sec
  result.content_start = analysis_or_err.content_start_sec
  result.content_end = analysis_or_err.content_end_sec
  result.peak_db = analysis_or_err.peak_db
  result.rms_db = analysis_or_err.rms_db
  return result
end

local function collect_selected_items()
  local items = {}
  local count = reaper.CountSelectedMediaItems(0)

  for index = 0, count - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, index)
  end

  return items
end

local function select_only_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function can_accept_final_length(original_length, final_length, settings)
  local min_length_sec = ms_to_sec(settings.min_length_ms)
  if final_length < min_length_sec then
    return false, "would be shorter than the minimum item length"
  end

  local trim_ratio = 1.0 - (final_length / math.max(original_length, 1e-12))
  if trim_ratio > (settings.max_trim_ratio / 100.0) then
    return false, "would exceed the max trim ratio"
  end

  return true
end

local function build_item_plan(analysis, settings)
  local plan = {
    analysis = analysis,
    item = analysis.item,
    take = analysis.take,
    messages = {},
    warnings = {},
    skip = false,
    skip_reason = nil,
    new_position = analysis.item_position,
    new_offset = analysis.take_start_offset or 0.0,
    new_length = analysis.total_length,
    head_trim_amount = 0.0,
    fade_length_sec = 0.0,
    fade_shape = nil,
    fade_dir = nil,
    gain_db = 0.0,
    gain_linear = 1.0,
    region_matches = analysis.region_matches or {},
  }

  if not analysis.valid then
    plan.skip = true
    plan.skip_reason = analysis.error or "Analysis failed."
    return plan
  end

  if analysis.is_silent then
    plan.skip = true
    plan.skip_reason = "Item contains no samples above threshold."
    return plan
  end

  local original_length = analysis.total_length
  local current_length = original_length
  local current_position = analysis.item_position
  local current_offset = analysis.take_start_offset or 0.0

  if settings.head_trim_enabled then
    local trim_amount = math.max(0.0, analysis.head_silence - ms_to_sec(settings.pre_roll_ms))
    if trim_amount > 0.0 then
      local candidate_length = original_length - trim_amount
      local ok, reason = can_accept_final_length(original_length, candidate_length, settings)
      if ok then
        current_length = candidate_length
        current_offset = current_offset + trim_amount
        if not settings.keep_position then
          current_position = current_position + trim_amount
        end
        plan.head_trim_amount = trim_amount
        plan.messages[#plan.messages + 1] = string.format("Head trim %.1f ms", trim_amount * 1000.0)
      else
        plan.warnings[#plan.warnings + 1] = "Head trim skipped: " .. reason .. "."
      end
    end
  end

  if settings.tail_enabled then
    local content_end_after_head = math.max(0.0, analysis.content_end - plan.head_trim_amount)

    if settings.tail_mode == "cut" then
      local desired_length = math.min(current_length, content_end_after_head + ms_to_sec(settings.post_roll_ms))
      if desired_length < current_length - 1e-9 then
        local ok, reason = can_accept_final_length(original_length, desired_length, settings)
        if ok then
          current_length = desired_length
          plan.messages[#plan.messages + 1] = string.format("Tail cut to %.3f s", desired_length)
        else
          plan.warnings[#plan.warnings + 1] = "Tail cut skipped: " .. reason .. "."
        end
      end
    elseif settings.tail_mode == "fade" then
      local fade_length_sec = ms_to_sec(settings.fade_length_ms)
      local desired_length = math.min(current_length, content_end_after_head + ms_to_sec(settings.post_roll_ms) + fade_length_sec)
      if desired_length < current_length - 1e-9 then
        local ok, reason = can_accept_final_length(original_length, desired_length, settings)
        if ok then
          current_length = desired_length
          plan.fade_length_sec = math.min(fade_length_sec, current_length)
          local preset = FADE_CURVE_PRESETS[settings.fade_curve] or FADE_CURVE_PRESETS.lin
          plan.fade_shape = preset.shape
          plan.fade_dir = preset.dir
          plan.messages[#plan.messages + 1] = string.format(
            "Tail fade %.0f ms (%s), new length %.3f s",
            settings.fade_length_ms,
            HUMAN_FADE_CURVE[settings.fade_curve] or settings.fade_curve,
            desired_length
          )
        else
          plan.warnings[#plan.warnings + 1] = "Tail fade skipped: " .. reason .. "."
        end
      elseif fade_length_sec > 0.0 then
        plan.fade_length_sec = math.min(fade_length_sec, current_length)
        local preset = FADE_CURVE_PRESETS[settings.fade_curve] or FADE_CURVE_PRESETS.lin
        plan.fade_shape = preset.shape
        plan.fade_dir = preset.dir
        plan.messages[#plan.messages + 1] = string.format(
          "Fade applied at existing length (%.0f ms, %s)",
          settings.fade_length_ms,
          HUMAN_FADE_CURVE[settings.fade_curve] or settings.fade_curve
        )
      end
    elseif settings.tail_mode == "target" then
      local desired_length = settings.target_length_sec
      if current_length > desired_length + 1e-9 then
        local ok, reason = can_accept_final_length(original_length, desired_length, settings)
        if ok then
          current_length = desired_length
          plan.messages[#plan.messages + 1] = string.format("Target length %.3f s", desired_length)
        else
          plan.warnings[#plan.warnings + 1] = "Target length skipped: " .. reason .. "."
        end
      else
        plan.warnings[#plan.warnings + 1] = "Target length skipped: item is already shorter than or equal to target."
      end
    end
  end

  if settings.normalize_mode ~= "off" then
    local current_level = settings.normalize_mode == "peak" and analysis.peak_db or analysis.rms_db
    if current_level <= NEG_INF_DB + 0.5 then
      plan.warnings[#plan.warnings + 1] = "Normalize skipped: level is too low to measure."
    else
      local gain_db = settings.normalize_target_db - current_level
      gain_db = math.min(gain_db, settings.max_gain_db)

      if settings.clip_protect then
        local max_safe_gain = -analysis.peak_db
        if gain_db > max_safe_gain then
          gain_db = max_safe_gain
          plan.warnings[#plan.warnings + 1] = "Normalize gain was reduced to prevent clipping."
        end
      end

      if math.abs(gain_db) > 0.001 then
        plan.gain_db = gain_db
        plan.gain_linear = db_to_linear(gain_db)
        plan.messages[#plan.messages + 1] = string.format(
          "Normalize %s %+.2f dB",
          HUMAN_NORMALIZE_MODE[settings.normalize_mode] or settings.normalize_mode,
          gain_db
        )
      end
    end
  end

  plan.new_position = current_position
  plan.new_offset = current_offset
  plan.new_length = current_length
  return plan
end

local function print_analysis_report(analyses, settings)
  local total_head = 0.0
  local total_tail = 0.0
  local longest_tail = 0.0
  local longest_tail_name = nil
  local peak_min = nil
  local peak_max = nil
  local valid_count = 0

  log_line("==========================================================================")
  log_line("  Tail/Silence Analysis Report")
  log_line("==========================================================================")
  log_line(string.format(
    "  Threshold: %.1f dB | Min Silence: %.1f ms | Block: %d | Items: %d",
    settings.threshold_db,
    settings.min_silence_ms,
    settings.block_size,
    #analyses
  ))
  log_line("--------------------------------------------------------------------------")
  log_line(string.format("  %-3s %-26s %-8s %-8s %-8s %-8s %-8s", "#", "Name", "Length", "Head", "Tail", "Peak", "Status"))
  log_line("--------------------------------------------------------------------------")

  for _, analysis in ipairs(analyses) do
    local status = "OK"
    if not analysis.valid then
      status = "SKIP"
    elseif analysis.is_silent then
      status = "SILENT"
    else
      total_head = total_head + analysis.head_silence
      total_tail = total_tail + analysis.tail_silence
      valid_count = valid_count + 1

      if analysis.tail_silence > longest_tail then
        longest_tail = analysis.tail_silence
        longest_tail_name = analysis.take_name
      end

      if peak_min == nil or analysis.peak_db < peak_min then
        peak_min = analysis.peak_db
      end
      if peak_max == nil or analysis.peak_db > peak_max then
        peak_max = analysis.peak_db
      end
    end

    log_line(string.format(
      "  %-3d %-26s %-8s %-8s %-8s %-8s %-8s",
      analysis.item_index,
      truncate_text(analysis.take_name, 26),
      format_seconds(analysis.total_length),
      format_ms_from_sec(analysis.head_silence),
      format_ms_from_sec(analysis.tail_silence),
      format_db(analysis.peak_db),
      status
    ))

    if analysis.error then
      log_line("      Reason: " .. analysis.error)
    end
  end

  log_line("--------------------------------------------------------------------------")
  log_line("  Summary:")
  log_line(string.format("    Total head silence detected: %s", format_ms_from_sec(total_head)))
  log_line(string.format("    Total tail silence detected: %s", format_ms_from_sec(total_tail)))
  if longest_tail_name then
    log_line(string.format("    Longest tail: %s (%s)", format_ms_from_sec(longest_tail), longest_tail_name))
  else
    log_line("    Longest tail: n/a")
  end
  if peak_min ~= nil and peak_max ~= nil then
    log_line(string.format(
      "    Peak range: %s dB to %s dB (spread %.1f dB)",
      format_db(peak_min),
      format_db(peak_max),
      peak_max - peak_min
    ))
  else
    log_line("    Peak range: n/a")
  end
  log_line(string.format("    Valid audio items: %d", valid_count))
  log_line("==========================================================================")
end

local function print_plan_preview(plans, settings)
  log_line("")
  log_line("==========================================================================")
  log_line(settings.dry_run and "  Dry Run Preview" or "  Processing Plan")
  log_line("==========================================================================")

  for _, plan in ipairs(plans) do
    local name = plan.analysis.take_name
    log_line(string.format("[%02d] %s", plan.analysis.item_index, name))

    if plan.skip then
      log_line("  Skip: " .. tostring(plan.skip_reason))
    else
      if #plan.messages == 0 then
        log_line("  No audible edits needed.")
      else
        for _, message in ipairs(plan.messages) do
          log_line("  " .. message)
        end
      end

      if #plan.warnings > 0 then
        for _, warning in ipairs(plan.warnings) do
          log_line("  Warning: " .. warning)
        end
      end

      log_line(string.format(
        "  Result -> Pos %.3f s | Length %.3f s | Offset %.3f s",
        plan.new_position,
        plan.new_length,
        plan.new_offset
      ))

      if settings.sync_regions and #plan.region_matches > 0 then
        log_line(string.format("  Matching regions to sync: %d", #plan.region_matches))
      end
    end

    log_line("")
  end
end

local function update_matching_regions(plan)
  if not plan or not plan.region_matches or #plan.region_matches == 0 then
    return 0
  end

  local project = reaper.GetItemProjectContext(plan.item)
  local new_start = plan.new_position
  local new_end = plan.new_position + plan.new_length
  local updated = 0

  for _, region in ipairs(plan.region_matches) do
    if region and reaper.GetRegionOrMarkerInfo_Value(project, region, "B_ISREGION") > 0.5 then
      reaper.SetRegionOrMarkerInfo_Value(project, region, "D_STARTPOS", new_start)
      reaper.SetRegionOrMarkerInfo_Value(project, region, "D_ENDPOS", new_end)
      updated = updated + 1
    end
  end

  return updated
end

local function apply_item_plan(plan, settings)
  if plan.skip then
    return true, 0
  end

  local item = plan.item
  local take = plan.take
  if not item or not take then
    return false, 0, "Item or take became invalid before processing."
  end

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", plan.new_offset)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", plan.new_position)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", plan.new_length)

  if plan.fade_length_sec > 0.0 then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", -1.0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", plan.fade_length_sec)
    if plan.fade_shape ~= nil then
      reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", plan.fade_shape)
    end
    if plan.fade_dir ~= nil then
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", plan.fade_dir)
    end
  end

  if math.abs(plan.gain_db) > 0.001 then
    local current_take_vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
    reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", current_take_vol * plan.gain_linear)
  end

  local updated_regions = 0
  if settings.sync_regions then
    updated_regions = update_matching_regions(plan)
  end

  return true, updated_regions
end

local function process_plans(plans, selected_items, settings)
  local processed_count = 0
  local skipped_count = 0
  local updated_regions = 0

  if settings.dry_run then
    return true, {
      processed_count = 0,
      skipped_count = 0,
      updated_regions = 0,
    }
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, result_or_err = pcall(function()
    for _, plan in ipairs(plans) do
      if plan.skip then
        skipped_count = skipped_count + 1
      else
        local applied, region_updates, apply_err = apply_item_plan(plan, settings)
        if not applied then
          error(apply_err or "Failed to apply item plan.")
        end
        processed_count = processed_count + 1
        updated_regions = updated_regions + (region_updates or 0)
      end
    end
  end)

  select_only_items(selected_items)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock("Tail/Silence Processing", -1)
    return true, {
      processed_count = processed_count,
      skipped_count = skipped_count,
      updated_regions = updated_regions,
    }
  end

  reaper.Undo_EndBlock("Tail/Silence Processing (failed)", -1)
  return false, tostring(result_or_err)
end

local function print_final_summary(plans, settings, process_result)
  local total_trimmed = 0.0
  local total_gain = 0.0
  local edited_count = 0
  local skipped_count = 0

  for _, plan in ipairs(plans) do
    if plan.skip then
      skipped_count = skipped_count + 1
    else
      local trimmed = math.max(0.0, plan.analysis.total_length - plan.new_length)
      total_trimmed = total_trimmed + trimmed
      total_gain = total_gain + math.abs(plan.gain_db or 0.0)
      edited_count = edited_count + 1
    end
  end

  log_line("")
  log_line("==========================================================================")
  log_line(settings.dry_run and "  Tail/Silence Dry Run Complete" or "  Tail/Silence Processing Complete")
  log_line("==========================================================================")
  log_line(string.format("  Items analyzed:        %d", #plans))
  log_line(string.format("  Items ready/edited:    %d", edited_count))
  log_line(string.format("  Items skipped:         %d", skipped_count))
  log_line(string.format("  Total trim planned:    %s", format_ms_from_sec(total_trimmed)))
  log_line(string.format("  Total gain magnitude:  %.2f dB", total_gain))
  log_line(string.format("  Tail mode:             %s", HUMAN_TAIL_MODE[settings.tail_mode] or settings.tail_mode))
  log_line(string.format("  Normalize:             %s", HUMAN_NORMALIZE_MODE[settings.normalize_mode] or settings.normalize_mode))

  if not settings.dry_run and process_result then
    log_line(string.format("  Applied items:         %d", process_result.processed_count or 0))
    log_line(string.format("  Synced regions:        %d", process_result.updated_regions or 0))
  end

  log_line("==========================================================================")
end

local function main()
  local selected_items = collect_selected_items()
  if #selected_items == 0 then
    reaper.ShowMessageBox("No selected media items were found.", SCRIPT_TITLE, 0)
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

  local analyses = {}
  reaper.ClearConsole()

  for index, item in ipairs(selected_items) do
    analyses[#analyses + 1] = analyze_item(item, index, settings)
  end

  print_analysis_report(analyses, settings)

  local plans = {}
  for _, analysis in ipairs(analyses) do
    plans[#plans + 1] = build_item_plan(analysis, settings)
  end

  print_plan_preview(plans, settings)

  local ok, result_or_err = process_plans(plans, selected_items, settings)
  if not ok then
    reaper.ShowMessageBox("Tail/Silence processing failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Tail Processor] ERROR: " .. tostring(result_or_err))
    return
  end

  print_final_summary(plans, settings, result_or_err)
end

main()
