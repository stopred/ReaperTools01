-- Game Sound Recipe Logger v1.0
-- Reaper ReaScript (Lua)
-- Auto-documents game-audio recipe data from folder-based REAPER sessions.
--
-- Usage:
-- [Crawl]   Select a recipe folder track, or an item inside one, then run the script.
-- [Batch]   Crawl every top-level folder recipe in the current project.
-- [Export]  Write Markdown, CSV, and/or JSON recipe documents.
--
-- Phase 1 status:
-- - Implemented: single recipe crawl, batch crawl, console report, Markdown/CSV/JSON export,
--   source file inspection, FX chain capture, notes/tags prompt, ExtState persistence.
-- - Planned later: rebuild from JSON, recipe diff, gfx GUI.
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
  output_format = "markdown",
  output_folder = "",
  include_fx_parameters = true,
  include_file_paths = true,
  add_notes_prompt = true,
  prefix_filter = "",
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
    log_line("     Library:   " .. (ingredient.source.library_name or "Unknown"))
    if settings.include_file_paths then
      log_line("     Path:      " .. (ingredient.source.filepath ~= "" and ingredient.source.filepath or "(none)"))
    end
    if ingredient.source.file_exists == false and ingredient.source.filepath ~= "" then
      log_line("     Warning:   source file not found on disk")
    end
    log_line("     Original:  " .. format_source_overview(ingredient.source))
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

  log_line("")
  log_line(repeat_char("=", REPORT_WIDTH))
  log_line("  Recipe Summary")
  log_line("  " .. repeat_char("-", REPORT_WIDTH - 4))
  log_line("  Source Files:   " .. tostring(count_unique_sources(recipe)))
  log_line("  Libraries:      " .. (#libraries > 0 and table.concat(libraries, ", ") or "(none)"))
  log_line("  Total FX:       " .. tostring(count_total_fx(recipe)))
  log_line("  Total Sends:    " .. tostring(count_total_sends(recipe)))
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

local function append_markdown_fx_chain(lines, heading_level, title, fx_chain, include_parameters)
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

  if include_parameters then
    for index, fx in ipairs(fx_chain) do
      if #fx.parameters > 0 then
        lines[#lines + 1] = heading_prefix .. "# [" .. tostring(index) .. "] " .. escape_markdown_cell(fx.name)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "| Param | Display | Normalized |"
        lines[#lines + 1] = "|-------|---------|------------|"

        for _, parameter in ipairs(fx.parameters) do
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

  append_markdown_fx_chain(lines, 2, "Master FX Chain", recipe.master_fx, settings.include_fx_parameters)

  for index, ingredient in ipairs(recipe.ingredients) do
    local flags = format_take_flags(ingredient)

    lines[#lines + 1] = "## Layer " .. tostring(index) .. ": " .. escape_markdown_cell(ingredient.layer_label)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Source"
    lines[#lines + 1] = "| Field | Value |"
    lines[#lines + 1] = "|-------|-------|"
    lines[#lines + 1] = "| File | `" .. escape_inline_code(ingredient.source.filename) .. "` |"
    lines[#lines + 1] = "| Library | " .. escape_markdown_cell(ingredient.source.library_name or "Unknown") .. " |"
    lines[#lines + 1] = "| Exists On Disk | " .. tostring(ingredient.source.file_exists and "Yes" or "No") .. " |"
    if settings.include_file_paths then
      lines[#lines + 1] = "| Path | `" .. escape_inline_code(ingredient.source.filepath ~= "" and ingredient.source.filepath or "(none)") .. "` |"
    end
    lines[#lines + 1] = "| Original | " .. escape_markdown_cell(format_source_overview(ingredient.source)) .. " |"
    if ingredient.source.file_size_kb then
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

    append_markdown_fx_chain(lines, 3, "FX Chain", ingredient.fx_chain, settings.include_fx_parameters)

    if #ingredient.sends > 0 then
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

local function build_csv_rows_for_recipe(recipe)
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
      ingredient.source.library_name or "Unknown",
      string.format("%.3f", ingredient.item.length or 0),
      tostring(ingredient.take.pitch_cents or 0),
      string.format("%.1f", ingredient.take.volume_db or 0),
      string.format("%.1f", ingredient.track.volume_db or 0),
      string.format("%.1f", ingredient.effective_volume_db or 0),
      format_pan_short(ingredient.track.pan),
      fx_columns[1],
      fx_columns[2],
      fx_columns[3],
      table.concat(send_names, "; "),
      table.concat(send_volumes, "; "),
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

local function export_recipe_csv(recipe, filepath)
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

  local body_rows = build_csv_rows_for_recipe(recipe)
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

  if not settings.include_file_paths then
    copied.project_file = ""
    for _, ingredient in ipairs(copied.ingredients) do
      ingredient.source.filepath = ""
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

local function wants_markdown(output_format)
  return output_format == "markdown" or output_format == "all"
end

local function wants_csv(output_format)
  return output_format == "csv" or output_format == "all"
end

local function wants_json(output_format)
  return output_format == "json" or output_format == "all"
end

local function wants_file_output(output_format)
  return output_format ~= "console"
end

local function append_written_file(written_files, path)
  written_files[#written_files + 1] = normalize_path(path)
end

local function export_recipes(recipes, settings)
  local written_files = {}

  if not wants_file_output(settings.output_format) then
    return written_files
  end

  local output_dir = resolve_output_dir(settings.output_folder)
  if not ensure_directory(output_dir) then
    return nil, "Could not create output folder: " .. output_dir
  end

  if #recipes == 1 then
    local recipe = recipes[1]
    local safe_name = sanitize_filename(recipe.name)

    if wants_markdown(settings.output_format) then
      local path = join_paths(output_dir, safe_name .. ".md")
      local ok, error_message = export_recipe_markdown(recipe, path, settings)
      if not ok then
        return nil, "Markdown export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    if wants_csv(settings.output_format) then
      local path = join_paths(output_dir, safe_name .. ".csv")
      local ok, error_message = export_recipe_csv(recipe, path)
      if not ok then
        return nil, "CSV export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    if wants_json(settings.output_format) then
      local path = join_paths(output_dir, safe_name .. ".json")
      local ok, error_message = export_recipe_json(recipe, path, settings)
      if not ok then
        return nil, "JSON export failed: " .. tostring(error_message)
      end
      append_written_file(written_files, path)
    end

    return written_files
  end

  if wants_markdown(settings.output_format) then
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

  if wants_csv(settings.output_format) then
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
      local recipe_rows = build_csv_rows_for_recipe(recipe)
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

  if wants_json(settings.output_format) then
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
  settings.output_format = parse_output_format(settings.output_format, DEFAULTS.output_format)
  settings.prefix_filter = trim_string(settings.prefix_filter)
  settings.output_folder = trim_string(settings.output_folder)
  return settings
end

local function save_settings(settings)
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

  return settings
end

local function apply_optional_notes(recipe, settings)
  if not settings.add_notes_prompt then
    return recipe
  end

  local notes, tags, difficulty = prompt_recipe_notes(recipe.name)
  if notes ~= nil then
    recipe.notes = notes
    recipe.tags = tags or {}
    recipe.difficulty = difficulty
  end

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

local function run_single(settings)
  local folder_track = find_selected_recipe_folder()
  if not folder_track then
    return false, "Select a folder track, or a media item inside a recipe folder, then run the script again."
  end

  local recipe = crawl_recipe(folder_track)
  apply_optional_notes(recipe, settings)
  print_recipe_report(recipe, settings)

  local written_files, export_error = export_recipes({ recipe }, settings)
  if not written_files then
    return false, export_error
  end

  return true, "Recipe captured: " .. recipe.name .. "\n\n" .. summarize_written_files(written_files)
end

local function run_batch(settings)
  local recipes = batch_crawl_all_recipes(settings)
  if #recipes == 0 then
    local filter_text = settings.prefix_filter ~= "" and (" with prefix '" .. settings.prefix_filter .. "'") or ""
    return false, "No top-level folder recipes were found" .. filter_text .. "."
  end

  for _, recipe in ipairs(recipes) do
    apply_optional_notes(recipe, settings)
    print_recipe_report(recipe, settings)
  end

  local written_files, export_error = export_recipes(recipes, settings)
  if not written_files then
    return false, export_error
  end

  return true, string.format("Crawled %d recipes.\n\n%s", #recipes, summarize_written_files(written_files))
end

local function run_mode(settings)
  if settings.mode == "single" then
    return run_single(settings)
  end
  if settings.mode == "batch" then
    return run_batch(settings)
  end
  if settings.mode == "rebuild" then
    return false, "Rebuild mode is planned for a later phase. This build implements crawl and export only."
  end
  if settings.mode == "compare" then
    return false, "Compare mode is planned for a later phase. This build implements crawl and export only."
  end
  return false, "Unsupported mode: " .. tostring(settings.mode)
end

local function main()
  clear_console()
  local current_settings = load_settings()
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
    show_error(result_message)
    return
  end

  if result_message and result_message ~= "" then
    reaper.ShowMessageBox(result_message, SCRIPT_TITLE, 0)
  end
end

main()
