-- Game Sound Recipe Logger v1.0
-- Reaper ReaScript (Lua)
-- Auto-documents game-audio recipe data from folder-based REAPER sessions.
--
-- Usage:
-- [Crawl]   Select a recipe folder track, or an item inside one, then run the script.
-- [Batch]   Crawl every top-level folder recipe in the current project.
-- [Export]  Write Markdown, CSV, and/or JSON recipe documents.
--
-- Phase 3 status:
-- - Implemented: crawl/export flow, batch crawl, recipe book export, notes/tags,
--   gfx UI, rebuild from JSON, recipe diff, custom library patterns.
-- - Remaining future ideas: richer compare/rebuild UI, deeper plugin-specific restore rules.
--
-- Requirements: REAPER v7.0+
-- Related scripts: GameSoundLayeringTemplate.lua,
--                  GameSoundVariationGenerator.lua,
--                  GameSoundBatchRenderer.lua,
--                  GameSoundMetadataTagger.lua

local SCRIPT_TITLE = "Game Sound Recipe Logger v1.0"
local EXT_SECTION = "GameSoundRecipeLogger"
local REPORT_WIDTH = 78
local REAPER_COLOR_FLAG = 0x1000000

local DEFAULTS = {
  mode = "single",
  source_scope = "selected_folder",
  output_format = "markdown",
  output_folder = "",
  export_console = true,
  export_markdown = true,
  export_csv = false,
  export_json = false,
  include_source_info = true,
  include_fx_parameters = true,
  verbose_fx_parameters = false,
  include_file_paths = true,
  include_sends = true,
  add_notes_prompt = true,
  auto_detect_library = true,
  auto_tag_keywords = false,
  prefix_filter = "",
  rebuild_json_path = "",
  compare_old_json_path = "",
  compare_new_json_path = "",
  rebuild_restore_fx = true,
  rebuild_restore_master_fx = true,
  rebuild_restore_sends = true,
  rebuild_create_missing_send_tracks = true,
  custom_library_patterns = "",
}

local KNOWN_LIBRARY_PATTERNS = {
  { "Boom Library",       { "boom library", "boomlibrary", "boomlib", "/boom/", "\\boom\\" } },
  { "Sound Ideas",        { "soundideas", "sound ideas" } },
  { "Sonniss GDC",        { "sonniss", "gdc" } },
  { "Pro Sound Effects",  { "pro sound effects", "prosoundeffects", "pse" } },
  { "Krotos",             { "krotos" } },
  { "Artlist",            { "artlist" } },
  { "Epidemic Sound",     { "epidemic" } },
  { "Splice",             { "splice" } },
  { "Freesound",          { "freesound" } },
  { "Personal Recording", { "recording", "field_rec", "fieldrec", "foley", "captures" } },
  { "Synthesized",        { "synth", "generated", "procedural", "designed" } },
}

local AUTO_TAG_KEYWORDS = {
  SFX_Weapon = { "weapon", "combat", "attack", "impact" },
  SFX_Footstep = { "footstep", "foley", "movement", "surface" },
  SFX_Explosion = { "explosion", "blast", "debris" },
  SFX_Impact = { "impact", "hit", "collision" },
  SFX_Creature = { "creature", "vocal", "monster" },
  UI_Menu = { "ui", "menu", "interface" },
  UI_Button = { "ui", "button", "click" },
  AMB_Nature = { "ambience", "nature", "environment" },
  AMB_Indoor = { "ambience", "indoor", "room" },
  MUS_BGM = { "music", "bgm", "score" },
  VO_Dialogue = { "voice", "dialogue", "speech" },
  FOL_Cloth = { "foley", "cloth", "fabric" },
}

local CUSTOM_LIBRARY_PATTERNS = {}

local FX_NAME_PREFIXES = {
  "VST3: ",
  "VSTi: ",
  "VST: ",
  "JS: ",
  "AU: ",
  "CLAPi: ",
  "CLAP: ",
  "LV2i: ",
  "LV2: ",
}

