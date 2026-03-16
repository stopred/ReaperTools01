-- Game Sound Loudness Normalizer v1.0
-- Reaper ReaScript (Lua)
-- 게임 사운드 에셋 라우드니스/피크 일괄 노멀라이즈 도구
--
-- 사용법:
-- 1. Reaper에서 노멀라이즈할 미디어 아이템(들)을 선택
-- 2. Actions -> 이 스크립트 실행
-- 3. Analyze로 현재 레벨 분석 -> 카테고리별 목표 확인/조정 -> Normalize 실행
-- 4. 노멀라이즈 완료 후 Batch Renderer로 최종 렌더링
--
-- 요구사항: REAPER v7.0+
-- 연계 스크립트: GameSoundVariationGenerator.lua,
--               GameSoundTailProcessor.lua,
--               GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Loudness Normalizer v1.0"
local EXT_SECTION = "GameSoundLoudnessNorm"
local NEG_INF_DB = -150.0
local REGION_MATCH_TOLERANCE_SEC = 0.01

local DEFAULT_CATEGORY_TARGETS = {
  ["SFX_Weapon"]      = { metric = "peak", target = -1.0 },
  ["SFX_Impact"]      = { metric = "peak", target = -1.0 },
  ["SFX_Explosion"]   = { metric = "peak", target = -1.0 },
  ["SFX_Footstep"]    = { metric = "lufs", target = -24.0 },
  ["SFX_Foley"]       = { metric = "lufs", target = -22.0 },
  ["UI_Menu"]         = { metric = "peak", target = -6.0 },
  ["UI_Button"]       = { metric = "peak", target = -6.0 },
  ["UI_Notification"] = { metric = "peak", target = -3.0 },
  ["AMB_Nature"]      = { metric = "lufs", target = -28.0 },
  ["AMB_Indoor"]      = { metric = "lufs", target = -30.0 },
  ["AMB_Urban"]       = { metric = "lufs", target = -26.0 },
  ["MUS_BGM"]         = { metric = "lufs", target = -16.0 },
  ["MUS_Jingle"]      = { metric = "peak", target = -3.0 },
  ["VO_Dialogue"]     = { metric = "lufs", target = -18.0 },
  ["VO_Narration"]    = { metric = "lufs", target = -16.0 },
  ["VO_Shout"]        = { metric = "peak", target = -3.0 },
  ["FOL_Cloth"]       = { metric = "lufs", target = -26.0 },
  ["FOL_Movement"]    = { metric = "lufs", target = -24.0 },
  ["Uncategorized"]   = { metric = "peak", target = -3.0 },
}

local DEFAULT_MANUAL_TARGETS = {
  peak = -3.0,
  rms = -20.0,
  lufs = -23.0,
}

local DEFAULTS = {
  normalize_mode = "auto",
  manual_target_db = DEFAULT_MANUAL_TARGETS.peak,
  silence_threshold_db = -60.0,
  exclude_silence = true,
  min_silence_ms = 10.0,
  channel_mode = "max",
  max_gain_db = 20.0,
  max_cut_db = -20.0,
  ceiling_dbfs = -0.3,
  deadzone_db = 0.5,
  clip_prevention = "limit",
  balance_mode = "individual",
  dry_run = false,
  block_size = 2048,
  lufs_window_sec = 0.4,
  lufs_hop_sec = 0.1,
  preset_name = "Default",
}

local HUMAN_METRIC = {
  peak = "Peak",
  rms = "RMS",
  lufs = "LUFS",
}

local HUMAN_BALANCE_MODE = {
  individual = "Individual",
  relative = "Relative",
}

