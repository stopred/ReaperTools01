-- Game Sound Asset Batch Renderer v1.0
-- Reaper ReaScript (Lua)
-- 게임 사운드 에셋 네이밍 자동화 + 일괄 렌더링 도구
--
-- 사용법:
-- 1. Reaper -> Actions -> Show action list -> Load ReaScript
-- 2. 이 스크립트 파일을 선택하여 로드
-- 3. 리전 또는 아이템을 준비한 후 스크립트 실행
-- 4. GUI에서 설정 조정 후 [Render All] 클릭
--
-- 요구사항: REAPER v7.0+

local SCRIPT_TITLE = "Game Sound Asset Batch Renderer v1.0"
local EXT_SECTION = "GameSoundBatchRenderer"

local SETTINGS_KEYS = {
  "prefix",
  "category",
  "case_style",
  "naming_source",
  "render_scope",
  "sample_rate",
  "bit_depth",
  "channels",
  "output_path",
  "create_subfolders",
  "tail_ms",
  "trim_silence",
  "trim_threshold_db",
  "fade_out_ms",
  "open_folder",
}

local DEFAULTS = {
  prefix = "SFX",
  category = "General",
  case_style = "pascal",
  naming_source = "regions",
  render_scope = "selected_regions",
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

local HUMAN_CASE_STYLE = {
  pascal = "PascalCase",
  snake = "snake_case",
}

local HUMAN_NAMING_SOURCE = {
  regions = "Regions",
  track = "Track Names",
}

local HUMAN_RENDER_SCOPE = {
  selected_regions = "Selected Regions",
  all_regions = "All Regions",
  selected_items = "Selected Items",
  time_selection = "Time Selection",
}

local HUMAN_CHANNELS = {
  [1] = "Mono",
  [2] = "Stereo",
}

local PREFIX_OPTIONS = {
  "SFX",
  "AMB",
  "MUS",
  "UI",
  "VO",
  "FOL",
}

local CASE_STYLE_OPTIONS = {
  { value = "pascal", label = "PascalCase" },
  { value = "snake", label = "snake_case" },
}

local NAMING_SOURCE_OPTIONS = {
  { value = "regions", label = "Regions" },
  { value = "track", label = "Track Names" },
}

local RENDER_SCOPE_OPTIONS = {
  { value = "selected_regions", label = "Selected Regions" },
  { value = "all_regions", label = "All Regions" },
  { value = "selected_items", label = "Selected Items" },
  { value = "time_selection", label = "Time Selection" },
}

local SAMPLE_RATE_OPTIONS = {
  { value = 44100, label = "44100 Hz" },
  { value = 48000, label = "48000 Hz" },
  { value = 96000, label = "96000 Hz" },
}

local BIT_DEPTH_OPTIONS = {
  { value = 16, label = "16-bit PCM" },
  { value = 24, label = "24-bit PCM" },
  { value = 32, label = "32-bit float" },
}

local CHANNEL_OPTIONS = {
  { value = 1, label = "Mono" },
  { value = 2, label = "Stereo" },
}

local NUMERIC_RENDER_KEYS = {
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

local STRING_RENDER_KEYS = {
  "RENDER_FILE",
  "RENDER_PATTERN",
  "RENDER_FORMAT",
  "RENDER_FORMAT2",
}

-- Print a line to the ReaScript console.
local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

-- Trim leading and trailing whitespace.
local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
end

-- Return true when a string is empty after trimming.
local function is_blank(value)
  return trim_string(value) == ""
end

-- Normalize path separators for Reaper and Windows-safe comparisons.
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

-- Join two path fragments with a single slash.
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

-- Check whether a Windows path is absolute.
local function is_absolute_path(path)
  local value = trim_string(path)
  return value:match("^%a:[/\\]") ~= nil or value:match("^[/\\][/\\]") ~= nil
end

-- Convert a boolean to a stable ExtState string.
local function bool_to_string(value)
  return value and "1" or "0"
end

-- Convert a user-provided token to boolean.
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

-- Split the CSV returned by GetUserInputs into a fixed number of parts.
local function split_csv(retvals_csv, expected_count)
  local parts = {}
  for part in (tostring(retvals_csv or "") .. ","):gmatch("(.-),") do
    parts[#parts + 1] = part
  end
  while #parts < expected_count do
    parts[#parts + 1] = ""
  end
  return parts
end

-- Clamp a value to the given numeric range.
local function clamp_number(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

-- Convert a dB threshold to a linear amplitude ratio.
local function db_to_amplitude(db_value)
  return 10 ^ (tonumber(db_value or 0) / 20)
end

-- Encode binary data as base64 for RENDER_FORMAT.
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

-- Build a WAV sink configuration for the selected bit depth.
local function build_wave_render_format(bit_depth)
  local raw = string.char(101, 118, 97, 119, bit_depth, 0, 0)
  return base64_encode(raw)
end

-- Read a string render setting safely.
local function get_project_info_string(key)
  local _, value = reaper.GetSetProjectInfo_String(0, key, "", false)
  return value or ""
end

-- Write a string render setting safely.
local function set_project_info_string(key, value)
  reaper.GetSetProjectInfo_String(0, key, tostring(value or ""), true)
end

-- Back up all render settings that this script may override.
local function backup_render_state()
  local backup = {
    numeric = {},
    string = {},
  }

  for _, key in ipairs(NUMERIC_RENDER_KEYS) do
    backup.numeric[key] = reaper.GetSetProjectInfo(0, key, 0, false)
  end

  for _, key in ipairs(STRING_RENDER_KEYS) do
    backup.string[key] = get_project_info_string(key)
  end

  return backup
end

-- Restore the render settings that were active before the script changed them.
local function restore_render_state(backup)
  if not backup then
    return
  end

  for _, key in ipairs(NUMERIC_RENDER_KEYS) do
    if backup.numeric[key] ~= nil then
      reaper.GetSetProjectInfo(0, key, backup.numeric[key], true)
    end
  end

  for _, key in ipairs(STRING_RENDER_KEYS) do
    if backup.string[key] ~= nil then
      set_project_info_string(key, backup.string[key])
    end
  end
end

-- Load persisted settings from ExtState.
local function load_settings()
  local settings = {}
  for _, key in ipairs(SETTINGS_KEYS) do
    local default_value = DEFAULTS[key]
    local stored = reaper.GetExtState(EXT_SECTION, key)
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
  return settings
end

-- Persist the latest settings into ExtState.
local function save_settings(settings)
  for _, key in ipairs(SETTINGS_KEYS) do
    local value = settings[key]
    local encoded = value
    if type(value) == "boolean" then
      encoded = bool_to_string(value)
    end
    reaper.SetExtState(EXT_SECTION, key, tostring(encoded), true)
  end
end

-- Copy default values back into a settings table.
local function reset_settings_to_defaults(settings)
  for _, key in ipairs(SETTINGS_KEYS) do
    settings[key] = DEFAULTS[key]
  end
end

-- Escape text for preset storage inside ExtState.
local function preset_escape(value)
  local escaped = tostring(value or "")
  escaped = escaped:gsub("%%", "%%25")
  escaped = escaped:gsub("\r", "%%0D")
  escaped = escaped:gsub("\n", "%%0A")
  escaped = escaped:gsub("=", "%%3D")
  return escaped
end

-- Unescape preset text loaded from ExtState.
local function preset_unescape(value)
  local unescaped = tostring(value or "")
  unescaped = unescaped:gsub("%%3D", "=")
  unescaped = unescaped:gsub("%%0A", "\n")
  unescaped = unescaped:gsub("%%0D", "\r")
  unescaped = unescaped:gsub("%%25", "%%")
  return unescaped
end

-- Build a stable ExtState key for a preset name.
local function preset_storage_key(name)
  local hex_parts = {}
  for index = 1, #name do
    hex_parts[#hex_parts + 1] = string.format("%02X", name:byte(index))
  end
  return "preset_" .. table.concat(hex_parts)
end

-- Sanitize a user preset name.
local function normalize_preset_name(name)
  local value = trim_string(name)
  value = value:gsub("[%c]", " ")
  value = value:gsub("%s+", " ")
  return value
end

-- Read all saved preset names from ExtState.
local function load_preset_names()
  local stored = reaper.GetExtState(EXT_SECTION, "preset_names")
  local names = {}

  for line in tostring(stored or ""):gmatch("[^\n]+") do
    local name = normalize_preset_name(preset_unescape(line))
    if name ~= "" then
      names[#names + 1] = name
    end
  end

  table.sort(names, function(left, right)
    return left:lower() < right:lower()
  end)

  return names
end

-- Persist the current preset name list to ExtState.
local function save_preset_names(names)
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = preset_escape(name)
  end
  reaper.SetExtState(EXT_SECTION, "preset_names", table.concat(lines, "\n"), true)
end

-- Save the last-used preset name separately for GUI display.
local function set_last_preset_name(name)
  reaper.SetExtState(EXT_SECTION, "last_preset_name", tostring(name or ""), true)
end

-- Return the last-used preset name if it still exists.
local function get_last_preset_name()
  local name = normalize_preset_name(reaper.GetExtState(EXT_SECTION, "last_preset_name"))
  if name == "" then
    return ""
  end

  for _, preset_name in ipairs(load_preset_names()) do
    if preset_name == name then
      return name
    end
  end

  return ""
end

-- Serialize the current settings into a preset blob.
local function serialize_preset(settings)
  local lines = {}
  for _, key in ipairs(SETTINGS_KEYS) do
    lines[#lines + 1] = key .. "=" .. preset_escape(settings[key])
  end
  return table.concat(lines, "\n")
end

-- Apply a serialized preset blob onto the current settings table.
local function apply_serialized_preset(settings, blob)
  local applied = false

  for line in tostring(blob or ""):gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and DEFAULTS[key] ~= nil then
      local default_value = DEFAULTS[key]
      local decoded = preset_unescape(value)
      if type(default_value) == "boolean" then
        settings[key] = parse_boolean(decoded, default_value)
      elseif type(default_value) == "number" then
        settings[key] = tonumber(decoded) or default_value
      else
        settings[key] = decoded
      end
      applied = true
    end
  end

  return applied
end

-- Save the current settings as a named preset.
local function save_named_preset(name, settings)
  local preset_name = normalize_preset_name(name)
  if preset_name == "" then
    return false
  end

  reaper.SetExtState(EXT_SECTION, preset_storage_key(preset_name), serialize_preset(settings), true)

  local names = load_preset_names()
  local exists = false
  for _, existing_name in ipairs(names) do
    if existing_name == preset_name then
      exists = true
      break
    end
  end

  if not exists then
    names[#names + 1] = preset_name
    table.sort(names, function(left, right)
      return left:lower() < right:lower()
    end)
    save_preset_names(names)
  end

  set_last_preset_name(preset_name)
  return true
end

-- Load a named preset onto the active settings table.
local function load_named_preset(name, settings)
  local preset_name = normalize_preset_name(name)
  if preset_name == "" then
    return false
  end

  local blob = reaper.GetExtState(EXT_SECTION, preset_storage_key(preset_name))
  if blob == "" then
    return false
  end

  local applied = apply_serialized_preset(settings, blob)
  if applied then
    save_settings(settings)
    set_last_preset_name(preset_name)
  end
  return applied
end

-- Delete a named preset from ExtState.
local function delete_named_preset(name)
  local preset_name = normalize_preset_name(name)
  if preset_name == "" then
    return false
  end

  reaper.DeleteExtState(EXT_SECTION, preset_storage_key(preset_name), true)

  local names = {}
  for _, existing_name in ipairs(load_preset_names()) do
    if existing_name ~= preset_name then
      names[#names + 1] = existing_name
    end
  end
  save_preset_names(names)

  if get_last_preset_name() == preset_name then
    set_last_preset_name("")
  end

  return true
end

-- Convert user text to the supported case style key.
local function normalize_case_style(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "pascal" or lowered == "pascalcase" then
    return "pascal"
  end
  if lowered == "snake" or lowered == "snake_case" then
    return "snake"
  end
  return default_value
end

-- Convert user text to the supported naming source key.
local function normalize_naming_source(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "regions" or lowered == "region" then
    return "regions"
  end
  if lowered == "track" or lowered == "tracks" or lowered == "track_names" then
    return "track"
  end
  return default_value
end

-- Convert user text to the supported render scope key.
local function normalize_render_scope(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "selected_regions" or lowered == "selected regions" or lowered == "sel_regions" then
    return "selected_regions"
  end
  if lowered == "all_regions" or lowered == "all regions" or lowered == "regions" then
    return "all_regions"
  end
  if lowered == "selected_items" or lowered == "selected items" or lowered == "items" then
    return "selected_items"
  end
  if lowered == "time_selection" or lowered == "time selection" or lowered == "timesel" then
    return "time_selection"
  end
  return default_value
end

-- Convert user text to mono or stereo.
local function normalize_channels(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "mono" or lowered == "1" then
    return 1
  end
  if lowered == "stereo" or lowered == "2" then
    return 2
  end
  return default_value
end

-- Convert user text to the supported sample rate.
local function normalize_sample_rate(value, default_value)
  local numeric = tonumber(value)
  if numeric == 44100 or numeric == 48000 or numeric == 96000 then
    return numeric
  end
  return default_value
end

-- Convert user text to the supported bit depth list.
local function normalize_bit_depth(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "16" or lowered == "16bit" or lowered == "16pcm" then
    return 16
  end
  if lowered == "24" or lowered == "24bit" or lowered == "24pcm" then
    return 24
  end
  if lowered == "32" or lowered == "32f" or lowered == "32float" or lowered == "32-bit float" or lowered == "32bit float" then
    return 32
  end
  return default_value
end

-- Resolve the default project render root.
local function get_default_output_root()
  return join_paths(reaper.GetProjectPath(""), "Renders")
end

-- Resolve the effective output root from user settings.
local function resolve_output_root(settings)
  local configured = trim_string(settings.output_path)
  if configured == "" then
    return get_default_output_root()
  end

  if is_absolute_path(configured) then
    return normalize_path(configured)
  end

  return join_paths(reaper.GetProjectPath(""), configured)
end

-- Create an output directory if it does not already exist.
local function ensure_directory(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end

  reaper.RecursiveCreateDirectory(normalized, 0)
  return true
end

-- Return the current human-readable output directory.
local function get_target_output_directory(settings)
  local output_root = resolve_output_root(settings)
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

-- Prompt for naming-related settings.
local function prompt_naming_settings(settings)
  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Naming",
    4,
    "Prefix (custom or SFX/AMB/MUS/UI/VO/FOL),Category (custom text),Case Style (pascal/snake),Naming Source (regions/track)",
    table.concat({
      settings.prefix,
      settings.category,
      settings.case_style,
      settings.naming_source,
    }, ",")
  )

  if not ok then
    return false
  end

  local values = split_csv(csv, 4)
  settings.prefix = trim_string(values[1]):upper()
  settings.category = trim_string(values[2])
  settings.case_style = normalize_case_style(values[3], settings.case_style)
  settings.naming_source = normalize_naming_source(values[4], settings.naming_source)
  return true
end

-- Prompt for render-format and scope settings.
local function prompt_render_settings(settings)
  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Render",
    4,
    "Render Scope,Sample Rate,Bit Depth (16/24/32float),Channels (mono/stereo)",
    table.concat({
      settings.render_scope,
      tostring(settings.sample_rate),
      settings.bit_depth == 32 and "32float" or tostring(settings.bit_depth),
      settings.channels == 1 and "mono" or "stereo",
    }, ",")
  )

  if not ok then
    return false
  end

  local values = split_csv(csv, 4)
  settings.render_scope = normalize_render_scope(values[1], settings.render_scope)
  settings.sample_rate = normalize_sample_rate(values[2], settings.sample_rate)
  settings.bit_depth = normalize_bit_depth(values[3], settings.bit_depth)
  settings.channels = normalize_channels(values[4], settings.channels)
  return true
end

-- Prompt for output and post-processing settings.
local function prompt_output_settings(settings)
  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Output/Post",
    7,
    "Output Path,Subfolder By Prefix (1/0),Tail ms,Trim Silence (1/0),Trim Threshold dB,Fade Out ms,Open Folder (1/0)",
    table.concat({
      settings.output_path,
      bool_to_string(settings.create_subfolders),
      tostring(settings.tail_ms),
      bool_to_string(settings.trim_silence),
      tostring(settings.trim_threshold_db),
      tostring(settings.fade_out_ms),
      bool_to_string(settings.open_folder),
    }, ",")
  )

  if not ok then
    return false
  end

  local values = split_csv(csv, 7)
  settings.output_path = trim_string(values[1])
  settings.create_subfolders = parse_boolean(values[2], settings.create_subfolders)
  settings.tail_ms = math.max(0, tonumber(values[3]) or settings.tail_ms)
  settings.trim_silence = parse_boolean(values[4], settings.trim_silence)
  settings.trim_threshold_db = tonumber(values[5]) or settings.trim_threshold_db
  settings.fade_out_ms = math.max(0, tonumber(values[6]) or settings.fade_out_ms)
  settings.open_folder = parse_boolean(values[7], settings.open_folder)
  return true
end

-- Prompt for a single text value and return nil when canceled.
local function prompt_single_text(title, caption, default_value)
  local ok, value = reaper.GetUserInputs(title, 1, caption, tostring(default_value or ""))
  if not ok then
    return nil
  end
  return trim_string(value)
end

-- Prompt for a number and fall back to nil when canceled or invalid.
local function prompt_single_number(title, caption, default_value)
  local result = prompt_single_text(title, caption, tostring(default_value or ""))
  if result == nil then
    return nil
  end
  local numeric = tonumber(result)
  if numeric == nil then
    reaper.ShowMessageBox("Please enter a valid number.", SCRIPT_TITLE, 0)
    return nil
  end
  return numeric
end

-- Return the label for the current bit depth.
local function get_bit_depth_label(bit_depth)
  for _, option in ipairs(BIT_DEPTH_OPTIONS) do
    if option.value == bit_depth then
      return option.label
    end
  end
  return tostring(bit_depth)
end

-- Return the label for the current sample rate.
local function get_sample_rate_label(sample_rate)
  for _, option in ipairs(SAMPLE_RATE_OPTIONS) do
    if option.value == sample_rate then
      return option.label
    end
  end
  return tostring(sample_rate)
end

-- Return the label for the current render scope.
local function get_render_scope_label(render_scope)
  return HUMAN_RENDER_SCOPE[render_scope] or render_scope
end

-- Return the label for the current naming source.
local function get_naming_source_label(naming_source)
  return HUMAN_NAMING_SOURCE[naming_source] or naming_source
end

-- Return the label for the current case style.
local function get_case_style_label(case_style)
  return HUMAN_CASE_STYLE[case_style] or case_style
end

-- Find the matching option index in an option table.
local function find_option_index(options, current_value)
  for index, option in ipairs(options) do
    local option_value = type(option) == "table" and option.value or option
    if option_value == current_value then
      return index
    end
  end
  return 1
end

-- Show a popup menu at the given position and return the selected option value.
local function show_option_menu(x, y, options, current_value)
  local menu_parts = {}
  local current_index = find_option_index(options, current_value)

  for index, option in ipairs(options) do
    local label = type(option) == "table" and option.label or tostring(option)
    if index == current_index then
      label = "!" .. label
    end
    menu_parts[#menu_parts + 1] = label
  end

  gfx.x = x
  gfx.y = y
  local selected_index = gfx.showmenu(table.concat(menu_parts, "|"))
  if selected_index <= 0 then
    return nil
  end

  local selected_option = options[selected_index]
  if type(selected_option) == "table" then
    return selected_option.value
  end
  return selected_option
end

-- Try to browse for a folder via JS extension, otherwise fall back to a text prompt.
local function browse_for_output_path(current_path)
  local start_path = current_path
  if is_blank(start_path) then
    start_path = get_default_output_root()
  end

  if reaper.JS_Dialog_BrowseForFolder then
    local selected = reaper.JS_Dialog_BrowseForFolder(SCRIPT_TITLE, start_path)
    if selected and selected ~= "" then
      return normalize_path(selected)
    end
    return nil
  end

  local typed = prompt_single_text(SCRIPT_TITLE .. " - Output Path", "Output Path", start_path)
  if typed == nil then
    return nil
  end
  return normalize_path(typed)
end


-- Validate the essential settings before collecting jobs.
local function validate_settings(settings)
  if is_blank(settings.prefix) then
    return false, "Prefix is required."
  end

  if is_blank(settings.category) then
    return false, "Category is required."
  end

  local output_dir = get_target_output_directory(settings)
  if is_blank(output_dir) then
    return false, "Output path is empty."
  end

  return true
end

-- Get the visible name of a track.
local function get_track_name(track)
  local _, name = reaper.GetTrackName(track)
  return trim_string(name)
end

-- Collect metadata for every item in the project and assign a track order index.
local function collect_all_item_metadata()
  local all_items = {}
  local lookup = {}
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    if track then
      local track_items = {}
      local track_name = get_track_name(track)
      local item_count = reaper.CountTrackMediaItems(track)

      for item_index = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if item then
          local start_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          track_items[#track_items + 1] = {
            item = item,
            track = track,
            track_name = track_name,
            start_pos = start_pos,
            end_pos = start_pos + length,
          }
        end
      end

      table.sort(track_items, function(left, right)
        if left.start_pos == right.start_pos then
          return tostring(left.item) < tostring(right.item)
        end
        return left.start_pos < right.start_pos
      end)

      for order_index, meta in ipairs(track_items) do
        meta.track_order = order_index
        all_items[#all_items + 1] = meta
        lookup[meta.item] = meta
      end
    end
  end

  table.sort(all_items, function(left, right)
    if left.start_pos == right.start_pos then
      return left.track_order < right.track_order
    end
    return left.start_pos < right.start_pos
  end)

  return all_items, lookup
end

-- Collect all regions, optionally filtering to the UI-selected ones only.
local function collect_regions(selected_only)
  local regions = {}
  local count = reaper.GetNumRegionsOrMarkers(0)

  for index = 0, count - 1 do
    local region_or_marker = reaper.GetRegionOrMarker(0, index, "")
    if region_or_marker and reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "B_ISREGION") > 0.5 then
      local is_selected = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "B_UISEL") > 0.5
      if not selected_only or is_selected then
        local _, name = reaper.GetSetRegionOrMarkerInfo_String(0, region_or_marker, "P_NAME", "", false)
        regions[#regions + 1] = {
          object = region_or_marker,
          start_pos = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_STARTPOS"),
          end_pos = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_ENDPOS"),
          display_number = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "I_NUMBER"),
          internal_index = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "I_INDEX"),
          name = trim_string(name),
        }
      end
    end
  end

  table.sort(regions, function(left, right)
    if left.start_pos == right.start_pos then
      return left.display_number < right.display_number
    end
    return left.start_pos < right.start_pos
  end)

  return regions
end

-- Find the first overlapping item in a time range.
local function find_first_overlapping_item(all_items, start_pos, end_pos)
  for _, item in ipairs(all_items) do
    if item.end_pos > start_pos and item.start_pos < end_pos then
      return item
    end
  end
  return nil
end

-- Find the best named region that contains or overlaps the requested range.
local function find_named_region_for_range(regions, start_pos, end_pos)
  local best_region = nil
  local best_overlap = 0

  for _, region in ipairs(regions) do
    if not is_blank(region.name) then
      local contains = region.start_pos <= start_pos + 0.0001 and region.end_pos >= end_pos - 0.0001
      if contains then
        return region.name
      end

      local overlap = math.min(region.end_pos, end_pos) - math.max(region.start_pos, start_pos)
      if overlap > best_overlap then
        best_overlap = overlap
        best_region = region
      end
    end
  end

  if best_region then
    return best_region.name
  end

  return nil
end

-- Strip unsupported file-name characters and split text into ASCII-friendly tokens.
local function tokenize_name(raw_text)
  local cleaned = tostring(raw_text or "")
  cleaned = cleaned:gsub("[%c]", " ")
  cleaned = cleaned:gsub("[<>:\"/\\|%?%*]", " ")
  cleaned = cleaned:gsub("[^%w%s_%-]", " ")
  cleaned = cleaned:gsub("[%s_%-]+", " ")
  cleaned = trim_string(cleaned)

  local tokens = {}
  for token in cleaned:gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

-- Apply the chosen case style to a user text segment.
local function format_segment(raw_text, case_style)
  local tokens = tokenize_name(raw_text)
  if #tokens == 0 then
    return ""
  end

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

-- Format the prefix separately so it remains uppercase.
local function format_prefix(raw_text)
  local tokens = tokenize_name(raw_text)
  if #tokens == 0 then
    return ""
  end

  for index, token in ipairs(tokens) do
    tokens[index] = token:upper()
  end

  return table.concat(tokens, "_")
end

-- Resolve the base asset name for a region-oriented render job.
local function resolve_region_asset_name(region, settings, all_items)
  if settings.naming_source == "regions" and not is_blank(region.name) then
    return region.name
  end

  local overlapping_item = find_first_overlapping_item(all_items, region.start_pos, region.end_pos)
  if overlapping_item and not is_blank(overlapping_item.track_name) then
    return overlapping_item.track_name
  end

  return "Region_" .. tostring(math.floor(region.display_number))
end

-- Resolve the base asset name for an item-oriented render job.
local function resolve_item_asset_name(item_meta, settings, all_regions)
  if settings.naming_source == "regions" then
    local region_name = find_named_region_for_range(all_regions, item_meta.start_pos, item_meta.end_pos)
    if not is_blank(region_name) then
      return region_name
    end
  end

  if not is_blank(item_meta.track_name) then
    return item_meta.track_name
  end

  return "Item"
end

-- Resolve the base asset name for a time range render job.
local function resolve_range_asset_name(start_pos, end_pos, settings, all_regions, all_items)
  if settings.naming_source == "regions" then
    local region_name = find_named_region_for_range(all_regions, start_pos, end_pos)
    if not is_blank(region_name) then
      return region_name
    end
  end

  local overlapping_item = find_first_overlapping_item(all_items, start_pos, end_pos)
  if overlapping_item and not is_blank(overlapping_item.track_name) then
    return overlapping_item.track_name
  end

  return "Time_Selection"
end

-- Collect the currently selected items as metadata records.
local function collect_selected_item_metadata(item_lookup)
  local items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)

  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    if item and item_lookup[item] then
      items[#items + 1] = item_lookup[item]
    end
  end

  table.sort(items, function(left, right)
    if left.start_pos == right.start_pos then
      if left.track_name == right.track_name then
        return left.track_order < right.track_order
      end
      return left.track_name < right.track_name
    end
    return left.start_pos < right.start_pos
  end)

  return items
end

-- Build render jobs for the chosen scope and assign final file names.
local function build_render_jobs(settings)
  local all_regions = collect_regions(false)
  local all_items, item_lookup = collect_all_item_metadata()
  local jobs = {}

  if settings.render_scope == "selected_regions" then
    local selected_regions = collect_regions(true)
    if #selected_regions == 0 then
      return nil, "No regions are selected. Select regions in the Region/Marker Manager and try again."
    end

    for _, region in ipairs(selected_regions) do
      jobs[#jobs + 1] = {
        render_mode = "custom_bounds",
        start_pos = region.start_pos,
        end_pos = region.end_pos,
        source_label = string.format("Region %d", region.display_number),
        raw_asset_name = resolve_region_asset_name(region, settings, all_items),
      }
    end
  elseif settings.render_scope == "all_regions" then
    if #all_regions == 0 then
      return nil, "No regions were found in the project."
    end

    for _, region in ipairs(all_regions) do
      jobs[#jobs + 1] = {
        render_mode = "custom_bounds",
        start_pos = region.start_pos,
        end_pos = region.end_pos,
        source_label = string.format("Region %d", region.display_number),
        raw_asset_name = resolve_region_asset_name(region, settings, all_items),
      }
    end
  elseif settings.render_scope == "selected_items" then
    local selected_items = collect_selected_item_metadata(item_lookup)
    if #selected_items == 0 then
      return nil, "No media items are selected."
    end

    for _, item_meta in ipairs(selected_items) do
      jobs[#jobs + 1] = {
        render_mode = "selected_item",
        item = item_meta.item,
        start_pos = item_meta.start_pos,
        end_pos = item_meta.end_pos,
        source_label = string.format("%s item %02d", item_meta.track_name, item_meta.track_order),
        raw_asset_name = resolve_item_asset_name(item_meta, settings, all_regions),
      }
    end
  elseif settings.render_scope == "time_selection" then
    local start_pos, end_pos = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if end_pos <= start_pos then
      return nil, "Time selection is empty."
    end

    jobs[#jobs + 1] = {
      render_mode = "custom_bounds",
      start_pos = start_pos,
      end_pos = end_pos,
      source_label = "Time Selection",
      raw_asset_name = resolve_range_asset_name(start_pos, end_pos, settings, all_regions, all_items),
    }
  else
    return nil, "Unsupported render scope."
  end

  local prefix = format_prefix(settings.prefix)
  local category = format_segment(settings.category, settings.case_style)
  local output_dir = get_target_output_directory(settings)
  local variation_by_stem = {}

  if prefix == "" then
    return nil, "Prefix becomes empty after sanitizing. Please enter a valid prefix."
  end

  if category == "" then
    return nil, "Category becomes empty after sanitizing. Please enter a valid category."
  end

  for _, job in ipairs(jobs) do
    local asset_name = format_segment(job.raw_asset_name, settings.case_style)
    if asset_name == "" then
      asset_name = "Asset"
    end

    local stem_key = string.lower(prefix .. "|" .. category .. "|" .. asset_name)
    variation_by_stem[stem_key] = (variation_by_stem[stem_key] or 0) + 1

    local variation = string.format("%02d", variation_by_stem[stem_key])
    local file_stem = string.format("%s_%s_%s_%s", prefix, category, asset_name, variation)

    job.prefix = prefix
    job.category = category
    job.asset_name = asset_name
    job.variation = variation
    job.file_stem = file_stem
    job.output_dir = output_dir
    job.file_path = join_paths(output_dir, file_stem .. ".wav")
  end

  return jobs
end

-- Detect generated duplicate names and files that already exist on disk.
local function inspect_job_conflicts(jobs)
  local generated_duplicates = {}
  local existing_files = {}
  local seen = {}

  for _, job in ipairs(jobs) do
    local key = job.file_path:lower()
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

-- Print the preview list to the ReaScript console.
local function preview_jobs(jobs)
  reaper.ClearConsole()
  log_line("== Preview Names ==")
  log_line("")

  for index, job in ipairs(jobs) do
    log_line(string.format("%02d. %s", index, job.file_path))
    log_line("    Source: " .. job.source_label)
  end
end

-- Select only one media item for selected-item rendering.
local function select_single_item(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
end

-- Restore a previously captured item selection.
local function restore_item_selection(selected_items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(selected_items) do
    reaper.SetMediaItemSelected(item, true)
  end
  reaper.UpdateArrange()
end

-- Capture the currently selected items so the script can restore them later.
local function capture_selected_items()
  local items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)
  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    if item then
      items[#items + 1] = item
    end
  end
  return items
end

-- Apply WAV, sample rate, channel count, and post-processing settings.
local function apply_common_render_settings(settings, render_mode)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", settings.sample_rate, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", settings.channels, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  set_project_info_string("RENDER_FORMAT", build_wave_render_format(settings.bit_depth))
  set_project_info_string("RENDER_FORMAT2", "")

  local normalize_flags = 0

  if settings.trim_silence then
    normalize_flags = normalize_flags | 16384 | 32768
    local threshold = clamp_number(db_to_amplitude(settings.trim_threshold_db), 0, 1)
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
    local tail_flag = render_mode == "selected_item" and 16 or 1
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", tail_flag, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILMS", settings.tail_ms, true)
  else
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILMS", 0, true)
  end
end

-- Apply job-specific bounds and file naming before calling the render action.
local function apply_job_render_settings(settings, job)
  ensure_directory(job.output_dir)
  set_project_info_string("RENDER_FILE", job.output_dir)
  set_project_info_string("RENDER_PATTERN", job.file_stem)

  if job.render_mode == "selected_item" then
    select_single_item(job.item)
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 64, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", 0, true)
  else
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", job.start_pos, true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", job.end_pos, true)
  end

  apply_common_render_settings(settings, job.render_mode)
end

-- Build the confirmation text shown before preview or render.
local function build_summary(settings, jobs)
  local lines = {
    "Files: " .. tostring(#jobs),
    "Scope: " .. (HUMAN_RENDER_SCOPE[settings.render_scope] or settings.render_scope),
    "Case Style: " .. (HUMAN_CASE_STYLE[settings.case_style] or settings.case_style),
    "Naming Source: " .. (HUMAN_NAMING_SOURCE[settings.naming_source] or settings.naming_source),
    "Sample Rate: " .. tostring(settings.sample_rate),
    "Bit Depth: " .. (settings.bit_depth == 32 and "32-bit float" or (tostring(settings.bit_depth) .. "-bit")),
    "Channels: " .. (HUMAN_CHANNELS[settings.channels] or tostring(settings.channels)),
    "Output: " .. get_target_output_directory(settings),
    "Tail: " .. tostring(settings.tail_ms) .. " ms",
    "Trim Silence: " .. (settings.trim_silence and ("On (" .. tostring(settings.trim_threshold_db) .. " dB)") or "Off"),
    "Fade Out: " .. tostring(settings.fade_out_ms) .. " ms",
    "",
    "Yes = Render All",
    "No = Preview Names",
    "Cancel = Abort",
  }

  return table.concat(lines, "\n")
end

-- Ask the user whether to preview, render, or cancel.
local function choose_preview_or_render(settings, jobs)
  while true do
    local response = reaper.ShowMessageBox(build_summary(settings, jobs), SCRIPT_TITLE, 3)
    if response == 6 then
      return "render"
    end
    if response == 7 then
      preview_jobs(jobs)
      reaper.ShowMessageBox("Preview printed to the ReaScript console.", SCRIPT_TITLE, 0)
    else
      return nil
    end
  end
end

-- Render all prepared jobs and return a short result summary.
local function render_jobs(settings, jobs)
  local output_dir = get_target_output_directory(settings)
  if not ensure_directory(output_dir) then
    return false, "Failed to create output directory:\n" .. output_dir
  end

  local started_at = reaper.time_precise()
  local render_state_backup = backup_render_state()
  local selected_items_backup = capture_selected_items()
  local success_count = 0

  local ok, err = xpcall(function()
    for index, job in ipairs(jobs) do
      log_line(string.format("[%d/%d] Rendering %s", index, #jobs, job.file_path))
      apply_job_render_settings(settings, job)
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

  restore_render_state(render_state_backup)
  restore_item_selection(selected_items_backup)

  if not ok then
    return false, err
  end

  local elapsed = reaper.time_precise() - started_at
  local summary = {
    "Render complete.",
    "Files rendered: " .. tostring(success_count) .. "/" .. tostring(#jobs),
    "Output path: " .. output_dir,
    string.format("Elapsed: %.2f sec", elapsed),
  }

  return true, table.concat(summary, "\n")
end

-- Offer to continue when files already exist on disk.
local function confirm_existing_files(existing_files)
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

  local response = reaper.ShowMessageBox(table.concat(lines, "\n"), SCRIPT_TITLE, 4)
  return response == 6
end

-- Abort when generated file names collide inside the current batch.
local function reject_generated_duplicates(duplicates)
  if #duplicates == 0 then
    return true
  end

  local unique = {}
  local seen = {}
  for _, path in ipairs(duplicates) do
    local key = path:lower()
    if not seen[key] then
      unique[#unique + 1] = path
      seen[key] = true
    end
  end

  local lines = {
    "Duplicate generated file names were detected.",
    "Adjust Prefix, Category, Naming Source, or source names, then try again.",
    "",
  }

  for _, path in ipairs(unique) do
    lines[#lines + 1] = path
  end

  reaper.ShowMessageBox(table.concat(lines, "\n"), SCRIPT_TITLE, 0)
  return false
end

-- Open the target output folder in Windows Explorer.
local function open_output_folder(path)
  local normalized = normalize_path(path):gsub("/", "\\")
  if normalized == "" then
    return
  end
  os.execute('explorer "' .. normalized .. '"')
end

-- Validate and build the current batch jobs for preview or render.
local function prepare_jobs(settings)
  local valid, validation_error = validate_settings(settings)
  if not valid then
    reaper.ShowMessageBox(validation_error, SCRIPT_TITLE, 0)
    return nil, validation_error
  end

  save_settings(settings)

  local jobs, build_error = build_render_jobs(settings)
  if not jobs then
    reaper.ShowMessageBox(build_error, SCRIPT_TITLE, 0)
    return nil, build_error
  end

  local generated_duplicates, existing_files = inspect_job_conflicts(jobs)
  if not reject_generated_duplicates(generated_duplicates) then
    return nil, "Duplicate generated file names were detected."
  end

  return jobs, existing_files
end

-- Preview names from the current GUI settings and return a status message.
local function preview_from_settings(settings)
  local jobs, existing_files = prepare_jobs(settings)
  if not jobs then
    return false, "Preview failed."
  end

  preview_jobs(jobs)

  local message = string.format("Previewed %d file names.", #jobs)
  if #existing_files > 0 then
    message = message .. string.format(" %d existing files were also found.", #existing_files)
  end

  reaper.ShowMessageBox("Preview printed to the ReaScript console.", SCRIPT_TITLE, 0)
  return true, message
end

-- Render from the current GUI settings and return a status message.
local function render_from_settings(settings)
  local jobs, existing_files = prepare_jobs(settings)
  if not jobs then
    return false, "Render canceled."
  end

  if not confirm_existing_files(existing_files) then
    return false, "Render canceled."
  end

  reaper.ClearConsole()
  reaper.Undo_BeginBlock()
  local ok, result = render_jobs(settings, jobs)
  reaper.Undo_EndBlock("Game Sound Asset Batch Renderer", -1)

  log_line(result)

  if ok then
    reaper.ShowMessageBox(result, SCRIPT_TITLE, 0)
    if settings.open_folder then
      open_output_folder(get_target_output_directory(settings))
    end
  else
    reaper.ShowMessageBox("Render failed:\n\n" .. tostring(result), SCRIPT_TITLE, 0)
  end

  return ok, result
end

-- Set the current drawing color.
local function gui_set_color(r, g, b, a)
  gfx.set(r, g, b, a or 1)
end

-- Draw a text label using the requested size.
local function gui_draw_text(x, y, text, size, r, g, b, a)
  gfx.setfont(1, "Segoe UI", size)
  gui_set_color(r, g, b, a)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

-- Return true when the mouse is inside the given rectangle.
local function gui_point_in_rect(x, y, rect)
  return x >= rect.x and x <= (rect.x + rect.w) and y >= rect.y and y <= (rect.y + rect.h)
end

-- Shorten text so it fits inside a button.
local function gui_fit_text(text, max_width, font_size)
  local value = tostring(text or "")
  gfx.setfont(1, "Segoe UI", font_size)

  if gfx.measurestr(value) <= max_width then
    return value
  end

  local clipped = value
  while #clipped > 0 and gfx.measurestr(clipped .. "...") > max_width do
    clipped = clipped:sub(1, -2)
  end

  return clipped .. "..."
end

-- Register and draw a clickable button.
local function gui_button(ui, x, y, w, h, label, on_click, options)
  local rect = { x = x, y = y, w = w, h = h, on_click = on_click }
  ui.buttons[#ui.buttons + 1] = rect

  local hovered = gui_point_in_rect(gfx.mouse_x, gfx.mouse_y, rect)
  local active = options and options.active
  local fill = options and options.fill or { 0.20, 0.24, 0.30, 1 }
  local border = options and options.border or { 0.42, 0.48, 0.58, 1 }
  local text_color = options and options.text or { 0.95, 0.96, 0.98, 1 }

  if active then
    fill = { 0.23, 0.47, 0.36, 1 }
    border = { 0.33, 0.69, 0.52, 1 }
  elseif hovered then
    fill = { math.min(fill[1] + 0.05, 1), math.min(fill[2] + 0.05, 1), math.min(fill[3] + 0.05, 1), fill[4] }
  end

  gui_set_color(fill[1], fill[2], fill[3], fill[4])
  gfx.rect(x, y, w, h, 1)
  gui_set_color(border[1], border[2], border[3], border[4])
  gfx.rect(x, y, w, h, 0)

  local font_size = options and options.font_size or 15
  local text = gui_fit_text(label, w - 16, font_size)
  gfx.setfont(1, "Segoe UI", font_size)
  local text_w, text_h = gfx.measurestr(text)
  gui_draw_text(x + (w - text_w) * 0.5, y + (h - text_h) * 0.5, text, font_size, text_color[1], text_color[2], text_color[3], text_color[4])
end

-- Draw a titled section box.
local function gui_section(x, y, w, h, title)
  gui_set_color(0.12, 0.14, 0.18, 1)
  gfx.rect(x, y, w, h, 1)
  gui_set_color(0.28, 0.32, 0.38, 1)
  gfx.rect(x, y, w, h, 0)
  gui_draw_text(x + 12, y + 10, title, 17, 0.93, 0.95, 0.98, 1)
end

-- Draw a labeled value row with a primary edit button.
local function gui_value_row(ui, x, y, label, value, on_click, options)
  local value_w = options and options.value_w or 320
  gui_draw_text(x, y + 6, label, 15, 0.86, 0.88, 0.92, 1)
  gui_button(ui, x + 150, y, value_w, 28, value, on_click, options and options.button_options or nil)

  if options and options.extra_buttons then
    local extra_x = x + 150 + value_w + 8
    for _, button in ipairs(options.extra_buttons) do
      gui_button(ui, extra_x, y, button.w, 28, button.label, button.on_click, button.options)
      extra_x = extra_x + button.w + 8
    end
  end
end

-- Draw a labeled toggle row with multiple option buttons.
local function gui_toggle_row(ui, x, y, label, options, current_value, on_select)
  gui_draw_text(x, y + 6, label, 15, 0.86, 0.88, 0.92, 1)
  local button_x = x + 150
  for _, option in ipairs(options) do
    gui_button(ui, button_x, y, 140, 28, option.label, function()
      on_select(option.value)
    end, { active = option.value == current_value })
    button_x = button_x + 148
  end
end

-- Dispatch mouse clicks to the topmost button under the cursor.
local function gui_dispatch_mouse(ui)
  local mouse_down = (gfx.mouse_cap & 1) == 1
  if ui.ignore_mouse_until_release then
    if not mouse_down then
      ui.ignore_mouse_until_release = false
    end
    ui.prev_mouse_down = mouse_down
    return
  end

  if mouse_down and not ui.prev_mouse_down then
    for index = #ui.buttons, 1, -1 do
      local button = ui.buttons[index]
      if gui_point_in_rect(gfx.mouse_x, gfx.mouse_y, button) then
        button.on_click()
        break
      end
    end
  end
  ui.prev_mouse_down = mouse_down
end

-- Open the legacy multi-dialog editor from the GUI.
local function gui_open_dialog_editor(settings, ui)
  if not prompt_naming_settings(settings) then
    return
  end
  if not prompt_render_settings(settings) then
    return
  end
  if not prompt_output_settings(settings) then
    return
  end
  save_settings(settings)
  ui.current_preset_name = ""
  set_last_preset_name("")
  ui.status_message = "Settings updated from dialog editor."
end

-- Draw the entire Phase 3 GUI.
local function gui_draw(settings, ui)
  ui.buttons = {}

  gui_set_color(0.08, 0.09, 0.11, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gui_draw_text(24, 18, SCRIPT_TITLE, 24, 0.96, 0.98, 1.0, 1)
  gui_draw_text(24, 48, "Prefix and Category accept direct text input. Menus remain available as quick shortcuts.", 14, 0.72, 0.76, 0.82, 1)

  local margin = 20
  local section_w = gfx.w - margin * 2

  gui_section(margin, 78, section_w, 82, "Presets")
  gui_value_row(ui, margin + 18, 118, "Current Preset", ui.current_preset_name ~= "" and ui.current_preset_name or "(unsaved)", function()
    local names = load_preset_names()
    if #names == 0 then
      reaper.ShowMessageBox("No presets have been saved yet.", SCRIPT_TITLE, 0)
      return
    end

    local options = {}
    for _, name in ipairs(names) do
      options[#options + 1] = { value = name, label = name }
    end

    local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, options, ui.current_preset_name)
    if selected and load_named_preset(selected, settings) then
      ui.current_preset_name = selected
      ui.status_message = "Preset loaded: " .. selected
    end
  end, {
    value_w = 360,
    extra_buttons = {
      {
        label = "Load",
        w = 92,
        on_click = function()
          local names = load_preset_names()
          if #names == 0 then
            reaper.ShowMessageBox("No presets have been saved yet.", SCRIPT_TITLE, 0)
            return
          end

          local options = {}
          for _, name in ipairs(names) do
            options[#options + 1] = { value = name, label = name }
          end

          local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, options, ui.current_preset_name)
          if selected and load_named_preset(selected, settings) then
            ui.current_preset_name = selected
            ui.status_message = "Preset loaded: " .. selected
          end
        end,
      },
      {
        label = "Save",
        w = 92,
        on_click = function()
          local suggested = ui.current_preset_name
          if suggested == "" then
            suggested = settings.prefix .. "_" .. settings.category
          end
          local name = prompt_single_text(SCRIPT_TITLE .. " - Save Preset", "Preset Name", suggested)
          if name and save_named_preset(name, settings) then
            ui.current_preset_name = normalize_preset_name(name)
            ui.status_message = "Preset saved: " .. ui.current_preset_name
          end
        end,
      },
      {
        label = "Delete",
        w = 92,
        on_click = function()
          local preset_name = ui.current_preset_name
          if preset_name == "" then
            reaper.ShowMessageBox("Select or save a preset first.", SCRIPT_TITLE, 0)
            return
          end

          local response = reaper.ShowMessageBox("Delete preset '" .. preset_name .. "'?", SCRIPT_TITLE, 4)
          if response == 6 and delete_named_preset(preset_name) then
            ui.current_preset_name = ""
            ui.status_message = "Preset deleted."
          end
        end,
      },
      {
        label = "Defaults",
        w = 100,
        on_click = function()
          reset_settings_to_defaults(settings)
          save_settings(settings)
          ui.current_preset_name = ""
          set_last_preset_name("")
          ui.status_message = "Settings reset to defaults."
        end,
      },
    },
  })

  gui_section(margin, 172, section_w, 174, "Naming Convention")
  gui_value_row(ui, margin + 18, 214, "Prefix", settings.prefix, function()
    local value = prompt_single_text(SCRIPT_TITLE .. " - Prefix", "Prefix", settings.prefix)
    if value and value ~= "" then
      settings.prefix = value
      save_settings(settings)
      ui.status_message = "Prefix updated."
    end
  end, {
    value_w = 320,
    extra_buttons = {
      {
        label = "Examples",
        w = 110,
        on_click = function()
          local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, PREFIX_OPTIONS, settings.prefix)
          if selected then
            settings.prefix = selected
            save_settings(settings)
            ui.status_message = "Prefix updated from examples."
          end
        end,
      },
    },
  })
  gui_value_row(ui, margin + 18, 250, "Category", settings.category, function()
    local value = prompt_single_text(SCRIPT_TITLE .. " - Category", "Category", settings.category)
    if value and value ~= "" then
      settings.category = value
      save_settings(settings)
      ui.status_message = "Category updated."
    end
  end, { value_w = 420 })
  gui_toggle_row(ui, margin + 18, 286, "Case Style", CASE_STYLE_OPTIONS, settings.case_style, function(value)
    settings.case_style = value
    save_settings(settings)
    ui.status_message = "Case style updated."
  end)
  gui_toggle_row(ui, margin + 18, 322, "Naming Source", NAMING_SOURCE_OPTIONS, settings.naming_source, function(value)
    settings.naming_source = value
    save_settings(settings)
    ui.status_message = "Naming source updated."
  end)

  gui_section(margin, 358, section_w, 174, "Render Settings")
  gui_value_row(ui, margin + 18, 400, "Render Scope", get_render_scope_label(settings.render_scope), function()
    local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, RENDER_SCOPE_OPTIONS, settings.render_scope)
    if selected then
      settings.render_scope = selected
      save_settings(settings)
      ui.status_message = "Render scope updated."
    end
  end)
  gui_value_row(ui, margin + 18, 436, "Sample Rate", get_sample_rate_label(settings.sample_rate), function()
    local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, SAMPLE_RATE_OPTIONS, settings.sample_rate)
    if selected then
      settings.sample_rate = selected
      save_settings(settings)
      ui.status_message = "Sample rate updated."
    end
  end)
  gui_value_row(ui, margin + 18, 472, "Bit Depth", get_bit_depth_label(settings.bit_depth), function()
    local selected = show_option_menu(gfx.mouse_x, gfx.mouse_y, BIT_DEPTH_OPTIONS, settings.bit_depth)
    if selected then
      settings.bit_depth = selected
      save_settings(settings)
      ui.status_message = "Bit depth updated."
    end
  end)
  gui_toggle_row(ui, margin + 18, 508, "Channels", CHANNEL_OPTIONS, settings.channels, function(value)
    settings.channels = value
    save_settings(settings)
    ui.status_message = "Channel mode updated."
  end)

  gui_section(margin, 544, section_w, 142, "Output")
  gui_value_row(ui, margin + 18, 586, "Output Path", get_target_output_directory(settings), function()
    local value = prompt_single_text(SCRIPT_TITLE .. " - Output Path", "Output Path", resolve_output_root(settings))
    if value ~= nil then
      settings.output_path = normalize_path(value)
      save_settings(settings)
      ui.status_message = "Output path updated."
    end
  end, {
    value_w = 500,
    extra_buttons = {
      {
        label = "Browse",
        w = 110,
        on_click = function()
          local selected = browse_for_output_path(resolve_output_root(settings))
          if selected then
            settings.output_path = selected
            save_settings(settings)
            ui.status_message = "Output path updated."
          end
        end,
      },
      {
        label = "Default",
        w = 110,
        on_click = function()
          settings.output_path = ""
          save_settings(settings)
          ui.status_message = "Output path reset to project /Renders."
        end,
      },
    },
  })
  gui_toggle_row(ui, margin + 18, 622, "Subfolders", {
    { value = true, label = "By Prefix" },
    { value = false, label = "Flat Folder" },
  }, settings.create_subfolders, function(value)
    settings.create_subfolders = value
    save_settings(settings)
    ui.status_message = "Output folder mode updated."
  end)

  gui_section(margin, 698, section_w, 150, "Post-Processing")
  gui_value_row(ui, margin + 18, 740, "Tail (ms)", tostring(settings.tail_ms), function()
    local value = prompt_single_number(SCRIPT_TITLE .. " - Tail", "Tail (ms)", settings.tail_ms)
    if value ~= nil then
      settings.tail_ms = math.max(0, value)
      save_settings(settings)
      ui.status_message = "Tail updated."
    end
  end)
  gui_toggle_row(ui, margin + 18, 776, "Trim Silence", {
    { value = true, label = "Enabled" },
    { value = false, label = "Disabled" },
  }, settings.trim_silence, function(value)
    settings.trim_silence = value
    save_settings(settings)
    ui.status_message = "Trim silence updated."
  end)
  gui_value_row(ui, margin + 18, 812, "Trim Threshold", tostring(settings.trim_threshold_db) .. " dB", function()
    local value = prompt_single_number(SCRIPT_TITLE .. " - Trim Threshold", "Trim Threshold dB", settings.trim_threshold_db)
    if value ~= nil then
      settings.trim_threshold_db = value
      save_settings(settings)
      ui.status_message = "Trim threshold updated."
    end
  end, {
    value_w = 220,
    extra_buttons = {
      {
        label = "Fade Out",
        w = 110,
        on_click = function()
          local value = prompt_single_number(SCRIPT_TITLE .. " - Fade Out", "Fade Out (ms)", settings.fade_out_ms)
          if value ~= nil then
            settings.fade_out_ms = math.max(0, value)
            save_settings(settings)
            ui.status_message = "Fade out updated."
          end
        end,
      },
      {
        label = tostring(settings.fade_out_ms) .. " ms",
        w = 110,
        on_click = function()
          local value = prompt_single_number(SCRIPT_TITLE .. " - Fade Out", "Fade Out (ms)", settings.fade_out_ms)
          if value ~= nil then
            settings.fade_out_ms = math.max(0, value)
            save_settings(settings)
            ui.status_message = "Fade out updated."
          end
        end,
        options = { active = settings.fade_out_ms > 0 },
      },
      {
        label = settings.open_folder and "Open Folder On" or "Open Folder Off",
        w = 150,
        on_click = function()
          settings.open_folder = not settings.open_folder
          save_settings(settings)
          ui.status_message = "Open folder option updated."
        end,
        options = { active = settings.open_folder },
      },
    },
  })

  gui_set_color(0.15, 0.17, 0.21, 1)
  gfx.rect(0, gfx.h - 74, gfx.w, 74, 1)
  gui_draw_text(24, gfx.h - 60, gui_fit_text(ui.status_message or "Ready.", gfx.w - 420, 14), 14, 0.82, 0.86, 0.92, 1)

  gui_button(ui, gfx.w - 516, gfx.h - 56, 120, 34, "Dialog Edit", function()
    gui_open_dialog_editor(settings, ui)
  end, { fill = { 0.22, 0.24, 0.28, 1 } })
  gui_button(ui, gfx.w - 384, gfx.h - 56, 120, 34, "Preview Names", function()
    local ok, message = preview_from_settings(settings)
    ui.status_message = message
    if ok then
      ui.status_message = message
    end
  end, { fill = { 0.22, 0.31, 0.46, 1 }, border = { 0.38, 0.52, 0.76, 1 } })
  gui_button(ui, gfx.w - 252, gfx.h - 56, 120, 34, "Render All", function()
    local ok, message = render_from_settings(settings)
    ui.status_message = message
    if ok then
      ui.close_requested = true
    end
  end, { fill = { 0.20, 0.45, 0.33, 1 }, border = { 0.35, 0.70, 0.54, 1 } })
  gui_button(ui, gfx.w - 120, gfx.h - 56, 96, 34, "Cancel", function()
    ui.close_requested = true
  end, { fill = { 0.34, 0.19, 0.19, 1 }, border = { 0.64, 0.36, 0.36, 1 } })
end

-- Run the Phase 3 gfx interface until the user closes it.
local function run_gui(settings)
  local ui = {
    buttons = {},
    prev_mouse_down = false,
    ignore_mouse_until_release = false,
    close_requested = false,
    current_preset_name = get_last_preset_name(),
    status_message = "Ready. Adjust settings, preview names, or render.",
  }

  gfx.init(SCRIPT_TITLE, 980, 960, 0)
  ui.prev_mouse_down = (gfx.mouse_cap & 1) == 1
  ui.ignore_mouse_until_release = ui.prev_mouse_down

  local function loop()
    if ui.close_requested then
      gfx.quit()
      return
    end

    local key = gfx.getchar()
    if key < 0 or key == 27 then
      gfx.quit()
      return
    end

    gui_draw(settings, ui)
    gui_dispatch_mouse(ui)
    gfx.update()
    reaper.defer(loop)
  end

  reaper.defer(loop)
end

-- Launch the GUI with the last saved settings.
local function main()
  local settings = load_settings()
  run_gui(settings)
end

main()
