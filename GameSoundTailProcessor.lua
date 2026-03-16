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
local BATCH_RENDER_EXT_SECTION = "GameSoundBatchRenderer"
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
  category_rules_text = "SFX_Weapon=peak:-1;SFX_Footstep=peak:-6;UI=peak:-3;AMB=rms:-24",
  clip_protect = true,
  dry_run = false,
  min_length_ms = 50.0,
  max_trim_ratio = 90.0,
  sync_regions = true,
  create_markers = false,
}

local BATCH_RENDER_DEFAULTS = {
  prefix = "SFX",
  category = "General",
  case_style = "pascal",
  naming_source = "regions",
  render_scope = "selected_items",
  sample_rate = 48000,
  bit_depth = 24,
  channels = 1,
  output_path = "",
  create_subfolders = true,
  tail_ms = 0,
  trim_silence = true,
  trim_threshold_db = -60,
  fade_out_ms = 0,
  open_folder = false,
}

local BATCH_RENDER_NUMERIC_KEYS = {
  "RENDER_SETTINGS",
  "RENDER_BOUNDSFLAG",
  "RENDER_STARTPOS",
  "RENDER_ENDPOS",
  "RENDER_SRATE",
  "RENDER_CHANNELS",
  "RENDER_TAILFLAG",
  "RENDER_TAILMS",
  "RENDER_ADDTOPROJ",
  "RENDER_NORMALIZE",
  "RENDER_NORMALIZE_TARGET",
  "RENDER_BRICKWALL",
  "RENDER_FADEIN",
  "RENDER_FADEOUT",
  "RENDER_FADEINSHAPE",
  "RENDER_FADEOUTSHAPE",
  "RENDER_FADELPF",
  "RENDER_PADSTART",
  "RENDER_PADEND",
  "RENDER_TRIMSTART",
  "RENDER_TRIMEND",
  "RENDER_DELAY",
}