local FADE_SHAPES = {
  [0] = "linear",
  [1] = "shape 1",
  [2] = "shape 2",
  [3] = "shape 3",
  [4] = "shape 4",
  [5] = "shape 5",
  [6] = "shape 6",
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function clear_console()
  if reaper.ClearConsole then
    reaper.ClearConsole()
  end
end

local function show_error(message)
  local text = tostring(message or "Unknown error.")
  log_line("")
  log_line("[Error] " .. text)
  reaper.ShowMessageBox(text, SCRIPT_TITLE, 0)
end

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
end

local function is_blank(value)
  return trim_string(value) == ""
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

local function parse_mode(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "single" or lowered == "s" then
    return "single"
  end
  if lowered == "batch" or lowered == "b" then
    return "batch"
  end
  if lowered == "rebuild" or lowered == "r" then
    return "rebuild"
  end
  if lowered == "compare" or lowered == "diff" or lowered == "c" then
    return "compare"
  end
  return default_value
end

local function parse_output_format(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "console" then
    return "console"
  end
  if lowered == "markdown" or lowered == "md" then
    return "markdown"
  end
  if lowered == "csv" then
    return "csv"
  end
  if lowered == "json" then
    return "json"
  end
  if lowered == "all" then
    return "all"
  end
  return default_value
end

local function parse_source_scope(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "selected" or lowered == "selected_folder" or lowered == "selected_folder_track" then
    return "selected_folder"
  end
  if lowered == "all" or lowered == "all_folders" or lowered == "all_folder_tracks" then
    return "all_folder_tracks"
  end
  return default_value
end

local function apply_export_flags_from_output_format(settings)
  local output_format = parse_output_format(settings.output_format, DEFAULTS.output_format)
  settings.output_format = output_format
  settings.export_console = true
  settings.export_markdown = false
  settings.export_csv = false
  settings.export_json = false

  if output_format == "markdown" then
    settings.export_markdown = true
  elseif output_format == "csv" then
    settings.export_csv = true
  elseif output_format == "json" then
    settings.export_json = true
  elseif output_format == "all" then
    settings.export_markdown = true
    settings.export_csv = true
    settings.export_json = true
  end
end

local function derive_output_format_from_flags(settings)
  local console_on = settings.export_console ~= false
  local markdown_on = settings.export_markdown == true
  local csv_on = settings.export_csv == true
  local json_on = settings.export_json == true

  if console_on and markdown_on and csv_on and json_on then
    return "all"
  end
  if console_on and markdown_on and not csv_on and not json_on then
    return "markdown"
  end
  if console_on and csv_on and not markdown_on and not json_on then
    return "csv"
  end
  if console_on and json_on and not markdown_on and not csv_on then
    return "json"
  end
  if console_on and not markdown_on and not csv_on and not json_on then
    return "console"
  end
  if markdown_on and csv_on and json_on then
    return "all"
  end
  if markdown_on then
    return "markdown"
  end
  if csv_on then
    return "csv"
  end
  if json_on then
    return "json"
  end
  return "console"
end

local function has_any_output_enabled(settings)
  return settings.export_console or settings.export_markdown or settings.export_csv or settings.export_json
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

local function dirname(path)
  local normalized = normalize_path(path)
  local directory = normalized:match("^(.*)/[^/]+$")
  return directory or ""
end

local function strip_extension(path)
  return tostring(path or ""):gsub("%.[^%.\\/]+$", "")
end

local function is_absolute_path(path)
  local value = trim_string(path)
  return value:match("^%a:[/\\]") ~= nil or value:match("^[/\\][/\\]") ~= nil
end

local function ensure_directory(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end
  reaper.RecursiveCreateDirectory(normalized, 0)
  return true
end

local function sanitize_filename(value)
  local sanitized = trim_string(value)
  sanitized = sanitized:gsub("[%c]", "")
  sanitized = sanitized:gsub("[\\/:*?\"<>|]", "_")
  sanitized = sanitized:gsub("%s+", "_")
  sanitized = sanitized:gsub("_+", "_")
  sanitized = sanitized:gsub("^_+", "")
  sanitized = sanitized:gsub("_+$", "")
  if sanitized == "" then
    return "Recipe"
  end
  return sanitized
end

local function get_project_file_path()
  local _, project_path = reaper.EnumProjects(-1, "")
  project_path = trim_string(project_path)
  if project_path ~= "" then
    return normalize_path(project_path)
  end
  return join_paths(reaper.GetProjectPath(""), "UnsavedProject.rpp")
end

local function get_project_name()
  local project_path = get_project_file_path()
  local basename = project_path:match("([^/]+)$") or project_path
  basename = basename:gsub("%.rpp%-bak$", "")
  basename = basename:gsub("%.rpp$", "")
  basename = trim_string(basename)
  if basename == "" then
    return "UnsavedProject"
  end
  return basename
end

local function get_default_output_dir()
  return join_paths(reaper.GetProjectPath(""), "Recipes")
end

local function resolve_output_dir(configured_path)
  local configured = trim_string(configured_path)
  if configured == "" then
    return get_default_output_dir()
  end
  if is_absolute_path(configured) then
    return normalize_path(configured)
  end
  return join_paths(reaper.GetProjectPath(""), configured)
end

local function copy_table(value)
  if type(value) ~= "table" then
    return value
  end

  local copied = {}
  for key, nested_value in pairs(value) do
    copied[key] = copy_table(nested_value)
  end
  return copied
end

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

local function is_array_table(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      return false
    end
    count = count + 1
  end

  return count == #value
end

local function repeat_char(char, count)
  return string.rep(char or " ", math.max(0, tonumber(count) or 0))
end

local function truncate_string(text, width)
  local value = tostring(text or "")
  if #value <= width then
    return value
  end
  if width <= 3 then
    return value:sub(1, width)
  end
  return value:sub(1, width - 3) .. "..."
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
  value = tonumber(value) or 0
  local power = 10 ^ (decimals or 0)
  if value >= 0 then
    return math.floor(value * power + 0.5) / power
  end
  return math.ceil(value * power - 0.5) / power
end

local function log10(value)
  return math.log(value) / math.log(10)
end

local function linear_to_db(linear_value)
  local safe = math.abs(tonumber(linear_value) or 0.0)
  if safe <= 1e-12 then
    return -150.0
  end
  return 20.0 * log10(safe)
end

local function db_to_linear(db_value)
  return 10 ^ ((tonumber(db_value) or 0.0) / 20.0)
end

local function format_db(db_value)
  if db_value == nil then
    return "N/A"
  end
  if db_value <= -149.9 then
    return "-inf dB"
  end
  return string.format("%.1f dB", db_value)
end

local function format_seconds(seconds, unit_override)
  local value = tonumber(seconds) or 0
  if unit_override == "qn" then
    return string.format("%.3f QN", value)
  end
  return string.format("%.3fs", value)
end

local function format_short_duration(seconds)
  local value = tonumber(seconds) or 0
  if math.abs(value) < 1.0 then
    return string.format("%.0fms", value * 1000.0)
  end
  return string.format("%.3fs", value)
end

local function format_pan_short(pan_value)
  local pan = tonumber(pan_value) or 0
  if math.abs(pan) < 0.0005 then
    return "C"
  end

  local percent = math.abs(pan) * 100.0
  if pan < 0 then
    return string.format("L%.0f", percent)
  end
  return string.format("R%.0f", percent)
end

local function format_pan_verbose(pan_value)
  local pan = tonumber(pan_value) or 0
  if math.abs(pan) < 0.0005 then
    return "Center"
  end

  local percent = math.abs(pan) * 100.0
  if pan < 0 then
    return string.format("Left %.0f%%", percent)
  end
  return string.format("Right %.0f%%", percent)
end

local function format_channels(channel_count)
  local channels = tonumber(channel_count) or 0
  if channels == 1 then
    return "Mono"
  end
  if channels == 2 then
    return "Stereo"
  end
  if channels <= 0 then
    return "Unknown"
  end
  return string.format("%d ch", channels)
end

local function describe_pan_law(raw_value)
  local value = tonumber(raw_value)
  if value == nil or value < 0 then
    return "Project default"
  end
  if value > 0 and value <= 1.0 then
    return format_db(linear_to_db(value))
  end
  if value == 0 then
    return "-inf dB"
  end
  return string.format("%.3f (compensated)", value)
end

local function classify_fade_shape(shape_index, curvature)
  local label = FADE_SHAPES[math.floor(tonumber(shape_index) or 0)] or ("shape " .. tostring(shape_index))
  local curve = tonumber(curvature) or 0
  if math.abs(curve) >= 0.001 then
    return string.format("%s (curve %.2f)", label, curve)
  end
  return label
end

local function hex_to_native_color(color_hex)
  local hex = trim_string(color_hex)
  local red, green, blue = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
  if not red then
    return nil
  end
  local r = tonumber(red, 16) or 0
  local g = tonumber(green, 16) or 0
  local b = tonumber(blue, 16) or 0
  return reaper.ColorToNative(r, g, b) + REAPER_COLOR_FLAG
end

local function escape_markdown_cell(value)
  local text = tostring(value or "")
  text = text:gsub("\r\n", "\n")
  text = text:gsub("\r", "\n")
  text = text:gsub("\n", "<br>")
  text = text:gsub("|", "\\|")
  return text
end

local function escape_inline_code(value)
  return tostring(value or ""):gsub("`", "'")
end

local function csv_escape(value)
  local text = tostring(value or "")
  if text:find("[\",\r\n]") then
    text = text:gsub("\"", "\"\"")
    return "\"" .. text .. "\""
  end
  return text
end

local function parse_tags(value)
  local tags = {}
  local seen = {}

  for raw_tag in tostring(value or ""):gmatch("[^,]+") do
    local tag = trim_string(raw_tag)
    if tag ~= "" then
      local key = tag:lower()
      if not seen[key] then
        seen[key] = true
        tags[#tags + 1] = tag
      end
    end
  end

  return tags
end

local function merge_tags(base_tags, extra_tags)
  local merged = {}
  local seen = {}

  for _, tag in ipairs(base_tags or {}) do
    local clean = trim_string(tag)
    if clean ~= "" then
      local key = clean:lower()
      if not seen[key] then
        seen[key] = true
        merged[#merged + 1] = clean
      end
    end
  end

  for _, tag in ipairs(extra_tags or {}) do
    local clean = trim_string(tag)
    if clean ~= "" then
      local key = clean:lower()
      if not seen[key] then
        seen[key] = true
        merged[#merged + 1] = clean
      end
    end
  end

  return merged
end

local function build_auto_tags(recipe_name)
  local tags = {}
  local normalized = tostring(recipe_name or "")
  local upper_name = normalized:upper()

  for prefix, keyword_tags in pairs(AUTO_TAG_KEYWORDS) do
    if upper_name:find(prefix:upper(), 1, true) then
      tags = merge_tags(tags, keyword_tags)
    end
  end

  for token in normalized:gmatch("[A-Za-z0-9]+") do
    local lowered = token:lower()
    if #lowered >= 4 and lowered ~= "sfx" and lowered ~= "amb" and lowered ~= "mus" and lowered ~= "ui" and lowered ~= "vo" and lowered ~= "fol" then
      tags = merge_tags(tags, { lowered })
    end
  end

  return tags
end

local function serialize_custom_library_patterns(patterns)
  local entries = {}

  for _, entry in ipairs(patterns or {}) do
    local name = trim_string(entry.name)
    local pattern_list = {}

    for _, pattern in ipairs(entry.patterns or {}) do
      local clean = trim_string(pattern)
      if clean ~= "" then
        pattern_list[#pattern_list + 1] = clean
      end
    end

    if name ~= "" and #pattern_list > 0 then
      entries[#entries + 1] = name .. "=" .. table.concat(pattern_list, ";")
    end
  end

  return table.concat(entries, "||")
end

local function parse_custom_library_patterns(blob)
  local patterns = {}
  local text = tostring(blob or "")
  local entries = split_delimited(text, "||", 1)

  for _, entry_text in ipairs(entries) do
    local name, pattern_text = entry_text:match("^%s*(.-)%s*=%s*(.-)%s*$")
    if name and pattern_text and name ~= "" and pattern_text ~= "" then
      local entry = { name = name, patterns = {} }
      for pattern in pattern_text:gmatch("[^;]+") do
        local clean = trim_string(pattern)
        if clean ~= "" then
          entry.patterns[#entry.patterns + 1] = clean:lower()
        end
      end
      if #entry.patterns > 0 then
        patterns[#patterns + 1] = entry
      end
    end
  end

  return patterns
end

local function refresh_custom_library_patterns(blob)
  CUSTOM_LIBRARY_PATTERNS = parse_custom_library_patterns(blob)
end

local function get_track_name(track)
  if not track then
    return ""
  end
  local _, name = reaper.GetTrackName(track, "")
  return trim_string(name)
end

local function get_take_name(take)
  if not take then
    return ""
  end
  return trim_string(reaper.GetTakeName(take) or "")
end

local function is_folder_track(track)
  if not track then
    return false
  end
  return (reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") or 0) > 0
end

local function get_top_recipe_folder(track)
  if not track then
    return nil
  end

  local candidate = track
  local parent = reaper.GetParentTrack(candidate)
  while parent do
    candidate = parent
    parent = reaper.GetParentTrack(candidate)
  end

  if is_folder_track(candidate) then
    return candidate
  end

  if is_folder_track(track) then
    return track
  end

  return nil
end

local function find_selected_recipe_folder()
  local selected_item_count = reaper.CountSelectedMediaItems(0)
  if selected_item_count > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    local track = reaper.GetMediaItemTrack(item)
    local folder = get_top_recipe_folder(track)
    if folder then
      return folder
    end
  end

  local selected_track_count = reaper.CountSelectedTracks(0)
  for index = 0, selected_track_count - 1 do
    local track = reaper.GetSelectedTrack(0, index)
    local folder = get_top_recipe_folder(track)
    if folder then
      return folder
    end
  end

  return nil
end

local function resolve_existing_file_path(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return ""
  end

  if reaper.file_exists(normalized) then
    return normalized
  end

  if not is_absolute_path(normalized) then
    local candidate = join_paths(reaper.GetProjectPath(""), normalized)
    if reaper.file_exists(candidate) then
      return normalize_path(candidate)
    end
  end

  return normalized
end

local function read_u16le(data, start_index)
  local byte1, byte2 = data:byte(start_index, start_index + 1)
  if not byte2 then
    return nil
  end
  return byte1 + byte2 * 256
end

local function read_u32le(data, start_index)
  local byte1, byte2, byte3, byte4 = data:byte(start_index, start_index + 3)
  if not byte4 then
    return nil
  end
  return byte1 + byte2 * 256 + byte3 * 65536 + byte4 * 16777216
end

local function read_u16be(data, start_index)
  local byte1, byte2 = data:byte(start_index, start_index + 1)
  if not byte2 then
    return nil
  end
  return byte1 * 256 + byte2
end

local function read_u32be(data, start_index)
  local byte1, byte2, byte3, byte4 = data:byte(start_index, start_index + 3)
  if not byte4 then
    return nil
  end
  return byte1 * 16777216 + byte2 * 65536 + byte3 * 256 + byte4
end

local function parse_wav_bit_depth(data)
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
    return nil
  end

  local position = 13
  while position + 7 <= #data do
    local chunk_id = data:sub(position, position + 3)
    local chunk_size = read_u32le(data, position + 4)
    if not chunk_size then
      break
    end

    if chunk_id == "fmt " and chunk_size >= 16 then
      return read_u16le(data, position + 8 + 14)
    end

    position = position + 8 + chunk_size
    if chunk_size % 2 == 1 then
      position = position + 1
    end
  end

  return nil
end

local function parse_aiff_bit_depth(data)
  if data:sub(1, 4) ~= "FORM" then
    return nil
  end

  local form_type = data:sub(9, 12)
  if form_type ~= "AIFF" and form_type ~= "AIFC" then
    return nil
  end

  local position = 13
  while position + 7 <= #data do
    local chunk_id = data:sub(position, position + 3)
    local chunk_size = read_u32be(data, position + 4)
    if not chunk_size then
      break
    end

    if chunk_id == "COMM" and chunk_size >= 18 then
      return read_u16be(data, position + 8 + 6)
    end

    position = position + 8 + chunk_size
    if chunk_size % 2 == 1 then
      position = position + 1
    end
  end

  return nil
end

local function detect_audio_bit_depth(header_data)
  if type(header_data) ~= "string" or header_data == "" then
    return nil
  end

  local wav_depth = parse_wav_bit_depth(header_data)
  if wav_depth then
    return wav_depth
  end

  local aiff_depth = parse_aiff_bit_depth(header_data)
  if aiff_depth then
    return aiff_depth
  end

  return nil
end

local function inspect_file_on_disk(path)
  local info = {
    filepath = resolve_existing_file_path(path),
    file_exists = false,
    file_size_kb = nil,
    bit_depth = nil,
    extension = "",
  }

  if info.filepath == "" or not reaper.file_exists(info.filepath) then
    return info
  end

  info.file_exists = true
  info.extension = (info.filepath:match("%.([^%.\\/]+)$") or ""):lower()

  local handle = io.open(info.filepath, "rb")
  if not handle then
    return info
  end

  local file_size = handle:seek("end") or 0
  info.file_size_kb = round_to(file_size / 1024.0, 1)
  handle:seek("set", 0)
  local header = handle:read(131072) or ""
  handle:close()

  info.bit_depth = detect_audio_bit_depth(header)
  return info
end

local function guess_library_name(filepath, source_type)
  local normalized = normalize_path(filepath):lower()
  if normalized ~= "" then
    for _, library in ipairs(KNOWN_LIBRARY_PATTERNS) do
      local library_name = library[1]
      local patterns = library[2]
      for _, pattern in ipairs(patterns) do
        if normalized:find(pattern, 1, true) then
          return library_name
        end
      end
    end

    for _, library in ipairs(CUSTOM_LIBRARY_PATTERNS) do
      for _, pattern in ipairs(library.patterns or {}) do
        if normalized:find(pattern, 1, true) then
          return library.name
        end
      end
    end

    local parent_dir = normalized:match("([^/]+)/[^/]+$")
    if parent_dir and parent_dir ~= "" then
      return parent_dir
    end
  end

  local type_name = trim_string(source_type)
  if type_name ~= "" then
    return type_name
  end

  return "Unknown"
end

local function strip_fx_prefix(fx_name)
  local text = trim_string(fx_name)
  for _, prefix in ipairs(FX_NAME_PREFIXES) do
    if text:sub(1, #prefix):lower() == prefix:lower() then
      return trim_string(text:sub(#prefix + 1))
    end
  end
  return text
end

local function guess_plugin_type(fx_name)
  local text = trim_string(fx_name)
  local lowered = text:lower()
  if lowered:find("^vst3:") then
    return "VST3"
  end
  if lowered:find("^vst") then
    return "VST"
  end
  if lowered:find("^js:") then
    return "JS"
  end
  if lowered:find("^au:") then
    return "AU"
  end
  if lowered:find("^clap") then
    return "CLAP"
  end
  if lowered:find("^lv2") then
    return "LV2"
  end
  return "Unknown"
end

local function decode_pitch_mode(pitch_mode_value)
  local value = math.floor(tonumber(pitch_mode_value) or -1)
  if value < 0 then
    return "Project default"
  end

  local mode = math.floor(value / 65536)
  local submode = value % 65536
  local ok, mode_name = reaper.EnumPitchShiftModes(mode)
  mode_name = trim_string(mode_name)

  if not ok or mode_name == "" then
    return tostring(value)
  end

  local submode_name = trim_string(reaper.EnumPitchShiftSubModes(mode, submode) or "")
  if submode_name ~= "" then
    return mode_name .. " / " .. submode_name
  end

  return mode_name
end

local function summarize_first_params(parameters, max_count)
  local parts = {}
  for _, parameter in ipairs(parameters) do
    if trim_string(parameter.display) ~= "" then
      parts[#parts + 1] = parameter.name .. "=" .. parameter.display
    elseif parameter.normalized_value ~= nil then
      parts[#parts + 1] = parameter.name .. "=" .. string.format("%.3f", parameter.normalized_value)
    end

    if #parts >= max_count then
      break
    end
  end

  if #parts == 0 then
    return "Default"
  end

  return table.concat(parts, ", ")
end

local function find_param(parameters, tokens)
  for _, parameter in ipairs(parameters) do
    local lowered = parameter.name:lower()
    local matched = true
    for _, token in ipairs(tokens) do
      if not lowered:find(token, 1, true) then
        matched = false
        break
      end
    end
    if matched then
      return parameter
    end
  end
  return nil
end

local function generate_reaeq_summary(parameters)
  local band_data = {}

  for _, parameter in ipairs(parameters) do
    local band_index, field = parameter.name:match("[Bb]and%s+(%d+)%s+(.+)")
    if band_index and field then
      band_index = tonumber(band_index)
      field = trim_string(field):lower()
      band_data[band_index] = band_data[band_index] or {}
      band_data[band_index][field] = parameter
    end
  end

  local parts = {}
  for band_index = 1, 32 do
    local band = band_data[band_index]
    if band then
      local enabled = band["enabled"]
      local enabled_text = enabled and trim_string(enabled.display):lower() or ""
      local is_enabled = enabled == nil or (enabled_text ~= "off" and enabled_text ~= "disabled")

      if is_enabled then
        local type_param = band["type"]
        local freq_param = band["freq"] or band["frequency"]
        local gain_param = band["gain"]
        local q_param = band["q"] or band["bandwidth"]

        local type_text = type_param and trim_string(type_param.display) or ""
        local freq_text = freq_param and trim_string(freq_param.display) or ""
        local gain_text = gain_param and trim_string(gain_param.display) or ""
        local q_text = q_param and trim_string(q_param.display) or ""

        if freq_text ~= "" then
          local lowered_type = type_text:lower()
          if lowered_type:find("pass", 1, true) or lowered_type:find("shelf", 1, true) then
            parts[#parts + 1] = trim_string(type_text .. " " .. freq_text)
          elseif gain_text ~= "" and gain_text ~= "0.0 dB" and gain_text ~= "0 dB" then
            parts[#parts + 1] = trim_string(freq_text .. " " .. gain_text)
          elseif q_text ~= "" then
            parts[#parts + 1] = trim_string(freq_text .. " Q=" .. q_text)
          else
            parts[#parts + 1] = freq_text
          end
        end
      end
    end
  end

  if #parts == 0 then
    return "EQ: " .. summarize_first_params(parameters, 3)
  end

  return "EQ: " .. table.concat(parts, ", ")
end

local function generate_reacomp_summary(parameters)
  local threshold = find_param(parameters, { "thresh" })
  local ratio = find_param(parameters, { "ratio" })
  local attack = find_param(parameters, { "attack" })
  local release = find_param(parameters, { "release" })

  return string.format(
    "Comp: Thr=%s Ratio=%s Atk=%s Rel=%s",
    threshold and trim_string(threshold.display) or "?",
    ratio and trim_string(ratio.display) or "?",
    attack and trim_string(attack.display) or "?",
    release and trim_string(release.display) or "?"
  )
end

local function generate_reverb_summary(parameters)
  local size = find_param(parameters, { "room" }) or find_param(parameters, { "size" })
  local damp = find_param(parameters, { "damp" })
  local wet = find_param(parameters, { "wet" })
  local parts = {}

  if size and trim_string(size.display) ~= "" then
    parts[#parts + 1] = "Size " .. trim_string(size.display)
  end
  if damp and trim_string(damp.display) ~= "" then
    parts[#parts + 1] = "Damp " .. trim_string(damp.display)
  end
  if wet and trim_string(wet.display) ~= "" then
    parts[#parts + 1] = "Wet " .. trim_string(wet.display)
  end

  if #parts == 0 then
    return "Reverb: " .. summarize_first_params(parameters, 2)
  end
  return "Reverb: " .. table.concat(parts, ", ")
end

local function generate_delay_summary(parameters)
  local time = find_param(parameters, { "time" }) or find_param(parameters, { "length" }) or find_param(parameters, { "delay" })
  local feedback = find_param(parameters, { "feedback" })
  local wet = find_param(parameters, { "wet" })
  local parts = {}

  if time and trim_string(time.display) ~= "" then
    parts[#parts + 1] = "Time " .. trim_string(time.display)
  end
  if feedback and trim_string(feedback.display) ~= "" then
    parts[#parts + 1] = "Feedback " .. trim_string(feedback.display)
  end
  if wet and trim_string(wet.display) ~= "" then
    parts[#parts + 1] = "Wet " .. trim_string(wet.display)
  end

  if #parts == 0 then
    return "Delay: " .. summarize_first_params(parameters, 2)
  end
  return "Delay: " .. table.concat(parts, ", ")
end

local function generate_fx_summary(fx_name, parameters)
  local lowered = trim_string(fx_name):lower()

  if lowered:find("reaeq", 1, true) then
    return generate_reaeq_summary(parameters)
  end
  if lowered:find("reacomp", 1, true) then
    return generate_reacomp_summary(parameters)
  end
  if lowered:find("reaverb", 1, true) or lowered:find("verb", 1, true) then
    return generate_reverb_summary(parameters)
  end
  if lowered:find("readelay", 1, true) or lowered:find("delay", 1, true) then
    return generate_delay_summary(parameters)
  end

  return summarize_first_params(parameters, 3)
end

local function collect_fx_chain(track)
  local chain = {}
  local fx_count = reaper.TrackFX_GetCount(track)

  for fx_index = 0, fx_count - 1 do
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index)
    local _, preset_name = reaper.TrackFX_GetPreset(track, fx_index)
    local wet_param_index = tonumber(reaper.TrackFX_GetParamFromIdent(track, fx_index, ":wet")) or -1

    local fx_entry = {
      index = fx_index,
      name = trim_string(fx_name),
      short_name = strip_fx_prefix(fx_name),
      plugin_type = guess_plugin_type(fx_name),
      enabled = reaper.TrackFX_GetEnabled(track, fx_index),
      offline = reaper.TrackFX_GetOffline(track, fx_index),
      wet_dry = wet_param_index >= 0 and round_to(reaper.TrackFX_GetParamNormalized(track, fx_index, wet_param_index), 6) or 1.0,
      preset_name = trim_string(preset_name),
      parameters = {},
      guid = trim_string(reaper.TrackFX_GetFXGUID(track, fx_index) or ""),
    }

    local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
    for param_index = 0, param_count - 1 do
      local raw_value, min_value, max_value = reaper.TrackFX_GetParam(track, fx_index, param_index)
      local normalized_value = reaper.TrackFX_GetParamNormalized(track, fx_index, param_index)
      local _, param_name = reaper.TrackFX_GetParamName(track, fx_index, param_index)
      local _, display_value = reaper.TrackFX_GetFormattedParamValue(track, fx_index, param_index)
      local _, param_ident = reaper.TrackFX_GetParamIdent(track, fx_index, param_index)

      fx_entry.parameters[#fx_entry.parameters + 1] = {
        index = param_index,
        name = trim_string(param_name),
        ident = trim_string(param_ident),
        normalized_value = round_to(normalized_value, 6),
        raw_value = round_to(raw_value, 6),
        min_value = round_to(min_value, 6),
        max_value = round_to(max_value, 6),
        display = trim_string(display_value),
      }
    end

    fx_entry.summary = generate_fx_summary(fx_entry.name, fx_entry.parameters)
    chain[#chain + 1] = fx_entry
  end

  return chain
end

local function collect_sends(track)
  local sends = {}
  local send_count = reaper.GetTrackNumSends(track, 0)
  local hw_output_count = reaper.GetTrackNumSends(track, 1)

  for send_index = 0, send_count - 1 do
    local _, send_name = reaper.GetTrackSendName(track, hw_output_count + send_index)
    local send_volume = reaper.GetTrackSendInfo_Value(track, 0, send_index, "D_VOL")
    local send_pan = reaper.GetTrackSendInfo_Value(track, 0, send_index, "D_PAN")
    local send_mute = reaper.GetTrackSendInfo_Value(track, 0, send_index, "B_MUTE") == 1
    local send_phase = reaper.GetTrackSendInfo_Value(track, 0, send_index, "B_PHASE") == 1
    local dest_name = trim_string(send_name)

    if dest_name == "" then
      dest_name = string.format("Send %d", send_index + 1)
    end

    sends[#sends + 1] = {
      index = send_index,
      dest_track_name = dest_name,
      send_volume_db = round_to(linear_to_db(send_volume), 1),
      send_pan = round_to(send_pan, 3),
      mute = send_mute,
      phase_invert = send_phase,
    }
  end

  return sends
end

local function collect_track_state(track)
  local track_name = get_track_name(track)
  local track_volume = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
  local track_pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN")
  local pan_law = reaper.GetMediaTrackInfo_Value(track, "D_PANLAW")
  local custom_color = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR") or 0)
  local color_without_flag = custom_color % REAPER_COLOR_FLAG
  local color_hex = ""

  if color_without_flag ~= 0 then
    local red, green, blue = reaper.ColorFromNative(color_without_flag)
    color_hex = string.format("#%02X%02X%02X", red, green, blue)
  end

  return {
    name = track_name,
    track_index = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0),
    volume_db = round_to(linear_to_db(track_volume), 1),
    pan = round_to(track_pan, 3),
    pan_law = round_to(pan_law, 6),
    pan_law_display = describe_pan_law(pan_law),
    mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1,
    solo = (reaper.GetMediaTrackInfo_Value(track, "I_SOLO") or 0) ~= 0,
    phase_invert = reaper.GetMediaTrackInfo_Value(track, "B_PHASE") == 1,
    color = color_hex,
  }
end

local function collect_source_state(take)
  local active_source = reaper.GetMediaItemTake_Source(take)
  local root_source = active_source
  local is_section, section_offset, section_length, is_reversed = reaper.PCM_Source_GetSectionInfo(active_source)

  while true do
    local parent_source = reaper.GetMediaSourceParent(root_source)
    if not parent_source then
      break
    end
    root_source = parent_source
  end

  local source_type = trim_string(reaper.GetMediaSourceType(root_source) or "")
  local filepath = trim_string(reaper.GetMediaSourceFileName(root_source) or "")
  filepath = resolve_existing_file_path(filepath)
  local file_info = inspect_file_on_disk(filepath)
  local source_length, length_is_qn = reaper.GetMediaSourceLength(root_source)
  local filename = filepath:match("([^/\\]+)$") or trim_string(source_type)

  if filename == "" then
    filename = "In-Project Source"
  end

  return {
    filename = filename,
    filepath = filepath,
    file_exists = file_info.file_exists,
    file_size_kb = file_info.file_size_kb,
    sample_rate = tonumber(reaper.GetMediaSourceSampleRate(root_source) or 0) or 0,
    bit_depth = file_info.bit_depth,
    channels = tonumber(reaper.GetMediaSourceNumChannels(root_source) or 0) or 0,
    source_length = round_to(source_length or 0, 6),
    source_length_is_qn = length_is_qn or false,
    library_name = guess_library_name(filepath, source_type),
    source_type = source_type,
    section_offset = is_section and round_to(section_offset or 0, 6) or 0,
    section_length = is_section and round_to(section_length or 0, 6) or 0,
    is_reversed = is_section and (is_reversed or false) or false,
  }
end

local function format_used_range(start_value, end_value, is_reversed, is_qn)
  local minimum = round_to(math.min(start_value, end_value), 3)
  local maximum = round_to(math.max(start_value, end_value), 3)
  local unit = is_qn and " QN" or "s"
  local reversed_text = is_reversed and " (reversed)" or ""
  return string.format("%.3f%s ~ %.3f%s%s", minimum, unit, maximum, unit, reversed_text)
end

local function collect_item_state(item, take, source_info)
  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
  local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
  local source_span = math.abs(length * playrate)
  local used_start = (source_info.section_offset or 0) + offset
  local used_end = used_start + source_span

  if source_info.is_reversed then
    local effective_section_length = source_info.section_length
    if effective_section_length == nil or effective_section_length <= 0 then
      effective_section_length = source_info.source_length or 0
    end
    local section_end = (source_info.section_offset or 0) + effective_section_length
    used_end = section_end - offset
    used_start = used_end - source_span
  end

  local fade_in_length = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN") or 0
  local fade_out_length = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN") or 0
  local fade_in_shape_index = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE") or 0)
  local fade_out_shape_index = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE") or 0)
  local fade_in_curve = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR") or 0
  local fade_out_curve = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR") or 0

  return {
    position = round_to(position, 6),
    length = round_to(length, 6),
    offset = round_to(offset, 6),
    source_time_span = round_to(source_span, 6),
    used_source_start = round_to(used_start, 6),
    used_source_end = round_to(used_end, 6),
    used_range = format_used_range(used_start, used_end, source_info.is_reversed, source_info.source_length_is_qn),
    fade_in_length = round_to(fade_in_length, 6),
    fade_out_length = round_to(fade_out_length, 6),
    fade_in_shape = classify_fade_shape(fade_in_shape_index, fade_in_curve),
    fade_out_shape = classify_fade_shape(fade_out_shape_index, fade_out_curve),
    fade_in_shape_index = fade_in_shape_index,
    fade_out_shape_index = fade_out_shape_index,
    fade_in_curve = round_to(fade_in_curve, 3),
    fade_out_curve = round_to(fade_out_curve, 3),
  }
end

local function collect_take_state(take, source_info)
  local raw_take_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL") or 1.0
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0
  local pitch_semitones = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH") or 0.0
  local start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0.0
  local preserve_pitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH") == 1
  local pitch_mode = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE") or -1

  return {
    name = get_take_name(take),
    pitch_semitones = round_to(pitch_semitones, 3),
    pitch_cents = round_to(pitch_semitones * 100.0, 0),
    playrate = round_to(playrate, 6),
    volume_db = round_to(linear_to_db(raw_take_volume), 1),
    volume_linear = round_to(math.abs(raw_take_volume), 6),
    phase_invert = raw_take_volume < 0,
    is_reversed = source_info.is_reversed,
    offset = round_to(start_offset, 6),
    preserve_pitch = preserve_pitch,
    pitch_mode = decode_pitch_mode(pitch_mode),
    pitch_mode_raw = pitch_mode,
  }
end

local function collect_ingredient(item, track, item_index, item_count)
  local take = reaper.GetActiveTake(item)
  if not take then
    return nil
  end

  local source_info = collect_source_state(take)
  local item_info = collect_item_state(item, take, source_info)
  local take_info = collect_take_state(take, source_info)
  local track_info = collect_track_state(track)
  local track_label = track_info.name

  if item_count > 1 then
    track_label = string.format("%s [Item %d]", track_label, item_index + 1)
  end

  return {
    layer_index = 0,
    layer_label = track_label,
    source = source_info,
    item = item_info,
    take = take_info,
    track = track_info,
    fx_chain = collect_fx_chain(track),
    sends = collect_sends(track),
    effective_volume_db = round_to((take_info.volume_db or 0) + (track_info.volume_db or 0), 1),
  }
end

local function crawl_recipe(folder_track)
  local master_track = collect_track_state(folder_track)
  local recipe = {
    name = master_track.name,
    project_name = get_project_name(),
    project_file = get_project_file_path(),
    created_date = os.date("%Y-%m-%d %H:%M"),
    folder_track_index = master_track.track_index,
    ingredients = {},
    master_fx = collect_fx_chain(folder_track),
    master_volume_db = master_track.volume_db,
    master_pan = master_track.pan,
    master_track = master_track,
    notes = "",
    tags = {},
    difficulty = nil,
  }

  local folder_track_index = math.floor(reaper.GetMediaTrackInfo_Value(folder_track, "IP_TRACKNUMBER") or 0) - 1
  local track_count = reaper.CountTracks(0)
  local child_index = folder_track_index + 1
  local open_depth = 1

  while child_index < track_count and open_depth > 0 do
    local child_track = reaper.GetTrack(0, child_index)
    local folder_delta = math.floor(reaper.GetMediaTrackInfo_Value(child_track, "I_FOLDERDEPTH") or 0)
    local item_count = reaper.CountTrackMediaItems(child_track)

    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(child_track, item_index)
      local ingredient = collect_ingredient(item, child_track, item_index, item_count)
      if ingredient then
        ingredient.layer_index = #recipe.ingredients + 1
        recipe.ingredients[#recipe.ingredients + 1] = ingredient
      end
    end

    open_depth = open_depth + folder_delta
    child_index = child_index + 1
  end

  return recipe
end

local function batch_crawl_all_recipes(settings)
  local recipes = {}
  local prefix_filter = trim_string(settings.prefix_filter)
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    local track_name = get_track_name(track)
    local parent_track = reaper.GetParentTrack(track)

    if parent_track == nil and is_folder_track(track) then
      local passes_prefix = prefix_filter == "" or track_name:sub(1, #prefix_filter) == prefix_filter
      if passes_prefix then
        log_line(string.format("[Recipe Logger] Crawling: %s", track_name))
        recipes[#recipes + 1] = crawl_recipe(track)
      end
    end
  end

  return recipes
end

local function prompt_recipe_notes(recipe_name)
  local ok, values = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Notes - " .. recipe_name,
    3,
    table.concat({
      "extrawidth=420",
      "separator=|",
      "Design Notes",
      "Tags (comma separated)",
      "Difficulty (1-5)",
    }, ","),
    "||3"
  )

  if not ok then
    return nil, nil, nil
  end

  local parts = split_delimited(values, "|", 3)
  local notes = trim_string(parts[1])
  local tags = parse_tags(parts[2])
  local difficulty = tonumber(trim_string(parts[3]))

  if difficulty then
    difficulty = math.floor(clamp_number(difficulty, 1, 5))
  end

  return notes, tags, difficulty
end

local function count_unique_sources(recipe)
  local seen = {}
  local count = 0

  for _, ingredient in ipairs(recipe.ingredients) do
    local key = normalize_path(ingredient.source.filepath)
    if key == "" then
      key = ingredient.source.filename
    end
    key = key:lower()
    if key ~= "" and not seen[key] then
      seen[key] = true
      count = count + 1
    end
  end

  return count
end

local function count_total_fx(recipe)
  local count = #recipe.master_fx
  for _, ingredient in ipairs(recipe.ingredients) do
    count = count + #ingredient.fx_chain
  end
  return count
end

local function count_total_sends(recipe)
  local count = 0
  for _, ingredient in ipairs(recipe.ingredients) do
    count = count + #ingredient.sends
  end
  return count
end

local function collect_unique_libraries(recipe)
  local seen = {}
  local libraries = {}

  for _, ingredient in ipairs(recipe.ingredients) do
    local library_name = trim_string(ingredient.source.library_name)
    local key = library_name:lower()
    if library_name ~= "" and not seen[key] then
      seen[key] = true
      libraries[#libraries + 1] = library_name
    end
  end

  table.sort(libraries)
  return libraries
end

local function collect_pitch_range(recipe)
  if #recipe.ingredients == 0 then
    return 0, 0
  end

  local minimum = recipe.ingredients[1].take.pitch_cents or 0
  local maximum = minimum

  for _, ingredient in ipairs(recipe.ingredients) do
    local pitch = ingredient.take.pitch_cents or 0
    if pitch < minimum then
      minimum = pitch
    end
    if pitch > maximum then
      maximum = pitch
    end
  end

  return minimum, maximum
end

local function collect_effective_volume_range(recipe)
  if #recipe.ingredients == 0 then
    return 0, 0
  end

  local minimum = recipe.ingredients[1].effective_volume_db or 0
  local maximum = minimum

  for _, ingredient in ipairs(recipe.ingredients) do
    local value = ingredient.effective_volume_db or 0
    if value < minimum then
      minimum = value
    end
    if value > maximum then
      maximum = value
    end
  end

  return minimum, maximum
end

local function format_source_overview(source)
  local original_length = format_seconds(source.source_length or 0, source.source_length_is_qn and "qn" or nil)
  local sample_rate = source.sample_rate and source.sample_rate > 0 and string.format("%dHz", source.sample_rate) or "unknown rate"
  local bit_depth = source.bit_depth and string.format("%dbit", source.bit_depth) or "unknown bit depth"
  local channels = format_channels(source.channels)
  return string.format("%s, %s/%s, %s", original_length, sample_rate, bit_depth, channels)
end

local function format_take_flags(ingredient)
  local flags = {}
  if ingredient.take.is_reversed then
    flags[#flags + 1] = "reversed"
  end
  if ingredient.take.phase_invert then
    flags[#flags + 1] = "take phase invert"
  end
  if ingredient.track.phase_invert then
    flags[#flags + 1] = "track phase invert"
  end
  if not ingredient.take.preserve_pitch then
    flags[#flags + 1] = "preserve pitch off"
  end
  if ingredient.track.mute then
    flags[#flags + 1] = "track muted"
  end
  if ingredient.track.solo then
    flags[#flags + 1] = "track solo"
  end
  return flags
end

local function filter_fx_parameters_for_display(fx, verbose)
  if verbose then
    return fx.parameters
  end

  local lowered = trim_string(fx.name):lower()
  local filtered = {}

  local function add_if_matches(tokens)
    for _, parameter in ipairs(fx.parameters) do
      local parameter_name = parameter.name:lower()
      for _, token in ipairs(tokens) do
        if parameter_name:find(token, 1, true) then
          filtered[#filtered + 1] = parameter
          break
        end
      end
    end
  end

  if lowered:find("reaeq", 1, true) then
    add_if_matches({ "enabled", "type", "freq", "frequency", "gain", "q", "bandwidth" })
  elseif lowered:find("reacomp", 1, true) then
    add_if_matches({ "thresh", "ratio", "attack", "release", "knee", "pre-comp", "rms" })
  elseif lowered:find("reaverb", 1, true) or lowered:find("verb", 1, true) then
    add_if_matches({ "room", "size", "damp", "wet", "dry", "predelay" })
  elseif lowered:find("readelay", 1, true) or lowered:find("delay", 1, true) then
    add_if_matches({ "time", "length", "feedback", "wet", "dry" })
  else
    for _, parameter in ipairs(fx.parameters) do
      if trim_string(parameter.display) ~= "" then
        filtered[#filtered + 1] = parameter
      end
      if #filtered >= 8 then
        break
      end
    end
  end

  if #filtered == 0 then
    return fx.parameters
  end
  return filtered
end

local function print_recipe_report(recipe, settings)
  local master_fx_names = {}
  for _, fx in ipairs(recipe.master_fx) do
    master_fx_names[#master_fx_names + 1] = fx.short_name
  end

  local libraries = collect_unique_libraries(recipe)
  local pitch_min, pitch_max = collect_pitch_range(recipe)
  local volume_min, volume_max = collect_effective_volume_range(recipe)

  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  SOUND RECIPE: " .. recipe.name)
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Created: " .. recipe.created_date)
  log_line("  Layers:  " .. tostring(#recipe.ingredients))
  log_line(string.format(
    "  Master:  Vol %s | Pan %s | FX: %s",
    format_db(recipe.master_volume_db),
    format_pan_short(recipe.master_pan),
    #master_fx_names > 0 and ("[" .. table.concat(master_fx_names, " -> ") .. "]") or "(none)"
  ))
  if not is_blank(recipe.notes) then
    log_line("  Notes:   " .. recipe.notes)
  end
  if recipe.difficulty then
    log_line("  Diff.:   " .. tostring(recipe.difficulty) .. "/5")
  end
  if #recipe.tags > 0 then
    log_line("  Tags:    " .. table.concat(recipe.tags, ", "))
  end
  log_line(repeat_char("=", REPORT_WIDTH))

  if #recipe.ingredients == 0 then
    log_line("  No active-take items were found inside this recipe folder.")
    log_line(repeat_char("=", REPORT_WIDTH))
    return
  end

  for index, ingredient in ipairs(recipe.ingredients) do
    local flags = format_take_flags(ingredient)

    log_line("")
    log_line(string.format("  Layer %d: %s", index, ingredient.layer_label))
    log_line("  " .. repeat_char("-", REPORT_WIDTH - 4))
    log_line("  Source:    " .. ingredient.source.filename)
    if settings.include_source_info and settings.auto_detect_library then
      log_line("     Library:   " .. (ingredient.source.library_name or "Unknown"))
    end
    if settings.include_source_info and settings.include_file_paths then
      log_line("     Path:      " .. (ingredient.source.filepath ~= "" and ingredient.source.filepath or "(none)"))
    end
    if settings.include_source_info and ingredient.source.file_exists == false and ingredient.source.filepath ~= "" then
      log_line("     Warning:   source file not found on disk")
    end
    if settings.include_source_info then
      log_line("     Original:  " .. format_source_overview(ingredient.source))
    end
    log_line("     Used:      " .. ingredient.item.used_range .. " (" .. format_seconds(ingredient.item.source_time_span or ingredient.item.length or 0, ingredient.source.source_length_is_qn and "qn" or nil) .. ")")

    log_line("")
    log_line("  Settings:")
    log_line(string.format(
      "     Pitch:     %+.2f semitones (%+.0f cents)",
      ingredient.take.pitch_semitones or 0,
      ingredient.take.pitch_cents or 0
    ))
    log_line(string.format(
      "     Volume:    Take %s | Track %s -> Effective %s",
      format_db(ingredient.take.volume_db),
      format_db(ingredient.track.volume_db),
      format_db(ingredient.effective_volume_db)
    ))
    log_line("     Pan:       " .. format_pan_verbose(ingredient.track.pan))
    log_line("     Playrate:  " .. string.format("%.3fx", ingredient.take.playrate or 1))
    log_line("     Fade In:   " .. format_short_duration(ingredient.item.fade_in_length) .. " (" .. ingredient.item.fade_in_shape .. ")")
    log_line("     Fade Out:  " .. format_short_duration(ingredient.item.fade_out_length) .. " (" .. ingredient.item.fade_out_shape .. ")")
    log_line("     PitchMode: " .. (ingredient.take.pitch_mode or "Project default"))
    if #flags > 0 then
      log_line("     Flags:     " .. table.concat(flags, ", "))
    end

    log_line("")
    log_line("  FX Chain:")
    if #ingredient.fx_chain == 0 then
      log_line("     (none)")
    else
      for fx_index, fx in ipairs(ingredient.fx_chain) do
        local status = fx.enabled and "ON" or "OFF"
        if fx.offline then
          status = status .. ",OFFLINE"
        end
        log_line(string.format("     [%d] %s [%s] - %s", fx_index, fx.short_name, status, fx.summary))
      end
    end

    if settings.include_sends then
      log_line("")
      log_line("  Sends:")
      if #ingredient.sends == 0 then
        log_line("     (none)")
      else
        for _, send in ipairs(ingredient.sends) do
          log_line(string.format(
            "     -> %s (%s, %s)",
            send.dest_track_name,
            format_db(send.send_volume_db),
            format_pan_short(send.send_pan)
          ))
        end
      end
    end
  end

  log_line("")
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Recipe Summary")
  log_line("  " .. repeat_char("-", REPORT_WIDTH - 4))
  log_line("  Source Files:   " .. tostring(count_unique_sources(recipe)))
  if settings.auto_detect_library then
    log_line("  Libraries:      " .. (#libraries > 0 and table.concat(libraries, ", ") or "(none)"))
  end
  log_line("  Total FX:       " .. tostring(count_total_fx(recipe)))
  if settings.include_sends then
    log_line("  Total Sends:    " .. tostring(count_total_sends(recipe)))
  end
  log_line(string.format("  Pitch Range:    %+.0f to %+.0f cents", pitch_min or 0, pitch_max or 0))
  log_line(string.format("  Volume Range:   %s to %s", format_db(volume_min), format_db(volume_max)))
  log_line(repeat_char("=", REPORT_WIDTH))
end

local function write_text_file(path, content)
  local handle, open_error = io.open(path, "wb")
  if not handle then
    return false, open_error
  end

  handle:write(content or "")
  handle:close()
  return true
end

local function read_text_file(path)
  local handle, open_error = io.open(path, "rb")
  if not handle then
    return nil, open_error
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

local function prompt_json_file(title, default_path)
  local initial_path = trim_string(default_path)
  if initial_path == "" then
    initial_path = resolve_output_dir("")
  end

  local ok, path = reaper.GetUserFileNameForRead(initial_path, title, ".json")
  if not ok or trim_string(path) == "" then
    return nil, "User cancelled."
  end

  return normalize_path(path)
end

local function prompt_yes_no_options(title, fields)
  local captions = { "separator=|" }
  local defaults = {}

  for _, field in ipairs(fields or {}) do
    captions[#captions + 1] = field.label
    defaults[#defaults + 1] = bool_to_string(field.value)
  end

  local ok, values = reaper.GetUserInputs(
    title,
    #fields,
    table.concat(captions, ","),
    table.concat(defaults, "|")
  )

  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", #fields)
  local result = {}
  for index, field in ipairs(fields) do
    result[field.key] = parse_boolean(parts[index], field.value)
  end
  return result
end

local function parse_json(text)
  local position = 1
  local text_length = #text

  local function skip_whitespace()
    while position <= text_length do
      local char = text:sub(position, position)
      if char ~= " " and char ~= "\t" and char ~= "\r" and char ~= "\n" then
        break
      end
      position = position + 1
    end
  end

  local parse_value

  local function parse_error(message)
    error(string.format("JSON parse error at position %d: %s", position, message))
  end

  local function parse_string()
    if text:sub(position, position) ~= "\"" then
      parse_error("expected string")
    end

    position = position + 1
    local output = {}

    while position <= text_length do
      local char = text:sub(position, position)
      if char == "\"" then
        position = position + 1
        return table.concat(output)
      end

      if char == "\\" then
        local escaped = text:sub(position + 1, position + 1)
        if escaped == "\"" or escaped == "\\" or escaped == "/" then
          output[#output + 1] = escaped
          position = position + 2
        elseif escaped == "b" then
          output[#output + 1] = "\b"
          position = position + 2
        elseif escaped == "f" then
          output[#output + 1] = "\f"
          position = position + 2
        elseif escaped == "n" then
          output[#output + 1] = "\n"
          position = position + 2
        elseif escaped == "r" then
          output[#output + 1] = "\r"
          position = position + 2
        elseif escaped == "t" then
          output[#output + 1] = "\t"
          position = position + 2
        elseif escaped == "u" then
          local hex = text:sub(position + 2, position + 5)
          if not hex:match("^%x%x%x%x$") then
            parse_error("invalid unicode escape")
          end
          local codepoint = tonumber(hex, 16) or 32
          if utf8 and utf8.char and codepoint <= 0x10FFFF then
            output[#output + 1] = utf8.char(codepoint)
          else
            output[#output + 1] = "?"
          end
          position = position + 6
        else
          parse_error("invalid escape sequence")
        end
      else
        output[#output + 1] = char
        position = position + 1
      end
    end

    parse_error("unterminated string")
  end

  local function parse_number()
    local start_pos = position
    local remainder = text:sub(position)
    local number_text = remainder:match("^-?%d+%.?%d*[eE]?[+-]?%d*")
    if not number_text or number_text == "" then
      number_text = remainder:match("^-?%.%d+[eE]?[+-]?%d*")
    end
    if not number_text or number_text == "" then
      parse_error("invalid number")
    end
    position = start_pos + #number_text
    local number_value = tonumber(number_text)
    if number_value == nil then
      parse_error("invalid numeric literal")
    end
    return number_value
  end

  local function parse_array()
    local result = {}
    position = position + 1
    skip_whitespace()
    if text:sub(position, position) == "]" then
      position = position + 1
      return result
    end

    while true do
      result[#result + 1] = parse_value()
      skip_whitespace()
      local char = text:sub(position, position)
      if char == "]" then
        position = position + 1
        return result
      end
      if char ~= "," then
        parse_error("expected ',' or ']'")
      end
      position = position + 1
      skip_whitespace()
    end
  end

  local function parse_object()
    local result = {}
    position = position + 1
    skip_whitespace()
    if text:sub(position, position) == "}" then
      position = position + 1
      return result
    end

    while true do
      skip_whitespace()
      local key = parse_string()
      skip_whitespace()
      if text:sub(position, position) ~= ":" then
        parse_error("expected ':'")
      end
      position = position + 1
      skip_whitespace()
      result[key] = parse_value()
      skip_whitespace()
      local char = text:sub(position, position)
      if char == "}" then
        position = position + 1
        return result
      end
      if char ~= "," then
        parse_error("expected ',' or '}'")
      end
      position = position + 1
      skip_whitespace()
    end
  end

  parse_value = function()
    skip_whitespace()
    local char = text:sub(position, position)
    if char == "\"" then
      return parse_string()
    end
    if char == "{" then
      return parse_object()
    end
    if char == "[" then
      return parse_array()
    end
    if char == "-" or char:match("%d") then
      return parse_number()
    end
    if text:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    end
    if text:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    end
    if text:sub(position, position + 3) == "null" then
      position = position + 4
      return nil
    end
    parse_error("unexpected token")
  end

  local ok, value_or_error = pcall(function()
    local value = parse_value()
    skip_whitespace()
    if position <= text_length then
      parse_error("trailing characters")
    end
    return value
  end)

  if not ok then
    return nil, value_or_error
  end

  return value_or_error
end

local function choose_recipe_from_payload(payload, source_path, prompt_title)
  if type(payload) ~= "table" then
    return nil, "Selected JSON does not contain a valid recipe payload."
  end

  if payload.ingredients then
    return payload
  end

  if #payload == 0 then
    return nil, "Selected JSON does not contain any recipes."
  end

  if #payload == 1 and type(payload[1]) == "table" then
    return payload[1]
  end

  clear_console()
  log_line("Recipe choices from: " .. tostring(source_path))
  for index, recipe in ipairs(payload) do
    log_line(string.format("  [%d] %s", index, tostring(recipe.name or ("Recipe " .. index))))
  end

  local ok, value = reaper.GetUserInputs(
    prompt_title or (SCRIPT_TITLE .. " - Select Recipe"),
    1,
    "Recipe Index or Name",
    "1"
  )
  if not ok then
    return nil, "User cancelled."
  end

  local token = trim_string(value)
  local numeric_index = tonumber(token)
  if numeric_index then
    numeric_index = math.floor(clamp_number(numeric_index, 1, #payload))
    return payload[numeric_index]
  end

  local lowered = token:lower()
  for _, recipe in ipairs(payload) do
    if trim_string(recipe.name):lower() == lowered then
      return recipe
    end
  end

  return nil, "No recipe matched '" .. token .. "'."
end

local function load_recipe_from_json_path(path, prompt_title)
  local content, read_error = read_text_file(path)
  if not content then
    return nil, "Could not read JSON file: " .. tostring(read_error)
  end

  local payload, parse_error_message = parse_json(content)
  if not payload then
    return nil, parse_error_message
  end

  return choose_recipe_from_payload(payload, path, prompt_title)
end

local function append_markdown_fx_chain(lines, heading_level, title, fx_chain, settings)
  if #fx_chain == 0 then
    return
  end

  local heading_prefix = repeat_char("#", heading_level)
  lines[#lines + 1] = heading_prefix .. " " .. title
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| # | Plugin | Status | Summary |"
  lines[#lines + 1] = "|---|--------|--------|---------|"

  for index, fx in ipairs(fx_chain) do
    local status = fx.enabled and "ON" or "OFF"
    if fx.offline then
      status = status .. " / Offline"
    end
    lines[#lines + 1] = string.format(
      "| %d | %s | %s | %s |",
      index,
      escape_markdown_cell(fx.name),
      status,
      escape_markdown_cell(fx.summary or "")
    )
  end

  lines[#lines + 1] = ""

  if settings.include_fx_parameters then
    for index, fx in ipairs(fx_chain) do
      local parameter_list = filter_fx_parameters_for_display(fx, settings.verbose_fx_parameters)
      if #parameter_list > 0 then
        lines[#lines + 1] = heading_prefix .. "# [" .. tostring(index) .. "] " .. escape_markdown_cell(fx.name)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "| Param | Display | Normalized |"
        lines[#lines + 1] = "|-------|---------|------------|"

        for _, parameter in ipairs(parameter_list) do
          lines[#lines + 1] = string.format(
            "| %s | %s | %.6f |",
            escape_markdown_cell(parameter.name),
            escape_markdown_cell(parameter.display ~= "" and parameter.display or tostring(parameter.raw_value)),
            parameter.normalized_value or 0
          )
        end

        lines[#lines + 1] = ""
      end
    end
  end
end

local function export_recipe_markdown(recipe, filepath, settings)
  local lines = {}
  local master_fx_names = {}

  for _, fx in ipairs(recipe.master_fx) do
    master_fx_names[#master_fx_names + 1] = fx.short_name
  end

  lines[#lines + 1] = "# Sound Recipe: " .. recipe.name
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**Created:** " .. recipe.created_date
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**Project:** " .. escape_markdown_cell(recipe.project_name)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**Layers:** " .. tostring(#recipe.ingredients) .. "  "
  lines[#lines + 1] = "**Master:** Vol " .. format_db(recipe.master_volume_db) .. " | Pan " .. format_pan_short(recipe.master_pan)
  if #master_fx_names > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Master FX:** " .. escape_markdown_cell(table.concat(master_fx_names, " -> "))
  end
  if recipe.difficulty then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Difficulty:** " .. tostring(recipe.difficulty) .. "/5"
  end
  if #recipe.tags > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Tags:** " .. escape_markdown_cell(table.concat(recipe.tags, ", "))
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""

  append_markdown_fx_chain(lines, 2, "Master FX Chain", recipe.master_fx, settings)

  for index, ingredient in ipairs(recipe.ingredients) do
    local flags = format_take_flags(ingredient)

    lines[#lines + 1] = "## Layer " .. tostring(index) .. ": " .. escape_markdown_cell(ingredient.layer_label)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Source"
    lines[#lines + 1] = "| Field | Value |"
    lines[#lines + 1] = "|-------|-------|"
    lines[#lines + 1] = "| File | `" .. escape_inline_code(ingredient.source.filename) .. "` |"
    if settings.include_source_info and settings.auto_detect_library then
      lines[#lines + 1] = "| Library | " .. escape_markdown_cell(ingredient.source.library_name or "Unknown") .. " |"
    end
    if settings.include_source_info then
      lines[#lines + 1] = "| Exists On Disk | " .. tostring(ingredient.source.file_exists and "Yes" or "No") .. " |"
    end
    if settings.include_source_info and settings.include_file_paths then
      lines[#lines + 1] = "| Path | `" .. escape_inline_code(ingredient.source.filepath ~= "" and ingredient.source.filepath or "(none)") .. "` |"
    end
    if settings.include_source_info then
      lines[#lines + 1] = "| Original | " .. escape_markdown_cell(format_source_overview(ingredient.source)) .. " |"
    end
    if settings.include_source_info and ingredient.source.file_size_kb then
      lines[#lines + 1] = "| File Size | " .. string.format("%.1f KB", ingredient.source.file_size_kb) .. " |"
    end
    lines[#lines + 1] = "| Used Range | " .. escape_markdown_cell(ingredient.item.used_range) .. " |"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "### Settings"
    lines[#lines + 1] = "| Parameter | Value |"
    lines[#lines + 1] = "|-----------|-------|"
    lines[#lines + 1] = string.format(
      "| Pitch | %+.2f semitones (%+.0f cents) |",
      ingredient.take.pitch_semitones or 0,
      ingredient.take.pitch_cents or 0
    )
    lines[#lines + 1] = "| Playrate | " .. string.format("%.3fx", ingredient.take.playrate or 1) .. " |"
    lines[#lines + 1] = "| Pitch Mode | " .. escape_markdown_cell(ingredient.take.pitch_mode or "Project default") .. " |"
    lines[#lines + 1] = "| Volume | Take " .. format_db(ingredient.take.volume_db) .. " + Track " .. format_db(ingredient.track.volume_db) .. " = **" .. format_db(ingredient.effective_volume_db) .. "** |"
    lines[#lines + 1] = "| Pan | " .. escape_markdown_cell(format_pan_verbose(ingredient.track.pan)) .. " |"
    lines[#lines + 1] = "| Fade In | " .. escape_markdown_cell(format_short_duration(ingredient.item.fade_in_length) .. " (" .. ingredient.item.fade_in_shape .. ")") .. " |"
    lines[#lines + 1] = "| Fade Out | " .. escape_markdown_cell(format_short_duration(ingredient.item.fade_out_length) .. " (" .. ingredient.item.fade_out_shape .. ")") .. " |"
    lines[#lines + 1] = "| Track Pan Law | " .. escape_markdown_cell(ingredient.track.pan_law_display or "Project default") .. " |"
    if ingredient.track.color and ingredient.track.color ~= "" then
      lines[#lines + 1] = "| Track Color | `" .. ingredient.track.color .. "` |"
    end
    if #flags > 0 then
      lines[#lines + 1] = "| Flags | " .. escape_markdown_cell(table.concat(flags, ", ")) .. " |"
    end
    lines[#lines + 1] = ""

    append_markdown_fx_chain(lines, 3, "FX Chain", ingredient.fx_chain, settings)

    if settings.include_sends and #ingredient.sends > 0 then
      lines[#lines + 1] = "### Sends"
      lines[#lines + 1] = "| Destination | Volume | Pan |"
      lines[#lines + 1] = "|-------------|--------|-----|"
      for _, send in ipairs(ingredient.sends) do
        lines[#lines + 1] = string.format(
          "| %s | %s | %s |",
          escape_markdown_cell(send.dest_track_name),
          format_db(send.send_volume_db),
          escape_markdown_cell(format_pan_short(send.send_pan))
        )
      end
      lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
  end

  if not is_blank(recipe.notes) then
    lines[#lines + 1] = "## Notes"
    lines[#lines + 1] = escape_markdown_cell(recipe.notes):gsub("<br>", "\n")
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "*Generated by Game Sound Recipe Logger v1.0*"
  lines[#lines + 1] = ""

  return write_text_file(filepath, table.concat(lines, "\n"))
end

local function build_csv_rows_for_recipe(recipe, settings)
  local rows = {}

  for index, ingredient in ipairs(recipe.ingredients) do
    local fx_columns = { "", "", "" }
    for fx_index = 1, math.min(3, #ingredient.fx_chain) do
      local fx = ingredient.fx_chain[fx_index]
      fx_columns[fx_index] = strip_fx_prefix(fx.name) .. (fx.summary ~= "" and (": " .. fx.summary) or "")
    end

    local send_names = {}
    local send_volumes = {}
    for _, send in ipairs(ingredient.sends) do
      send_names[#send_names + 1] = send.dest_track_name
      send_volumes[#send_volumes + 1] = format_db(send.send_volume_db)
    end

    rows[#rows + 1] = {
      recipe.name,
      tostring(index),
      ingredient.track.name,
      ingredient.source.filename,
      settings.include_source_info and settings.auto_detect_library and (ingredient.source.library_name or "Unknown") or "",
      string.format("%.3f", ingredient.item.length or 0),
      tostring(ingredient.take.pitch_cents or 0),
      string.format("%.1f", ingredient.take.volume_db or 0),
      string.format("%.1f", ingredient.track.volume_db or 0),
      string.format("%.1f", ingredient.effective_volume_db or 0),
      format_pan_short(ingredient.track.pan),
      fx_columns[1],
      fx_columns[2],
      fx_columns[3],
      settings.include_sends and table.concat(send_names, "; ") or "",
      settings.include_sends and table.concat(send_volumes, "; ") or "",
    }
  end

  return rows
end

local function write_csv_file(filepath, rows)
  local lines = {}
  for _, row in ipairs(rows) do
    local cells = {}
    for index, value in ipairs(row) do
      cells[index] = csv_escape(value)
    end
    lines[#lines + 1] = table.concat(cells, ",")
  end
  lines[#lines + 1] = ""
  return write_text_file(filepath, table.concat(lines, "\n"))
end

local function export_recipe_csv(recipe, filepath, settings)
  local rows = {
    {
      "Recipe",
      "Layer",
      "TrackName",
      "SourceFile",
      "Library",
      "UsedLength",
      "PitchCents",
      "TakeVol_dB",
      "TrackVol_dB",
      "EffectiveVol_dB",
      "Pan",
      "FX1",
      "FX2",
      "FX3",
      "SendTo",
      "SendVol_dB",
    }
  }

  local body_rows = build_csv_rows_for_recipe(recipe, settings)
  for _, row in ipairs(body_rows) do
    rows[#rows + 1] = row
  end

  return write_csv_file(filepath, rows)
end

local function escape_json_string(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub("\"", "\\\"")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\t", "\\t")
  return text
end

local function serialize_to_json(value, indent)
  indent = indent or 0
  local outer_padding = string.rep("  ", indent)
  local inner_padding = string.rep("  ", indent + 1)
  local value_type = type(value)

  if value_type == "table" then
    if is_array_table(value) then
      if #value == 0 then
        return "[]"
      end

      local parts = {}
      for _, nested_value in ipairs(value) do
        parts[#parts + 1] = inner_padding .. serialize_to_json(nested_value, indent + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. outer_padding .. "]"
    end

    local keys = sorted_keys(value)
    if #keys == 0 then
      return "{}"
    end

    local parts = {}
    for _, key in ipairs(keys) do
      if value[key] ~= nil then
        parts[#parts + 1] = inner_padding .. "\"" .. escape_json_string(key) .. "\": " .. serialize_to_json(value[key], indent + 1)
      end
    end

    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. outer_padding .. "}"
  end

  if value_type == "string" then
    return "\"" .. escape_json_string(value) .. "\""
  end
  if value_type == "boolean" then
    return value and "true" or "false"
  end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  end
  if value == nil then
    return "null"
  end

  return "\"" .. escape_json_string(tostring(value)) .. "\""
end

local function sanitize_recipe_for_export(recipe, settings)
  local copied = copy_table(recipe)

  if not settings.include_source_info then
    copied.project_file = ""
    for _, ingredient in ipairs(copied.ingredients) do
      ingredient.source.filepath = ""
      ingredient.source.file_size_kb = nil
      ingredient.source.sample_rate = nil
      ingredient.source.bit_depth = nil
      ingredient.source.channels = nil
      ingredient.source.source_length = nil
      ingredient.source.source_length_is_qn = nil
      ingredient.source.file_exists = nil
      ingredient.source.library_name = ""
    end
  elseif not settings.include_file_paths then
    copied.project_file = ""
    for _, ingredient in ipairs(copied.ingredients) do
      ingredient.source.filepath = ""
    end
  end

  if not settings.auto_detect_library then
    for _, ingredient in ipairs(copied.ingredients) do
      ingredient.source.library_name = ""
    end
  end

  if not settings.include_fx_parameters then
    for _, fx in ipairs(copied.master_fx) do
      fx.parameters = {}
    end
    for _, ingredient in ipairs(copied.ingredients) do
      for _, fx in ipairs(ingredient.fx_chain) do
        fx.parameters = {}
      end
    end
  end

  if not settings.include_sends then
    for _, ingredient in ipairs(copied.ingredients) do
      ingredient.sends = {}
    end
  end

  return copied
end

local function export_recipe_json(recipe, filepath, settings)
  local sanitized = sanitize_recipe_for_export(recipe, settings)
  local content = serialize_to_json(sanitized, 0) .. "\n"
  return write_text_file(filepath, content)
end

local function export_recipe_index(recipes, output_dir)
  local lines = {
    "# Recipe Book Index",
    "",
    "| Recipe | Layers | Sources | FX | Sends | Created |",
    "|--------|--------|---------|----|-------|---------|",
  }

  for _, recipe in ipairs(recipes) do
    lines[#lines + 1] = string.format(
      "| %s | %d | %d | %d | %d | %s |",
      escape_markdown_cell(recipe.name),
      #recipe.ingredients,
      count_unique_sources(recipe),
      count_total_fx(recipe),
      count_total_sends(recipe),
      escape_markdown_cell(recipe.created_date)
    )
  end

  lines[#lines + 1] = ""
  return write_text_file(join_paths(output_dir, "_RecipeBook_Index.md"), table.concat(lines, "\n"))
end

local function add_change(changes, change_type, label, old_value, new_value, details)
  changes[#changes + 1] = {
    type = change_type,
    label = label,
    old = old_value ~= nil and tostring(old_value) or "",
    new = new_value ~= nil and tostring(new_value) or "",
    details = details or "",
  }
end

local function compare_parameter_sets(old_params, new_params)
  local changes = {}
  local old_map = {}
  local new_map = {}

  for _, param in ipairs(old_params or {}) do
    old_map[(param.ident ~= "" and param.ident) or (param.name .. "#" .. tostring(param.index))] = param
  end
  for _, param in ipairs(new_params or {}) do
    new_map[(param.ident ~= "" and param.ident) or (param.name .. "#" .. tostring(param.index))] = param
  end

  for key, old_param in pairs(old_map) do
    local new_param = new_map[key]
    if not new_param then
      add_change(changes, "fx_param_removed", "FX parameter removed", old_param.name, "", "")
    else
      local old_display = trim_string(old_param.display ~= "" and old_param.display or tostring(old_param.normalized_value or old_param.raw_value or ""))
      local new_display = trim_string(new_param.display ~= "" and new_param.display or tostring(new_param.normalized_value or new_param.raw_value or ""))
      local old_value = tonumber(old_param.normalized_value or old_param.value or old_param.raw_value)
      local new_value = tonumber(new_param.normalized_value or new_param.value or new_param.raw_value)
      local changed = false

      if old_display ~= "" or new_display ~= "" then
        changed = old_display ~= new_display
      elseif old_value and new_value then
        changed = math.abs(old_value - new_value) > 0.0001
      end

      if changed then
        add_change(changes, "fx_param_changed", old_param.name, old_display, new_display, "")
      end
    end
  end

  for key, new_param in pairs(new_map) do
    if not old_map[key] then
      local display = trim_string(new_param.display ~= "" and new_param.display or tostring(new_param.normalized_value or new_param.raw_value or ""))
      add_change(changes, "fx_param_added", "FX parameter added", "", new_param.name .. "=" .. display, "")
    end
  end

  table.sort(changes, function(left, right)
    return (left.label or "") < (right.label or "")
  end)

  if #changes > 8 then
    local trimmed = {}
    for index = 1, 8 do
      trimmed[index] = changes[index]
    end
    trimmed[#trimmed + 1] = {
      type = "fx_param_more",
      label = "Additional parameter changes",
      old = "",
      new = "",
      details = tostring(#changes - 8) .. " more changes omitted",
    }
    return trimmed
  end

  return changes
end

local function compare_fx_chains(old_chain, new_chain)
  local changes = {}
  local max_count = math.max(#old_chain, #new_chain)

  for index = 1, max_count do
    local old_fx = old_chain[index]
    local new_fx = new_chain[index]

    if not old_fx and new_fx then
      add_change(changes, "fx_added", "FX added", "", new_fx.name or ("FX " .. index), new_fx.summary or "")
    elseif old_fx and not new_fx then
      add_change(changes, "fx_removed", "FX removed", old_fx.name or ("FX " .. index), "", old_fx.summary or "")
    elseif old_fx and new_fx then
      if trim_string(old_fx.name) ~= trim_string(new_fx.name) then
        add_change(changes, "fx_replaced", "FX replaced", old_fx.name, new_fx.name, "")
      else
        if old_fx.enabled ~= new_fx.enabled then
          add_change(changes, "fx_enabled", "FX enabled state", tostring(old_fx.enabled), tostring(new_fx.enabled), new_fx.name)
        end
        if old_fx.summary ~= new_fx.summary then
          add_change(changes, "fx_summary", "FX summary changed", old_fx.summary, new_fx.summary, new_fx.name)
        end

        local param_changes = compare_parameter_sets(old_fx.parameters or {}, new_fx.parameters or {})
        for _, change in ipairs(param_changes) do
          change.details = trim_string((new_fx.name or "") .. (change.details ~= "" and (" | " .. change.details) or ""))
          changes[#changes + 1] = change
        end
      end
    end
  end

  return changes
end

local function compare_sends(old_sends, new_sends)
  local changes = {}
  local old_map = {}
  local new_map = {}

  for _, send in ipairs(old_sends or {}) do
    old_map[trim_string(send.dest_track_name)] = send
  end
  for _, send in ipairs(new_sends or {}) do
    new_map[trim_string(send.dest_track_name)] = send
  end

  for dest_name, old_send in pairs(old_map) do
    local new_send = new_map[dest_name]
    if not new_send then
      add_change(changes, "send_removed", "Send removed", dest_name, "", "")
    else
      if math.abs((old_send.send_volume_db or 0) - (new_send.send_volume_db or 0)) > 0.1 then
        add_change(changes, "send_volume", "Send volume changed", format_db(old_send.send_volume_db), format_db(new_send.send_volume_db), dest_name)
      end
      if math.abs((old_send.send_pan or 0) - (new_send.send_pan or 0)) > 0.01 then
        add_change(changes, "send_pan", "Send pan changed", format_pan_short(old_send.send_pan), format_pan_short(new_send.send_pan), dest_name)
      end
    end
  end

  for dest_name, new_send in pairs(new_map) do
    if not old_map[dest_name] then
      add_change(changes, "send_added", "Send added", "", dest_name, format_db(new_send.send_volume_db))
    end
  end

  table.sort(changes, function(left, right)
    return (left.label or "") < (right.label or "")
  end)
  return changes
end

local function compare_recipes(recipe_old, recipe_new)
  local report = {
    recipe_name = recipe_new.name or recipe_old.name or "Recipe",
    old_name = recipe_old.name or "Old",
    new_name = recipe_new.name or "New",
    old_date = recipe_old.created_date or "",
    new_date = recipe_new.created_date or "",
    master_changes = {},
    layer_results = {},
    summary = {
      changed_layers = 0,
      added_layers = 0,
      removed_layers = 0,
      unchanged_layers = 0,
      total_changes = 0,
    },
  }

  if trim_string(recipe_old.name) ~= trim_string(recipe_new.name) then
    add_change(report.master_changes, "recipe_name", "Recipe name changed", recipe_old.name, recipe_new.name, "")
  end
  if math.abs((recipe_old.master_volume_db or 0) - (recipe_new.master_volume_db or 0)) > 0.1 then
    add_change(report.master_changes, "master_volume", "Master volume changed", format_db(recipe_old.master_volume_db), format_db(recipe_new.master_volume_db), "")
  end
  if math.abs((recipe_old.master_pan or 0) - (recipe_new.master_pan or 0)) > 0.01 then
    add_change(report.master_changes, "master_pan", "Master pan changed", format_pan_short(recipe_old.master_pan), format_pan_short(recipe_new.master_pan), "")
  end

  local master_fx_changes = compare_fx_chains(recipe_old.master_fx or {}, recipe_new.master_fx or {})
  for _, change in ipairs(master_fx_changes) do
    report.master_changes[#report.master_changes + 1] = change
  end

  local max_layers = math.max(#(recipe_old.ingredients or {}), #(recipe_new.ingredients or {}))
  for index = 1, max_layers do
    local old_ing = recipe_old.ingredients and recipe_old.ingredients[index] or nil
    local new_ing = recipe_new.ingredients and recipe_new.ingredients[index] or nil
    local old_effective = old_ing and (
      old_ing.effective_volume_db ~= nil and old_ing.effective_volume_db or
      ((old_ing.take and old_ing.take.volume_db or 0) + (old_ing.track and old_ing.track.volume_db or 0))
    ) or 0
    local new_effective = new_ing and (
      new_ing.effective_volume_db ~= nil and new_ing.effective_volume_db or
      ((new_ing.take and new_ing.take.volume_db or 0) + (new_ing.track and new_ing.track.volume_db or 0))
    ) or 0
    local layer_result = {
      layer = index,
      name = (new_ing and (new_ing.layer_label or new_ing.track and new_ing.track.name)) or (old_ing and (old_ing.layer_label or old_ing.track and old_ing.track.name)) or ("Layer " .. index),
      changes = {},
      state = "changed",
    }

    if not old_ing and new_ing then
      layer_result.state = "added"
      add_change(layer_result.changes, "layer_added", "Layer added", "", layer_result.name, new_ing.source and new_ing.source.filename or "")
      report.summary.added_layers = report.summary.added_layers + 1
    elseif old_ing and not new_ing then
      layer_result.state = "removed"
      add_change(layer_result.changes, "layer_removed", "Layer removed", layer_result.name, "", old_ing.source and old_ing.source.filename or "")
      report.summary.removed_layers = report.summary.removed_layers + 1
    else
      if trim_string(old_ing.source and old_ing.source.filename or "") ~= trim_string(new_ing.source and new_ing.source.filename or "") then
        add_change(layer_result.changes, "source_changed", "Source changed", old_ing.source and old_ing.source.filename or "", new_ing.source and new_ing.source.filename or "", "")
      end
      if math.abs((old_ing.take and old_ing.take.pitch_cents or 0) - (new_ing.take and new_ing.take.pitch_cents or 0)) > 0.5 then
        add_change(layer_result.changes, "pitch_changed", "Pitch changed", string.format("%+.0f cents", old_ing.take and old_ing.take.pitch_cents or 0), string.format("%+.0f cents", new_ing.take and new_ing.take.pitch_cents or 0), "")
      end
      if math.abs((old_ing.take and old_ing.take.playrate or 1) - (new_ing.take and new_ing.take.playrate or 1)) > 0.001 then
        add_change(layer_result.changes, "playrate_changed", "Playrate changed", string.format("%.3fx", old_ing.take and old_ing.take.playrate or 1), string.format("%.3fx", new_ing.take and new_ing.take.playrate or 1), "")
      end
      if math.abs(old_effective - new_effective) > 0.1 then
        add_change(layer_result.changes, "volume_changed", "Effective volume changed", format_db(old_effective), format_db(new_effective), "")
      end
      if math.abs((old_ing.track and old_ing.track.pan or 0) - (new_ing.track and new_ing.track.pan or 0)) > 0.01 then
        add_change(layer_result.changes, "pan_changed", "Pan changed", format_pan_short(old_ing.track and old_ing.track.pan or 0), format_pan_short(new_ing.track and new_ing.track.pan or 0), "")
      end
      if math.abs((old_ing.item and old_ing.item.offset or 0) - (new_ing.item and new_ing.item.offset or 0)) > 0.001 then
        add_change(layer_result.changes, "offset_changed", "Source offset changed", format_seconds(old_ing.item and old_ing.item.offset or 0), format_seconds(new_ing.item and new_ing.item.offset or 0), "")
      end
      if math.abs((old_ing.item and old_ing.item.length or 0) - (new_ing.item and new_ing.item.length or 0)) > 0.001 then
        add_change(layer_result.changes, "length_changed", "Item length changed", format_seconds(old_ing.item and old_ing.item.length or 0), format_seconds(new_ing.item and new_ing.item.length or 0), "")
      end

      local fx_changes = compare_fx_chains(old_ing.fx_chain or {}, new_ing.fx_chain or {})
      for _, change in ipairs(fx_changes) do
        layer_result.changes[#layer_result.changes + 1] = change
      end

      local send_changes = compare_sends(old_ing.sends or {}, new_ing.sends or {})
      for _, change in ipairs(send_changes) do
        layer_result.changes[#layer_result.changes + 1] = change
      end

      if #layer_result.changes == 0 then
        layer_result.state = "unchanged"
        report.summary.unchanged_layers = report.summary.unchanged_layers + 1
      else
        report.summary.changed_layers = report.summary.changed_layers + 1
      end
    end

    report.summary.total_changes = report.summary.total_changes + #layer_result.changes
    report.layer_results[#report.layer_results + 1] = layer_result
  end

  return report
end

local function print_compare_report(report)
  clear_console()
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Recipe Diff: " .. tostring(report.recipe_name))
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Old: " .. tostring(report.old_date) .. " -> New: " .. tostring(report.new_date))
  log_line("")

  if #report.master_changes > 0 then
    log_line("  Master Changes:")
    for _, change in ipairs(report.master_changes) do
      local detail = change.details ~= "" and (" [" .. change.details .. "]") or ""
      log_line(string.format("    - %s: %s -> %s%s", change.label, change.old, change.new, detail))
    end
    log_line("")
  end

  for _, layer in ipairs(report.layer_results) do
    log_line(string.format("  Layer %d (%s):", layer.layer, layer.name))
    if layer.state == "unchanged" then
      log_line("    (no changes)")
    else
      for _, change in ipairs(layer.changes) do
        local detail = change.details ~= "" and (" [" .. change.details .. "]") or ""
        if change.old ~= "" or change.new ~= "" then
          log_line(string.format("    - %s: %s -> %s%s", change.label, change.old, change.new, detail))
        else
          log_line(string.format("    - %s%s", change.label, detail))
        end
      end
    end
    log_line("")
  end

  log_line(repeat_char("=", REPORT_WIDTH))
  log_line(string.format(
    "  Summary: %d changed, %d added, %d removed, %d unchanged, %d total changes",
    report.summary.changed_layers,
    report.summary.added_layers,
    report.summary.removed_layers,
    report.summary.unchanged_layers,
    report.summary.total_changes
  ))
  log_line(repeat_char("=", REPORT_WIDTH))
end

local function build_compare_csv_rows(report)
  local rows = {
    { "Layer", "LayerName", "ChangeType", "Label", "Old", "New", "Details" }
  }

  for _, change in ipairs(report.master_changes or {}) do
    rows[#rows + 1] = { "Master", "Master", change.type or "", change.label or "", change.old or "", change.new or "", change.details or "" }
  end

  for _, layer in ipairs(report.layer_results or {}) do
    if #layer.changes == 0 then
      rows[#rows + 1] = { tostring(layer.layer), layer.name or "", "unchanged", "No changes", "", "", "" }
    else
      for _, change in ipairs(layer.changes) do
        rows[#rows + 1] = {
          tostring(layer.layer),
          layer.name or "",
          change.type or "",
          change.label or "",
          change.old or "",
          change.new or "",
          change.details or "",
        }
      end
    end
  end

  return rows
end

local function export_compare_markdown(report, filepath)
  local lines = {
    "# Recipe Diff: " .. tostring(report.recipe_name),
    "",
    "**Old:** " .. tostring(report.old_date) .. "  ",
    "**New:** " .. tostring(report.new_date),
    "",
  }

  if #report.master_changes > 0 then
    lines[#lines + 1] = "## Master Changes"
    lines[#lines + 1] = ""
    for _, change in ipairs(report.master_changes) do
      local detail = change.details ~= "" and (" (" .. escape_markdown_cell(change.details) .. ")") or ""
      lines[#lines + 1] = string.format("- **%s:** %s -> %s%s", escape_markdown_cell(change.label), escape_markdown_cell(change.old), escape_markdown_cell(change.new), detail)
    end
    lines[#lines + 1] = ""
  end

  for _, layer in ipairs(report.layer_results) do
    lines[#lines + 1] = "## Layer " .. tostring(layer.layer) .. ": " .. escape_markdown_cell(layer.name or "")
    lines[#lines + 1] = ""
    if #layer.changes == 0 then
      lines[#lines + 1] = "(no changes)"
    else
      for _, change in ipairs(layer.changes) do
        local detail = change.details ~= "" and (" (" .. escape_markdown_cell(change.details) .. ")") or ""
        if change.old ~= "" or change.new ~= "" then
          lines[#lines + 1] = string.format("- **%s:** %s -> %s%s", escape_markdown_cell(change.label), escape_markdown_cell(change.old), escape_markdown_cell(change.new), detail)
        else
          lines[#lines + 1] = string.format("- **%s**%s", escape_markdown_cell(change.label), detail)
        end
      end
    end
    lines[#lines + 1] = ""
  end

  return write_text_file(filepath, table.concat(lines, "\n"))
end

local function export_compare_csv(report, filepath)
  return write_csv_file(filepath, build_compare_csv_rows(report))
end

local function export_compare_json(report, filepath)
  return write_text_file(filepath, serialize_to_json(report, 0) .. "\n")
end

local function export_compare_outputs(report, settings)
  local written_files = {}
  if not wants_file_output(settings) then
    return written_files
  end

  local output_dir = resolve_output_dir(settings.output_folder)
  if not ensure_directory(output_dir) then
    return nil, "Could not create output folder: " .. output_dir
  end

  local base_name = sanitize_filename((report.old_name or "Old") .. "_vs_" .. (report.new_name or "New") .. "_diff")

  if wants_markdown(settings) then
    local path = join_paths(output_dir, base_name .. ".md")
    local ok, err = export_compare_markdown(report, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end
  if wants_csv(settings) then
    local path = join_paths(output_dir, base_name .. ".csv")
    local ok, err = export_compare_csv(report, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end
  if wants_json(settings) then
    local path = join_paths(output_dir, base_name .. ".json")
    local ok, err = export_compare_json(report, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end

  return written_files
end

local function find_track_by_name(name)
  local target = trim_string(name)
  if target == "" then
    return nil
  end

  local track_count = reaper.CountTracks(0)
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    if trim_string(get_track_name(track)) == target then
      return track
    end
  end

  return nil
end

local function create_named_track_at_end(name)
  local insert_index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insert_index, true)
  local track = reaper.GetTrack(0, insert_index)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", trim_string(name), true)
  return track
end

local function add_fx_by_recipe_name(track, fx_entry)
  local candidates = {
    trim_string(fx_entry.name),
    trim_string(fx_entry.short_name),
    trim_string(strip_fx_prefix(fx_entry.name or "")),
    trim_string((fx_entry.name or ""):gsub("%s*%b()", "")),
  }

  local seen = {}
  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and not seen[candidate] then
      seen[candidate] = true
      local fx_index = reaper.TrackFX_AddByName(track, candidate, false, -1)
      if fx_index >= 0 then
        return fx_index, candidate
      end
    end
  end

  return -1, ""
end

local function restore_fx_chain_to_track(track, fx_chain, summary)
  for _, fx_entry in ipairs(fx_chain or {}) do
    local fx_index = add_fx_by_recipe_name(track, fx_entry)
    if fx_index and fx_index >= 0 then
      if fx_entry.parameters then
        for _, parameter in ipairs(fx_entry.parameters) do
          local normalized = tonumber(parameter.normalized_value or parameter.value)
          if normalized ~= nil then
            reaper.TrackFX_SetParamNormalized(track, fx_index, parameter.index or 0, normalized)
          elseif parameter.raw_value ~= nil then
            reaper.TrackFX_SetParam(track, fx_index, parameter.index or 0, tonumber(parameter.raw_value) or 0)
          end
        end
      end

      local wet_param_index = tonumber(reaper.TrackFX_GetParamFromIdent(track, fx_index, ":wet")) or -1
      if wet_param_index >= 0 and fx_entry.wet_dry ~= nil then
        reaper.TrackFX_SetParamNormalized(track, fx_index, wet_param_index, tonumber(fx_entry.wet_dry) or 1.0)
      end

      if fx_entry.enabled ~= nil then
        reaper.TrackFX_SetEnabled(track, fx_index, fx_entry.enabled)
      end
      if fx_entry.offline ~= nil then
        reaper.TrackFX_SetOffline(track, fx_index, fx_entry.offline)
      end

      summary.restored_fx = (summary.restored_fx or 0) + 1
    else
      summary.skipped_fx = (summary.skipped_fx or 0) + 1
      summary.warnings[#summary.warnings + 1] = "Could not load FX: " .. tostring(fx_entry.name)
    end
  end
end

local function apply_track_state(track, track_state)
  if not track or type(track_state) ~= "table" then
    return
  end

  if trim_string(track_state.name) ~= "" then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", trim_string(track_state.name), true)
  end
  if track_state.volume_db ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", db_to_linear(track_state.volume_db))
  end
  if track_state.pan ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", tonumber(track_state.pan) or 0)
  end
  if track_state.mute ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", track_state.mute and 1 or 0)
  end
  if track_state.phase_invert ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "B_PHASE", track_state.phase_invert and 1 or 0)
  end
  if track_state.color and track_state.color ~= "" then
    local native = hex_to_native_color(track_state.color)
    if native then
      reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", native)
    end
  end
end

local function rebuild_from_recipe(recipe, options)
  options = options or {}
  local summary = {
    recipe_name = recipe.name or "Recipe",
    created_tracks = 0,
    created_items = 0,
    created_send_tracks = 0,
    restored_sends = 0,
    restored_fx = 0,
    skipped_fx = 0,
    missing_sources = {},
    warnings = {},
  }

  local layer_tracks = {}
  local send_target_tracks = {}

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, error_message = xpcall(function()
    local insert_index = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(insert_index, true)
    local folder_track = reaper.GetTrack(0, insert_index)
    summary.created_tracks = summary.created_tracks + 1

    apply_track_state(folder_track, recipe.master_track or { name = recipe.name, volume_db = recipe.master_volume_db, pan = recipe.master_pan })
    reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", #(recipe.ingredients or {}) > 0 and 1 or 0)

    for index, ingredient in ipairs(recipe.ingredients or {}) do
      local track_index = insert_index + index
      reaper.InsertTrackAtIndex(track_index, true)
      local layer_track = reaper.GetTrack(0, track_index)
      layer_tracks[index] = layer_track
      summary.created_tracks = summary.created_tracks + 1

      apply_track_state(layer_track, ingredient.track or { name = ingredient.layer_label })
      reaper.SetMediaTrackInfo_Value(layer_track, "I_FOLDERDEPTH", index == #(recipe.ingredients or {}) and -1 or 0)

      if ingredient.source and ingredient.source.filepath ~= "" then
        local source_path = resolve_existing_file_path(ingredient.source.filepath)
        if reaper.file_exists(source_path) then
          local item = reaper.AddMediaItemToTrack(layer_track)
          summary.created_items = summary.created_items + 1
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", tonumber(ingredient.item and ingredient.item.position) or 0)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", tonumber(ingredient.item and ingredient.item.length) or 1.0)
          reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", tonumber(ingredient.item and ingredient.item.fade_in_length) or 0)
          reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", tonumber(ingredient.item and ingredient.item.fade_out_length) or 0)
          reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", tonumber(ingredient.item and ingredient.item.fade_in_shape_index) or 0)
          reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", tonumber(ingredient.item and ingredient.item.fade_out_shape_index) or 0)
          reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", tonumber(ingredient.item and ingredient.item.fade_in_curve) or 0)
          reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", tonumber(ingredient.item and ingredient.item.fade_out_curve) or 0)

          local take = reaper.AddTakeToMediaItem(item)
          local pcm_source = reaper.PCM_Source_CreateFromFile(source_path)
          if pcm_source then
            reaper.SetMediaItemTake_Source(take, pcm_source)
          end

          if ingredient.take then
            reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", tonumber(ingredient.take.pitch_semitones) or 0)
            reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", tonumber(ingredient.take.playrate) or 1)
            reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", tonumber(ingredient.take.volume_linear) or db_to_linear(ingredient.take.volume_db or 0))
            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", tonumber(ingredient.take.offset or ingredient.item and ingredient.item.offset) or 0)
            reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", ingredient.take.preserve_pitch == false and 0 or 1)
            if ingredient.take.pitch_mode_raw ~= nil then
              reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", tonumber(ingredient.take.pitch_mode_raw) or -1)
            end
            if trim_string(ingredient.take.name) ~= "" then
              reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", ingredient.take.name, true)
            end
          end

          reaper.UpdateItemInProject(item)
        else
          summary.missing_sources[#summary.missing_sources + 1] = source_path
        end
      end

      if options.restore_fx then
        restore_fx_chain_to_track(layer_track, ingredient.fx_chain or {}, summary)
      end
    end

    if options.restore_master_fx then
      restore_fx_chain_to_track(folder_track, recipe.master_fx or {}, summary)
    end

    if options.restore_sends then
      for index, ingredient in ipairs(recipe.ingredients or {}) do
        local source_track = layer_tracks[index]
        for _, send in ipairs(ingredient.sends or {}) do
          local dest_name = trim_string(send.dest_track_name)
          if dest_name ~= "" then
            local dest_track = send_target_tracks[dest_name] or find_track_by_name(dest_name)
            if not dest_track and options.create_missing_send_tracks then
              dest_track = create_named_track_at_end(dest_name)
              send_target_tracks[dest_name] = dest_track
              summary.created_tracks = summary.created_tracks + 1
              summary.created_send_tracks = summary.created_send_tracks + 1
            end

            if dest_track then
              local send_index = reaper.CreateTrackSend(source_track, dest_track)
              if send_index >= 0 then
                reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_VOL", db_to_linear(send.send_volume_db or 0))
                reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_PAN", tonumber(send.send_pan) or 0)
                if send.mute ~= nil then
                  reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "B_MUTE", send.mute and 1 or 0)
                end
                if send.phase_invert ~= nil then
                  reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "B_PHASE", send.phase_invert and 1 or 0)
                end
                summary.restored_sends = summary.restored_sends + 1
              end
            else
              summary.warnings[#summary.warnings + 1] = "Send target not found: " .. dest_name
            end
          end
        end
      end
    end
  end, function(message)
    return debug.traceback(message, 2)
  end)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock("Rebuild Recipe: " .. tostring(summary.recipe_name), -1)
    return true, summary
  end

  reaper.Undo_EndBlock("Rebuild Recipe Failed", -1)
  return false, error_message
end

local function print_rebuild_report(summary)
  clear_console()
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Recipe Rebuild: " .. tostring(summary.recipe_name))
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Tracks Created:      " .. tostring(summary.created_tracks))
  log_line("  Items Created:       " .. tostring(summary.created_items))
  log_line("  FX Restored:         " .. tostring(summary.restored_fx or 0))
  log_line("  FX Skipped:          " .. tostring(summary.skipped_fx or 0))
  log_line("  Sends Restored:      " .. tostring(summary.restored_sends or 0))
  log_line("  Send Tracks Created: " .. tostring(summary.created_send_tracks or 0))
  log_line("  Missing Sources:     " .. tostring(#(summary.missing_sources or {})))
  if #(summary.missing_sources or {}) > 0 then
    log_line("")
    for _, path in ipairs(summary.missing_sources) do
      log_line("  Missing: " .. tostring(path))
    end
  end
  if #(summary.warnings or {}) > 0 then
    log_line("")
    for _, warning in ipairs(summary.warnings) do
      log_line("  Warning: " .. tostring(warning))
    end
  end
  log_line(repeat_char("=", REPORT_WIDTH))
end

local function export_rebuild_markdown(summary, filepath)
  local lines = {
    "# Recipe Rebuild: " .. tostring(summary.recipe_name),
    "",
    "| Field | Value |",
    "|-------|-------|",
    "| Tracks Created | " .. tostring(summary.created_tracks) .. " |",
    "| Items Created | " .. tostring(summary.created_items) .. " |",
    "| FX Restored | " .. tostring(summary.restored_fx or 0) .. " |",
    "| FX Skipped | " .. tostring(summary.skipped_fx or 0) .. " |",
    "| Sends Restored | " .. tostring(summary.restored_sends or 0) .. " |",
    "| Send Tracks Created | " .. tostring(summary.created_send_tracks or 0) .. " |",
    "| Missing Sources | " .. tostring(#(summary.missing_sources or {})) .. " |",
    "",
  }

  if #(summary.missing_sources or {}) > 0 then
    lines[#lines + 1] = "## Missing Sources"
    lines[#lines + 1] = ""
    for _, path in ipairs(summary.missing_sources) do
      lines[#lines + 1] = "- `" .. escape_inline_code(path) .. "`"
    end
    lines[#lines + 1] = ""
  end

  if #(summary.warnings or {}) > 0 then
    lines[#lines + 1] = "## Warnings"
    lines[#lines + 1] = ""
    for _, warning in ipairs(summary.warnings) do
      lines[#lines + 1] = "- " .. escape_markdown_cell(warning)
    end
    lines[#lines + 1] = ""
  end

  return write_text_file(filepath, table.concat(lines, "\n"))
end

local function export_rebuild_csv(summary, filepath)
  local rows = {
    { "Recipe", "TracksCreated", "ItemsCreated", "FXRestored", "FXSkipped", "SendsRestored", "SendTracksCreated", "MissingSources", "Warnings" },
    {
      summary.recipe_name or "",
      tostring(summary.created_tracks or 0),
      tostring(summary.created_items or 0),
      tostring(summary.restored_fx or 0),
      tostring(summary.skipped_fx or 0),
      tostring(summary.restored_sends or 0),
      tostring(summary.created_send_tracks or 0),
      table.concat(summary.missing_sources or {}, "; "),
      table.concat(summary.warnings or {}, "; "),
    }
  }
  return write_csv_file(filepath, rows)
end

local function export_rebuild_json(summary, filepath)
  return write_text_file(filepath, serialize_to_json(summary, 0) .. "\n")
end

local function export_rebuild_outputs(summary, settings)
  local written_files = {}
  if not wants_file_output(settings) then
    return written_files
  end

  local output_dir = resolve_output_dir(settings.output_folder)
  if not ensure_directory(output_dir) then
    return nil, "Could not create output folder: " .. output_dir
  end

  local base_name = sanitize_filename((summary.recipe_name or "Recipe") .. "_rebuild_report")

  if wants_markdown(settings) then
    local path = join_paths(output_dir, base_name .. ".md")
    local ok, err = export_rebuild_markdown(summary, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end
  if wants_csv(settings) then
    local path = join_paths(output_dir, base_name .. ".csv")
    local ok, err = export_rebuild_csv(summary, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end
  if wants_json(settings) then
    local path = join_paths(output_dir, base_name .. ".json")
    local ok, err = export_rebuild_json(summary, path)
    if not ok then
      return nil, err
    end
    append_written_file(written_files, path)
  end

  return written_files
end

local function wants_markdown(settings)
  return settings.export_markdown == true
end

local function wants_csv(settings)
  return settings.export_csv == true
end

local function wants_json(settings)
  return settings.export_json == true
end

local function wants_file_output(settings)
  return settings.export_markdown or settings.export_csv or settings.export_json
end

local function append_written_file(written_files, path)
  written_files[#written_files + 1] = normalize_path(path)
end

local function export_recipes(recipes, settings)
  local written_files = {}

  if not wants_file_output(settings) then
    return written_files
  end

  local output_dir = resolve_output_dir(settings.output_folder)
  if not ensure_directory(output_dir) then
    return nil, "Could not create output folder: " .. output_dir
  end

  if #recipes == 1 then
    local recipe = recipes[1]
    local safe_name = sanitize_filename(recipe.name)

    if wants_markdown(settings) then
      local path = join_paths(output_dir, safe_name .. ".md")
      local ok, error_message = export_recipe_markdown(recipe, path, settings)
      if not ok then
        return nil, "Markdown export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    if wants_csv(settings) then
      local path = join_paths(output_dir, safe_name .. ".csv")
      local ok, error_message = export_recipe_csv(recipe, path, settings)
      if not ok then
        return nil, "CSV export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    if wants_json(settings) then
      local path = join_paths(output_dir, safe_name .. ".json")
      local ok, error_message = export_recipe_json(recipe, path, settings)
      if not ok then
        return nil, "JSON export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    return written_files
  end

  if wants_markdown(settings) then
    for _, recipe in ipairs(recipes) do
      local path = join_paths(output_dir, sanitize_filename(recipe.name) .. ".md")
      local ok, error_message = export_recipe_markdown(recipe, path, settings)
      if not ok then
        return nil, "Markdown export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    local index_ok, index_error = export_recipe_index(recipes, output_dir)
    if not index_ok then
      return nil, "Recipe index export failed: " .. tostring(index_error)
    end
    append_written_file(written_files, join_paths(output_dir, "_RecipeBook_Index.md"))
  end

  if wants_csv(settings) then
    local rows = {
      {
        "Recipe",
        "Layer",
        "TrackName",
        "SourceFile",
        "Library",
        "UsedLength",
        "PitchCents",
        "TakeVol_dB",
        "TrackVol_dB",
        "EffectiveVol_dB",
        "Pan",
        "FX1",
        "FX2",
        "FX3",
        "SendTo",
        "SendVol_dB",
      }
    }

    for _, recipe in ipairs(recipes) do
      local recipe_rows = build_csv_rows_for_recipe(recipe, settings)
      for _, row in ipairs(recipe_rows) do
        rows[#rows + 1] = row
      end
    end

    local csv_path = join_paths(output_dir, "recipes_all.csv")
    local ok, error_message = write_csv_file(csv_path, rows)
    if not ok then
      return nil, "CSV export failed: " .. tostring(error_message)
    end
    append_written_file(written_files, csv_path)
  end

  if wants_json(settings) then
    local json_path = join_paths(output_dir, "recipes_all.json")
    local payload = {}
    for _, recipe in ipairs(recipes) do
      payload[#payload + 1] = sanitize_recipe_for_export(recipe, settings)
    end
    local ok, error_message = write_text_file(json_path, serialize_to_json(payload, 0) .. "\n")
    if not ok then
      return nil, "JSON export failed: " .. tostring(error_message)
    end
    append_written_file(written_files, json_path)
  end

  return written_files
end

local function load_settings()
  local settings = {}
  for key, default_value in pairs(DEFAULTS) do
    local stored = reaper.GetExtState(EXT_SECTION, key)
    if stored == "" then
      settings[key] = default_value
    elseif type(default_value) == "boolean" then
      settings[key] = parse_boolean(stored, default_value)
    else
      settings[key] = stored
    end
  end

  settings.mode = parse_mode(settings.mode, DEFAULTS.mode)
  settings.source_scope = parse_source_scope(settings.source_scope, DEFAULTS.source_scope)
  settings.output_format = parse_output_format(settings.output_format, DEFAULTS.output_format)
  settings.prefix_filter = trim_string(settings.prefix_filter)
  settings.output_folder = trim_string(settings.output_folder)
  settings.rebuild_json_path = trim_string(settings.rebuild_json_path)
  settings.compare_old_json_path = trim_string(settings.compare_old_json_path)
  settings.compare_new_json_path = trim_string(settings.compare_new_json_path)
  settings.custom_library_patterns = tostring(settings.custom_library_patterns or "")

  local has_export_flags =
    reaper.GetExtState(EXT_SECTION, "export_console") ~= "" or
    reaper.GetExtState(EXT_SECTION, "export_markdown") ~= "" or
    reaper.GetExtState(EXT_SECTION, "export_csv") ~= "" or
    reaper.GetExtState(EXT_SECTION, "export_json") ~= ""

  if not has_export_flags then
    apply_export_flags_from_output_format(settings)
  else
    settings.output_format = derive_output_format_from_flags(settings)
  end

  refresh_custom_library_patterns(settings.custom_library_patterns)

  return settings
end

local function save_settings(settings)
  settings.output_format = derive_output_format_from_flags(settings)
  settings.custom_library_patterns = tostring(settings.custom_library_patterns or serialize_custom_library_patterns(CUSTOM_LIBRARY_PATTERNS))
  refresh_custom_library_patterns(settings.custom_library_patterns)
  for key, value in pairs(settings) do
    local encoded = value
    if type(value) == "boolean" then
      encoded = bool_to_string(value)
    end
    reaper.SetExtState(EXT_SECTION, key, tostring(encoded), true)
  end
end

local function prompt_for_settings(current)
  local ok, values = reaper.GetUserInputs(
    SCRIPT_TITLE,
    7,
    table.concat({
      "extrawidth=420",
      "separator=|",
      "Mode (single/batch/rebuild/compare)",
      "Output Format (console/markdown/csv/json/all)",
      "Output Folder (blank=project/Recipes)",
      "Include FX Parameters (yes/no)",
      "Include File Paths (yes/no)",
      "Add Notes Prompt (yes/no)",
      "Prefix Filter (batch only)",
    }, ","),
    table.concat({
      current.mode,
      current.output_format,
      current.output_folder,
      bool_to_string(current.include_fx_parameters),
      bool_to_string(current.include_file_paths),
      bool_to_string(current.add_notes_prompt),
      current.prefix_filter,
    }, "|")
  )

  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 7)
  local settings = {
    mode = parse_mode(parts[1], current.mode),
    output_format = parse_output_format(parts[2], current.output_format),
    output_folder = trim_string(parts[3]),
    include_fx_parameters = parse_boolean(parts[4], current.include_fx_parameters),
    include_file_paths = parse_boolean(parts[5], current.include_file_paths),
    add_notes_prompt = parse_boolean(parts[6], current.add_notes_prompt),
    prefix_filter = trim_string(parts[7]),
  }

  if settings.mode == nil then
    return nil, "Unsupported mode."
  end
  if settings.output_format == nil then
    return nil, "Unsupported output format."
  end

  settings.source_scope = settings.mode == "batch" and "all_folder_tracks" or current.source_scope or DEFAULTS.source_scope
  apply_export_flags_from_output_format(settings)
  settings.include_source_info = current.include_source_info
  settings.verbose_fx_parameters = current.verbose_fx_parameters
  settings.include_sends = current.include_sends
  settings.auto_detect_library = current.auto_detect_library
  settings.auto_tag_keywords = current.auto_tag_keywords

  if not has_any_output_enabled(settings) then
    return nil, "Select at least one output format."
  end

  return settings
end

local function apply_optional_notes(recipe, settings)
  local tags = recipe.tags or {}
  if settings.auto_tag_keywords then
    tags = merge_tags(tags, build_auto_tags(recipe.name))
  end

  if settings.add_notes_prompt then
    local notes, entered_tags, difficulty = prompt_recipe_notes(recipe.name)
    if notes ~= nil then
      recipe.notes = notes
      tags = merge_tags(tags, entered_tags or {})
      recipe.difficulty = difficulty
    end
  end

  recipe.tags = tags
  return recipe
end

local function summarize_written_files(written_files)
  if #written_files == 0 then
    return "No files were written (console report only)."
  end

  local lines = { "Saved files:" }
  for _, path in ipairs(written_files) do
    lines[#lines + 1] = "- " .. path
  end
  return table.concat(lines, "\n")
end

local function prompt_compare_settings(settings)
  local old_path, old_error = prompt_json_file(
    "Select OLD recipe JSON",
    settings.compare_old_json_path or settings.output_folder or ""
  )
  if not old_path then
    return nil, old_error
  end

  local new_path, new_error = prompt_json_file(
    "Select NEW recipe JSON",
    settings.compare_new_json_path or old_path
  )
  if not new_path then
    return nil, new_error
  end

  settings.compare_old_json_path = old_path
  settings.compare_new_json_path = new_path
  save_settings(settings)
  return settings
end

local function prompt_rebuild_settings(settings)
  local json_path, path_error = prompt_json_file(
    "Select recipe JSON to rebuild",
    settings.rebuild_json_path or settings.output_folder or ""
  )
  if not json_path then
    return nil, path_error
  end

  local options, options_error = prompt_yes_no_options(
    SCRIPT_TITLE .. " - Rebuild Options",
    {
      { key = "rebuild_restore_fx", label = "Restore Layer FX (yes/no)", value = settings.rebuild_restore_fx ~= false },
      { key = "rebuild_restore_master_fx", label = "Restore Folder FX (yes/no)", value = settings.rebuild_restore_master_fx ~= false },
      { key = "rebuild_restore_sends", label = "Restore Sends (yes/no)", value = settings.rebuild_restore_sends ~= false },
      { key = "rebuild_create_missing_send_tracks", label = "Create Missing Send Tracks (yes/no)", value = settings.rebuild_create_missing_send_tracks ~= false },
    }
  )
  if not options then
    return nil, options_error
  end

  settings.rebuild_json_path = json_path
  settings.rebuild_restore_fx = options.rebuild_restore_fx
  settings.rebuild_restore_master_fx = options.rebuild_restore_master_fx
  settings.rebuild_restore_sends = options.rebuild_restore_sends
  settings.rebuild_create_missing_send_tracks = options.rebuild_create_missing_send_tracks
  save_settings(settings)
  return settings
end

local function run_single(settings)
  if not has_any_output_enabled(settings) then
    return false, "Select at least one output format."
  end

  local folder_track = find_selected_recipe_folder()
  if not folder_track then
    return false, "Select a folder track, or a media item inside a recipe folder, then run the script again."
  end

  clear_console()
  local recipe = crawl_recipe(folder_track)
  apply_optional_notes(recipe, settings)
  if settings.export_console then
    print_recipe_report(recipe, settings)
  end

  local written_files, export_error = export_recipes({ recipe }, settings)
  if not written_files then
    return false, export_error
  end

  return true, "Recipe captured: " .. recipe.name .. "\n\n" .. summarize_written_files(written_files)
end

local function run_batch(settings)
  if not has_any_output_enabled(settings) then
    return false, "Select at least one output format."
  end

  local recipes = batch_crawl_all_recipes(settings)
  if #recipes == 0 then
    local filter_text = settings.prefix_filter ~= "" and (" with prefix '" .. settings.prefix_filter .. "'") or ""
    return false, "No top-level folder recipes were found" .. filter_text .. "."
  end

  clear_console()
  for _, recipe in ipairs(recipes) do
    apply_optional_notes(recipe, settings)
    if settings.export_console then
      print_recipe_report(recipe, settings)
    end
  end

  local written_files, export_error = export_recipes(recipes, settings)
  if not written_files then
    return false, export_error
  end

  return true, string.format("Crawled %d recipes.\n\n%s", #recipes, summarize_written_files(written_files))
end

local function run_compare(settings)
  if not has_any_output_enabled(settings) then
    return false, "Select at least one output format."
  end

  local prepared_settings, settings_error = prompt_compare_settings(settings)
  if not prepared_settings then
    return false, settings_error
  end

  local recipe_old, old_error = load_recipe_from_json_path(
    prepared_settings.compare_old_json_path,
    SCRIPT_TITLE .. " - Select OLD Recipe"
  )
  if not recipe_old then
    return false, old_error
  end

  local recipe_new, new_error = load_recipe_from_json_path(
    prepared_settings.compare_new_json_path,
    SCRIPT_TITLE .. " - Select NEW Recipe"
  )
  if not recipe_new then
    return false, new_error
  end

  local report = compare_recipes(recipe_old, recipe_new)
  if prepared_settings.export_console then
    print_compare_report(report)
  end

  local written_files, export_error = export_compare_outputs(report, prepared_settings)
  if not written_files then
    return false, export_error
  end

  return true, "Recipe diff completed: " .. tostring(report.recipe_name) .. "\n\n" .. summarize_written_files(written_files)
end

local function run_rebuild(settings)
  if not has_any_output_enabled(settings) then
    return false, "Select at least one output format."
  end

  local prepared_settings, settings_error = prompt_rebuild_settings(settings)
  if not prepared_settings then
    return false, settings_error
  end

  local recipe, recipe_error = load_recipe_from_json_path(
    prepared_settings.rebuild_json_path,
    SCRIPT_TITLE .. " - Select Recipe To Rebuild"
  )
  if not recipe then
    return false, recipe_error
  end

  local rebuild_ok, rebuild_result = rebuild_from_recipe(recipe, {
    restore_fx = prepared_settings.rebuild_restore_fx ~= false,
    restore_master_fx = prepared_settings.rebuild_restore_master_fx ~= false,
    restore_sends = prepared_settings.rebuild_restore_sends ~= false,
    create_missing_send_tracks = prepared_settings.rebuild_create_missing_send_tracks ~= false,
  })
  if not rebuild_ok then
    return false, rebuild_result
  end

  if prepared_settings.export_console then
    print_rebuild_report(rebuild_result)
  end

  local written_files, export_error = export_rebuild_outputs(rebuild_result, prepared_settings)
  if not written_files then
    return false, export_error
  end

  return true, "Recipe rebuilt: " .. tostring(rebuild_result.recipe_name) .. "\n\n" .. summarize_written_files(written_files)
end

local function run_mode(settings)
  if settings.mode == "single" and settings.source_scope == "all_folder_tracks" then
    return run_batch(settings)
  end
  if settings.mode == "single" then
    return run_single(settings)
  end
  if settings.mode == "batch" then
    return run_batch(settings)
  end
  if settings.mode == "rebuild" then
    return run_rebuild(settings)
  end
  if settings.mode == "compare" then
    return run_compare(settings)
  end
  return false, "Unsupported mode: " .. tostring(settings.mode)
end

local UI_MODE_LABELS = {
  single = "Single Recipe",
  batch = "Batch All",
  rebuild = "Rebuild",
  compare = "Compare",
}

local function get_mode_label(mode)
  return UI_MODE_LABELS[mode] or tostring(mode or "")
end

local function get_scope_label(scope)
  if scope == "all_folder_tracks" then
    return "All folder tracks"
  end
  return "Selected folder track"
end

local function build_settings_from_ui(ui)
  local settings = {
    mode = ui.mode,
    source_scope = ui.source_scope,
    output_folder = trim_string(ui.output_folder),
    export_console = ui.export_console,
    export_markdown = ui.export_markdown,
    export_csv = ui.export_csv,
    export_json = ui.export_json,
    include_source_info = ui.include_source_info,
    include_fx_parameters = ui.include_fx_parameters,
    verbose_fx_parameters = ui.verbose_fx_parameters,
    include_file_paths = ui.include_file_paths,
    include_sends = ui.include_sends,
    add_notes_prompt = ui.add_notes_prompt,
    auto_detect_library = ui.auto_detect_library,
    auto_tag_keywords = ui.auto_tag_keywords,
    prefix_filter = trim_string(ui.prefix_filter),
    rebuild_json_path = trim_string(ui.rebuild_json_path),
    compare_old_json_path = trim_string(ui.compare_old_json_path),
    compare_new_json_path = trim_string(ui.compare_new_json_path),
    rebuild_restore_fx = ui.rebuild_restore_fx ~= false,
    rebuild_restore_master_fx = ui.rebuild_restore_master_fx ~= false,
    rebuild_restore_sends = ui.rebuild_restore_sends ~= false,
    rebuild_create_missing_send_tracks = ui.rebuild_create_missing_send_tracks ~= false,
    custom_library_patterns = tostring(ui.custom_library_patterns or ""),
  }

  if settings.mode == "batch" then
    settings.source_scope = "all_folder_tracks"
  end

  settings.output_format = derive_output_format_from_flags(settings)
  return settings
end

local function save_ui_settings(ui)
  save_settings(build_settings_from_ui(ui))
end

local function apply_settings_to_ui(ui, settings)
  if not ui or not settings then
    return
  end

  ui.mode = settings.mode or ui.mode
  ui.source_scope = settings.source_scope or ui.source_scope
  ui.output_folder = settings.output_folder or ui.output_folder
  ui.export_console = settings.export_console ~= false
  ui.export_markdown = settings.export_markdown == true
  ui.export_csv = settings.export_csv == true
  ui.export_json = settings.export_json == true
  ui.include_source_info = settings.include_source_info ~= false
  ui.include_fx_parameters = settings.include_fx_parameters ~= false
  ui.verbose_fx_parameters = settings.verbose_fx_parameters == true
  ui.include_file_paths = settings.include_file_paths ~= false
  ui.include_sends = settings.include_sends ~= false
  ui.add_notes_prompt = settings.add_notes_prompt ~= false
  ui.auto_detect_library = settings.auto_detect_library ~= false
  ui.auto_tag_keywords = settings.auto_tag_keywords == true
  ui.prefix_filter = settings.prefix_filter or ui.prefix_filter
  ui.rebuild_json_path = settings.rebuild_json_path or ui.rebuild_json_path
  ui.compare_old_json_path = settings.compare_old_json_path or ui.compare_old_json_path
  ui.compare_new_json_path = settings.compare_new_json_path or ui.compare_new_json_path
  ui.rebuild_restore_fx = settings.rebuild_restore_fx ~= false
  ui.rebuild_restore_master_fx = settings.rebuild_restore_master_fx ~= false
  ui.rebuild_restore_sends = settings.rebuild_restore_sends ~= false
  ui.rebuild_create_missing_send_tracks = settings.rebuild_create_missing_send_tracks ~= false
  ui.custom_library_patterns = settings.custom_library_patterns or ui.custom_library_patterns
end

local function run_prompt_flow(current_settings)
  local settings, prompt_error = prompt_for_settings(current_settings)

  if not settings then
    if prompt_error and prompt_error ~= "User cancelled." then
      show_error(prompt_error)
    end
    return
  end

  save_settings(settings)

  local success, run_ok, result_message = xpcall(function()
    return run_mode(settings)
  end, function(message)
    return debug.traceback(message, 2)
  end)

  if not success then
    show_error("Script failed.\n\n" .. tostring(run_ok))
    return
  end

  if not run_ok then
    if result_message and result_message ~= "User cancelled." then
      show_error(result_message)
    end
    return
  end

  if result_message and result_message ~= "" then
    reaper.ShowMessageBox(result_message, SCRIPT_TITLE, 0)
  end
end

local function set_status(ui, message)
  ui.status_message = tostring(message or "")
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= rect_x + rect_w and y >= rect_y and y <= rect_y + rect_h
end

local function set_gfx_color(r, g, b, a)
  gfx.set((r or 0) / 255, (g or 0) / 255, (b or 0) / 255, (a or 255) / 255)
end

local function draw_rect(rect_x, rect_y, rect_w, rect_h, fill, r, g, b, a)
  set_gfx_color(r, g, b, a)
  gfx.rect(rect_x, rect_y, rect_w, rect_h, fill and 1 or 0)
end

local function draw_text(text, x, y, r, g, b, a, font_index, font_name, font_size)
  gfx.setfont(font_index or 1, font_name or "Segoe UI", font_size or 16)
  set_gfx_color(r, g, b, a)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function shorten_text(value, max_length)
  local text = tostring(value or "")
  if #text <= max_length then
    return text
  end
  if max_length <= 3 then
    return text:sub(1, max_length)
  end
  return text:sub(1, max_length - 3) .. "..."
end

local function draw_button(ui, id, label, rect_x, rect_y, rect_w, rect_h, enabled)
  local is_enabled = enabled ~= false
  local hovered = is_enabled and point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)

  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end

  local clicked = is_enabled and hovered and ui.mouse_released and ui.active_mouse_id == id
  local fill = is_enabled and (hovered and 74 or 56) or 34
  local border = is_enabled and (hovered and 132 or 92) or 55

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, fill, fill, fill + 4, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, border, border, border, 255)
  draw_text(label, rect_x + 10, rect_y + 8, is_enabled and 240 or 120, is_enabled and 240 or 120, is_enabled and 240 or 120, 255, 1, "Segoe UI", 15)

  return clicked
end

local function draw_checkbox(ui, id, label, rect_x, rect_y, value)
  local box_size = 18
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, box_size + 8 + 260, box_size)
  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end
  local changed = hovered and ui.mouse_released and ui.active_mouse_id == id

  draw_rect(rect_x, rect_y, box_size, box_size, true, 35, 35, 35, 255)
  draw_rect(rect_x, rect_y, box_size, box_size, false, 100, 100, 100, 255)
  if value then
    draw_rect(rect_x + 4, rect_y + 4, box_size - 8, box_size - 8, true, 110, 190, 120, 255)
  end
  draw_text(label, rect_x + box_size + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 15)

  return changed and not value or value
end

local function draw_radio(ui, id, label, rect_x, rect_y, value, target_value)
  local radius = 18
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, radius + 8 + 260, radius)
  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end
  local changed = hovered and ui.mouse_released and ui.active_mouse_id == id

  draw_rect(rect_x, rect_y, radius, radius, true, 35, 35, 35, 255)
  draw_rect(rect_x, rect_y, radius, radius, false, 100, 100, 100, 255)
  if value == target_value then
    draw_rect(rect_x + 5, rect_y + 5, radius - 10, radius - 10, true, 100, 175, 220, 255)
  end
  draw_text(label, rect_x + radius + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 15)

  if changed then
    return target_value
  end
  return value
end

local function draw_text_input(ui, id, label, rect_x, rect_y, rect_w, rect_h, value)
  draw_text(label, rect_x, rect_y - 22, 215, 215, 215, 255, 1, "Segoe UI", 14)

  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)
  if hovered and ui.mouse_pressed then
    ui.focus_field = id
    ui.active_mouse_id = nil
  elseif ui.mouse_pressed and not hovered and ui.focus_field == id then
    ui.focus_field = nil
  end

  local is_focused = ui.focus_field == id
  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 26, 26, 26, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, is_focused and 110 or 78, is_focused and 145 or 78, is_focused and 210 or 78, 255)

  local text_value = tostring(value or "")
  if is_focused and ui.key_char > 0 then
    if ui.key_char == 8 then
      text_value = text_value:sub(1, math.max(#text_value - 1, 0))
    elseif ui.key_char == 13 then
      ui.focus_field = nil
    elseif ui.key_char == 27 then
      ui.focus_field = nil
      ui.consume_escape = true
    elseif ui.key_char >= 32 and ui.key_char <= 126 then
      text_value = text_value .. string.char(ui.key_char)
    end
  end

  local draw_value = shorten_text(text_value, math.max(8, math.floor(rect_w / 8)))
  draw_text(draw_value, rect_x + 8, rect_y + 7, 240, 240, 240, 255, 1, "Consolas", 15)
  return text_value
end

local function show_mode_menu(ui, rect_x, rect_y)
  local items = {}
  local mapping = { "single", "batch", "rebuild", "compare" }
  for _, mode in ipairs(mapping) do
    local label = get_mode_label(mode)
    if mode == ui.mode then
      label = "!" .. label
    end
    items[#items + 1] = label
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  local chosen_mode = mapping[selection]
  if chosen_mode then
    ui.mode = chosen_mode
    if chosen_mode == "batch" then
      ui.source_scope = "all_folder_tracks"
    elseif chosen_mode == "single" and ui.source_scope == "all_folder_tracks" then
      ui.source_scope = "selected_folder"
    end
    save_ui_settings(ui)
    set_status(ui, "Mode: " .. get_mode_label(chosen_mode))
  end
end

local function browse_output_folder(current_value)
  local current_path = trim_string(current_value)
  if current_path == "" then
    current_path = get_default_output_dir()
  end

  if reaper.JS_Dialog_BrowseForFolder then
    local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select output folder", current_path)
    if ok and trim_string(folder) ~= "" then
      return normalize_path(folder)
    end
  end

  local ok, value = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Output Folder",
    1,
    "Output Folder",
    current_path
  )
  if ok then
    return normalize_path(value)
  end

  return nil
end

local function prompt_custom_library_entry(existing_entry)
  local existing_patterns = {}
  if existing_entry and existing_entry.patterns then
    for _, pattern in ipairs(existing_entry.patterns) do
      existing_patterns[#existing_patterns + 1] = pattern
    end
  end

  local ok, values = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Custom Library Pattern",
    2,
    table.concat({
      "extrawidth=420",
      "separator=|",
      "Library Name",
      "Path Patterns (; separated)",
    }, ","),
    table.concat({
      existing_entry and existing_entry.name or "",
      table.concat(existing_patterns, ";"),
    }, "|")
  )

  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 2)
  local name = trim_string(parts[1])
  local pattern_text = trim_string(parts[2])
  if name == "" then
    return nil, "Library name is required."
  end
  if pattern_text == "" then
    return nil, "At least one path pattern is required."
  end

  local patterns = {}
  for pattern in pattern_text:gmatch("[^;]+") do
    local clean = trim_string(pattern):lower()
    if clean ~= "" then
      patterns[#patterns + 1] = clean
    end
  end

  if #patterns == 0 then
    return nil, "At least one valid path pattern is required."
  end

  return {
    name = name,
    patterns = patterns,
  }
end

local function choose_custom_library_index(patterns, title)
  if #patterns == 0 then
    return nil
  end

  local items = {}
  for index, entry in ipairs(patterns) do
    items[#items + 1] = string.format("%d. %s", index, trim_string(entry.name))
  end

  gfx.x = gfx.mouse_x
  gfx.y = gfx.mouse_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection and selection > 0 then
    return selection
  end

  local ok, value = reaper.GetUserInputs(title, 1, "Library Index", "1")
  if not ok then
    return nil
  end

  local numeric = tonumber(trim_string(value))
  if not numeric then
    return nil
  end
  numeric = math.floor(clamp_number(numeric, 1, #patterns))
  return numeric
end

local function update_custom_library_patterns_from_ui(ui, patterns, status_message)
  ui.custom_library_patterns = serialize_custom_library_patterns(patterns)
  refresh_custom_library_patterns(ui.custom_library_patterns)
  save_ui_settings(ui)
  set_status(ui, status_message)
end

local function manage_custom_library_patterns(ui)
  local patterns = parse_custom_library_patterns(ui.custom_library_patterns)
  gfx.x = gfx.mouse_x
  gfx.y = gfx.mouse_y
  local selection = gfx.showmenu("Add Pattern...|Edit Pattern...|Remove Pattern...|Clear All")

  if selection == 1 then
    local entry, entry_error = prompt_custom_library_entry(nil)
    if not entry then
      if entry_error and entry_error ~= "User cancelled." then
        set_status(ui, entry_error)
      end
      return
    end
    patterns[#patterns + 1] = entry
    update_custom_library_patterns_from_ui(ui, patterns, "Added custom library: " .. entry.name)
    return
  end

  if selection == 2 then
    if #patterns == 0 then
      set_status(ui, "No custom library patterns to edit.")
      return
    end
    local index = choose_custom_library_index(patterns, SCRIPT_TITLE .. " - Edit Custom Library")
    if not index then
      return
    end
    local entry, entry_error = prompt_custom_library_entry(patterns[index])
    if not entry then
      if entry_error and entry_error ~= "User cancelled." then
        set_status(ui, entry_error)
      end
      return
    end
    patterns[index] = entry
    update_custom_library_patterns_from_ui(ui, patterns, "Updated custom library: " .. entry.name)
    return
  end

  if selection == 3 then
    if #patterns == 0 then
      set_status(ui, "No custom library patterns to remove.")
      return
    end
    local index = choose_custom_library_index(patterns, SCRIPT_TITLE .. " - Remove Custom Library")
    if not index then
      return
    end
    local removed_name = trim_string(patterns[index].name)
    table.remove(patterns, index)
    update_custom_library_patterns_from_ui(ui, patterns, "Removed custom library: " .. removed_name)
    return
  end

  if selection == 4 then
    local confirm = reaper.ShowMessageBox(
      "Clear all custom library patterns?",
      SCRIPT_TITLE,
      4
    )
    if confirm == 6 then
      update_custom_library_patterns_from_ui(ui, {}, "Cleared custom library patterns.")
    end
  end
end

local function draw_preview_panel(ui, rect_x, rect_y, rect_w, rect_h)
  local settings = build_settings_from_ui(ui)
  local output_dir = resolve_output_dir(settings.output_folder)
  local export_labels = {}
  local custom_patterns = parse_custom_library_patterns(settings.custom_library_patterns)

  if settings.export_console then
    export_labels[#export_labels + 1] = "Console"
  end
  if settings.export_markdown then
    export_labels[#export_labels + 1] = "Markdown"
  end
  if settings.export_csv then
    export_labels[#export_labels + 1] = "CSV"
  end
  if settings.export_json then
    export_labels[#export_labels + 1] = "JSON"
  end

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 20, 20, 20, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, 60, 60, 60, 255)

  local line_y = rect_y + 14
  local lines = {
    "Mode: " .. get_mode_label(settings.mode),
    "Scope: " .. get_scope_label(settings.source_scope),
    "Exports: " .. (#export_labels > 0 and table.concat(export_labels, ", ") or "(none)"),
    "Output Dir: " .. shorten_text(output_dir, 58),
    "Prefix Filter: " .. (settings.prefix_filter ~= "" and settings.prefix_filter or "(all)"),
    "Source Details: " .. (settings.include_source_info and "on" or "off"),
    "FX Params: " .. (settings.include_fx_parameters and (settings.verbose_fx_parameters and "verbose" or "filtered") or "summary only"),
    "Paths: " .. (settings.include_file_paths and "on" or "off"),
    "Sends: " .. (settings.include_sends and "on" or "off"),
    "Library Detect: " .. (settings.auto_detect_library and "on" or "off"),
    "Custom Libraries: " .. tostring(#custom_patterns),
    "Notes Prompt: " .. (settings.add_notes_prompt and "on" or "off"),
    "Auto Tags: " .. (settings.auto_tag_keywords and "on" or "off"),
  }

  if settings.mode == "rebuild" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Rebuild JSON: " .. shorten_text(settings.rebuild_json_path ~= "" and settings.rebuild_json_path or "(prompt on run)", 58)
    lines[#lines + 1] = "Restore FX: " .. ((settings.rebuild_restore_fx and settings.rebuild_restore_master_fx) and "layers + folder" or (settings.rebuild_restore_fx and "layers only" or (settings.rebuild_restore_master_fx and "folder only" or "off")))
    lines[#lines + 1] = "Restore Sends: " .. (settings.rebuild_restore_sends and "on" or "off")
    lines[#lines + 1] = "Create Send Tracks: " .. (settings.rebuild_create_missing_send_tracks and "on" or "off")
  elseif settings.mode == "compare" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Old JSON: " .. shorten_text(settings.compare_old_json_path ~= "" and settings.compare_old_json_path or "(prompt on run)", 61)
    lines[#lines + 1] = "New JSON: " .. shorten_text(settings.compare_new_json_path ~= "" and settings.compare_new_json_path or "(prompt on run)", 61)
  end

  draw_text("Current Configuration", rect_x + 14, line_y, 240, 240, 240, 255, 1, "Segoe UI Semibold", 16)
  line_y = line_y + 32

  for _, line in ipairs(lines) do
    if line == "" then
      line_y = line_y + 10
    else
      draw_text(shorten_text(line, 72), rect_x + 16, line_y, 205, 205, 205, 255, 1, "Consolas", 14)
      line_y = line_y + 22
    end
  end
end

local function perform_run_from_ui(ui)
  local settings = build_settings_from_ui(ui)
  if not has_any_output_enabled(settings) then
    set_status(ui, "Select at least one output format.")
    return
  end

  save_settings(settings)

  local success, run_ok, result_message = xpcall(function()
    return run_mode(settings)
  end, function(message)
    return debug.traceback(message, 2)
  end)

  if not success then
    reaper.ShowMessageBox(tostring(run_ok), SCRIPT_TITLE, 0)
    set_status(ui, "Run failed. See error dialog.")
    return
  end

  apply_settings_to_ui(ui, settings)

  if not run_ok then
    if result_message and result_message ~= "User cancelled." then
      reaper.ShowMessageBox(result_message, SCRIPT_TITLE, 0)
      set_status(ui, shorten_text(result_message, 96))
    else
      set_status(ui, "Action cancelled.")
    end
    return
  end

  local headline = result_message:match("([^\n]+)") or "Completed."
  set_status(ui, headline)
  reaper.ShowMessageBox(result_message, SCRIPT_TITLE, 0)
end

local function run_gfx_ui(current_settings)
  if not gfx or not gfx.init then
    return false
  end

  local ui = {
    width = 1100,
    height = 820,
    mode = current_settings.mode or DEFAULTS.mode,
    source_scope = current_settings.source_scope or DEFAULTS.source_scope,
    output_folder = current_settings.output_folder or DEFAULTS.output_folder,
    export_console = current_settings.export_console,
    export_markdown = current_settings.export_markdown,
    export_csv = current_settings.export_csv,
    export_json = current_settings.export_json,
    include_source_info = current_settings.include_source_info,
    include_fx_parameters = current_settings.include_fx_parameters,
    verbose_fx_parameters = current_settings.verbose_fx_parameters,
    include_file_paths = current_settings.include_file_paths,
    include_sends = current_settings.include_sends,
    add_notes_prompt = current_settings.add_notes_prompt,
    auto_detect_library = current_settings.auto_detect_library,
    auto_tag_keywords = current_settings.auto_tag_keywords,
    prefix_filter = current_settings.prefix_filter or DEFAULTS.prefix_filter,
    rebuild_json_path = current_settings.rebuild_json_path or DEFAULTS.rebuild_json_path,
    compare_old_json_path = current_settings.compare_old_json_path or DEFAULTS.compare_old_json_path,
    compare_new_json_path = current_settings.compare_new_json_path or DEFAULTS.compare_new_json_path,
    rebuild_restore_fx = current_settings.rebuild_restore_fx,
    rebuild_restore_master_fx = current_settings.rebuild_restore_master_fx,
    rebuild_restore_sends = current_settings.rebuild_restore_sends,
    rebuild_create_missing_send_tracks = current_settings.rebuild_create_missing_send_tracks,
    custom_library_patterns = current_settings.custom_library_patterns or DEFAULTS.custom_library_patterns,
    mouse_x = 0,
    mouse_y = 0,
    mouse_down = false,
    prev_mouse_down = false,
    mouse_pressed = false,
    mouse_released = false,
    active_mouse_id = nil,
    focus_field = nil,
    key_char = 0,
    consume_escape = false,
    status_message = "Ready.",
  }

  if ui.mode == "batch" then
    ui.source_scope = "all_folder_tracks"
  end

  gfx.init(SCRIPT_TITLE, ui.width, ui.height, 0)
  if (gfx.w or 0) <= 0 then
    return false
  end

  local function loop()
    local key = gfx.getchar()
    if key < 0 then
      save_ui_settings(ui)
      gfx.quit()
      return
    end

    ui.key_char = key
    ui.consume_escape = false
    ui.mouse_x = gfx.mouse_x
    ui.mouse_y = gfx.mouse_y
    ui.mouse_down = ((gfx.mouse_cap or 0) % 2) == 1
    ui.mouse_pressed = ui.mouse_down and not ui.prev_mouse_down
    ui.mouse_released = (not ui.mouse_down) and ui.prev_mouse_down

    draw_rect(0, 0, ui.width, ui.height, true, 16, 18, 22, 255)
    draw_text(SCRIPT_TITLE, 24, 18, 245, 245, 245, 255, 1, "Segoe UI Semibold", 22)
    draw_text("Phase 3: rebuild, compare, recipe-book export, custom library patterns", 24, 48, 150, 170, 185, 255, 1, "Segoe UI", 13)

    draw_rect(20, 82, 500, 680, true, 24, 24, 24, 255)
    draw_rect(20, 82, 500, 680, false, 58, 58, 58, 255)
    draw_rect(540, 82, 540, 680, true, 24, 24, 24, 255)
    draw_rect(540, 82, 540, 680, false, 58, 58, 58, 255)

    draw_text("Mode", 40, 104, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    if draw_button(ui, "mode_menu", get_mode_label(ui.mode), 40, 132, 220, 34, true) then
      show_mode_menu(ui, 40, 166)
    end

    draw_text("Source", 40, 192, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    local previous_scope = ui.source_scope
    ui.source_scope = draw_radio(ui, "scope_selected", "Selected folder track", 40, 222, ui.source_scope, "selected_folder")
    ui.source_scope = draw_radio(ui, "scope_all", "All folder tracks", 40, 250, ui.source_scope, "all_folder_tracks")
    if ui.mode == "single" and previous_scope ~= ui.source_scope and ui.source_scope == "all_folder_tracks" then
      ui.mode = "batch"
      set_status(ui, "Scope changed to all folder tracks. Mode switched to Batch All.")
    elseif ui.mode == "batch" and previous_scope ~= ui.source_scope and ui.source_scope == "selected_folder" then
      ui.mode = "single"
      set_status(ui, "Scope changed to selected folder. Mode switched to Single Recipe.")
    end

    ui.prefix_filter = draw_text_input(ui, "prefix_filter", "Prefix Filter", 40, 316, 320, 34, ui.prefix_filter)

    draw_text("Output Format", 40, 386, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    ui.export_console = draw_checkbox(ui, "export_console", "Console report", 40, 418, ui.export_console)
    ui.export_markdown = draw_checkbox(ui, "export_markdown", "Markdown (.md)", 40, 446, ui.export_markdown)
    ui.export_csv = draw_checkbox(ui, "export_csv", "CSV (.csv)", 40, 474, ui.export_csv)
    ui.export_json = draw_checkbox(ui, "export_json", "JSON (.json)", 40, 502, ui.export_json)

    ui.output_folder = draw_text_input(ui, "output_folder", "Output Folder", 40, 570, 350, 34, ui.output_folder)
    if draw_button(ui, "browse_output", "Browse...", 400, 570, 90, 34, true) then
      local folder = browse_output_folder(ui.output_folder)
      if folder then
        ui.output_folder = folder
        set_status(ui, "Output folder updated.")
      end
    end

    draw_text("Detail Level", 560, 104, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    ui.include_source_info = draw_checkbox(ui, "include_source_info", "Source file info", 560, 136, ui.include_source_info)
    ui.include_fx_parameters = draw_checkbox(ui, "include_fx_parameters", "FX parameter details", 560, 164, ui.include_fx_parameters)
    ui.include_sends = draw_checkbox(ui, "include_sends", "Sends / routing", 560, 192, ui.include_sends)
    ui.verbose_fx_parameters = draw_checkbox(ui, "verbose_fx_parameters", "All FX parameters (verbose)", 560, 220, ui.verbose_fx_parameters)
    ui.include_file_paths = draw_checkbox(ui, "include_file_paths", "Include file paths", 560, 248, ui.include_file_paths)
    ui.auto_detect_library = draw_checkbox(ui, "auto_detect_library", "Auto-detect source library", 560, 276, ui.auto_detect_library)
    if draw_button(ui, "custom_libraries", "Library Patterns...", 560, 304, 180, 32, true) then
      manage_custom_library_patterns(ui)
    end

    draw_text("Notes & Tags", 560, 348, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    ui.add_notes_prompt = draw_checkbox(ui, "add_notes_prompt", "Prompt for design notes", 560, 380, ui.add_notes_prompt)
    ui.auto_tag_keywords = draw_checkbox(ui, "auto_tag_keywords", "Auto-tag from recipe name", 560, 408, ui.auto_tag_keywords)

    draw_preview_panel(ui, 560, 456, 500, 212)

    local run_label = ui.mode == "batch" and "Batch Crawl" or
      (ui.mode == "single" and "Crawl Recipe" or
      (ui.mode == "compare" and "Run Compare" or
      (ui.mode == "rebuild" and "Run Rebuild" or "Run Mode")))
    if draw_button(ui, "run_mode", run_label, 560, 694, 170, 38, true) then
      perform_run_from_ui(ui)
    end
    if draw_button(ui, "run_compare", "Compare...", 742, 694, 110, 38, true) then
      ui.mode = "compare"
      perform_run_from_ui(ui)
    end
    if draw_button(ui, "run_rebuild", "Rebuild...", 864, 694, 110, 38, true) then
      ui.mode = "rebuild"
      perform_run_from_ui(ui)
    end
    if draw_button(ui, "close", "Close", 986, 694, 74, 38, true) then
      save_ui_settings(ui)
      gfx.quit()
      return
    end

    draw_rect(20, 778, 1060, 1, true, 48, 48, 48, 255)
    draw_text(shorten_text(ui.status_message, 150), 24, 788, 170, 205, 220, 255, 1, "Segoe UI", 13)

    if key == 27 and not ui.consume_escape and ui.focus_field == nil then
      save_ui_settings(ui)
      gfx.quit()
      return
    end

    if ui.mouse_released then
      ui.active_mouse_id = nil
    end
    ui.prev_mouse_down = ui.mouse_down

    gfx.update()
    reaper.defer(loop)
  end

  loop()
  return true
end

local function main()
  clear_console()
  local current_settings = load_settings()
  local ok = run_gfx_ui(current_settings)
  if not ok then
    run_prompt_flow(current_settings)
  end
end

main()