local HUMAN_CLIP_MODE = {
  limit = "Limit",
  warn = "Warn",
  skip = "Skip",
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
  return value and "yes" or "no"
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
  local safe = math.max(math.abs(tonumber(linear_value) or 0.0), 1e-12)
  return 20.0 * log10(safe)
end

local function ms_to_sec(value)
  return (tonumber(value) or 0.0) / 1000.0
end

local function strip_extension(name)
  return trim_string(name):gsub("%.[^%.\\/]+$", "")
end

local function sanitize_category_key(name)
  local sanitized = trim_string(name):gsub("[|;\r\n\t]", "_")
  sanitized = sanitized:gsub("%s%s+", " ")
  return sanitized
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

local function format_target(metric, target_db)
  if metric == "lufs" then
    return string.format("%s %.1f LUFS", HUMAN_METRIC[metric] or metric, target_db)
  end
  return string.format("%s %.1f dBFS", HUMAN_METRIC[metric] or metric, target_db)
end

local function format_seconds(seconds)
  return string.format("%.3fs", tonumber(seconds) or 0.0)
end

local function sort_strings_case_insensitive(values)
  table.sort(values, function(left, right)
    local lhs = tostring(left or ""):lower()
    local rhs = tostring(right or ""):lower()
    if lhs == rhs then
      return tostring(left or "") < tostring(right or "")
    end
    return lhs < rhs
  end)
end

local function shallow_copy_list(values)
  local copy = {}
  for index = 1, #values do
    copy[index] = values[index]
  end
  return copy
end

local function copy_presets(source)
  local copy = {}
  for key, data in pairs(source or {}) do
    copy[key] = {
      metric = data.metric,
      target = tonumber(data.target) or 0.0,
    }
  end
  return copy
end

local function merge_presets(defaults, overrides)
  local merged = copy_presets(defaults)
  for key, data in pairs(overrides or {}) do
    if type(data) == "table" and (data.metric == "peak" or data.metric == "rms" or data.metric == "lufs")
      and tonumber(data.target) ~= nil then
      merged[key] = {
        metric = data.metric,
        target = tonumber(data.target),
      }
    end
  end
  return merged
end

local function serialize_presets(presets)
  local keys = {}
  for key in pairs(presets or {}) do
    keys[#keys + 1] = key
  end
  sort_strings_case_insensitive(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    local data = presets[key]
    parts[#parts + 1] = key .. "|" .. tostring(data.metric) .. "|" .. tostring(data.target)
  end
  return table.concat(parts, ";")
end

local function deserialize_presets(serialized)
  local presets = {}
  local text = trim_string(serialized)
  if text == "" then
    return presets
  end

  for entry in text:gmatch("[^;]+") do
    local category, metric, target = entry:match("(.+)|(.+)|(.+)")
    if category and (metric == "peak" or metric == "rms" or metric == "lufs") and tonumber(target) ~= nil then
      presets[category] = {
        metric = metric,
        target = tonumber(target),
      }
    end
  end

  return presets
end

local function sanitize_preset_name(name)
  local sanitized = trim_string(name):gsub("[\r\n\t|]", " ")
  sanitized = sanitized:gsub("%s%s+", " ")
  if sanitized == "" then
    return "Default"
  end
  return sanitized
end

local function serialize_preset_sets(preset_sets)
  local names = {}
  for name in pairs(preset_sets or {}) do
    names[#names + 1] = sanitize_preset_name(name)
  end
  sort_strings_case_insensitive(names)

  local lines = {}
  local seen = {}
  for _, name in ipairs(names) do
    if not seen[name] then
      seen[name] = true
      lines[#lines + 1] = name .. "\t" .. serialize_presets(preset_sets[name] or {})
    end
  end
  return table.concat(lines, "\n")
end

local function deserialize_preset_sets(serialized)
  local preset_sets = {}
  local text = tostring(serialized or "")
  for line in text:gmatch("[^\r\n]+") do
    local name, preset_blob = line:match("^([^\t]+)\t(.*)$")
    if name and preset_blob then
      preset_sets[sanitize_preset_name(name)] = deserialize_presets(preset_blob)
    end
  end
  return preset_sets
end

local function ensure_default_preset_sets(preset_sets)
  local ensured = preset_sets or {}
  if not ensured["Default"] then
    ensured["Default"] = copy_presets(DEFAULT_CATEGORY_TARGETS)
  end
  return ensured
end

local function rebuild_preset_lookup(settings)
  settings.preset_lookup = {}
  for key in pairs(settings.presets or {}) do
    settings.preset_lookup[key:lower()] = key
  end
end

local function load_preset_set_into_settings(settings, preset_name)
  settings.preset_sets = ensure_default_preset_sets(settings.preset_sets)
  local normalized_name = sanitize_preset_name(preset_name)
  local preset_data = settings.preset_sets[normalized_name]
  if not preset_data then
    return false
  end

  settings.preset_name = normalized_name
  settings.presets = merge_presets(DEFAULT_CATEGORY_TARGETS, preset_data)
  rebuild_preset_lookup(settings)
  return true
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function get_default_manual_target(metric)
  return DEFAULT_MANUAL_TARGETS[metric] or DEFAULT_MANUAL_TARGETS.peak
end

local function parse_normalize_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "auto" or lowered == "a" then
    return "auto"
  end
  if lowered == "peak" or lowered == "p" then
    return "peak"
  end
  if lowered == "rms" or lowered == "r" then
    return "rms"
  end
  if lowered == "lufs" or lowered == "lufs-i" or lowered == "l" then
    return "lufs"
  end
  return nil
end

local function parse_clip_prevention(value)
  local lowered = trim_string(value):lower()
  if lowered == "limit" or lowered == "l" then
    return "limit"
  end
  if lowered == "warn" or lowered == "w" then
    return "warn"
  end
  if lowered == "skip" or lowered == "s" then
    return "skip"
  end
  return nil
end

local function parse_balance_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "individual" or lowered == "ind" or lowered == "i" then
    return "individual"
  end
  if lowered == "relative" or lowered == "rel" or lowered == "r" then
    return "relative"
  end
  return nil
end

local function load_settings()
  local settings = {}

  settings.normalize_mode = parse_normalize_mode(get_ext_state("normalize_mode", DEFAULTS.normalize_mode)) or DEFAULTS.normalize_mode
  settings.manual_target_db = tonumber(get_ext_state("manual_target_db", tostring(DEFAULTS.manual_target_db))) or DEFAULTS.manual_target_db
  settings.silence_threshold_db = tonumber(get_ext_state("silence_threshold_db", tostring(DEFAULTS.silence_threshold_db))) or DEFAULTS.silence_threshold_db
  settings.exclude_silence = parse_boolean(get_ext_state("exclude_silence", bool_to_string(DEFAULTS.exclude_silence)), DEFAULTS.exclude_silence)
  settings.min_silence_ms = tonumber(get_ext_state("min_silence_ms", tostring(DEFAULTS.min_silence_ms))) or DEFAULTS.min_silence_ms
  settings.channel_mode = trim_string(get_ext_state("channel_mode", DEFAULTS.channel_mode)):lower()
  if settings.channel_mode ~= "max" and settings.channel_mode ~= "average" then
    settings.channel_mode = DEFAULTS.channel_mode
  end
  settings.max_gain_db = tonumber(get_ext_state("max_gain_db", tostring(DEFAULTS.max_gain_db))) or DEFAULTS.max_gain_db
  settings.max_cut_db = tonumber(get_ext_state("max_cut_db", tostring(DEFAULTS.max_cut_db))) or DEFAULTS.max_cut_db
  settings.ceiling_dbfs = tonumber(get_ext_state("ceiling_dbfs", tostring(DEFAULTS.ceiling_dbfs))) or DEFAULTS.ceiling_dbfs
  settings.deadzone_db = tonumber(get_ext_state("deadzone_db", tostring(DEFAULTS.deadzone_db))) or DEFAULTS.deadzone_db
  settings.clip_prevention = parse_clip_prevention(get_ext_state("clip_prevention", DEFAULTS.clip_prevention)) or DEFAULTS.clip_prevention
  settings.balance_mode = parse_balance_mode(get_ext_state("balance_mode", DEFAULTS.balance_mode)) or DEFAULTS.balance_mode
  settings.dry_run = parse_boolean(get_ext_state("dry_run", bool_to_string(DEFAULTS.dry_run)), DEFAULTS.dry_run)
  settings.block_size = math.floor((tonumber(get_ext_state("block_size", tostring(DEFAULTS.block_size))) or DEFAULTS.block_size) + 0.5)
  settings.lufs_window_sec = tonumber(get_ext_state("lufs_window_sec", tostring(DEFAULTS.lufs_window_sec))) or DEFAULTS.lufs_window_sec
  settings.lufs_hop_sec = tonumber(get_ext_state("lufs_hop_sec", tostring(DEFAULTS.lufs_hop_sec))) or DEFAULTS.lufs_hop_sec
  settings.preset_name = sanitize_preset_name(get_ext_state("preset_name", DEFAULTS.preset_name))

  local stored_presets = deserialize_presets(get_ext_state("category_presets", ""))
  settings.preset_sets = ensure_default_preset_sets(deserialize_preset_sets(get_ext_state("preset_sets", "")))
  if not load_preset_set_into_settings(settings, settings.preset_name) then
    if next(stored_presets) ~= nil then
      settings.presets = merge_presets(DEFAULT_CATEGORY_TARGETS, stored_presets)
      settings.preset_sets[settings.preset_name] = copy_presets(settings.presets)
    else
      settings.preset_name = "Default"
      settings.presets = merge_presets(DEFAULT_CATEGORY_TARGETS, settings.preset_sets["Default"])
    end
    rebuild_preset_lookup(settings)
  end

  return settings
end

local function save_settings(settings)
  settings.preset_name = sanitize_preset_name(settings.preset_name)
  settings.preset_sets = ensure_default_preset_sets(settings.preset_sets)
  settings.preset_sets[settings.preset_name] = copy_presets(settings.presets)
  rebuild_preset_lookup(settings)

  reaper.SetExtState(EXT_SECTION, "normalize_mode", tostring(settings.normalize_mode), true)
  reaper.SetExtState(EXT_SECTION, "manual_target_db", tostring(settings.manual_target_db), true)
  reaper.SetExtState(EXT_SECTION, "silence_threshold_db", tostring(settings.silence_threshold_db), true)
  reaper.SetExtState(EXT_SECTION, "exclude_silence", bool_to_string(settings.exclude_silence), true)
  reaper.SetExtState(EXT_SECTION, "min_silence_ms", tostring(settings.min_silence_ms), true)
  reaper.SetExtState(EXT_SECTION, "channel_mode", tostring(settings.channel_mode), true)
  reaper.SetExtState(EXT_SECTION, "max_gain_db", tostring(settings.max_gain_db), true)
  reaper.SetExtState(EXT_SECTION, "max_cut_db", tostring(settings.max_cut_db), true)
  reaper.SetExtState(EXT_SECTION, "ceiling_dbfs", tostring(settings.ceiling_dbfs), true)
  reaper.SetExtState(EXT_SECTION, "deadzone_db", tostring(settings.deadzone_db), true)
  reaper.SetExtState(EXT_SECTION, "clip_prevention", tostring(settings.clip_prevention), true)
  reaper.SetExtState(EXT_SECTION, "balance_mode", tostring(settings.balance_mode), true)
  reaper.SetExtState(EXT_SECTION, "dry_run", bool_to_string(settings.dry_run), true)
  reaper.SetExtState(EXT_SECTION, "block_size", tostring(settings.block_size), true)
  reaper.SetExtState(EXT_SECTION, "lufs_window_sec", tostring(settings.lufs_window_sec), true)
  reaper.SetExtState(EXT_SECTION, "lufs_hop_sec", tostring(settings.lufs_hop_sec), true)
  reaper.SetExtState(EXT_SECTION, "preset_name", tostring(settings.preset_name), true)
  reaper.SetExtState(EXT_SECTION, "category_presets", serialize_presets(settings.presets), true)
  reaper.SetExtState(EXT_SECTION, "preset_sets", serialize_preset_sets(settings.preset_sets), true)
end

local function clone_settings(settings)
  local copy = {}
  for key, value in pairs(settings or {}) do
    copy[key] = value
  end

  copy.presets = copy_presets(settings.presets or {})
  copy.preset_sets = {}
  for name, presets in pairs(settings.preset_sets or {}) do
    copy.preset_sets[name] = copy_presets(presets)
  end
  rebuild_preset_lookup(copy)
  return copy
end

local function prompt_for_settings(current)
  local captions = table.concat({
    "extrawidth=320",
    "separator=|",
    "Normalize Mode (peak/rms/lufs/auto)",
    "Manual Target dB (used when mode != auto)",
    "Silence Threshold (dB)",
    "Max Gain (dB)",
    "Max Cut (dB)",
    "Ceiling (dBFS)",
    "Deadzone (dB)",
    "Clip Prevention (limit/warn/skip)",
    "Balance Mode (individual/relative)",
    "Dry Run (yes/no)",
  }, ",")

  local defaults = table.concat({
    tostring(current.normalize_mode),
    tostring(current.manual_target_db),
    tostring(current.silence_threshold_db),
    tostring(current.max_gain_db),
    tostring(current.max_cut_db),
    tostring(current.ceiling_dbfs),
    tostring(current.deadzone_db),
    tostring(current.clip_prevention),
    tostring(current.balance_mode),
    bool_to_string(current.dry_run),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 10, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 10)
  local settings = load_settings()

  settings.normalize_mode = parse_normalize_mode(parts[1])
  settings.manual_target_db = trim_string(parts[2]) == "" and nil or tonumber(parts[2])
  settings.silence_threshold_db = tonumber(parts[3])
  settings.max_gain_db = tonumber(parts[4])
  settings.max_cut_db = tonumber(parts[5])
  settings.ceiling_dbfs = tonumber(parts[6])
  settings.deadzone_db = tonumber(parts[7])
  settings.clip_prevention = parse_clip_prevention(parts[8])
  settings.balance_mode = parse_balance_mode(parts[9])
  settings.dry_run = parse_boolean(parts[10], nil)

  if not settings.normalize_mode then
    return nil, "Normalize mode must be peak, rms, lufs, or auto."
  end

  if settings.normalize_mode ~= "auto" and settings.manual_target_db == nil then
    settings.manual_target_db = get_default_manual_target(settings.normalize_mode)
  end

  if settings.normalize_mode ~= "auto" and (not settings.manual_target_db or settings.manual_target_db > 6 or settings.manual_target_db < -150) then
    return nil, "Manual target must be between -150 and +6 dB."
  end
  if not settings.silence_threshold_db or settings.silence_threshold_db > 0 or settings.silence_threshold_db < -150 then
    return nil, "Silence threshold must be between -150 and 0 dB."
  end
  if not settings.max_gain_db or settings.max_gain_db < 0 or settings.max_gain_db > 60 then
    return nil, "Max gain must be between 0 and 60 dB."
  end
  if not settings.max_cut_db or settings.max_cut_db > 0 or settings.max_cut_db < -60 then
    return nil, "Max cut must be between -60 and 0 dB."
  end
  if not settings.ceiling_dbfs or settings.ceiling_dbfs > 0 or settings.ceiling_dbfs < -20 then
    return nil, "Ceiling must be between -20 and 0 dBFS."
  end
  if not settings.deadzone_db or settings.deadzone_db < 0 or settings.deadzone_db > 6 then
    return nil, "Deadzone must be between 0 and 6 dB."
  end
  if not settings.clip_prevention then
    return nil, "Clip prevention must be limit, warn, or skip."
  end
  if not settings.balance_mode then
    return nil, "Balance mode must be individual or relative."
  end
  if settings.dry_run == nil then
    return nil, "Dry run must be yes or no."
  end

  settings.silence_threshold_db = round_to(settings.silence_threshold_db, 3)
  settings.manual_target_db = round_to(settings.manual_target_db or get_default_manual_target("peak"), 3)
  settings.max_gain_db = round_to(settings.max_gain_db, 3)
  settings.max_cut_db = round_to(settings.max_cut_db, 3)
  settings.ceiling_dbfs = round_to(settings.ceiling_dbfs, 3)
  settings.deadzone_db = round_to(settings.deadzone_db, 3)

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

local function extract_category_from_name(name)
  local normalized = strip_extension(trim_string(name))
  if normalized == "" then
    return nil
  end

  local prefix, category = normalized:match("^([A-Za-z0-9]+)_([^_]+)")
  if prefix and category and prefix ~= "" and category ~= "" then
    return prefix .. "_" .. category
  end

  return nil
end

local function resolve_category_key(raw_category, preset_lookup)
  if not raw_category or raw_category == "" then
    return "Uncategorized"
  end

  local canonical = preset_lookup and preset_lookup[raw_category:lower()]
  if canonical then
    return canonical
  end

  return raw_category
end

local function get_track_name(item)
  local track = item and reaper.GetMediaItemTrack(item) or nil
  if not track then
    return ""
  end
  local _, track_name = reaper.GetTrackName(track, "")
  return trim_string(track_name)
end

local function get_matching_region_name(project, item_pos, item_end)
  if not project then
    return ""
  end

  local index = 0
  while true do
    local retval, is_region, region_start, region_end, region_name = reaper.EnumProjectMarkers3(project, index)
    if retval == 0 then
      break
    end

    if is_region then
      local contains_item = item_pos >= (region_start - REGION_MATCH_TOLERANCE_SEC)
        and item_end <= (region_end + REGION_MATCH_TOLERANCE_SEC)
      local exact_match = math.abs(region_start - item_pos) <= REGION_MATCH_TOLERANCE_SEC
        and math.abs(region_end - item_end) <= REGION_MATCH_TOLERANCE_SEC
      if exact_match or contains_item then
        return trim_string(region_name)
      end
    end

    index = index + 1
  end

  return ""
end

local function detect_category(item, take_name, preset_lookup)
  local candidate = extract_category_from_name(take_name)
  if candidate then
    return resolve_category_key(candidate, preset_lookup), "take"
  end

  local track_name = get_track_name(item)
  candidate = extract_category_from_name(track_name)
  if candidate then
    return resolve_category_key(candidate, preset_lookup), "track"
  end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local project = reaper.GetItemProjectContext(item)
  local region_name = get_matching_region_name(project, item_pos, item_pos + item_length)
  candidate = extract_category_from_name(region_name)
  if candidate then
    return resolve_category_key(candidate, preset_lookup), "region"
  end

  return "Uncategorized", "fallback"
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

local function compute_window_rms_linear(buffer, frames_to_read, num_channels, channel_mode)
  if frames_to_read <= 0 then
    return 0.0
  end

  local total_sum_squares = 0.0
  local total_count = 0
  local channel_sum_squares = {}
  local channel_count = {}
  for channel = 1, num_channels do
    channel_sum_squares[channel] = 0.0
    channel_count[channel] = 0
  end

  for frame_index = 0, frames_to_read - 1 do
    local base_index = frame_index * num_channels
    for channel = 1, num_channels do
      local sample = buffer[base_index + channel]
      local squared = sample * sample
      total_sum_squares = total_sum_squares + squared
      total_count = total_count + 1
      channel_sum_squares[channel] = channel_sum_squares[channel] + squared
      channel_count[channel] = channel_count[channel] + 1
    end
  end

  if channel_mode == "average" then
    if total_count <= 0 then
      return 0.0
    end
    return math.sqrt(total_sum_squares / total_count)
  end

  local channel_rms_max = 0.0
  for channel = 1, num_channels do
    if channel_count[channel] > 0 then
      local channel_rms = math.sqrt(channel_sum_squares[channel] / channel_count[channel])
      if channel_rms > channel_rms_max then
        channel_rms_max = channel_rms
      end
    end
  end
  return channel_rms_max
end

local function find_content_bounds(accessor, sample_rate, num_channels, item_pos, total_frames, settings)
  local threshold_linear = db_to_linear(settings.silence_threshold_db)
  local block_size = math.max(64, math.floor(settings.block_size))
  local min_silence_frames = math.max(1, math.floor(ms_to_sec(settings.min_silence_ms) * sample_rate + 0.5))
  local buffer = reaper.new_array(block_size * num_channels)

  if not settings.exclude_silence then
    return {
      is_silent = false,
      head_silence_frames = 0,
      tail_silence_frames = 0,
      content_start_frame = 0,
      content_end_frame_exclusive = total_frames,
    }
  end

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
      head_silence_frames = total_frames,
      tail_silence_frames = total_frames,
      content_start_frame = 0,
      content_end_frame_exclusive = 0,
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

  return {
    is_silent = false,
    head_silence_frames = head_silence_frames,
    tail_silence_frames = tail_silence_frames,
    content_start_frame = content_start_frame,
    content_end_frame_exclusive = content_end_frame_exclusive,
  }
end

local function measure_peak_and_rms(accessor, sample_rate, num_channels, item_pos, start_frame, end_frame_exclusive, settings)
  if end_frame_exclusive <= start_frame then
    return NEG_INF_DB, NEG_INF_DB
  end

  local block_size = math.max(64, math.floor(settings.block_size))
  local buffer = reaper.new_array(block_size * num_channels)
  local peak_linear = 0.0
  local total_sum_squares = 0.0
  local total_count = 0
  local channel_sum_squares = {}
  local channel_count = {}

  for channel = 1, num_channels do
    channel_sum_squares[channel] = 0.0
    channel_count[channel] = 0
  end

  local frame_cursor = start_frame
  while frame_cursor < end_frame_exclusive do
    local frames_to_read = math.min(block_size, end_frame_exclusive - frame_cursor)
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
      error("Audio accessor read failed during level scan.")
    end

    if retval ~= 0 then
      for frame_index = 0, frames_to_read - 1 do
        local base_index = frame_index * num_channels
        for channel = 1, num_channels do
          local sample = buffer[base_index + channel]
          local abs_sample = math.abs(sample)
          local squared = sample * sample

          if abs_sample > peak_linear then
            peak_linear = abs_sample
          end

          total_sum_squares = total_sum_squares + squared
          total_count = total_count + 1
          channel_sum_squares[channel] = channel_sum_squares[channel] + squared
          channel_count[channel] = channel_count[channel] + 1
        end
      end
    end

    frame_cursor = frame_cursor + frames_to_read
  end

  local peak_db = peak_linear > 0.0 and linear_to_db(peak_linear) or NEG_INF_DB
  local rms_linear = 0.0

  if settings.channel_mode == "average" then
    rms_linear = total_count > 0 and math.sqrt(total_sum_squares / total_count) or 0.0
  else
    for channel = 1, num_channels do
      if channel_count[channel] > 0 then
        local channel_rms = math.sqrt(channel_sum_squares[channel] / channel_count[channel])
        if channel_rms > rms_linear then
          rms_linear = channel_rms
        end
      end
    end
  end

  local rms_db = rms_linear > 0.0 and linear_to_db(rms_linear) or NEG_INF_DB
  return peak_db, rms_db
end

local function estimate_lufs(accessor, sample_rate, num_channels, item_pos, start_frame, end_frame_exclusive, settings)
  if end_frame_exclusive <= start_frame then
    return NEG_INF_DB
  end

  local total_frames = end_frame_exclusive - start_frame
  local window_frames = math.max(1, math.floor(settings.lufs_window_sec * sample_rate + 0.5))
  local hop_frames = math.max(1, math.floor(settings.lufs_hop_sec * sample_rate + 0.5))
  local loudness_values = {}

  local function read_window(window_start_frame, frames_to_read)
    local buffer = reaper.new_array(frames_to_read * num_channels)
    buffer.clear()
    local retval = reaper.GetAudioAccessorSamples(
      accessor,
      sample_rate,
      num_channels,
      item_pos + (window_start_frame / sample_rate),
      frames_to_read,
      buffer
    )

    if retval < 0 then
      error("Audio accessor read failed during LUFS scan.")
    end

    if retval ~= 0 then
      local window_rms = compute_window_rms_linear(buffer, frames_to_read, num_channels, settings.channel_mode)
      if window_rms > 1e-10 then
        loudness_values[#loudness_values + 1] = window_rms
      end
    end
  end

  if total_frames <= window_frames then
    read_window(start_frame, total_frames)
  else
    local position = start_frame
    while position + window_frames <= end_frame_exclusive do
      read_window(position, window_frames)
      position = position + hop_frames
    end
  end

  if #loudness_values == 0 then
    return NEG_INF_DB
  end

  table.sort(loudness_values)
  local gate_index = math.floor(#loudness_values * 0.3) + 1
  local gated_sum = 0.0
  local gated_count = 0

  for index = gate_index, #loudness_values do
    gated_sum = gated_sum + (loudness_values[index] * loudness_values[index])
    gated_count = gated_count + 1
  end

  if gated_count <= 0 then
    return NEG_INF_DB
  end

  local gated_rms = math.sqrt(gated_sum / gated_count)
  return gated_rms > 0.0 and linear_to_db(gated_rms) or NEG_INF_DB
end

local function analyze_item_full(item, index, settings)
  local take = reaper.GetActiveTake(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local take_name = get_take_name_or_fallback(take, index)
  local category, category_source = detect_category(item, take_name, settings.preset_lookup)
  local take_volume = take and reaper.GetMediaItemTakeInfo_Value(take, "D_VOL") or 1.0
  local item_volume = reaper.GetMediaItemInfo_Value(item, "D_VOL")

  local result = {
    item = item,
    take = take,
    item_index = index,
    item_position = item_pos,
    total_length = item_length,
    take_name = take_name,
    category = category,
    category_source = category_source,
    valid = false,
    is_silent = false,
    content_start = 0.0,
    content_end = item_length,
    true_peak_dbfs = NEG_INF_DB,
    rms_dbfs = NEG_INF_DB,
    estimated_lufs = NEG_INF_DB,
    crest_factor_db = 0.0,
    current_item_vol_db = linear_to_db(math.abs((take_volume or 1.0) * (item_volume or 1.0))),
    take_volume = take_volume,
    item_volume = item_volume,
    warnings = {},
    target_metric = nil,
    target_db = nil,
    target_gain_db = nil,
    requested_gain_db = nil,
    predicted_peak_after = nil,
    predicted_metric_after = nil,
    status = "UNANALYZED",
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

  if math.abs(take_volume or 1.0) <= 1e-12 then
    result.warnings[#result.warnings + 1] = "Current take volume is -inf; gain changes will remain inaudible until volume is restored."
  end

  if item_length <= 0 then
    result.error = "Item length is zero."
    return result
  end

  local total_frames = math.max(1, math.floor(item_length * sample_rate + 0.5))
  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    result.error = "Failed to create take audio accessor."
    return result
  end

  local ok, analysis_or_error = pcall(function()
    local bounds = find_content_bounds(accessor, sample_rate, num_channels, item_pos, total_frames, settings)
    if bounds.is_silent then
      return {
        is_silent = true,
        content_start = 0.0,
        content_end = 0.0,
        peak_db = NEG_INF_DB,
        rms_db = NEG_INF_DB,
        lufs_db = NEG_INF_DB,
      }
    end

    local peak_db, rms_db = measure_peak_and_rms(
      accessor,
      sample_rate,
      num_channels,
      item_pos,
      bounds.content_start_frame,
      bounds.content_end_frame_exclusive,
      settings
    )

    local lufs_db = estimate_lufs(
      accessor,
      sample_rate,
      num_channels,
      item_pos,
      bounds.content_start_frame,
      bounds.content_end_frame_exclusive,
      settings
    )

    return {
      is_silent = false,
      content_start = bounds.content_start_frame / sample_rate,
      content_end = bounds.content_end_frame_exclusive / sample_rate,
      peak_db = peak_db,
      rms_db = rms_db,
      lufs_db = lufs_db,
    }
  end)

  reaper.DestroyAudioAccessor(accessor)

  if not ok then
    result.error = tostring(analysis_or_error)
    return result
  end

  result.valid = true
  result.is_silent = analysis_or_error.is_silent
  result.content_start = analysis_or_error.content_start
  result.content_end = analysis_or_error.content_end
  result.true_peak_dbfs = analysis_or_error.peak_db
  result.rms_dbfs = analysis_or_error.rms_db
  result.estimated_lufs = analysis_or_error.lufs_db
  if result.true_peak_dbfs > NEG_INF_DB + 0.5 and result.rms_dbfs > NEG_INF_DB + 0.5 then
    result.crest_factor_db = result.true_peak_dbfs - result.rms_dbfs
  else
    result.crest_factor_db = 0.0
  end

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
  for _, item in ipairs(items or {}) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function get_metric_value(analysis, metric)
  if metric == "peak" then
    return analysis.true_peak_dbfs
  end
  if metric == "rms" then
    return analysis.rms_dbfs
  end
  if metric == "lufs" then
    return analysis.estimated_lufs
  end
  return nil
end

local function create_skip_plan(analysis, metric, target_db, reason, status)
  local current_db = metric and get_metric_value(analysis, metric) or NEG_INF_DB
  local plan = {
    analysis = analysis,
    item = analysis.item,
    take = analysis.take,
    metric = metric,
    target_db = target_db,
    current_db = current_db,
    requested_gain_db = 0.0,
    applied_gain_db = 0.0,
    predicted_peak_after = analysis.true_peak_dbfs,
    predicted_metric_after = current_db,
    within_deadzone = false,
    will_apply = false,
    status = status or "SKIP",
    notes = {},
    skip_reason = reason,
    clip_warning = false,
    clip_limited = false,
    max_gain_limited = false,
    max_cut_limited = false,
  }
  if reason and reason ~= "" then
    plan.notes[#plan.notes + 1] = reason
  end
  return plan
end

local function finalize_plan(plan, analysis, settings)
  plan.predicted_peak_after = analysis.true_peak_dbfs
  if plan.applied_gain_db then
    plan.predicted_peak_after = analysis.true_peak_dbfs + plan.applied_gain_db
  end

  if plan.current_db ~= nil and plan.applied_gain_db ~= nil then
    plan.predicted_metric_after = plan.current_db + plan.applied_gain_db
  end

  local residual_db = nil
  if plan.predicted_metric_after ~= nil and plan.target_db ~= nil then
    residual_db = plan.target_db - plan.predicted_metric_after
  end

  if not plan.status or plan.status == "PENDING" then
    if plan.within_deadzone then
      plan.status = "DEADZONE"
      plan.will_apply = false
    elseif plan.clip_warning then
      plan.status = "CLIP"
    elseif plan.max_gain_limited and residual_db and residual_db > settings.deadzone_db then
      plan.status = "QUIET"
    elseif plan.max_cut_limited and residual_db and residual_db < -settings.deadzone_db then
      plan.status = "LOUD"
    elseif plan.clip_limited then
      plan.status = "CLIP_LIMIT"
    else
      plan.status = "OK"
    end
  end

  analysis.target_metric = plan.metric
  analysis.target_db = plan.target_db
  analysis.requested_gain_db = plan.requested_gain_db
  analysis.target_gain_db = plan.applied_gain_db
  analysis.predicted_peak_after = plan.predicted_peak_after
  analysis.predicted_metric_after = plan.predicted_metric_after
  analysis.status = plan.status
  analysis.plan = plan
  return plan
end

local function get_target_for_category(category_name, settings)
  if settings.normalize_mode == "auto" then
    local preset = settings.presets[category_name] or settings.presets["Uncategorized"]
    return preset.metric, preset.target
  end
  return settings.normalize_mode, settings.manual_target_db
end

local function build_individual_plan(analysis, metric, target_db, settings)
  if not analysis.valid then
    return finalize_plan(create_skip_plan(analysis, metric, target_db, analysis.error or "Item analysis failed.", "INVALID"), analysis, settings)
  end

  if analysis.is_silent then
    return finalize_plan(create_skip_plan(analysis, metric, target_db, "Item appears to be silent.", "SILENT"), analysis, settings)
  end

  local current_db = get_metric_value(analysis, metric)
  if not current_db or current_db <= NEG_INF_DB + 0.5 then
    return finalize_plan(create_skip_plan(analysis, metric, target_db, "Selected metric could not be measured.", "SKIP"), analysis, settings)
  end

  local plan = {
    analysis = analysis,
    item = analysis.item,
    take = analysis.take,
    metric = metric,
    target_db = target_db,
    current_db = current_db,
    requested_gain_db = target_db - current_db,
    applied_gain_db = target_db - current_db,
    predicted_peak_after = analysis.true_peak_dbfs,
    predicted_metric_after = current_db,
    within_deadzone = false,
    will_apply = true,
    status = "PENDING",
    notes = {},
    skip_reason = nil,
    clip_warning = false,
    clip_limited = false,
    max_gain_limited = false,
    max_cut_limited = false,
  }

  if plan.applied_gain_db > settings.max_gain_db then
    plan.applied_gain_db = settings.max_gain_db
    plan.max_gain_limited = true
    plan.notes[#plan.notes + 1] = string.format("Gain capped at +%.1f dB.", settings.max_gain_db)
  end

  if plan.applied_gain_db < settings.max_cut_db then
    plan.applied_gain_db = settings.max_cut_db
    plan.max_cut_limited = true
    plan.notes[#plan.notes + 1] = string.format("Cut capped at %.1f dB.", settings.max_cut_db)
  end

  local predicted_peak = analysis.true_peak_dbfs + plan.applied_gain_db
  if predicted_peak > settings.ceiling_dbfs then
    if settings.clip_prevention == "limit" then
      plan.applied_gain_db = settings.ceiling_dbfs - analysis.true_peak_dbfs
      plan.clip_limited = true
      predicted_peak = settings.ceiling_dbfs
      plan.notes[#plan.notes + 1] = string.format("Gain reduced to honor %.1f dBFS ceiling.", settings.ceiling_dbfs)
    elseif settings.clip_prevention == "warn" then
      plan.clip_warning = true
      plan.notes[#plan.notes + 1] = string.format("Predicted peak %.1f dBFS exceeds ceiling.", predicted_peak)
    else
      return finalize_plan(create_skip_plan(
        analysis,
        metric,
        target_db,
        string.format("Skipped: predicted peak %.1f dBFS exceeds ceiling %.1f dBFS.", predicted_peak, settings.ceiling_dbfs),
        "SKIP"
      ), analysis, settings)
    end
  end

  if math.abs(plan.applied_gain_db) < settings.deadzone_db then
    plan.applied_gain_db = 0.0
    plan.within_deadzone = true
    plan.will_apply = false
    plan.notes[#plan.notes + 1] = string.format("Already within %.1f dB deadzone.", settings.deadzone_db)
  end

  return finalize_plan(plan, analysis, settings)
end

local function build_relative_plans(category_name, analyses, metric, target_db, settings)
  local measurable_values = {}
  local measured_analyses = {}

  for _, analysis in ipairs(analyses) do
    if analysis.valid and not analysis.is_silent then
      local value = get_metric_value(analysis, metric)
      if value and value > NEG_INF_DB + 0.5 then
        measurable_values[#measurable_values + 1] = value
        measured_analyses[#measured_analyses + 1] = analysis
      end
    end
  end

  if #measurable_values == 0 then
    local plans = {}
    for _, analysis in ipairs(analyses) do
      plans[#plans + 1] = finalize_plan(create_skip_plan(
        analysis,
        metric,
        target_db,
        "No measurable audio available for category average.",
        analysis.valid and "SKIP" or "INVALID"
      ), analysis, settings)
    end
    return plans
  end

  local sum = 0.0
  for _, value in ipairs(measurable_values) do
    sum = sum + value
  end
  local average_db = sum / #measurable_values
  local requested_gain_db = target_db - average_db
  local applied_gain_db = requested_gain_db
  local category_notes = {}
  local category_skip_reason = nil
  local category_clip_limited = false
  local category_clip_warning = false
  local category_max_gain_limited = false
  local category_max_cut_limited = false

  if applied_gain_db > settings.max_gain_db then
    applied_gain_db = settings.max_gain_db
    category_max_gain_limited = true
    category_notes[#category_notes + 1] = string.format("Category gain capped at +%.1f dB.", settings.max_gain_db)
  end

  if applied_gain_db < settings.max_cut_db then
    applied_gain_db = settings.max_cut_db
    category_max_cut_limited = true
    category_notes[#category_notes + 1] = string.format("Category cut capped at %.1f dB.", settings.max_cut_db)
  end

  local max_allowed_gain = math.huge
  local worst_predicted_peak = NEG_INF_DB
  local any_clip = false
  for _, analysis in ipairs(measured_analyses) do
    local allowed = settings.ceiling_dbfs - analysis.true_peak_dbfs
    if allowed < max_allowed_gain then
      max_allowed_gain = allowed
    end
    local predicted_peak = analysis.true_peak_dbfs + applied_gain_db
    if predicted_peak > worst_predicted_peak then
      worst_predicted_peak = predicted_peak
    end
    if predicted_peak > settings.ceiling_dbfs then
      any_clip = true
    end
  end

  if any_clip then
    if settings.clip_prevention == "limit" then
      applied_gain_db = max_allowed_gain
      category_clip_limited = true
      category_notes[#category_notes + 1] = string.format("Common gain limited to preserve %.1f dBFS ceiling.", settings.ceiling_dbfs)
    elseif settings.clip_prevention == "warn" then
      category_clip_warning = true
      category_notes[#category_notes + 1] = string.format("Some items would exceed %.1f dBFS.", settings.ceiling_dbfs)
    else
      category_skip_reason = string.format(
        "Relative mode skipped: category %s would clip at %.1f dBFS.",
        category_name,
        worst_predicted_peak
      )
    end
  end

  local deadzone_skip = math.abs(applied_gain_db) < settings.deadzone_db
  if deadzone_skip then
    category_notes[#category_notes + 1] = string.format("Category already within %.1f dB deadzone.", settings.deadzone_db)
  end

  local plans = {}
  for _, analysis in ipairs(analyses) do
    if not analysis.valid then
      plans[#plans + 1] = finalize_plan(create_skip_plan(analysis, metric, target_db, analysis.error or "Item analysis failed.", "INVALID"), analysis, settings)
    elseif analysis.is_silent then
      plans[#plans + 1] = finalize_plan(create_skip_plan(analysis, metric, target_db, "Item appears to be silent.", "SILENT"), analysis, settings)
    else
      local current_db = get_metric_value(analysis, metric)
      if not current_db or current_db <= NEG_INF_DB + 0.5 then
        plans[#plans + 1] = finalize_plan(create_skip_plan(analysis, metric, target_db, "Selected metric could not be measured.", "SKIP"), analysis, settings)
      elseif category_skip_reason then
        plans[#plans + 1] = finalize_plan(create_skip_plan(analysis, metric, target_db, category_skip_reason, "SKIP"), analysis, settings)
      else
        local plan = {
          analysis = analysis,
          item = analysis.item,
          take = analysis.take,
          metric = metric,
          target_db = target_db,
          current_db = current_db,
          requested_gain_db = requested_gain_db,
          applied_gain_db = deadzone_skip and 0.0 or applied_gain_db,
          predicted_peak_after = analysis.true_peak_dbfs,
          predicted_metric_after = current_db,
          within_deadzone = deadzone_skip,
          will_apply = not deadzone_skip,
          status = "PENDING",
          notes = shallow_copy_list(category_notes),
          skip_reason = nil,
          clip_warning = false,
          clip_limited = category_clip_limited,
          max_gain_limited = category_max_gain_limited,
          max_cut_limited = category_max_cut_limited,
        }

        if category_clip_warning and (analysis.true_peak_dbfs + applied_gain_db) > settings.ceiling_dbfs then
          plan.clip_warning = true
        end

        plans[#plans + 1] = finalize_plan(plan, analysis, settings)
      end
    end
  end

  return plans
end

local function analyze_selected_items(selected_items, settings)
  local analyses = {}
  local item_count = #selected_items

  for index, item in ipairs(selected_items) do
    analyses[#analyses + 1] = analyze_item_full(item, index, settings)
    if index % 10 == 0 or index == item_count then
      log_line(string.format("[Normalizer] Analyzed %d / %d items...", index, item_count))
    end
  end

  return analyses
end

local function group_by_category(analyses)
  local groups = {}
  local category_names = {}

  for _, analysis in ipairs(analyses) do
    local category = analysis.category or "Uncategorized"
    if not groups[category] then
      groups[category] = {
        name = category,
        items = {},
      }
      category_names[#category_names + 1] = category
    end
    groups[category].items[#groups[category].items + 1] = analysis
  end

  sort_strings_case_insensitive(category_names)

  for _, category in ipairs(category_names) do
    table.sort(groups[category].items, function(left, right)
      local lhs = tostring(left.take_name or ""):lower()
      local rhs = tostring(right.take_name or ""):lower()
      if lhs == rhs then
        return (left.item_index or 0) < (right.item_index or 0)
      end
      return lhs < rhs
    end)
  end

  return groups, category_names
end

local function build_normalize_plans(analyses, settings)
  local groups, category_names = group_by_category(analyses)
  local plans = {}

  for _, category_name in ipairs(category_names) do
    local group = groups[category_name]
    local metric, target_db = get_target_for_category(category_name, settings)
    if settings.balance_mode == "relative" then
      local category_plans = build_relative_plans(category_name, group.items, metric, target_db, settings)
      for _, plan in ipairs(category_plans) do
        plans[#plans + 1] = plan
      end
    else
      for _, analysis in ipairs(group.items) do
        plans[#plans + 1] = build_individual_plan(analysis, metric, target_db, settings)
      end
    end
  end

  return plans, groups, category_names
end

local function build_analysis_lookup(analyses)
  local lookup = {}
  for _, analysis in ipairs(analyses or {}) do
    if analysis.item then
      lookup[analysis.item] = analysis
    end
  end
  return lookup
end

local function join_messages(parts, separator)
  local items = {}
  for _, value in ipairs(parts or {}) do
    local text = trim_string(value)
    if text ~= "" then
      items[#items + 1] = text
    end
  end
  return table.concat(items, separator or " | ")
end

local function determine_verification_flag(before_analysis, after_analysis, settings)
  local plan = before_analysis.plan or {}
  if not before_analysis.valid then
    return "INVALID", before_analysis.error or "Pre-analysis failed.", nil
  end
  if not plan.will_apply then
    return "SKIP", plan.skip_reason or "No gain change applied.", nil
  end
  if not after_analysis or not after_analysis.valid then
    return "INVALID", (after_analysis and after_analysis.error) or "Post-analysis failed.", nil
  end
  if after_analysis.is_silent then
    return "SILENT", "Item appears silent after normalize.", nil
  end

  local metric = plan.metric
  local after_metric = get_metric_value(after_analysis, metric)
  if not after_metric or after_metric <= NEG_INF_DB + 0.5 then
    return "INVALID", "Post-analysis metric could not be measured.", nil
  end

  local residual_db = (plan.target_db or 0.0) - after_metric

  if after_analysis.true_peak_dbfs > (settings.ceiling_dbfs + 0.05) then
    return "CLIP", string.format("After peak %.1f dBFS exceeds ceiling %.1f dBFS.", after_analysis.true_peak_dbfs, settings.ceiling_dbfs), residual_db
  end

  if (plan.clip_warning or plan.clip_limited) and after_analysis.true_peak_dbfs >= (settings.ceiling_dbfs - 0.05) then
    return "CLIP", string.format("After peak %.1f dBFS is at the ceiling.", after_analysis.true_peak_dbfs), residual_db
  end

  if plan.max_gain_limited and residual_db > settings.deadzone_db then
    return "QUIET", string.format("Still %.1f dB below target after max gain cap.", residual_db), residual_db
  end

  if plan.max_cut_limited and residual_db < -settings.deadzone_db then
    return "LOUD", string.format("Still %.1f dB above target after max cut cap.", -residual_db), residual_db
  end

  if math.abs(residual_db) <= settings.deadzone_db then
    return "OK", string.format("Within %.1f dB deadzone after processing.", settings.deadzone_db), residual_db
  end

  if residual_db > settings.deadzone_db then
    return "QUIET", string.format("Still %.1f dB below target after processing.", residual_db), residual_db
  end

  return "LOUD", string.format("Still %.1f dB above target after processing.", -residual_db), residual_db
end

local function attach_post_analysis(before_analyses, after_analyses, settings)
  local after_lookup = build_analysis_lookup(after_analyses)
  local counts = {}

  for _, before_analysis in ipairs(before_analyses or {}) do
    local after_analysis = before_analysis.item and after_lookup[before_analysis.item] or nil
    local flag, note, residual_db = determine_verification_flag(before_analysis, after_analysis, settings)
    before_analysis.after_analysis = after_analysis
    before_analysis.verification_flag = flag
    before_analysis.verification_note = note
    before_analysis.actual_metric_after = after_analysis and before_analysis.plan and get_metric_value(after_analysis, before_analysis.plan.metric) or nil
    before_analysis.actual_peak_after = after_analysis and after_analysis.true_peak_dbfs or nil
    before_analysis.actual_residual_db = residual_db
    before_analysis.status = flag or before_analysis.status
    counts[flag or "UNKNOWN"] = (counts[flag or "UNKNOWN"] or 0) + 1
  end

  return after_lookup, counts
end

local function count_verification_flags(analyses)
  local counts = {}
  for _, analysis in ipairs(analyses or {}) do
    local flag = analysis.verification_flag or analysis.status or "UNKNOWN"
    counts[flag] = (counts[flag] or 0) + 1
  end
  return counts
end

local function range_from_values(values)
  local minimum = nil
  local maximum = nil

  for _, value in ipairs(values) do
    if value and value > NEG_INF_DB + 0.5 then
      if minimum == nil or value < minimum then
        minimum = value
      end
      if maximum == nil or value > maximum then
        maximum = value
      end
    end
  end

  return minimum, maximum
end

local function format_range_line(label, minimum, maximum, suffix)
  suffix = suffix or ""
  if minimum == nil or maximum == nil then
    return string.format("    %-12s n/a", label .. ":")
  end

  local spread = maximum - minimum
  local min_text = format_db(minimum)
  local max_text = format_db(maximum)
  if suffix ~= "" then
    min_text = min_text .. " " .. suffix
    max_text = max_text .. " " .. suffix
  end

  return string.format("    %-12s %s to %s  (spread: %.1f dB)", label .. ":", min_text, max_text, spread)
end

local function count_plan_statuses(analyses)
  local summary = {
    boost = 0,
    cut = 0,
    skip = 0,
    clip = 0,
  }

  for _, analysis in ipairs(analyses) do
    local plan = analysis.plan
    if not plan or not plan.will_apply then
      summary.skip = summary.skip + 1
    elseif plan.applied_gain_db > 0 then
      summary.boost = summary.boost + 1
    elseif plan.applied_gain_db < 0 then
      summary.cut = summary.cut + 1
    else
      summary.skip = summary.skip + 1
    end

    if plan and (plan.clip_warning or plan.clip_limited) then
      summary.clip = summary.clip + 1
    end
  end

  return summary
end

local function print_settings_summary(settings, analyses, category_names)
  log_line("===========================================================================")
  log_line("  Game Sound Loudness Analysis Dashboard")
  log_line("===========================================================================")
  log_line(string.format(
    "  Total Items: %d | Categories: %d | Mode: %s | Balance: %s | Dry Run: %s",
    #analyses,
    #category_names,
    settings.normalize_mode,
    HUMAN_BALANCE_MODE[settings.balance_mode] or settings.balance_mode,
    settings.dry_run and "Yes" or "No"
  ))
  log_line(string.format(
    "  Silence Threshold: %.1f dB | Ceiling: %.1f dBFS | Deadzone: %.1f dB | Clip: %s",
    settings.silence_threshold_db,
    settings.ceiling_dbfs,
    settings.deadzone_db,
    HUMAN_CLIP_MODE[settings.clip_prevention] or settings.clip_prevention
  ))
  if settings.normalize_mode ~= "auto" then
    log_line(string.format("  Manual Target: %s", format_target(settings.normalize_mode, settings.manual_target_db)))
  else
    log_line(string.format("  Preset Set: %s", settings.preset_name))
  end
  log_line("===========================================================================")
end

local function print_category_dashboard(groups, category_names, settings)
  for _, category_name in ipairs(category_names) do
    local group = groups[category_name]
    local metric, target_db = get_target_for_category(category_name, settings)
    local peak_values = {}
    local rms_values = {}
    local lufs_values = {}
    local crest_values = {}
    local gain_values = {}
    local deadzone_count = 0
    local clip_count = 0
    local valid_measured = 0

    for _, analysis in ipairs(group.items) do
      if analysis.valid and not analysis.is_silent then
        peak_values[#peak_values + 1] = analysis.true_peak_dbfs
        rms_values[#rms_values + 1] = analysis.rms_dbfs
        lufs_values[#lufs_values + 1] = analysis.estimated_lufs
        crest_values[#crest_values + 1] = analysis.crest_factor_db
        valid_measured = valid_measured + 1
      end

      local plan = analysis.plan
      if plan then
        gain_values[#gain_values + 1] = plan.applied_gain_db
        if plan.within_deadzone then
          deadzone_count = deadzone_count + 1
        end
        if plan.clip_warning or plan.clip_limited then
          clip_count = clip_count + 1
        end
      end
    end

    local peak_min, peak_max = range_from_values(peak_values)
    local rms_min, rms_max = range_from_values(rms_values)
    local lufs_min, lufs_max = range_from_values(lufs_values)
    local crest_min, crest_max = range_from_values(crest_values)
    local gain_min, gain_max = range_from_values(gain_values)

    log_line(string.format("  > %s (%d items) - Target: %s", category_name, #group.items, format_target(metric, target_db)))
    log_line("  -------------------------------------------------------------------------")
    log_line(format_range_line("Peak Range", peak_min, peak_max, "dB"))
    log_line(format_range_line("RMS Range", rms_min, rms_max, "dB"))
    log_line(format_range_line("LUFS Range", lufs_min, lufs_max, "LUFS"))
    log_line(format_range_line("Crest Range", crest_min, crest_max, "dB"))
    log_line(format_range_line("Gain Needed", gain_min, gain_max, "dB"))

    if deadzone_count > 0 then
      log_line(string.format("    Near Target: %d item(s) already inside deadzone", deadzone_count))
    end
    if clip_count > 0 then
      log_line(string.format("    Clip Flags:  %d item(s) limited or warned by ceiling", clip_count))
    end
    if valid_measured == 0 then
      log_line("    Warning:    No valid measurable audio in this category.")
    end
    if category_name == "Uncategorized" then
      log_line("    Warning:    Consider renaming assets/tracks/regions for a better category match.")
    end

    log_line("")
  end
end

local function print_detailed_item_list(analyses)
  local sorted = shallow_copy_list(analyses)
  table.sort(sorted, function(left, right)
    local left_category = tostring(left.category or ""):lower()
    local right_category = tostring(right.category or ""):lower()
    if left_category ~= right_category then
      return left_category < right_category
    end
    local left_name = tostring(left.take_name or ""):lower()
    local right_name = tostring(right.take_name or ""):lower()
    if left_name ~= right_name then
      return left_name < right_name
    end
    return (left.item_index or 0) < (right.item_index or 0)
  end)

  log_line("  Detailed Item List")
  log_line("  -------------------------------------------------------------------------")
  log_line(string.format("  %-3s %-16s %-22s %-7s %-7s %-7s %-7s %-7s %-10s", "#", "Category", "Name", "Peak", "RMS", "LUFS", "Crest", "Gain", "Status"))
  log_line("  -------------------------------------------------------------------------")

  for _, analysis in ipairs(sorted) do
    local plan = analysis.plan or {}
    local gain_text = plan.applied_gain_db and string.format("%+.1f", plan.applied_gain_db) or "-"
    log_line(string.format(
      "  %-3d %-16s %-22s %-7s %-7s %-7s %-7s %-7s %-10s",
      analysis.item_index or 0,
      truncate_text(analysis.category or "Uncategorized", 16),
      truncate_text(analysis.take_name or "Item", 22),
      format_db(analysis.true_peak_dbfs),
      format_db(analysis.rms_dbfs),
      format_db(analysis.estimated_lufs),
      format_db(analysis.crest_factor_db),
      gain_text,
      tostring(analysis.verification_flag or analysis.status or "n/a")
    ))
    if analysis.error then
      log_line("      Reason: " .. tostring(analysis.error))
    elseif analysis.verification_note then
      log_line("      Verify: " .. tostring(analysis.verification_note))
    elseif plan.skip_reason then
      log_line("      Reason: " .. tostring(plan.skip_reason))
    elseif plan.notes and #plan.notes > 0 then
      log_line("      Note:   " .. tostring(plan.notes[1]))
    end
  end

  log_line("  -------------------------------------------------------------------------")
end

local function print_before_after_preview(groups, category_names, settings, after_lookup, title_override)
  log_line("")
  log_line("===========================================================================")
  log_line(title_override or (settings.dry_run and "  Predicted Normalization Preview" or "  Predicted Before / After"))
  log_line("===========================================================================")

  for _, category_name in ipairs(category_names) do
    local metric, target_db = get_target_for_category(category_name, settings)
    local group = groups[category_name]
    local before_values = {}
    local after_values = {}

    log_line(string.format("  Category: %s (Target: %s)", category_name, format_target(metric, target_db)))
    log_line("  -------------------------------------------------------------------------")
    log_line(string.format("  %-24s %-13s %-13s %-12s %-10s", "Name", "Before", "After", "Gain", "Status"))

    for _, analysis in ipairs(group.items) do
      local plan = analysis.plan or {}
      local before_db = get_metric_value(analysis, metric)
      local post_analysis = after_lookup and after_lookup[analysis.item] or nil
      local after_db = post_analysis and get_metric_value(post_analysis, metric) or plan.predicted_metric_after or before_db
      local status = analysis.verification_flag or plan.status or analysis.status or "n/a"
      local gain_label = string.format("%+.1f dB", plan.applied_gain_db or 0.0)
      if before_db and before_db > NEG_INF_DB + 0.5 then
        before_values[#before_values + 1] = before_db
      end
      if after_db and after_db > NEG_INF_DB + 0.5 then
        after_values[#after_values + 1] = after_db
      end
      log_line(string.format(
        "  %-24s %-13s %-13s %-12s %-10s",
        truncate_text(analysis.take_name or "Item", 24),
        format_db(before_db),
        format_db(after_db),
        gain_label,
        tostring(status)
      ))
    end

    local before_min, before_max = range_from_values(before_values)
    local after_min, after_max = range_from_values(after_values)
    local before_spread = (before_min and before_max) and (before_max - before_min) or nil
    local after_spread = (after_min and after_max) and (after_max - after_min) or nil

    if before_spread and after_spread then
      log_line(string.format("  Category spread: %.1f dB -> %.1f dB", before_spread, after_spread))
    else
      log_line("  Category spread: n/a")
    end

    log_line("  -------------------------------------------------------------------------")
    log_line("")
  end
end

local function apply_plan(plan)
  if not plan or not plan.will_apply then
    return true
  end

  local take = plan.take
  if not take then
    return false, "Take became invalid before processing."
  end

  local current_take_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
  local gain_linear = db_to_linear(plan.applied_gain_db or 0.0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", current_take_volume * gain_linear)
  return true
end

local function process_plans(plans, selected_items, settings)
  local summary = {
    processed_count = 0,
    skipped_count = 0,
    clip_count = 0,
  }

  for _, plan in ipairs(plans) do
    if plan.clip_warning or plan.clip_limited then
      summary.clip_count = summary.clip_count + 1
    end
    if not plan.will_apply then
      summary.skipped_count = summary.skipped_count + 1
    end
  end

  if settings.dry_run then
    select_only_items(selected_items)
    return true, summary
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, result_or_error = pcall(function()
    for index, plan in ipairs(plans) do
      if plan.will_apply then
        local applied, err = apply_plan(plan)
        if not applied then
          error(err or "Failed to apply gain.")
        end
        summary.processed_count = summary.processed_count + 1
      end

      if index % 10 == 0 or index == #plans then
        log_line(string.format("[Normalizer] Applied %d / %d plans...", index, #plans))
      end
    end
  end)

  select_only_items(selected_items)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock("Batch Loudness Normalize", -1)
    return true, summary
  end

  reaper.Undo_EndBlock("Batch Loudness Normalize (failed)", -1)
  return false, tostring(result_or_error)
end

local function print_action_summary(analyses, runtime_summary, settings)
  local plan_summary = count_plan_statuses(analyses)
  local verification_counts = runtime_summary and runtime_summary.verification_counts or count_verification_flags(analyses)

  log_line("===========================================================================")
  log_line(settings.dry_run and "  Dry Run Complete" or "  Normalization Complete")
  log_line("===========================================================================")
  log_line(string.format("  Items to boost:          %d", plan_summary.boost))
  log_line(string.format("  Items to cut:            %d", plan_summary.cut))
  log_line(string.format("  Items to skip:           %d", plan_summary.skip))
  log_line(string.format("  Items with clip flag:    %d", plan_summary.clip))
  if verification_counts and next(verification_counts) ~= nil then
    log_line(string.format("  Verify OK:               %d", verification_counts.OK or 0))
    log_line(string.format("  Verify SKIP:             %d", verification_counts.SKIP or 0))
    log_line(string.format("  Verify QUIET:            %d", verification_counts.QUIET or 0))
    log_line(string.format("  Verify LOUD:             %d", verification_counts.LOUD or 0))
    log_line(string.format("  Verify CLIP:             %d", verification_counts.CLIP or 0))
  end
  if not settings.dry_run then
    log_line(string.format("  Plans applied:           %d", runtime_summary.processed_count or 0))
    log_line(string.format("  Plans skipped:           %d", runtime_summary.skipped_count or 0))
  end
  log_line("===========================================================================")
end

local function print_full_report(analyses, groups, category_names, settings, runtime_summary, after_lookup, title_override)
  reaper.ClearConsole()
  print_settings_summary(settings, analyses, category_names)
  print_category_dashboard(groups, category_names, settings)
  print_detailed_item_list(analyses)
  print_before_after_preview(groups, category_names, settings, after_lookup, title_override)
  if runtime_summary then
    print_action_summary(analyses, runtime_summary, settings)
  end
end

local function csv_escape(value)
  local text = tostring(value == nil and "" or value)
  if text:find('[,"\r\n]') then
    text = '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function get_project_directory()
  local _, project_path = reaper.EnumProjects(-1, "")
  project_path = trim_string(project_path)
  if project_path ~= "" then
    return project_path:match("^(.*)[/\\][^/\\]+$") or project_path
  end

  if reaper.GetProjectPathEx then
    local project_dir = trim_string(reaper.GetProjectPathEx(0))
    if project_dir ~= "" then
      return project_dir
    end
  end

  return trim_string(reaper.GetResourcePath and reaper.GetResourcePath() or "")
end

local function join_path(left, right)
  local lhs = trim_string(left):gsub("/", "\\")
  local rhs = trim_string(right):gsub("/", "\\")
  if lhs == "" then
    return rhs
  end
  if rhs == "" then
    return lhs
  end
  return lhs:gsub("\\+$", "") .. "\\" .. rhs:gsub("^\\+", "")
end

local function prompt_export_path(default_path)
  local ok, value = reaper.GetUserInputs(SCRIPT_TITLE, 1, "CSV Export Path", default_path)
  if not ok then
    return nil, "User cancelled."
  end

  local path = trim_string(value)
  if path == "" then
    return nil, "Export path cannot be empty."
  end
  return path
end

local function build_report_rows(analyses, after_lookup)
  local sorted = shallow_copy_list(analyses or {})
  table.sort(sorted, function(left, right)
    local left_category = tostring(left.category or ""):lower()
    local right_category = tostring(right.category or ""):lower()
    if left_category ~= right_category then
      return left_category < right_category
    end
    local left_name = tostring(left.take_name or ""):lower()
    local right_name = tostring(right.take_name or ""):lower()
    if left_name ~= right_name then
      return left_name < right_name
    end
    return (left.item_index or 0) < (right.item_index or 0)
  end)

  local rows = {}
  for _, analysis in ipairs(sorted) do
    local plan = analysis.plan or {}
    local after_analysis = after_lookup and after_lookup[analysis.item] or analysis.after_analysis
    local target_metric = plan.metric or analysis.target_metric or ""
    local actual_after_metric = after_analysis and target_metric ~= "" and get_metric_value(after_analysis, target_metric) or nil
    local residual_db = analysis.actual_residual_db
    if residual_db == nil and actual_after_metric and plan.target_db ~= nil then
      residual_db = plan.target_db - actual_after_metric
    end

    rows[#rows + 1] = {
      analysis.item_index or "",
      analysis.category or "",
      analysis.take_name or "",
      analysis.category_source or "",
      target_metric,
      plan.target_db or analysis.target_db or "",
      analysis.true_peak_dbfs,
      analysis.rms_dbfs,
      analysis.estimated_lufs,
      analysis.crest_factor_db,
      plan.requested_gain_db or analysis.requested_gain_db or "",
      plan.applied_gain_db or analysis.target_gain_db or "",
      plan.predicted_peak_after or analysis.predicted_peak_after or "",
      plan.predicted_metric_after or analysis.predicted_metric_after or "",
      after_analysis and after_analysis.true_peak_dbfs or "",
      after_analysis and after_analysis.rms_dbfs or "",
      after_analysis and after_analysis.estimated_lufs or "",
      after_analysis and after_analysis.crest_factor_db or "",
      residual_db or "",
      analysis.verification_flag or analysis.status or "",
      analysis.verification_note or plan.skip_reason or join_messages(plan.notes, " / "),
    }
  end

  return rows
end

local function export_report_to_csv(report_context)
  local project_dir = get_project_directory()
  local suggested_name = string.format(
    "GameSoundLoudnessReport_%s_%s.csv",
    sanitize_preset_name(report_context.settings.preset_name or "Default"):gsub("%s+", "_"),
    os.date("%Y%m%d_%H%M%S")
  )
  local default_path = join_path(project_dir, suggested_name)
  local export_path, err = prompt_export_path(default_path)
  if not export_path then
    return false, err
  end

  local export_dir = export_path:match("^(.*)[/\\][^/\\]+$")
  if export_dir and export_dir ~= "" then
    reaper.RecursiveCreateDirectory(export_dir, 0)
  end

  local file, open_err = io.open(export_path, "w")
  if not file then
    return false, open_err or "Failed to open CSV for writing."
  end

  local headers = {
    "Index",
    "Category",
    "Name",
    "CategorySource",
    "Metric",
    "TargetDb",
    "BeforePeakDb",
    "BeforeRmsDb",
    "BeforeLufs",
    "BeforeCrestDb",
    "RequestedGainDb",
    "AppliedGainDb",
    "PredictedPeakAfterDb",
    "PredictedMetricAfterDb",
    "AfterPeakDb",
    "AfterRmsDb",
    "AfterLufs",
    "AfterCrestDb",
    "ResidualDb",
    "Status",
    "Notes",
  }

  file:write(table.concat(headers, ",") .. "\n")
  for _, row in ipairs(build_report_rows(report_context.analyses, report_context.after_lookup)) do
    local escaped = {}
    for index = 1, #row do
      escaped[index] = csv_escape(row[index])
    end
    file:write(table.concat(escaped, ",") .. "\n")
  end
  file:close()

  return true, export_path
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

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function calculate_average_metric(analyses, metric)
  local sum = 0.0
  local count = 0
  for _, analysis in ipairs(analyses or {}) do
    if analysis.valid and not analysis.is_silent then
      local value = get_metric_value(analysis, metric)
      if value and value > NEG_INF_DB + 0.5 then
        sum = sum + value
        count = count + 1
      end
    end
  end

  if count <= 0 then
    return nil
  end
  return sum / count
end

local function get_category_statistics(group, settings)
  local metric, target_db = get_target_for_category(group.name, settings)
  local average_db = calculate_average_metric(group.items, metric)
  local peak_average = calculate_average_metric(group.items, "peak")
  local rms_average = calculate_average_metric(group.items, "rms")
  local lufs_average = calculate_average_metric(group.items, "lufs")

  return {
    metric = metric,
    target_db = target_db,
    average_db = average_db,
    peak_average = peak_average,
    rms_average = rms_average,
    lufs_average = lufs_average,
    item_count = #group.items,
    delta_db = average_db and (target_db - average_db) or nil,
  }
end

local function refresh_analysis_state(ui, settings)
  local selected_items = collect_selected_items()
  if #selected_items == 0 then
    ui.selected_items = {}
    ui.analyses = {}
    ui.groups = {}
    ui.category_names = {}
    ui.plans = {}
    return false, "Select one or more audio items."
  end

  local analyses = analyze_selected_items(selected_items, settings)
  local plans, groups, category_names = build_normalize_plans(analyses, settings)

  ui.selected_items = selected_items
  ui.analyses = analyses
  ui.groups = groups
  ui.category_names = category_names
  ui.plans = plans
  if #category_names > 0 and (not ui.selected_category or not groups[ui.selected_category]) then
    ui.selected_category = category_names[1]
  end
  ui.table_scroll = clamp_number(ui.table_scroll or 0, 0, math.max(0, #category_names - 1))

  return true, string.format("Analyzed %d item(s) across %d categor%s.", #analyses, #category_names, #category_names == 1 and "y" or "ies")
end

local function save_current_preset_set(settings, preset_name)
  local normalized_name = sanitize_preset_name(preset_name)
  settings.preset_name = normalized_name
  settings.preset_sets = ensure_default_preset_sets(settings.preset_sets)
  settings.preset_sets[normalized_name] = copy_presets(settings.presets)
  save_settings(settings)
  return normalized_name
end

local function prompt_preset_name(default_name)
  local ok, value = reaper.GetUserInputs(SCRIPT_TITLE, 1, "Preset Set Name", sanitize_preset_name(default_name or "Custom"))
  if not ok then
    return nil, "User cancelled."
  end

  local preset_name = sanitize_preset_name(value)
  if preset_name == "" then
    return nil, "Preset name cannot be empty."
  end
  return preset_name
end

local function prompt_category_target(category_name, preset_data)
  local default_metric = preset_data and preset_data.metric or "peak"
  local default_target = preset_data and preset_data.target or get_default_manual_target(default_metric)
  local captions = table.concat({
    "separator=|",
    "Category Key",
    "Metric (peak/rms/lufs)",
    "Target dB",
  }, ",")
  local defaults = table.concat({
    sanitize_category_key(category_name or ""),
    tostring(default_metric),
    tostring(default_target),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 3, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 3)
  local edited_category = sanitize_category_key(parts[1])
  local metric = parse_normalize_mode(parts[2])
  local target_db = tonumber(parts[3])

  if edited_category == "" then
    return nil, "Category key cannot be empty."
  end
  if metric == "auto" or not metric then
    return nil, "Metric must be peak, rms, or lufs."
  end
  if not target_db or target_db > 6 or target_db < -150 then
    return nil, "Target must be between -150 and +6 dB."
  end

  return {
    category = edited_category,
    metric = metric,
    target = round_to(target_db, 3),
  }
end

local function delete_category_target(settings, category_name)
  if DEFAULT_CATEGORY_TARGETS[category_name] then
    settings.presets[category_name] = copy_presets(DEFAULT_CATEGORY_TARGETS)[category_name]
    return "Reset category to built-in default."
  end

  settings.presets[category_name] = nil
  rebuild_preset_lookup(settings)
  return "Deleted custom category target."
end

local function get_sorted_preset_names(settings)
  settings.preset_sets = ensure_default_preset_sets(settings.preset_sets)
  local names = {}
  for name in pairs(settings.preset_sets or {}) do
    names[#names + 1] = name
  end
  sort_strings_case_insensitive(names)
  return names
end

local function choose_preset_set_from_menu(settings)
  local names = get_sorted_preset_names(settings)
  if #names == 0 then
    return nil
  end

  local menu_items = {}
  for _, name in ipairs(names) do
    if name == settings.preset_name then
      menu_items[#menu_items + 1] = "!" .. name
    else
      menu_items[#menu_items + 1] = name
    end
  end

  gfx.x = gfx.mouse_x
  gfx.y = gfx.mouse_y
  local selection = gfx.showmenu(table.concat(menu_items, "|"))
  if selection and selection > 0 then
    return names[selection]
  end

  return nil
end

local function create_report_context(analyses, groups, category_names, settings, runtime_summary, after_analyses, after_lookup, title_override)
  return {
    analyses = analyses,
    groups = groups,
    category_names = category_names,
    settings = clone_settings(settings),
    runtime_summary = runtime_summary,
    after_analyses = after_analyses,
    after_lookup = after_lookup,
    title_override = title_override,
  }
end

local function run_preview(ui, settings)
  local ok, message = refresh_analysis_state(ui, settings)
  if not ok then
    return false, message
  end

  local preview_settings = clone_settings(settings)
  preview_settings.dry_run = true
  local runtime_summary = {
    processed_count = 0,
    skipped_count = 0,
    clip_count = 0,
    verification_counts = count_verification_flags(ui.analyses),
  }
  print_full_report(
    ui.analyses,
    ui.groups,
    ui.category_names,
    preview_settings,
    runtime_summary,
    nil,
    "  Predicted Normalization Preview"
  )
  ui.last_report_context = create_report_context(
    ui.analyses,
    ui.groups,
    ui.category_names,
    preview_settings,
    runtime_summary,
    nil,
    nil,
    "  Predicted Normalization Preview"
  )
  return true, "Dry run preview sent to the ReaScript console."
end

local function run_normalize(ui, settings)
  local ok, message = refresh_analysis_state(ui, settings)
  if not ok then
    return false, message
  end

  local run_settings = clone_settings(settings)
  run_settings.dry_run = false
  local before_analyses = ui.analyses
  local before_groups = ui.groups
  local before_category_names = ui.category_names

  local processed_ok, runtime_summary_or_error = process_plans(ui.plans, ui.selected_items, run_settings)
  if not processed_ok then
    return false, runtime_summary_or_error
  end

  local after_analyses = analyze_selected_items(ui.selected_items, run_settings)
  local after_lookup, verification_counts = attach_post_analysis(before_analyses, after_analyses, run_settings)
  runtime_summary_or_error.after_analyses = after_analyses
  runtime_summary_or_error.after_lookup = after_lookup
  runtime_summary_or_error.verification_counts = verification_counts

  print_full_report(
    before_analyses,
    before_groups,
    before_category_names,
    run_settings,
    runtime_summary_or_error,
    after_lookup,
    "  Normalization Results - Before / After"
  )

  ui.last_report_context = create_report_context(
    before_analyses,
    before_groups,
    before_category_names,
    run_settings,
    runtime_summary_or_error,
    after_analyses,
    after_lookup,
    "  Normalization Results - Before / After"
  )

  refresh_analysis_state(ui, settings)
  return true, string.format("Normalized %d item(s).", runtime_summary_or_error.processed_count or 0)
end

local UI_COLORS = {
  bg = { 0.08, 0.10, 0.12, 1.0 },
  panel = { 0.11, 0.13, 0.16, 1.0 },
  panel_alt = { 0.14, 0.17, 0.20, 1.0 },
  border = { 0.27, 0.34, 0.40, 1.0 },
  text = { 0.93, 0.95, 0.97, 1.0 },
  text_dim = { 0.63, 0.70, 0.76, 1.0 },
  accent = { 0.17, 0.57, 0.49, 1.0 },
  accent_hover = { 0.20, 0.66, 0.56, 1.0 },
  warning = { 0.82, 0.60, 0.20, 1.0 },
  danger = { 0.73, 0.29, 0.28, 1.0 },
  info = { 0.25, 0.48, 0.72, 1.0 },
  row = { 0.13, 0.15, 0.18, 1.0 },
  row_hover = { 0.17, 0.20, 0.24, 1.0 },
  row_selected = { 0.18, 0.29, 0.31, 1.0 },
}

local function ui_set_color(color)
  gfx.set(color[1], color[2], color[3], color[4] or 1.0)
end

local function ui_draw_rect(x, y, w, h, color, fill)
  ui_set_color(color)
  gfx.rect(x, y, w, h, fill and 1 or 0)
end

local function ui_draw_text(font_index, x, y, text, color)
  ui_set_color(color or UI_COLORS.text)
  gfx.setfont(font_index or 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function ui_draw_panel(x, y, w, h, title)
  ui_draw_rect(x, y, w, h, UI_COLORS.panel, true)
  ui_draw_rect(x, y, w, h, UI_COLORS.border, false)
  if title and title ~= "" then
    ui_draw_text(1, x + 14, y + 10, title, UI_COLORS.text)
  end
end

local function ui_draw_button(ui, x, y, w, h, label, fill_color)
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, x, y, w, h)
  local color = fill_color or UI_COLORS.panel_alt
  if hovered then
    color = {
      clamp_number(color[1] + 0.04, 0, 1),
      clamp_number(color[2] + 0.04, 0, 1),
      clamp_number(color[3] + 0.04, 0, 1),
      color[4],
    }
  end

  ui_draw_rect(x, y, w, h, color, true)
  ui_draw_rect(x, y, w, h, UI_COLORS.border, false)
  gfx.setfont(2)
  local text_w, text_h = gfx.measurestr(label or "")
  ui_draw_text(2, x + ((w - text_w) * 0.5), y + ((h - text_h) * 0.5), label, UI_COLORS.text)

  return hovered and ui.mouse_clicked
end

local function ui_draw_summary_card(x, y, w, h, title, value, accent_color)
  ui_draw_rect(x, y, w, h, UI_COLORS.panel_alt, true)
  ui_draw_rect(x, y, w, h, UI_COLORS.border, false)
  ui_draw_rect(x, y, w, 4, h, accent_color or UI_COLORS.accent, true)
  ui_draw_text(2, x + 16, y + 12, title, UI_COLORS.text_dim)
  ui_draw_text(3, x + 16, y + 34, value, UI_COLORS.text)
end

local function ui_draw_delta_bar(x, y, w, h, delta_db)
  ui_draw_rect(x, y, w, h, { 0.10, 0.12, 0.14, 1.0 }, true)
  local mid_x = x + (w * 0.5)
  ui_draw_rect(mid_x, y, 1, h, UI_COLORS.border, true)
  if not delta_db then
    return
  end

  local clamped = clamp_number(delta_db, -12.0, 12.0)
  local half_w = (w * 0.5) - 2
  local pixels = math.abs(clamped / 12.0) * half_w
  local color = clamped >= 0 and UI_COLORS.accent or UI_COLORS.danger

  if clamped >= 0 then
    ui_draw_rect(mid_x, y + 2, pixels, h - 4, color, true)
  else
    ui_draw_rect(mid_x - pixels, y + 2, pixels, h - 4, color, true)
  end
end

local function handle_settings_action(ui, settings)
  local updated, err = prompt_for_settings(settings)
  if not updated then
    return false, err
  end

  updated.presets = settings.presets
  updated.preset_sets = settings.preset_sets
  updated.preset_name = settings.preset_name
  rebuild_preset_lookup(updated)

  for key, value in pairs(updated) do
    settings[key] = value
  end

  save_settings(settings)
  return refresh_analysis_state(ui, settings)
end

local function handle_edit_target_action(ui, settings, default_category)
  local category_name = default_category or ui.selected_category or "Uncategorized"
  local preset_data = settings.presets[category_name] or DEFAULT_CATEGORY_TARGETS[category_name]
  local edited, err = prompt_category_target(category_name, preset_data)
  if not edited then
    return false, err
  end

  settings.presets[edited.category] = {
    metric = edited.metric,
    target = edited.target,
  }
  if default_category and default_category ~= edited.category and settings.presets[default_category]
    and not DEFAULT_CATEGORY_TARGETS[default_category] then
    settings.presets[default_category] = nil
  end
  rebuild_preset_lookup(settings)
  save_settings(settings)
  ui.selected_category = edited.category

  if #ui.analyses > 0 then
    local _, groups, category_names = build_normalize_plans(ui.analyses, settings)
    ui.groups = groups
    ui.category_names = category_names
  end

  return true, string.format("Updated target for %s.", edited.category)
end

local function handle_delete_target_action(ui, settings)
  local category_name = ui.selected_category
  if not category_name then
    return false, "Select a category first."
  end

  local response = reaper.ShowMessageBox("Reset/delete target for " .. category_name .. "?", SCRIPT_TITLE, 4)
  if response ~= 6 then
    return false, "User cancelled."
  end

  local message = delete_category_target(settings, category_name)
  save_settings(settings)
  if #ui.analyses > 0 then
    local _, groups, category_names = build_normalize_plans(ui.analyses, settings)
    ui.groups = groups
    ui.category_names = category_names
  end
  return true, message
end

local function handle_save_preset_action(settings)
  local preset_name, err = prompt_preset_name(settings.preset_name)
  if not preset_name then
    return false, err
  end

  local saved_name = save_current_preset_set(settings, preset_name)
  return true, string.format("Saved preset set '%s'.", saved_name)
end

local function handle_load_preset_action(ui, settings)
  local preset_name = choose_preset_set_from_menu(settings)
  if not preset_name then
    return false, "User cancelled."
  end

  if not load_preset_set_into_settings(settings, preset_name) then
    return false, "Could not load preset set."
  end

  save_settings(settings)
  return refresh_analysis_state(ui, settings)
end

local function handle_export_report_action(ui, settings)
  local report_context = ui.last_report_context
  if not report_context then
    local ok, message = refresh_analysis_state(ui, settings)
    if not ok then
      return false, message
    end

    local preview_settings = clone_settings(settings)
    preview_settings.dry_run = true
    report_context = create_report_context(
      ui.analyses,
      ui.groups,
      ui.category_names,
      preview_settings,
      {
        processed_count = 0,
        skipped_count = 0,
        clip_count = 0,
        verification_counts = count_verification_flags(ui.analyses),
      },
      nil,
      nil,
      "  Predicted Normalization Preview"
    )
    ui.last_report_context = report_context
  end

  local ok, path_or_error = export_report_to_csv(report_context)
  if not ok then
    return false, path_or_error
  end

  return true, "CSV report exported to " .. path_or_error
end

local function draw_category_table(ui, settings, x, y, w, h)
  ui_draw_panel(x, y, w, h, "Category Targets")

  local header_y = y + 42
  ui_draw_text(2, x + 14, header_y, "Category", UI_COLORS.text_dim)
  ui_draw_text(2, x + 210, header_y, "Metric", UI_COLORS.text_dim)
  ui_draw_text(2, x + 300, header_y, "Target", UI_COLORS.text_dim)
  ui_draw_text(2, x + 390, header_y, "Items", UI_COLORS.text_dim)
  ui_draw_text(2, x + 460, header_y, "Average", UI_COLORS.text_dim)
  ui_draw_text(2, x + 560, header_y, "Delta", UI_COLORS.text_dim)

  local table_y = header_y + 24
  local row_h = 28
  local visible_rows = math.max(1, math.floor((h - 84) / row_h))
  local max_scroll = math.max(0, #ui.category_names - visible_rows)

  if point_in_rect(ui.mouse_x, ui.mouse_y, x, y, w, h) and ui.wheel_steps ~= 0 then
    ui.table_scroll = clamp_number((ui.table_scroll or 0) - ui.wheel_steps, 0, max_scroll)
  end

  local start_index = (ui.table_scroll or 0) + 1
  local end_index = math.min(#ui.category_names, start_index + visible_rows - 1)

  for index = start_index, end_index do
    local category_name = ui.category_names[index]
    local row_y = table_y + ((index - start_index) * row_h)
    local group = ui.groups[category_name]
    local stats = get_category_statistics(group, settings)
    local selected = ui.selected_category == category_name
    local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, x + 8, row_y, w - 16, row_h - 2)

    if selected then
      ui_draw_rect(x + 8, row_y, w - 16, row_h - 2, UI_COLORS.row_selected, true)
    elseif hovered then
      ui_draw_rect(x + 8, row_y, w - 16, row_h - 2, UI_COLORS.row_hover, true)
    else
      ui_draw_rect(x + 8, row_y, w - 16, row_h - 2, UI_COLORS.row, true)
    end

    if hovered and ui.mouse_clicked then
      ui.selected_category = category_name
    end

    ui_draw_text(2, x + 14, row_y + 6, truncate_text(category_name, 24), UI_COLORS.text)
    ui_draw_text(2, x + 210, row_y + 6, HUMAN_METRIC[stats.metric] or stats.metric, UI_COLORS.text)
    ui_draw_text(2, x + 300, row_y + 6, string.format("%.1f", stats.target_db), UI_COLORS.text)
    ui_draw_text(2, x + 390, row_y + 6, tostring(stats.item_count), UI_COLORS.text)
    ui_draw_text(2, x + 460, row_y + 6, stats.average_db and format_db(stats.average_db) or "n/a", UI_COLORS.text)
    ui_draw_delta_bar(x + 560, row_y + 5, 180, 16, stats.delta_db)
  end

  if max_scroll > 0 then
    ui_draw_text(2, x + w - 180, y + h - 24, string.format("Scroll %d / %d", (ui.table_scroll or 0) + 1, max_scroll + 1), UI_COLORS.text_dim)
  end
end

local function draw_selected_category_panel(ui, settings, x, y, w, h)
  ui_draw_panel(x, y, w, h, "Selected Category")

  local category_name = ui.selected_category
  local group = category_name and ui.groups[category_name] or nil
  if not category_name or not group then
    ui_draw_text(2, x + 16, y + 48, "No category selected.", UI_COLORS.text_dim)
    return
  end

  local stats = get_category_statistics(group, settings)
  local preset = settings.presets[category_name] or DEFAULT_CATEGORY_TARGETS[category_name]
  local crest_average = (stats.peak_average and stats.rms_average) and ((stats.peak_average or 0.0) - (stats.rms_average or 0.0)) or nil

  ui_draw_text(3, x + 16, y + 42, truncate_text(category_name, 22), UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 84, "Metric", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 84, HUMAN_METRIC[preset.metric] or preset.metric, UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 112, "Target", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 112, string.format("%.1f", preset.target), UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 140, "Items", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 140, tostring(stats.item_count), UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 168, "Avg Peak", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 168, stats.peak_average and format_db(stats.peak_average) or "n/a", UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 196, "Avg RMS", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 196, stats.rms_average and format_db(stats.rms_average) or "n/a", UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 224, "Avg LUFS", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 224, stats.lufs_average and format_db(stats.lufs_average) or "n/a", UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 252, "Avg Crest", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 252, crest_average and format_db(crest_average) or "n/a", UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 280, "Category Avg", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 280, stats.average_db and format_db(stats.average_db) or "n/a", UI_COLORS.text)
  ui_draw_text(2, x + 16, y + 308, "Delta", UI_COLORS.text_dim)
  ui_draw_text(2, x + 120, y + 308, stats.delta_db and string.format("%+.1f dB", stats.delta_db) or "n/a", UI_COLORS.text)

  ui_draw_text(2, x + 16, y + 342, "Delta Preview", UI_COLORS.text_dim)
  ui_draw_delta_bar(x + 16, y + 366, w - 32, 22, stats.delta_db)

  if ui_draw_button(ui, x + 16, y + h - 142, w - 32, 30, "Edit Target", UI_COLORS.info) then
    local ok, message = handle_edit_target_action(ui, settings)
    ui.status_message = ok and message or (message ~= "User cancelled." and ("Error: " .. message) or ui.status_message)
  end

  if ui_draw_button(ui, x + 16, y + h - 102, w - 32, 30, "Add Target", UI_COLORS.accent) then
    local ok, message = handle_edit_target_action(ui, settings, "")
    ui.status_message = ok and message or (message ~= "User cancelled." and ("Error: " .. message) or ui.status_message)
  end

  if ui_draw_button(ui, x + 16, y + h - 62, w - 32, 30, "Reset / Delete Target", UI_COLORS.warning) then
    local ok, message = handle_delete_target_action(ui, settings)
    ui.status_message = ok and message or (message ~= "User cancelled." and ("Error: " .. message) or ui.status_message)
  end
end

local function draw_dashboard(ui, settings)
  ui_draw_rect(0, 0, gfx.w, gfx.h, UI_COLORS.bg, true)
  ui_draw_rect(0, 0, gfx.w, 58, UI_COLORS.panel_alt, true)
  ui_draw_text(3, 18, 14, SCRIPT_TITLE, UI_COLORS.text)
  ui_draw_text(2, gfx.w - 330, 20, "A Analyze | D Dry Run | N Normalize | E Export | Esc Close", UI_COLORS.text_dim)

  local settings_clicked = ui_draw_button(ui, 20, 72, 110, 32, "Settings", UI_COLORS.info)
  local analyze_clicked = ui_draw_button(ui, 140, 72, 140, 32, "Analyze Selected", UI_COLORS.accent)
  local load_clicked = ui_draw_button(ui, 290, 72, 120, 32, "Load Preset", UI_COLORS.panel_alt)
  local save_clicked = ui_draw_button(ui, 420, 72, 120, 32, "Save Preset", UI_COLORS.panel_alt)
  local export_clicked = ui_draw_button(ui, 550, 72, 130, 32, "Export Report", UI_COLORS.warning)

  local card_y = 118
  ui_draw_summary_card(20, card_y, 180, 76, "Selected Items", tostring(#ui.selected_items or 0), UI_COLORS.accent)
  ui_draw_summary_card(214, card_y, 180, 76, "Categories", tostring(#ui.category_names or 0), UI_COLORS.info)
  ui_draw_summary_card(408, card_y, 220, 76, "Normalize Mode", settings.normalize_mode, UI_COLORS.warning)
  ui_draw_summary_card(642, card_y, 220, 76, "Preset Set", settings.preset_name or "Default", UI_COLORS.accent)
  ui_draw_summary_card(876, card_y, 280, 76, "Balance / Ceiling", string.format("%s / %.1f dBFS", settings.balance_mode, settings.ceiling_dbfs), UI_COLORS.danger)

  draw_category_table(ui, settings, 20, 212, 800, 474)
  draw_selected_category_panel(ui, settings, 840, 212, 340, 474)

  local dry_run_clicked = ui_draw_button(ui, 20, 704, 160, 36, "Dry Run Preview", UI_COLORS.warning)
  local normalize_clicked = ui_draw_button(ui, 190, 704, 160, 36, "Normalize All", UI_COLORS.accent)
  local export_bottom_clicked = ui_draw_button(ui, 360, 704, 160, 36, "Export CSV", UI_COLORS.info)
  local close_clicked = ui_draw_button(ui, gfx.w - 140, 704, 120, 36, "Close", UI_COLORS.danger)

  ui_draw_rect(20, 748, gfx.w - 40, 22, UI_COLORS.panel_alt, true)
  ui_draw_rect(20, 748, gfx.w - 40, 22, UI_COLORS.border, false)
  ui_draw_text(2, 28, 752, ui.status_message or "Ready.", UI_COLORS.text_dim)

  if settings_clicked then
    local ok, message = handle_settings_action(ui, settings)
    if ok then
      ui.status_message = message
    elseif message and message ~= "User cancelled." then
      ui.status_message = "Error: " .. message
    end
  end

  if analyze_clicked then
    local ok, message = refresh_analysis_state(ui, settings)
    ui.status_message = ok and message or ("Error: " .. tostring(message))
  end

  if load_clicked then
    local ok, message = handle_load_preset_action(ui, settings)
    if ok then
      ui.status_message = message
    elseif message and message ~= "User cancelled." then
      ui.status_message = "Error: " .. message
    end
  end

  if save_clicked then
    local ok, message = handle_save_preset_action(settings)
    if ok then
      ui.status_message = message
    elseif message and message ~= "User cancelled." then
      ui.status_message = "Error: " .. message
    end
  end

  if export_clicked or export_bottom_clicked then
    local ok, message = handle_export_report_action(ui, settings)
    if ok then
      ui.status_message = message
    elseif message and message ~= "User cancelled." then
      ui.status_message = "Error: " .. message
    end
  end

  if dry_run_clicked then
    local ok, message = run_preview(ui, settings)
    ui.status_message = ok and message or ("Error: " .. tostring(message))
  end

  if normalize_clicked then
    local ok, message = run_normalize(ui, settings)
    ui.status_message = ok and message or ("Error: " .. tostring(message))
  end

  return close_clicked
end

local function run_gfx_dashboard(settings)
  if not gfx or not gfx.init then
    reaper.ShowMessageBox("gfx API is not available in this REAPER build.", SCRIPT_TITLE, 0)
    return
  end

  local ui = {
    width = 1200,
    height = 780,
    mouse_x = 0,
    mouse_y = 0,
    mouse_down = false,
    prev_mouse_down = false,
    mouse_clicked = false,
    wheel_steps = 0,
    last_wheel = 0,
    table_scroll = 0,
    status_message = "Opening dashboard...",
    selected_items = {},
    analyses = {},
    groups = {},
    category_names = {},
    plans = {},
    selected_category = nil,
    last_report_context = nil,
  }

  local ok, message = refresh_analysis_state(ui, settings)
  ui.status_message = ok and message or ("Error: " .. tostring(message))

  gfx.init(SCRIPT_TITLE, ui.width, ui.height, 0)
  if (gfx.w or 0) <= 0 then
    return
  end

  gfx.setfont(1, "Segoe UI", 16)
  gfx.setfont(2, "Segoe UI", 13)
  gfx.setfont(3, "Segoe UI", 22)

  local function loop()
    local char = gfx.getchar()
    if char < 0 or char == 27 then
      gfx.quit()
      return
    end

    ui.mouse_x = gfx.mouse_x
    ui.mouse_y = gfx.mouse_y
    ui.mouse_down = (gfx.mouse_cap & 1) == 1
    ui.mouse_clicked = ui.mouse_down and not ui.prev_mouse_down

    local wheel = gfx.mouse_wheel or 0
    local wheel_delta = wheel - (ui.last_wheel or 0)
    ui.last_wheel = wheel
    if wheel_delta > 0 then
      ui.wheel_steps = math.max(1, math.floor((wheel_delta / 120) + 0.5))
    elseif wheel_delta < 0 then
      ui.wheel_steps = math.min(-1, math.ceil((wheel_delta / 120) - 0.5))
    else
      ui.wheel_steps = 0
    end

    if char == string.byte("a") or char == string.byte("A") then
      local analyzed, analyzed_message = refresh_analysis_state(ui, settings)
      ui.status_message = analyzed and analyzed_message or ("Error: " .. tostring(analyzed_message))
    elseif char == string.byte("d") or char == string.byte("D") then
      local preview_ok, preview_message = run_preview(ui, settings)
      ui.status_message = preview_ok and preview_message or ("Error: " .. tostring(preview_message))
    elseif char == string.byte("n") or char == string.byte("N") then
      local normalize_ok, normalize_message = run_normalize(ui, settings)
      ui.status_message = normalize_ok and normalize_message or ("Error: " .. tostring(normalize_message))
    elseif char == string.byte("e") or char == string.byte("E") then
      local export_ok, export_message = handle_export_report_action(ui, settings)
      ui.status_message = export_ok and export_message or ("Error: " .. tostring(export_message))
    end

    local should_close = draw_dashboard(ui, settings)

    ui.prev_mouse_down = ui.mouse_down
    gfx.update()

    if should_close then
      gfx.quit()
      return
    end

    reaper.defer(loop)
  end

  loop()
end

local function main()
  if reaper.CountSelectedMediaItems(0) == 0 then
    reaper.ShowMessageBox("Select one or more audio items before running the normalizer.", SCRIPT_TITLE, 0)
    return
  end

  local current_settings = load_settings()
  local settings, prompt_error = prompt_for_settings(current_settings)
  if not settings then
    if prompt_error and prompt_error ~= "User cancelled." then
      reaper.ShowMessageBox(prompt_error, SCRIPT_TITLE, 0)
    end
    return
  end

  save_settings(settings)
  local ok, err = pcall(function()
    run_gfx_dashboard(settings)
  end)

  if not ok then
    log_line("[Loudness Normalizer] ERROR: " .. tostring(err))
    reaper.ShowMessageBox("Loudness normalizer failed:\n\n" .. tostring(err), SCRIPT_TITLE, 0)
  end
end

main()
