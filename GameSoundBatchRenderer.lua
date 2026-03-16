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
  for key, default_value in pairs(DEFAULTS) do
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
  for key, value in pairs(settings) do
    local encoded = value
    if type(value) == "boolean" then
      encoded = bool_to_string(value)
    end
    reaper.SetExtState(EXT_SECTION, key, tostring(encoded), true)
  end
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
    "Prefix (SFX/AMB/MUS/UI/VO/FOL),Category,Case Style (pascal/snake),Naming Source (regions/track)",
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

-- Execute the full prompt -> preview -> render flow.
local function main()
  local settings = load_settings()

  if not prompt_naming_settings(settings) then
    return
  end

  if not prompt_render_settings(settings) then
    return
  end

  if not prompt_output_settings(settings) then
    return
  end

  local valid, validation_error = validate_settings(settings)
  if not valid then
    reaper.ShowMessageBox(validation_error, SCRIPT_TITLE, 0)
    return
  end

  save_settings(settings)

  local jobs, build_error = build_render_jobs(settings)
  if not jobs then
    reaper.ShowMessageBox(build_error, SCRIPT_TITLE, 0)
    return
  end

  local generated_duplicates, existing_files = inspect_job_conflicts(jobs)
  if not reject_generated_duplicates(generated_duplicates) then
    return
  end

  if not confirm_existing_files(existing_files) then
    return
  end

  local action = choose_preview_or_render(settings, jobs)
  if action ~= "render" then
    return
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
end

main()