local BATCH_RENDER_STRING_KEYS = {
  "RENDER_FILE",
  "RENDER_PATTERN",
  "RENDER_FORMAT",
  "RENDER_FORMAT2",
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
  category = "Category",
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

local function clamp_number(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function clone_table(source)
  local target = {}
  for key, value in pairs(source or {}) do
    target[key] = value
  end
  return target
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

local function normalize_path(path)
  local normalized = trim_string(path):gsub("\\", "/")
  local unc_prefix = normalized:match("^//") and "//" or ""
  if unc_prefix ~= "" then
    normalized = normalized:sub(3)
  end
  normalized = normalized:gsub("/+", "/")
  normalized = normalized:gsub("/$", "")
  return unc_prefix .. normalized
end

local function join_paths(left, right)
  local lhs = normalize_path(left)
  local rhs = normalize_path(right)

  if lhs == "" then
    return rhs
  end
  if rhs == "" then
    return lhs
  end

  return lhs .. "/" .. rhs
end

local function is_absolute_path(path)
  local value = trim_string(path)
  return value:match("^%a:[/\\]") ~= nil or value:match("^[/\\][/\\]") ~= nil
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
  if lowered == "category" or lowered == "cat" or lowered == "preset" then
    return "category"
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

local function parse_category_rules(text)
  local rules = {}
  local errors = {}
  local source_text = tostring(text or "")

  for raw_entry in source_text:gmatch("[^;\r\n]+") do
    local entry = trim_string(raw_entry)
    if entry ~= "" then
      local key_part, value_part = entry:match("^([^=]+)=(.+)$")
      if not key_part or not value_part then
        errors[#errors + 1] = entry
      else
        local mode_part, target_part = value_part:match("^([^:]+):(.+)$")
        local key = trim_string(key_part)
        local mode = parse_normalize_mode(mode_part)
        local target = tonumber(trim_string(target_part))

        if key == "" or not mode or mode == "off" or mode == "category" or not target then
          errors[#errors + 1] = entry
        else
          rules[#rules + 1] = {
            key = key,
            match_upper = key:upper(),
            mode = mode,
            target_db = target,
          }
        end
      end
    end
  end

  if #errors > 0 then
    return nil, "Invalid category rule entries: " .. table.concat(errors, "; ")
  end

  return rules
end

local function normalize_category_text(text)
  local entries = {}
  for raw_entry in tostring(text or ""):gmatch("[^;\r\n]+") do
    local entry = trim_string(raw_entry)
    if entry ~= "" then
      entries[#entries + 1] = entry
    end
  end
  return table.concat(entries, ";")
end

local function batch_get_project_info_string(key)
  local _, value = reaper.GetSetProjectInfo_String(0, key, "", false)
  return value or ""
end

local function batch_set_project_info_string(key, value)
  reaper.GetSetProjectInfo_String(0, key, tostring(value or ""), true)
end

local function base64_encode(data)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local output = {}
  local padding = ({ "", "==", "=" })[(#data % 3) + 1]

  data = data .. string.rep("\0", (3 - #data % 3) % 3)

  for index = 1, #data, 3 do
    local a, b, c = data:byte(index, index + 2)
    local value = a * 65536 + b * 256 + c

    local i1 = math.floor(value / 262144) % 64 + 1
    local i2 = math.floor(value / 4096) % 64 + 1
    local i3 = math.floor(value / 64) % 64 + 1
    local i4 = value % 64 + 1

    output[#output + 1] = alphabet:sub(i1, i1)
    output[#output + 1] = alphabet:sub(i2, i2)
    output[#output + 1] = alphabet:sub(i3, i3)
    output[#output + 1] = alphabet:sub(i4, i4)
  end

  if padding ~= "" then
    output[#output] = padding:sub(#padding, #padding)
    if #padding == 2 then
      output[#output - 1] = padding:sub(1, 1)
    end
  end

  return table.concat(output)
end

local function build_wave_render_format(bit_depth)
  local raw = string.char(101, 118, 97, 119, bit_depth, 0, 0)
  return base64_encode(raw)
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
  settings.category_rules_text = normalize_category_text(get_ext_state("category_rules_text", DEFAULTS.category_rules_text))
  settings.category_rules = parse_category_rules(settings.category_rules_text)
  if not settings.category_rules then
    settings.category_rules_text = DEFAULTS.category_rules_text
    settings.category_rules = parse_category_rules(settings.category_rules_text) or {}
  end
  settings.clip_protect = parse_boolean(get_ext_state("clip_protect", bool_to_string(DEFAULTS.clip_protect)), DEFAULTS.clip_protect)
  settings.dry_run = parse_boolean(get_ext_state("dry_run", bool_to_string(DEFAULTS.dry_run)), DEFAULTS.dry_run)
  settings.min_length_ms = tonumber(get_ext_state("min_length_ms", tostring(DEFAULTS.min_length_ms))) or DEFAULTS.min_length_ms
  settings.max_trim_ratio = tonumber(get_ext_state("max_trim_ratio", tostring(DEFAULTS.max_trim_ratio))) or DEFAULTS.max_trim_ratio
  settings.sync_regions = parse_boolean(get_ext_state("sync_regions", bool_to_string(DEFAULTS.sync_regions)), DEFAULTS.sync_regions)
  settings.create_markers = parse_boolean(get_ext_state("create_markers", bool_to_string(DEFAULTS.create_markers)), DEFAULTS.create_markers)

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
  reaper.SetExtState(EXT_SECTION, "category_rules_text", tostring(settings.category_rules_text or DEFAULTS.category_rules_text), true)
  reaper.SetExtState(EXT_SECTION, "clip_protect", bool_to_string(settings.clip_protect), true)
  reaper.SetExtState(EXT_SECTION, "dry_run", bool_to_string(settings.dry_run), true)
  reaper.SetExtState(EXT_SECTION, "min_length_ms", tostring(settings.min_length_ms), true)
  reaper.SetExtState(EXT_SECTION, "max_trim_ratio", tostring(settings.max_trim_ratio), true)
  reaper.SetExtState(EXT_SECTION, "sync_regions", bool_to_string(settings.sync_regions), true)
  reaper.SetExtState(EXT_SECTION, "create_markers", bool_to_string(settings.create_markers), true)
end

local function load_batch_render_settings()
  local settings = {}
  for key, default_value in pairs(BATCH_RENDER_DEFAULTS) do
    local stored = reaper.GetExtState(BATCH_RENDER_EXT_SECTION, key)
    if stored == "" then
      settings[key] = default_value
    elseif type(default_value) == "boolean" then
      settings[key] = parse_boolean(stored, default_value)
    elseif type(default_value) == "number" then
      settings[key] = tonumber(stored) or default_value
    else
      settings[key] = stored
    end
  end

  settings.render_scope = "selected_items"
  if settings.case_style ~= "snake" then
    settings.case_style = "pascal"
  end
  if settings.naming_source ~= "track" then
    settings.naming_source = "regions"
  end
  if settings.sample_rate ~= 44100 and settings.sample_rate ~= 48000 and settings.sample_rate ~= 96000 then
    settings.sample_rate = BATCH_RENDER_DEFAULTS.sample_rate
  end
  if settings.bit_depth ~= 16 and settings.bit_depth ~= 24 and settings.bit_depth ~= 32 then
    settings.bit_depth = BATCH_RENDER_DEFAULTS.bit_depth
  end
  if settings.channels ~= 1 and settings.channels ~= 2 then
    settings.channels = BATCH_RENDER_DEFAULTS.channels
  end

  return settings
end

local function get_default_render_output_root()
  return join_paths(reaper.GetProjectPath(""), "Renders")
end

local function get_render_output_directory(settings)
  local configured = trim_string(settings.output_path)
  local output_root = configured == "" and get_default_render_output_root()
    or (is_absolute_path(configured) and normalize_path(configured) or join_paths(reaper.GetProjectPath(""), configured))

  if settings.create_subfolders then
    local folder_name = trim_string(settings.prefix):upper()
    folder_name = folder_name:gsub("[%s\\/:*?\"<>|]+", "_")
    folder_name = folder_name:gsub("_+", "_")
    folder_name = folder_name:gsub("^_+", "")
    folder_name = folder_name:gsub("_+$", "")
    if folder_name == "" then
      folder_name = "OUTPUT"
    end
    return join_paths(output_root, folder_name)
  end

  return output_root
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
    "Normalize Mode (off/peak/rms/category)",
    "Normalize Target (dB)",
    "Max Gain (dB)",
    "Protect From Clipping (y/n)",
    "Dry Run (y/n)",
    "Min Item Length (ms)",
    "Max Trim Ratio (%)",
    "Sync Matching Regions (y/n)",
    "Create Before/After Markers (y/n)",
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
    bool_to_string(current.create_markers),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 21, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 21)
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
  settings.create_markers = parse_boolean(parts[21], nil)

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
  if settings.create_markers == nil then
    return nil, "Create Before/After Markers must be y or n."
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
  settings.category_rules_text = current.category_rules_text or DEFAULTS.category_rules_text
  settings.category_rules = current.category_rules or {}

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

local function tokenize_name(value)
  local sanitized = tostring(value or "")
  sanitized = sanitized:gsub("[%c]", " ")
  sanitized = sanitized:gsub("[_%-%.]+", " ")
  sanitized = sanitized:gsub("(%l)(%u)", "%1 %2")
  sanitized = sanitized:gsub("[^%w%s]+", " ")

  local tokens = {}
  for token in sanitized:gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

local function format_segment(raw_text, case_style)
  local tokens = tokenize_name(raw_text)
  local formatted = {}

  for _, token in ipairs(tokens) do
    if case_style == "snake" then
      formatted[#formatted + 1] = token:lower()
    else
      formatted[#formatted + 1] = token:sub(1, 1):upper() .. token:sub(2):lower()
    end
  end

  return table.concat(formatted, "_")
end

local function format_prefix(raw_text)
  local tokens = tokenize_name(raw_text)
  for index, token in ipairs(tokens) do
    tokens[index] = token:upper()
  end
  return table.concat(tokens, "_")
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
  local names = {}
  local index = 0

  while true do
    local retval, is_region, region_start, region_end, region_name, region_id, region_color =
      reaper.EnumProjectMarkers3(project, index)
    if retval == 0 then
      break
    end

    if is_region
      and math.abs(region_start - start_pos) <= REGION_MATCH_TOLERANCE_SEC
      and math.abs(region_end - end_pos) <= REGION_MATCH_TOLERANCE_SEC then
      local clean_name = trim_string(region_name)
      matches[#matches + 1] = {
        id = region_id,
        name = clean_name,
        color = region_color or 0,
      }
      names[#names + 1] = clean_name
    end

    index = index + 1
  end

  return matches, names
end

local function analyze_item(item, index, settings)
  local take = reaper.GetActiveTake(item)
  local track = reaper.GetMediaItemTrack(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local project = reaper.GetItemProjectContext(item)
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)

  local result = {
    item = item,
    take = take,
    track = track,
    item_index = index,
    item_position = item_pos,
    item_end = item_pos + item_length,
    total_length = item_length,
    take_name = get_take_name_or_fallback(take, index),
    track_name = trim_string(track_name),
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
    region_names = {},
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

  result.region_matches, result.region_names = collect_matching_regions(project, item_pos, item_pos + item_length)

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
    local normalize_mode = settings.normalize_mode
    local normalize_target = settings.normalize_target_db
    local normalize_label = HUMAN_NORMALIZE_MODE[normalize_mode] or normalize_mode
    local category_rule = nil
    local category_source = nil

    if normalize_mode == "category" then
      category_rule, category_source = find_category_rule_for_analysis(analysis, settings)
      if not category_rule then
        plan.warnings[#plan.warnings + 1] = "Category normalize skipped: no matching preset for track/region."
        category_source = nil
        normalize_mode = "off"
      else
        normalize_mode = category_rule.mode
        normalize_target = category_rule.target_db
        normalize_label = string.format("Category(%s)", category_rule.key)
        plan.category_rule_key = category_rule.key
        plan.category_source_name = category_source
      end
    end

    local current_level = normalize_mode == "peak" and analysis.peak_db or analysis.rms_db
    if current_level <= NEG_INF_DB + 0.5 then
      plan.warnings[#plan.warnings + 1] = "Normalize skipped: level is too low to measure."
    elseif normalize_mode ~= "off" then
      local gain_db = normalize_target - current_level
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
        plan.normalize_mode_applied = normalize_mode
        plan.normalize_target_applied = normalize_target
        plan.messages[#plan.messages + 1] = string.format(
          "Normalize %s %+.2f dB",
          normalize_label,
          gain_db
        )
      elseif category_rule and category_source then
        plan.normalize_mode_applied = normalize_mode
        plan.normalize_target_applied = normalize_target
        plan.warnings[#plan.warnings + 1] = string.format(
          "Category preset %s matched %s, but no gain change was needed.",
          category_rule.key,
          category_source
        )
      end
    end
  end

  plan.new_position = current_position
  plan.new_offset = current_offset
  plan.new_length = current_length
  return plan
end

local function analyze_items(items, settings)
  local analyses = {}
  for index, item in ipairs(items or {}) do
    analyses[#analyses + 1] = analyze_item(item, index, settings)
  end
  return analyses
end

local function build_plans_from_analyses(analyses, settings)
  local plans = {}
  for _, analysis in ipairs(analyses or {}) do
    plans[#plans + 1] = build_item_plan(analysis, settings)
  end
  return plans
end

local function find_category_rule_for_analysis(analysis, settings)
  local rules = settings.category_rules or {}
  if #rules == 0 then
    return nil, nil
  end

  local candidates = {}
  if trim_string(analysis.track_name) ~= "" then
    candidates[#candidates + 1] = trim_string(analysis.track_name)
  end
  for _, region_name in ipairs(analysis.region_names or {}) do
    if trim_string(region_name) ~= "" then
      candidates[#candidates + 1] = trim_string(region_name)
    end
  end

  for _, rule in ipairs(rules) do
    for _, candidate in ipairs(candidates) do
      if candidate:upper():find(rule.match_upper, 1, true) == 1 then
        return rule, candidate
      end
    end
  end

  return nil, candidates[1]
end

local function summarize_plan(plan)
  if not plan then
    return ""
  end
  if plan.skip then
    return "Skip"
  end

  local parts = {}
  if plan.head_trim_amount > 0.0 then
    parts[#parts + 1] = "Head"
  end
  if plan.new_length < plan.analysis.total_length - 1e-9 then
    parts[#parts + 1] = "Trim"
  end
  if plan.fade_length_sec > 0.0 then
    parts[#parts + 1] = "Fade"
  end
  if math.abs(plan.gain_db or 0.0) > 0.001 then
    parts[#parts + 1] = string.format("%+.1fdB", plan.gain_db)
  end
  if #parts == 0 then
    return "No change"
  end
  return table.concat(parts, " | ")
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

  for _, region_info in ipairs(plan.region_matches) do
    if region_info and region_info.id then
      if reaper.SetProjectMarker3 then
        reaper.SetProjectMarker3(project, region_info.id, true, new_start, new_end, region_info.name or "", region_info.color or 0)
      else
        reaper.SetProjectMarker(region_info.id, true, new_start, new_end, region_info.name or "")
      end
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
  local created_markers = 0

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
        if settings.create_markers then
          created_markers = created_markers + add_before_after_markers(plan)
        end
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
      created_markers = created_markers,
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
    log_line(string.format("  Created markers:       %d", process_result.created_markers or 0))
  end

  log_line("==========================================================================")
end

local function csv_escape(value)
  local text = tostring(value or "")
  if text:find('[,"\r\n]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function ensure_directory(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end
  reaper.RecursiveCreateDirectory(normalized, 0)
  return true
end

local function get_export_csv_path()
  local project_path = reaper.GetProjectPath("")
  local analysis_dir = project_path .. "/Analysis"
  ensure_directory(analysis_dir)
  local timestamp = os.date("%Y%m%d_%H%M%S")
  return analysis_dir .. "/tail_analysis_" .. timestamp .. ".csv"
end

local function export_analysis_csv(analyses, plans, settings)
  local output_path = get_export_csv_path()
  local handle, err = io.open(output_path, "w")
  if not handle then
    return false, err or "Failed to open CSV for writing."
  end

  local headers = {
    "index", "take_name", "track_name", "region_names", "total_length_sec", "head_silence_sec",
    "tail_silence_sec", "content_start_sec", "content_end_sec", "peak_db", "rms_db",
    "status", "plan_summary", "new_position_sec", "new_length_sec", "new_offset_sec",
    "gain_db", "normalize_mode", "normalize_target_db",
  }
  handle:write(table.concat(headers, ",") .. "\n")

  for index, analysis in ipairs(analyses or {}) do
    local plan = plans[index]
    local status = (not analysis.valid and "ERROR") or (analysis.is_silent and "SILENT") or "OK"
    local row = {
      analysis.item_index,
      analysis.take_name,
      analysis.track_name,
      table.concat(analysis.region_names or {}, "|"),
      string.format("%.6f", analysis.total_length or 0.0),
      string.format("%.6f", analysis.head_silence or 0.0),
      string.format("%.6f", analysis.tail_silence or 0.0),
      string.format("%.6f", analysis.content_start or 0.0),
      string.format("%.6f", analysis.content_end or 0.0),
      string.format("%.3f", analysis.peak_db or NEG_INF_DB),
      string.format("%.3f", analysis.rms_db or NEG_INF_DB),
      status,
      summarize_plan(plan),
      string.format("%.6f", plan and plan.new_position or 0.0),
      string.format("%.6f", plan and plan.new_length or 0.0),
      string.format("%.6f", plan and plan.new_offset or 0.0),
      string.format("%.3f", plan and plan.gain_db or 0.0),
      tostring(plan and plan.normalize_mode_applied or settings.normalize_mode),
      string.format("%.3f", plan and plan.normalize_target_applied or settings.normalize_target_db),
    }

    for cell_index, value in ipairs(row) do
      row[cell_index] = csv_escape(value)
    end
    handle:write(table.concat(row, ",") .. "\n")
  end

  handle:close()
  return true, output_path
end

local function add_before_after_markers(plan)
  if not plan or plan.skip then
    return 0
  end

  local before_end = plan.analysis.item_position + plan.analysis.total_length
  local after_end = plan.new_position + plan.new_length
  local base_name = truncate_text(plan.analysis.take_name, 48)
  local created = 0

  if reaper.AddProjectMarker2 then
    reaper.AddProjectMarker2(0, false, before_end, 0, "Before:" .. base_name, -1, 0)
    reaper.AddProjectMarker2(0, false, after_end, 0, "After:" .. base_name, -1, 0)
    created = 2
  else
    reaper.AddProjectMarker(false, before_end, 0, "Before:" .. base_name, -1)
    reaper.AddProjectMarker(false, after_end, 0, "After:" .. base_name, -1)
    created = 2
  end

  return created
end

local function backup_batch_render_state()
  local backup = { numeric = {}, string = {} }
  for _, key in ipairs(BATCH_RENDER_NUMERIC_KEYS) do
    backup.numeric[key] = reaper.GetSetProjectInfo(0, key, 0, false)
  end
  for _, key in ipairs(BATCH_RENDER_STRING_KEYS) do
    backup.string[key] = batch_get_project_info_string(key)
  end
  return backup
end

local function restore_batch_render_state(backup)
  if not backup then
    return
  end
  for _, key in ipairs(BATCH_RENDER_NUMERIC_KEYS) do
    if backup.numeric[key] ~= nil then
      reaper.GetSetProjectInfo(0, key, backup.numeric[key], true)
    end
  end
  for _, key in ipairs(BATCH_RENDER_STRING_KEYS) do
    if backup.string[key] ~= nil then
      batch_set_project_info_string(key, backup.string[key])
    end
  end
end

local function select_single_item(item)
  reaper.SelectAllMediaItems(0, false)
  if item then
    reaper.SetMediaItemSelected(item, true)
  end
  reaper.UpdateArrange()
end

local function open_output_folder(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return
  end
  os.execute('explorer "' .. normalized .. '"')
end

local function apply_batch_common_render_settings(settings)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", settings.sample_rate, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", settings.channels, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  batch_set_project_info_string("RENDER_FORMAT", build_wave_render_format(settings.bit_depth))
  batch_set_project_info_string("RENDER_FORMAT2", "")

  local normalize_flags = 0
  if settings.trim_silence then
    normalize_flags = normalize_flags | 16384 | 32768
    local threshold = clamp_number(db_to_linear(settings.trim_threshold_db), 0, 1)
    reaper.GetSetProjectInfo(0, "RENDER_TRIMSTART", threshold, true)
    reaper.GetSetProjectInfo(0, "RENDER_TRIMEND", threshold, true)
  else
    reaper.GetSetProjectInfo(0, "RENDER_TRIMSTART", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_TRIMEND", 0, true)
  end

  if settings.fade_out_ms > 0 then
    normalize_flags = normalize_flags | 1024
    reaper.GetSetProjectInfo(0, "RENDER_FADEOUT", settings.fade_out_ms / 1000.0, true)
    reaper.GetSetProjectInfo(0, "RENDER_FADEOUTSHAPE", 0, true)
  else
    reaper.GetSetProjectInfo(0, "RENDER_FADEOUT", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_FADEOUTSHAPE", 0, true)
  end

  reaper.GetSetProjectInfo(0, "RENDER_FADEIN", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEINSHAPE", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADELPF", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_PADSTART", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_PADEND", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_DELAY", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", normalize_flags, true)

  if settings.tail_ms > 0 then
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 16, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILMS", settings.tail_ms, true)
  else
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILMS", 0, true)
  end
end

local function build_render_jobs_from_plans(plans, render_settings)
  local jobs = {}
  local output_dir = get_render_output_directory(render_settings)
  local prefix = format_prefix(render_settings.prefix)
  local category = format_segment(render_settings.category, render_settings.case_style)
  local variation_by_stem = {}

  if prefix == "" then
    return nil, "Render prefix is empty. Configure GameSoundBatchRenderer settings first."
  end
  if category == "" then
    return nil, "Render category is empty. Configure GameSoundBatchRenderer settings first."
  end

  for _, plan in ipairs(plans or {}) do
    if not plan.skip and plan.item then
      local raw_asset_name = nil
      if render_settings.naming_source == "regions" and plan.analysis.region_names and plan.analysis.region_names[1] then
        raw_asset_name = plan.analysis.region_names[1]
      end
      if trim_string(raw_asset_name) == "" then
        raw_asset_name = trim_string(plan.analysis.track_name)
      end
      if trim_string(raw_asset_name) == "" then
        raw_asset_name = plan.analysis.take_name
      end

      local asset_name = format_segment(raw_asset_name, render_settings.case_style)
      if asset_name == "" then
        asset_name = "Asset"
      end

      local stem_key = string.lower(prefix .. "|" .. category .. "|" .. asset_name)
      variation_by_stem[stem_key] = (variation_by_stem[stem_key] or 0) + 1

      local variation = string.format("%02d", variation_by_stem[stem_key])
      local file_stem = string.format("%s_%s_%s_%s", prefix, category, asset_name, variation)
      jobs[#jobs + 1] = {
        item = plan.item,
        file_stem = file_stem,
        output_dir = output_dir,
        file_path = join_paths(output_dir, file_stem .. ".wav"),
        source_label = plan.analysis.take_name,
      }
    end
  end

  if #jobs == 0 then
    return nil, "No processed audio items are available to render."
  end

  return jobs
end

local function inspect_render_job_conflicts(jobs)
  local generated_duplicates = {}
  local existing_files = {}
  local seen = {}

  for _, job in ipairs(jobs or {}) do
    local key = string.lower(job.file_path)
    if seen[key] then
      generated_duplicates[#generated_duplicates + 1] = job.file_path
    else
      seen[key] = true
    end

    if reaper.file_exists(job.file_path) then
      existing_files[#existing_files + 1] = job.file_path
    end
  end

  return generated_duplicates, existing_files
end

local function confirm_existing_render_files(existing_files)
  if #existing_files == 0 then
    return true
  end

  local preview_limit = math.min(#existing_files, 8)
  local lines = {
    "Existing files were found and may be overwritten:",
    "",
  }

  for index = 1, preview_limit do
    lines[#lines + 1] = existing_files[index]
  end
  if #existing_files > preview_limit then
    lines[#lines + 1] = string.format("...and %d more", #existing_files - preview_limit)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Continue?"

  return reaper.ShowMessageBox(table.concat(lines, "\n"), SCRIPT_TITLE, 4) == 6
end

local function render_jobs_in_place(render_settings, jobs, selected_items)
  local output_dir = get_render_output_directory(render_settings)
  if not ensure_directory(output_dir) then
    return false, "Failed to create output directory:\n" .. output_dir
  end

  local render_state_backup = backup_batch_render_state()
  local selected_backup = clone_table(selected_items or {})
  local success_count = 0
  local started_at = reaper.time_precise()

  local ok, err = xpcall(function()
    for index, job in ipairs(jobs) do
      log_line(string.format("[Render %d/%d] %s", index, #jobs, job.file_path))
      ensure_directory(job.output_dir)
      batch_set_project_info_string("RENDER_FILE", job.output_dir)
      batch_set_project_info_string("RENDER_PATTERN", job.file_stem)
      select_single_item(job.item)
      reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 64, true)
      reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)
      reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
      reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", 0, true)
      apply_batch_common_render_settings(render_settings)
      reaper.Main_OnCommand(42230, 0)

      if reaper.file_exists(job.file_path) then
        success_count = success_count + 1
      else
        log_line("  Warning: file was not found after render -> " .. job.file_path)
      end
    end
  end, function(message)
    return debug.traceback(message, 2)
  end)

  restore_batch_render_state(render_state_backup)
  select_only_items(selected_backup)

  if not ok then
    return false, err
  end

  local summary = string.format(
    "Render complete.\nFiles rendered: %d/%d\nOutput path: %s\nElapsed: %.2f sec",
    success_count,
    #jobs,
    output_dir,
    reaper.time_precise() - started_at
  )

  if render_settings.open_folder then
    open_output_folder(output_dir)
  end

  return true, summary
end

local GUI = {
  width = 1120,
  height = 1020,
  padding = 16,
  section_gap = 12,
  row_h = 26,
  table_row_h = 22,
}

local function set_color(r, g, b, a)
  gfx.set((r or 255) / 255.0, (g or 255) / 255.0, (b or 255) / 255.0, (a or 255) / 255.0)
end

local function point_in_rect(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function begin_gui_frame(state)
  local mouse_down = (gfx.mouse_cap & 1) == 1
  state.mouse_x = gfx.mouse_x
  state.mouse_y = gfx.mouse_y
  state.mouse_down = mouse_down
  state.mouse_pressed = mouse_down and not state.prev_mouse_down
  state.mouse_released = (not mouse_down) and state.prev_mouse_down
  state.prev_mouse_down = mouse_down
  state.mouse_consumed = false
  state.wheel_delta = gfx.mouse_wheel - (state.prev_mouse_wheel or gfx.mouse_wheel)
  state.prev_mouse_wheel = gfx.mouse_wheel
end

local function finish_gui_frame()
  gfx.update()
end

local function draw_text(x, y, text, r, g, b, a)
  set_color(r, g, b, a)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function draw_panel(x, y, w, h, title)
  set_color(28, 31, 36, 255)
  gfx.rect(x, y, w, h, true)
  set_color(60, 66, 74, 255)
  gfx.rect(x, y, w, h, false)
  if title and title ~= "" then
    gfx.setfont(1, "Arial", 17)
    draw_text(x + 10, y + 8, title, 230, 234, 240, 255)
  end
end

local function draw_button(state, x, y, w, h, label, options)
  options = options or {}
  local hovered = point_in_rect(state.mouse_x, state.mouse_y, x, y, w, h)
  local enabled = options.enabled ~= false
  local active = options.active == true
  local bg = { 58, 96, 156, 255 }
  local border = { 88, 130, 200, 255 }
  local fg = { 245, 247, 250, 255 }

  if not enabled then
    bg = { 52, 54, 58, 255 }
    border = { 72, 74, 78, 255 }
    fg = { 138, 141, 147, 255 }
  elseif active then
    bg = { 86, 122, 58, 255 }
    border = { 122, 170, 82, 255 }
  elseif hovered then
    bg = { 72, 110, 172, 255 }
  end

  set_color(bg[1], bg[2], bg[3], bg[4])
  gfx.rect(x, y, w, h, true)
  set_color(border[1], border[2], border[3], border[4])
  gfx.rect(x, y, w, h, false)

  gfx.setfont(1, "Arial", 15)
  local text_w, text_h = gfx.measurestr(label)
  draw_text(x + (w - text_w) * 0.5, y + (h - text_h) * 0.5, label, fg[1], fg[2], fg[3], fg[4])

  local clicked = enabled and hovered and state.mouse_released and not state.mouse_consumed
  if clicked then
    state.mouse_consumed = true
  end
  return clicked, hovered
end

local function draw_value_button(state, x, y, w, h, label, value, enabled)
  gfx.setfont(1, "Arial", 14)
  draw_text(x, y + 4, label, 200, 206, 214, 255)
  local clicked = draw_button(state, x + 150, y, w - 150, h, value, { enabled = enabled }) and true or false
  return clicked
end

local function set_status(state, message)
  state.status_message = message
end

local function refresh_plan_cache(state)
  if #state.analyses > 0 and not state.analysis_dirty then
    state.plans = build_plans_from_analyses(state.analyses, state.settings)
    state.process_dirty = false
  end
end

local function update_setting(state, key, value, analysis_affects)
  state.settings[key] = value
  if analysis_affects then
    state.analysis_dirty = true
    state.process_dirty = true
  else
    state.process_dirty = true
  end
  save_settings(state.settings)
  refresh_plan_cache(state)
end

local function prompt_numeric_setting(state, key, label, analysis_affects, minimum, maximum, decimals, integer_only)
  local ok, csv = reaper.GetUserInputs(SCRIPT_TITLE .. " - " .. label, 1, label, tostring(state.settings[key]))
  if not ok then
    return
  end

  local value = tonumber(csv)
  if not value then
    reaper.ShowMessageBox(label .. " must be numeric.", SCRIPT_TITLE, 0)
    return
  end
  if integer_only then
    value = math.floor(value + 0.5)
  else
    value = round_to(value, decimals or 3)
  end
  if value < minimum or value > maximum then
    reaper.ShowMessageBox(
      string.format("%s must be between %s and %s.", label, tostring(minimum), tostring(maximum)),
      SCRIPT_TITLE,
      0
    )
    return
  end

  update_setting(state, key, value, analysis_affects)
  set_status(state, label .. " updated.")
end

local function adopt_prompt_settings(state)
  local settings, err = prompt_for_settings(state.settings)
  if not settings then
    if err and err ~= "User cancelled." then
      reaper.ShowMessageBox(err, SCRIPT_TITLE, 0)
    end
    return
  end

  state.settings = settings
  state.analysis_dirty = true
  state.process_dirty = true
  save_settings(state.settings)
  set_status(state, "Settings updated from quick dialog.")
end

local function prompt_category_rules(state)
  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Category Rules",
    1,
    "extrawidth=640,Rules (Category=mode:target; Category2=mode:target)",
    tostring(state.settings.category_rules_text or DEFAULTS.category_rules_text)
  )
  if not ok then
    return
  end

  local normalized = normalize_category_text(csv)
  local parsed, err = parse_category_rules(normalized)
  if not parsed then
    reaper.ShowMessageBox(err or "Invalid category rules.", SCRIPT_TITLE, 0)
    return
  end

  state.settings.category_rules_text = normalized
  state.settings.category_rules = parsed
  state.process_dirty = true
  save_settings(state.settings)
  refresh_plan_cache(state)
  set_status(state, string.format("Category rules updated (%d presets).", #parsed))
end

local function run_export_action(state)
  if state.analysis_dirty or #state.analyses == 0 then
    if not run_analysis_pass(state) then
      return
    end
  end
  if state.process_dirty then
    state.plans = build_plans_from_analyses(state.analyses, state.settings)
    state.process_dirty = false
  end

  reaper.ClearConsole()
  print_analysis_report(state.analyses, state.settings)
  print_plan_preview(state.plans, state.settings)

  local ok, path_or_err = export_analysis_csv(state.analyses, state.plans, state.settings)
  if not ok then
    reaper.ShowMessageBox("CSV export failed:\n\n" .. tostring(path_or_err), SCRIPT_TITLE, 0)
    set_status(state, "CSV export failed.")
    return
  end

  log_line("")
  log_line("[Tail Processor] CSV exported to:")
  log_line(path_or_err)
  set_status(state, "CSV exported: " .. path_or_err)
end

local function run_analysis_pass(state)
  local items = collect_selected_items()
  if #items == 0 then
    set_status(state, "No selected media items.")
    return false
  end

  state.selected_items = items
  state.analyses = analyze_items(items, state.settings)
  state.plans = build_plans_from_analyses(state.analyses, state.settings)
  state.analysis_dirty = false
  state.process_dirty = false
  state.results_scroll = 0
  set_status(state, string.format("Analyzed %d selected items.", #items))
  return true
end

local function run_action(state, action)
  if not run_analysis_pass(state) then
    return
  end

  reaper.ClearConsole()
  print_analysis_report(state.analyses, state.settings)

  if action == "analyze" then
    return
  end

  local action_settings = clone_table(state.settings)
  action_settings.dry_run = action == "dry_run"
  local action_plans = build_plans_from_analyses(state.analyses, action_settings)

  print_plan_preview(action_plans, action_settings)
  local ok, result_or_err = process_plans(action_plans, state.selected_items, action_settings)
  if not ok then
    reaper.ShowMessageBox("Tail/Silence processing failed:\n\n" .. tostring(result_or_err), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Tail Processor] ERROR: " .. tostring(result_or_err))
    set_status(state, "Processing failed. See console.")
    return
  end

  print_final_summary(action_plans, action_settings, result_or_err)

  if action == "process_render" then
    local render_settings = load_batch_render_settings()
    local jobs, jobs_err = build_render_jobs_from_plans(action_plans, render_settings)
    if not jobs then
      reaper.ShowMessageBox(jobs_err or "Failed to prepare render jobs.", SCRIPT_TITLE, 0)
      set_status(state, "Processed, but render job preparation failed.")
      run_analysis_pass(state)
      return
    end

    local generated_duplicates, existing_files = inspect_render_job_conflicts(jobs)
    if #generated_duplicates > 0 then
      reaper.ShowMessageBox(
        "Duplicate generated render file names were detected:\n\n" .. table.concat(generated_duplicates, "\n"),
        SCRIPT_TITLE,
        0
      )
      set_status(state, "Processed, but render names conflicted.")
      run_analysis_pass(state)
      return
    end
    if not confirm_existing_render_files(existing_files) then
      set_status(state, "Processed. Render canceled.")
      run_analysis_pass(state)
      return
    end

    log_line("")
    log_line("[Tail Processor] Starting render with GameSoundBatchRenderer settings.")
    local render_ok, render_result = render_jobs_in_place(render_settings, jobs, state.selected_items)
    log_line(render_result)
    if render_ok then
      reaper.ShowMessageBox(render_result, SCRIPT_TITLE, 0)
      set_status(state, string.format("Processed %d items and rendered %d files.", result_or_err.processed_count or 0, #jobs))
    else
      reaper.ShowMessageBox("Render failed:\n\n" .. tostring(render_result), SCRIPT_TITLE, 0)
      set_status(state, "Processed, but render failed.")
    end
    run_analysis_pass(state)
  elseif action == "process" then
    run_analysis_pass(state)
    set_status(state, string.format(
      "Processed %d items. Regions: %d, Markers: %d.",
      result_or_err.processed_count or 0,
      result_or_err.updated_regions or 0,
      result_or_err.created_markers or 0
    ))
  else
    state.plans = action_plans
    set_status(state, "Dry run complete. See console for details.")
  end
end

local function draw_result_table(state, x, y, w, h)
  draw_panel(x, y, w, h, "Analysis Results")
  local header_y = y + 34
  local row_y = header_y + 28
  local plan_width = math.max(150, w - 36 - 240 - 80 - 76 - 76 - 70 - 28)
  local columns = {
    { label = "#", width = 36 },
    { label = "Name", width = 240 },
    { label = "Length", width = 80 },
    { label = "Head", width = 76 },
    { label = "Tail", width = 76 },
    { label = "Peak", width = 70 },
    { label = "Plan", width = plan_width },
  }

  local cursor_x = x + 10
  gfx.setfont(1, "Arial", 14)
  for _, column in ipairs(columns) do
    draw_text(cursor_x, header_y, column.label, 166, 174, 186, 255)
    cursor_x = cursor_x + column.width
  end

  local visible_rows = math.max(1, math.floor((h - 72) / GUI.table_row_h))
  local max_scroll = math.max(0, #state.analyses - visible_rows)
  local table_hover = point_in_rect(state.mouse_x, state.mouse_y, x + 6, row_y, w - 12, h - 54)

  if table_hover and state.wheel_delta ~= 0 then
    local step = state.wheel_delta > 0 and -1 or 1
    state.results_scroll = clamp_number(state.results_scroll + step, 0, max_scroll)
  end

  for row_index = 1, visible_rows do
    local data_index = state.results_scroll + row_index
    local analysis = state.analyses[data_index]
    local plan = state.plans[data_index]
    local current_y = row_y + (row_index - 1) * GUI.table_row_h

    set_color(row_index % 2 == 0 and 34 or 30, row_index % 2 == 0 and 38 or 34, 43, 255)
    gfx.rect(x + 8, current_y, w - 16, GUI.table_row_h - 2, true)

    if analysis then
      local status_color = { 220, 224, 230, 255 }
      if not analysis.valid then
        status_color = { 234, 120, 120, 255 }
      elseif analysis.is_silent then
        status_color = { 220, 186, 104, 255 }
      end

      local cells = {
        tostring(analysis.item_index),
        truncate_text(analysis.take_name, 30),
        format_seconds(analysis.total_length),
        format_ms_from_sec(analysis.head_silence),
        format_ms_from_sec(analysis.tail_silence),
        format_db(analysis.peak_db),
        truncate_text(summarize_plan(plan), 42),
      }

      local row_x = x + 10
      for cell_index, column in ipairs(columns) do
        local color = cell_index == 7 and status_color or { 220, 224, 230, 255 }
        draw_text(row_x, current_y + 3, cells[cell_index], color[1], color[2], color[3], color[4])
        row_x = row_x + column.width
      end
    end
  end

  if #state.analyses == 0 then
    gfx.setfont(1, "Arial", 16)
    draw_text(x + 16, y + 70, "No analysis yet. Select items and click Analyze Selected Items.", 170, 176, 184, 255)
  end

  if #state.analyses > visible_rows then
    local thumb_h = math.max(28, (h - 88) * (visible_rows / #state.analyses))
    local track_h = h - 88
    local thumb_y = y + 62 + (track_h - thumb_h) * (state.results_scroll / math.max(1, max_scroll))
    set_color(55, 60, 68, 255)
    gfx.rect(x + w - 12, y + 62, 6, track_h, true)
    set_color(120, 128, 140, 255)
    gfx.rect(x + w - 12, thumb_y, 6, thumb_h, true)
  end
end

local function draw_settings_column(state, x, y, w)
  local cursor_y = y

  draw_panel(x, cursor_y, w, 150, "Analysis Settings")
  local row_y = cursor_y + 40
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Threshold", string.format("%.1f dB", state.settings.threshold_db), true) then
    prompt_numeric_setting(state, "threshold_db", "Threshold (dB)", true, -150, 0, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Min Silence", string.format("%.1f ms", state.settings.min_silence_ms), true) then
    prompt_numeric_setting(state, "min_silence_ms", "Min Silence (ms)", true, 0, 5000, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Block Size", tostring(state.settings.block_size), true) then
    prompt_numeric_setting(state, "block_size", "Block Size (samples)", true, 64, 65536, 0, true)
  end

  cursor_y = cursor_y + 150 + GUI.section_gap
  draw_panel(x, cursor_y, w, 118, "Head Trim")
  row_y = cursor_y + 40
  if draw_button(state, x + 12, row_y, 126, 24, "Head Trim", { active = state.settings.head_trim_enabled }) then
    update_setting(state, "head_trim_enabled", not state.settings.head_trim_enabled, false)
  end
  if draw_button(state, x + 150, row_y, w - 162, 24, state.settings.keep_position and "Left Edge Fixed" or "Preserve Timing", { active = state.settings.keep_position }) then
    update_setting(state, "keep_position", not state.settings.keep_position, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Pre-roll", string.format("%.1f ms", state.settings.pre_roll_ms), true) then
    prompt_numeric_setting(state, "pre_roll_ms", "Head Pre-roll (ms)", false, 0, 500, 3, false)
  end

  cursor_y = cursor_y + 118 + GUI.section_gap
  draw_panel(x, cursor_y, w, 196, "Tail Processing")
  row_y = cursor_y + 40
  if draw_button(state, x + 12, row_y, 126, 24, "Tail Enabled", { active = state.settings.tail_enabled }) then
    update_setting(state, "tail_enabled", not state.settings.tail_enabled, false)
  end
  row_y = row_y + GUI.row_h
  if draw_button(state, x + 12, row_y, 78, 24, "Cut", { active = state.settings.tail_mode == "cut" }) then
    update_setting(state, "tail_mode", "cut", false)
  end
  if draw_button(state, x + 96, row_y, 78, 24, "Fade", { active = state.settings.tail_mode == "fade" }) then
    update_setting(state, "tail_mode", "fade", false)
  end
  if draw_button(state, x + 180, row_y, 110, 24, "Target", { active = state.settings.tail_mode == "target" }) then
    update_setting(state, "tail_mode", "target", false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Post-roll", string.format("%.1f ms", state.settings.post_roll_ms), true) then
    prompt_numeric_setting(state, "post_roll_ms", "Tail Post-roll (ms)", false, 0, 5000, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Fade Length", string.format("%.1f ms", state.settings.fade_length_ms), state.settings.tail_mode == "fade") then
    prompt_numeric_setting(state, "fade_length_ms", "Fade Out Length (ms)", false, 0, 10000, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_button(state, x + 12, row_y, 70, 24, "Lin", { active = state.settings.fade_curve == "lin" }) then
    update_setting(state, "fade_curve", "lin", false)
  end
  if draw_button(state, x + 88, row_y, 70, 24, "Exp", { active = state.settings.fade_curve == "exp" }) then
    update_setting(state, "fade_curve", "exp", false)
  end
  if draw_button(state, x + 164, row_y, 92, 24, "S-Curve", { active = state.settings.fade_curve == "scurve" }) then
    update_setting(state, "fade_curve", "scurve", false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Target Length", string.format("%.3f s", state.settings.target_length_sec), state.settings.tail_mode == "target") then
    prompt_numeric_setting(state, "target_length_sec", "Target Length (sec)", false, 0, 3600, 6, false)
  end

  cursor_y = cursor_y + 196 + GUI.section_gap
  draw_panel(x, cursor_y, w, 194, "Normalize")
  row_y = cursor_y + 40
  if draw_button(state, x + 12, row_y, 68, 24, "Off", { active = state.settings.normalize_mode == "off" }) then
    update_setting(state, "normalize_mode", "off", false)
  end
  if draw_button(state, x + 86, row_y, 76, 24, "Peak", { active = state.settings.normalize_mode == "peak" }) then
    update_setting(state, "normalize_mode", "peak", false)
  end
  if draw_button(state, x + 168, row_y, 70, 24, "RMS", { active = state.settings.normalize_mode == "rms" }) then
    update_setting(state, "normalize_mode", "rms", false)
  end
  if draw_button(state, x + 244, row_y, 82, 24, "Category", { active = state.settings.normalize_mode == "category" }) then
    update_setting(state, "normalize_mode", "category", false)
  end
  if draw_button(state, x + 12, row_y + GUI.row_h, w - 24, 24, state.settings.clip_protect and "Clip Protect On" or "Clip Protect Off", { active = state.settings.clip_protect }) then
    update_setting(state, "clip_protect", not state.settings.clip_protect, false)
  end
  row_y = row_y + (GUI.row_h * 2)
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Target", string.format("%.1f dB", state.settings.normalize_target_db), state.settings.normalize_mode ~= "off") then
    prompt_numeric_setting(state, "normalize_target_db", "Normalize Target (dB)", false, -150, 6, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Max Gain", string.format("%.1f dB", state.settings.max_gain_db), state.settings.normalize_mode ~= "off") then
    prompt_numeric_setting(state, "max_gain_db", "Max Gain (dB)", false, 0, 60, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_button(
    state,
    x + 12,
    row_y,
    w - 24,
    24,
    string.format("Edit Category Rules (%d)", #(state.settings.category_rules or {})),
    { active = state.settings.normalize_mode == "category" }
  ) then
    prompt_category_rules(state)
  end

  cursor_y = cursor_y + 194 + GUI.section_gap
  draw_panel(x, cursor_y, w, 146, "Safety / Sync")
  row_y = cursor_y + 40
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Min Item Length", string.format("%.1f ms", state.settings.min_length_ms), true) then
    prompt_numeric_setting(state, "min_length_ms", "Min Item Length (ms)", false, 1, 10000, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_value_button(state, x + 12, row_y, w - 24, 22, "Max Trim Ratio", string.format("%.1f %%", state.settings.max_trim_ratio), true) then
    prompt_numeric_setting(state, "max_trim_ratio", "Max Trim Ratio (%)", false, 0, 99.999, 3, false)
  end
  row_y = row_y + GUI.row_h
  if draw_button(state, x + 12, row_y, w - 24, 24, state.settings.sync_regions and "Sync Matching Regions" or "Do Not Sync Regions", { active = state.settings.sync_regions }) then
    update_setting(state, "sync_regions", not state.settings.sync_regions, false)
  end
  row_y = row_y + GUI.row_h
  if draw_button(state, x + 12, row_y, w - 24, 24, state.settings.create_markers and "Create Before/After Markers" or "No Comparison Markers", { active = state.settings.create_markers }) then
    update_setting(state, "create_markers", not state.settings.create_markers, false)
  end
end

local function draw_gui(state)
  begin_gui_frame(state)

  local window_w, window_h = gfx.w, gfx.h
  set_color(20, 23, 27, 255)
  gfx.rect(0, 0, window_w, window_h, true)

  gfx.setfont(1, "Arial", 22)
  draw_text(GUI.padding, GUI.padding, SCRIPT_TITLE, 238, 241, 245, 255)
  gfx.setfont(1, "Arial", 14)
  draw_text(GUI.padding, GUI.padding + 30, "Phase 2 GUI - analyze, preview, process, and keep settings persistent.", 176, 183, 192, 255)

  local toolbar_y = GUI.padding + 56
  if draw_button(state, GUI.padding, toolbar_y, 166, 30, "Analyze Selected Items", { enabled = true }) then
    run_action(state, "analyze")
  end
  if draw_button(state, GUI.padding + 176, toolbar_y, 104, 30, "Dry Run", { enabled = true }) then
    run_action(state, "dry_run")
  end
  if draw_button(state, GUI.padding + 290, toolbar_y, 118, 30, "Process All", { enabled = true }) then
    run_action(state, "process")
  end
  if draw_button(state, GUI.padding + 418, toolbar_y, 140, 30, "Process + Render", { enabled = true }) then
    run_action(state, "process_render")
  end
  if draw_button(state, GUI.padding + 568, toolbar_y, 102, 30, "Export CSV", { enabled = true }) then
    run_export_action(state)
  end
  if draw_button(state, GUI.padding + 680, toolbar_y, 110, 30, "Quick Setup", { enabled = true }) then
    adopt_prompt_settings(state)
  end
  if draw_button(state, window_w - GUI.padding - 96, toolbar_y, 96, 30, "Close", { enabled = true }) then
    state.should_close = true
  end

  local stale_text = state.analysis_dirty and "Analysis stale" or (state.process_dirty and "Plan stale" or "Ready")
  draw_text(GUI.padding + 804, toolbar_y + 7, stale_text, state.analysis_dirty and 230 or 150, state.analysis_dirty and 180 or 208, 120, 255)

  local left_w = 336
  local right_x = GUI.padding + left_w + GUI.section_gap
  draw_settings_column(state, GUI.padding, toolbar_y + 44, left_w)
  draw_result_table(state, right_x, toolbar_y + 44, window_w - right_x - GUI.padding, window_h - (toolbar_y + 92))

  local footer_y = window_h - 30
  set_color(38, 42, 48, 255)
  gfx.rect(0, footer_y - 6, window_w, 36, true)
  draw_text(GUI.padding, footer_y, state.status_message or "Ready.", 220, 224, 230, 255)
  draw_text(GUI.padding + 520, footer_y, "Process + Render uses GameSoundBatchRenderer saved render settings.", 156, 164, 174, 255)
  if #state.analyses > 0 then
    draw_text(window_w - 260, footer_y, string.format("Rows: %d  Scroll: %d", #state.analyses, state.results_scroll), 156, 164, 174, 255)
  end

  finish_gui_frame()
end

local function run_gui()
  gfx.init(SCRIPT_TITLE, GUI.width, GUI.height, 0)
  local state = {
    settings = load_settings(),
    selected_items = {},
    analyses = {},
    plans = {},
    status_message = "Select items, adjust settings, then analyze.",
    analysis_dirty = true,
    process_dirty = true,
    results_scroll = 0,
    prev_mouse_down = false,
    prev_mouse_wheel = 0,
    should_close = false,
  }

  local function loop()
    if state.should_close or gfx.getchar() < 0 then
      save_settings(state.settings)
      return
    end

    draw_gui(state)
    reaper.defer(loop)
  end

  loop()
end

local function main()
  run_gui()
end

main()
