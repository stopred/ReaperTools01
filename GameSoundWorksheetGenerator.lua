-- Game Sound Worksheet Generator v1.0
-- Reaper ReaScript (Lua)
-- Game-audio marker/region worksheet export and import helper.
--
-- Usage:
-- [Export]    Export project regions/markers to CSV and/or text report.
-- [Import]    Read an external CSV/asset list and create empty regions.
-- [Dashboard] Print the current project progress report to the console.
-- [Sync]      Preview/apply CSV status/name changes back to the project.
-- [GUI]       Open the gfx control panel for export/import/dashboard/sync.
--
-- Requirements: REAPER v7.0+
-- Related scripts: GameSoundLayeringTemplate.lua,
--                  GameSoundVariationGenerator.lua,
--                  GameSoundTailProcessor.lua,
--                  GameSoundLoudnessNormalizer.lua,
--                  GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Worksheet Generator v1.0"
local EXT_SECTION = "GameSoundWorksheet"
local REPORT_WIDTH = 78

local STATUS_ORDER = {
  "Done",
  "WIP",
  "Review",
  "Revision",
  "Todo",
  "Hold",
  "Approved",
  "Unset",
  "Unknown",
}

local DEFAULT_STATUS_COLORS = {
  Done = { r = 80,  g = 200, b = 80  },
  WIP = { r = 220, g = 200, b = 60  },
  Review = { r = 60,  g = 140, b = 220 },
  Revision = { r = 220, g = 130, b = 40  },
  Todo = { r = 200, g = 60,  b = 60  },
  Hold = { r = 150, g = 150, b = 150 },
  Approved = { r = 60,  g = 180, b = 160 },
}

local function clone_status_colors(source)
  local copy = {}
  for status, color in pairs(source) do
    copy[status] = {
      r = tonumber(color.r) or 0,
      g = tonumber(color.g) or 0,
      b = tonumber(color.b) or 0,
    }
  end
  return copy
end

local STATUS_COLORS = clone_status_colors(DEFAULT_STATUS_COLORS)

local DEFAULTS = {
  mode = "export",
  gui_mode = "export",
  include_regions = true,
  include_markers = false,
  only_time_selection = false,
  include_audio_analysis = false,
  include_pivot_summary = false,
  output_format = "csv",
  export_path = "",
  add_bom = true,
  auto_open_export = false,
  import_csv_path = "",
  start_position = "cursor",
  gap_between_regions = 0.5,
  default_duration = 2.0,
  default_prefix = "SFX",
  skip_duplicates = true,
  auto_color_by_status = true,
  auto_expand_variations = false,
  sync_csv_path = "",
  sync_update_status = true,
  sync_update_names = true,
  sync_include_markers = false,
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

local function clamp_number(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function pad_right(text, width)
  local value = tostring(text or "")
  if #value >= width then
    return value
  end
  return value .. string.rep(" ", width - #value)
end

local function pad_left(text, width)
  local value = tostring(text or "")
  if #value >= width then
    return value
  end
  return string.rep(" ", width - #value) .. value
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

local function shallow_copy(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    copy[key] = value
  end
  return copy
end

local function ensure_directory(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end
  reaper.RecursiveCreateDirectory(normalized, 0)
  return true
end

local function open_path_with_shell(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end

  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(normalized)
    return true
  end

  os.execute('start "" "' .. normalized:gsub("/", "\\") .. '"')
  return true
end

local function parse_hex_color(value)
  local text = trim_string(value):upper():gsub("#", "")
  if text:match("^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
    return {
      r = tonumber(text:sub(1, 2), 16),
      g = tonumber(text:sub(3, 4), 16),
      b = tonumber(text:sub(5, 6), 16),
    }
  end
  return nil
end

local function format_hex_color(color)
  if not color then
    return "#000000"
  end
  return string.format("#%02X%02X%02X", tonumber(color.r) or 0, tonumber(color.g) or 0, tonumber(color.b) or 0)
end

local function serialize_status_colors()
  local parts = {}
  for _, status in ipairs({ "Done", "WIP", "Review", "Revision", "Todo", "Hold", "Approved" }) do
    local color = STATUS_COLORS[status] or DEFAULT_STATUS_COLORS[status]
    parts[#parts + 1] = status .. "=" .. format_hex_color(color)
  end
  return table.concat(parts, ";")
end

local function load_status_colors()
  STATUS_COLORS = clone_status_colors(DEFAULT_STATUS_COLORS)
  local stored = reaper.GetExtState(EXT_SECTION, "status_colors")
  if trim_string(stored) == "" then
    return
  end

  for token in tostring(stored):gmatch("[^;]+") do
    local status, color_value = token:match("^([^=]+)=(.+)$")
    status = trim_string(status)
    if status ~= "" and DEFAULT_STATUS_COLORS[status] then
      local parsed = parse_hex_color(color_value or "")
      if parsed then
        STATUS_COLORS[status] = parsed
      end
    end
  end
end

local function save_status_colors()
  reaper.SetExtState(EXT_SECTION, "status_colors", serialize_status_colors(), true)
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

local function get_export_base_path(configured_path)
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local auto_base = join_paths(join_paths(reaper.GetProjectPath(""), "Worksheets"), get_project_name() .. "_worksheet_" .. timestamp)

  local configured = trim_string(configured_path)
  if configured == "" then
    return auto_base
  end

  configured = normalize_path(configured)
  if configured:match("/$") then
    return join_paths(configured, get_project_name() .. "_worksheet_" .. timestamp)
  end

  if configured:match("%.[^%.\\/]+$") then
    return strip_extension(configured)
  end

  return configured
end

local function resolve_export_paths(settings)
  local base_path = get_export_base_path(settings.export_path)
  return base_path .. ".csv", base_path .. ".txt", base_path .. "_pivot.csv"
end

local function load_settings()
  load_status_colors()
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

local function save_settings(settings)
  save_status_colors()
  for key, value in pairs(settings) do
    local encoded = value
    if type(value) == "boolean" then
      encoded = bool_to_string(value)
    end
    reaper.SetExtState(EXT_SECTION, key, tostring(encoded), true)
  end
end

local function normalize_mode(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "export" or lowered == "e" then
    return "export"
  end
  if lowered == "import" or lowered == "i" then
    return "import"
  end
  if lowered == "dashboard" or lowered == "d" then
    return "dashboard"
  end
  if lowered == "sync" or lowered == "s" then
    return "sync"
  end
  if lowered == "gui" or lowered == "g" then
    return "gui"
  end
  return default_value
end

local function normalize_output_format(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "csv" then
    return "csv"
  end
  if lowered == "report" or lowered == "text" then
    return "report"
  end
  if lowered == "both" then
    return "both"
  end
  return default_value
end

local function normalize_token(value)
  return trim_string(value):lower():gsub("[%s%-%_]+", "")
end

local function canonicalize_status(value)
  local token = normalize_token(value)
  if token == "" then
    return nil
  end

  local aliases = {
    done = "Done",
    complete = "Done",
    completed = "Done",
    finish = "Done",
    finished = "Done",
    wip = "WIP",
    inprogress = "WIP",
    working = "WIP",
    progress = "WIP",
    review = "Review",
    pendingreview = "Review",
    revision = "Revision",
    revise = "Revision",
    revisions = "Revision",
    todo = "Todo",
    new = "Todo",
    pending = "Todo",
    hold = "Hold",
    onhold = "Hold",
    blocked = "Hold",
    pause = "Hold",
    paused = "Hold",
    approved = "Approved",
    approve = "Approved",
    unset = "Unset",
    unknown = "Unknown",
  }

  return aliases[token]
end

local function map_priority_to_status(value)
  local direct_status = canonicalize_status(value)
  if direct_status then
    return direct_status
  end

  local token = normalize_token(value)
  if token == "urgent" or token == "high" or token == "medium" or token == "med" or token == "low" then
    return "Todo"
  end

  return "Todo"
end

local function get_color_components(native_color)
  if not native_color or native_color == 0 then
    return nil, nil, nil
  end
  return reaper.ColorFromNative(native_color & 0xFFFFFF)
end

local function detect_status_from_color(native_color)
  if not native_color or native_color == 0 then
    return "Unset"
  end

  local r, g, b = get_color_components(native_color)
  if not r then
    return "Unknown"
  end

  local min_distance = math.huge
  local best_status = "Unknown"

  for status, reference in pairs(STATUS_COLORS) do
    local distance = math.sqrt((r - reference.r) ^ 2 + (g - reference.g) ^ 2 + (b - reference.b) ^ 2)
    if distance < min_distance then
      min_distance = distance
      best_status = status
    end
  end

  if min_distance > 100 then
    return "Unknown"
  end

  return best_status
end

local function get_color_for_status(status)
  local resolved = canonicalize_status(status) or map_priority_to_status(status)
  local reference = STATUS_COLORS[resolved]
  if not reference then
    return 0
  end
  return reaper.ColorToNative(reference.r, reference.g, reference.b) | 0x1000000
end

local function parse_asset_name(name)
  local value = trim_string(name)
  if value == "" then
    return nil, nil, "", nil
  end

  local parts = {}
  for token in value:gmatch("[^_]+") do
    parts[#parts + 1] = token
  end

  local variation = nil
  if #parts >= 2 and tostring(parts[#parts]):match("^%d+$") then
    variation = tostring(parts[#parts])
    table.remove(parts, #parts)
  end

  if #parts >= 3 then
    local prefix = parts[1]
    local category = parts[2]
    local asset_parts = {}
    for index = 3, #parts do
      asset_parts[#asset_parts + 1] = parts[index]
    end
    return prefix, category, table.concat(asset_parts, "_"), variation
  end

  if #parts == 2 then
    return parts[1], nil, parts[2], variation
  end

  return nil, nil, value, variation
end

local function format_timecode(seconds)
  if seconds == nil then
    return ""
  end

  local total = tonumber(seconds) or 0.0
  local mins = math.floor(total / 60.0)
  local secs = total - (mins * 60.0)
  return string.format("%d:%05.2f", mins, secs)
end

local function format_decimal(value, decimals)
  if value == nil then
    return ""
  end
  local fmt = "%." .. tostring(decimals or 3) .. "f"
  return string.format(fmt, tonumber(value) or 0.0)
end

local function format_percent(value, total)
  local ratio = total > 0 and ((value / total) * 100.0) or 0.0
  return string.format("%.1f%%", ratio)
end

local function csv_escape(value)
  local text = tostring(value or "")
  if text:find('[,"\n\r]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function write_text_file(filepath, content, add_bom)
  ensure_directory(dirname(filepath))

  local file = io.open(filepath, "wb")
  if not file then
    return false, "Cannot create file: " .. tostring(filepath)
  end

  if add_bom then
    file:write("\xEF\xBB\xBF")
  end
  file:write(content or "")
  file:close()
  return true
end

local function browse_for_read_file(current_path, title, extension)
  if not reaper.GetUserFileNameForRead then
    return nil
  end

  local ok, selected = reaper.GetUserFileNameForRead(
    trim_string(current_path or ""),
    title or SCRIPT_TITLE,
    extension or ""
  )

  if not ok then
    return nil
  end

  return trim_string(selected)
end

local function prompt_single_value(title, caption, default_value, width)
  local captions = caption
  if width then
    captions = string.format("extrawidth=%d,%s", width, caption)
  end

  local ok, value = reaper.GetUserInputs(title, 1, captions, tostring(default_value or ""))
  if not ok then
    return nil
  end

  return trim_string(value)
end

local function get_time_selection()
  return reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
end

local function entry_is_in_scope(is_region, start_pos, end_pos, only_time_selection)
  if not only_time_selection then
    return true
  end

  local selection_start, selection_end = get_time_selection()
  if selection_end <= selection_start then
    return true
  end

  if is_region then
    return start_pos < selection_end and end_pos > selection_start
  end

  return start_pos >= selection_start and start_pos <= selection_end
end

local function range_has_audio(start_pos, end_pos)
  local item_count = reaper.CountMediaItems(0)
  for index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, index)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_start < end_pos and item_end > start_pos then
      return true
    end
  end
  return false
end

local function log10(value)
  return math.log(value) / math.log(10)
end

local function linear_to_db(linear_value)
  local safe = math.max(math.abs(tonumber(linear_value) or 0.0), 1e-12)
  return 20.0 * log10(safe)
end

local function create_region_analysis_context()
  local master_track = reaper.GetMasterTrack and reaper.GetMasterTrack(0) or nil
  if not master_track or not reaper.CreateTrackAudioAccessor or not reaper.GetAudioAccessorSamples or not reaper.new_array then
    return nil
  end

  local accessor = reaper.CreateTrackAudioAccessor(master_track)
  if not accessor then
    return nil
  end

  return {
    accessor = accessor,
    sample_rate = 48000,
    num_channels = 2,
    block_size = 2048,
  }
end

local function destroy_region_analysis_context(context)
  if context and context.accessor and reaper.DestroyAudioAccessor then
    reaper.DestroyAudioAccessor(context.accessor)
  end
end

local function analyze_region_audio(context, start_pos, end_pos)
  if not context or not context.accessor or end_pos <= start_pos then
    return nil, nil, range_has_audio(start_pos, end_pos)
  end

  local total_frames = math.max(1, math.floor((end_pos - start_pos) * context.sample_rate + 0.5))
  local buffer = reaper.new_array(context.block_size * context.num_channels)
  local peak_linear = 0.0
  local total_sum_squares = 0.0
  local total_count = 0
  local frame_cursor = 0

  while frame_cursor < total_frames do
    local frames_to_read = math.min(context.block_size, total_frames - frame_cursor)
    buffer.clear()

    local retval = reaper.GetAudioAccessorSamples(
      context.accessor,
      context.sample_rate,
      context.num_channels,
      start_pos + (frame_cursor / context.sample_rate),
      frames_to_read,
      buffer
    )

    if retval < 0 then
      return nil, nil, range_has_audio(start_pos, end_pos)
    end

    if retval ~= 0 then
      for frame_index = 0, frames_to_read - 1 do
        local base_index = frame_index * context.num_channels
        for channel = 1, context.num_channels do
          local sample = buffer[base_index + channel]
          local abs_sample = math.abs(sample)
          local squared = sample * sample

          if abs_sample > peak_linear then
            peak_linear = abs_sample
          end

          total_sum_squares = total_sum_squares + squared
          total_count = total_count + 1
        end
      end
    end

    frame_cursor = frame_cursor + frames_to_read
  end

  if total_count == 0 or peak_linear <= 1e-6 then
    return nil, nil, false
  end

  local rms_linear = math.sqrt(total_sum_squares / total_count)
  local peak_db = linear_to_db(peak_linear)
  local rms_db = rms_linear > 1e-6 and linear_to_db(rms_linear) or nil

  return peak_db, rms_db, true
end

local function collect_all_regions_and_markers(options)
  local results = {}
  local index = 0
  local analysis_context = options.include_audio_analysis and create_region_analysis_context() or nil

  while true do
    local retval, is_region, position, region_end, name, marker_index, native_color =
      reaper.EnumProjectMarkers3(0, index)

    if retval == 0 then
      break
    end

    local include_entry = false
    if is_region and options.include_regions then
      include_entry = true
    elseif (not is_region) and options.include_markers then
      include_entry = true
    end

    if include_entry and entry_is_in_scope(is_region, position, region_end, options.only_time_selection) then
      local prefix, category, asset_name, variation = parse_asset_name(name)
      local entry = {
        index = marker_index,
        type = is_region and "region" or "marker",
        name = tostring(name or ""),
        position = position,
        region_end = is_region and region_end or nil,
        length = is_region and math.max(0.0, region_end - position) or nil,
        native_color = native_color or 0,
        prefix = prefix,
        category = category,
        asset_name = asset_name,
        variation = variation,
        peak_dbfs = nil,
        rms_dbfs = nil,
        has_audio = nil,
        status = detect_status_from_color(native_color),
        notes = "",
      }

      if options.include_audio_analysis and is_region then
        entry.peak_dbfs, entry.rms_dbfs, entry.has_audio = analyze_region_audio(analysis_context, position, region_end)
      end

      results[#results + 1] = entry
    end

    index = index + 1
  end

  table.sort(results, function(left, right)
    if left.position == right.position then
      return tostring(left.name) < tostring(right.name)
    end
    return left.position < right.position
  end)

  destroy_region_analysis_context(analysis_context)
  return results
end

local function build_category_label(entry)
  local prefix = trim_string(entry.prefix or "")
  local category = trim_string(entry.category or "")

  if prefix ~= "" and category ~= "" then
    return prefix .. "_" .. category
  end
  if prefix ~= "" then
    return prefix
  end
  if category ~= "" then
    return category
  end
  if entry.type == "marker" then
    return "Markers"
  end
  return "Uncategorized"
end

local function get_display_item_name(entry)
  local asset_name = trim_string(entry.asset_name or "")
  local variation = trim_string(entry.variation or "")
  if asset_name ~= "" then
    if variation ~= "" then
      return asset_name .. "_" .. variation
    end
    return asset_name
  end
  return trim_string(entry.name or "")
end

local function summarize_entries(data)
  local summary = {
    total = #data,
    regions = 0,
    markers = 0,
    status_totals = {},
    categories = {},
  }

  for _, status in ipairs(STATUS_ORDER) do
    summary.status_totals[status] = 0
  end

  for _, entry in ipairs(data) do
    if entry.type == "region" then
      summary.regions = summary.regions + 1
    else
      summary.markers = summary.markers + 1
    end

    local status = canonicalize_status(entry.status) or entry.status or "Unset"
    if summary.status_totals[status] == nil then
      summary.status_totals[status] = 0
    end
    summary.status_totals[status] = summary.status_totals[status] + 1

    local category_key = build_category_label(entry)
    local category = summary.categories[category_key]
    if not category then
      category = {
        key = category_key,
        items = {},
        status_totals = {},
      }
      summary.categories[category_key] = category
    end

    category.items[#category.items + 1] = entry
    category.status_totals[status] = (category.status_totals[status] or 0) + 1
  end

  return summary
end

local function draw_progress_bar(done_count, total_count, width)
  width = width or 40
  local ratio = total_count > 0 and (done_count / total_count) or 0.0
  local filled = math.floor(ratio * width + 0.5)
  filled = clamp_number(filled, 0, width)
  local empty = width - filled
  local bar = string.rep("#", filled) .. string.rep(".", empty)
  return string.format("[%s] %d/%d (%s)", bar, done_count, total_count, format_percent(done_count, total_count))
end

local function sort_category_keys(categories)
  local keys = {}
  for key in pairs(categories) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return left:lower() < right:lower()
  end)
  return keys
end

local function build_text_report(data)
  local summary = summarize_entries(data)
  local project_path = get_project_file_path()
  local project_name = get_project_name()
  local complete_count = (summary.status_totals.Done or 0) + (summary.status_totals.Approved or 0)
  local show_peak = false
  local lines = {}
  local divider = string.rep("=", REPORT_WIDTH)

  for _, entry in ipairs(data) do
    if entry.peak_dbfs ~= nil then
      show_peak = true
      break
    end
  end

  lines[#lines + 1] = divider
  lines[#lines + 1] = "GAME SOUND ASSET WORKSHEET"
  lines[#lines + 1] = "Project: " .. project_name
  lines[#lines + 1] = "Date: " .. os.date("%Y-%m-%d %H:%M:%S")
  lines[#lines + 1] = string.format("Total Assets: %d (Regions: %d, Markers: %d)", summary.total, summary.regions, summary.markers)
  lines[#lines + 1] = divider
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- Progress Summary --"

  for _, status in ipairs(STATUS_ORDER) do
    local count = summary.status_totals[status] or 0
    if count > 0 or status ~= "Unknown" then
      lines[#lines + 1] = string.format("  %-9s %4d  (%s)", status .. ":", count, format_percent(count, summary.total))
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. draw_progress_bar(complete_count, summary.total, 50)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- By Category --"
  lines[#lines + 1] = ""

  for _, category_key in ipairs(sort_category_keys(summary.categories)) do
    local category = summary.categories[category_key]
    table.sort(category.items, function(left, right)
      if left.position == right.position then
        return tostring(left.name) < tostring(right.name)
      end
      return left.position < right.position
    end)

    lines[#lines + 1] = string.format("%s (%d assets)", category_key, #category.items)
    lines[#lines + 1] = string.rep("-", REPORT_WIDTH)
    if show_peak then
      lines[#lines + 1] = string.format("%-4s %-26s %-9s %-10s %-8s %-14s", "#", "Name", "Length", "Status", "Peak", "Notes")
    else
      lines[#lines + 1] = string.format("%-4s %-30s %-9s %-10s %-18s", "#", "Name", "Length", "Status", "Notes")
    end

    for index, entry in ipairs(category.items) do
      local length_text = entry.length and (format_decimal(entry.length, 2) .. "s") or "marker"
      local status_text = canonicalize_status(entry.status) or entry.status or "Unset"
      local note_text = trim_string(entry.notes or "")
      local peak_text = entry.peak_dbfs and (format_decimal(entry.peak_dbfs, 1) .. "dB") or "---"

      if show_peak then
        lines[#lines + 1] = string.format(
          "%-4s %-26s %-9s %-10s %-8s %-14s",
          pad_left(index, 2),
          truncate_string(get_display_item_name(entry), 26),
          pad_left(length_text, 7),
          pad_right(status_text, 10),
          pad_left(peak_text, 8),
          truncate_string(note_text, 14)
        )
      else
        lines[#lines + 1] = string.format(
          "%-4s %-30s %-9s %-10s %-18s",
          pad_left(index, 2),
          truncate_string(get_display_item_name(entry), 30),
          pad_left(length_text, 7),
          pad_right(status_text, 10),
          truncate_string(note_text, 18)
        )
      end
    end

    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = divider
  lines[#lines + 1] = "Generated by Game Sound Worksheet Generator v1.0"
  lines[#lines + 1] = "Reaper Project: " .. project_path
  lines[#lines + 1] = divider

  return table.concat(lines, "\n")
end

local function export_to_csv(data, filepath, options)
  ensure_directory(dirname(filepath))

  local file = io.open(filepath, "wb")
  if not file then
    return false, "Cannot create file: " .. tostring(filepath)
  end

  if options.add_bom then
    file:write("\xEF\xBB\xBF")
  end

  local headers = {
    "Index",
    "Type",
    "Name",
    "Prefix",
    "Category",
    "AssetName",
    "Variation",
    "Start(sec)",
    "End(sec)",
    "Length(sec)",
    "Length(TC)",
    "Status",
  }

  if options.include_audio_analysis then
    headers[#headers + 1] = "Peak(dBFS)"
    headers[#headers + 1] = "RMS(dBFS)"
    headers[#headers + 1] = "HasAudio"
  end

  headers[#headers + 1] = "Notes"
  file:write(table.concat(headers, ",") .. "\r\n")

  for _, entry in ipairs(data) do
    local row = {
      tostring(entry.index or ""),
      csv_escape(entry.type or ""),
      csv_escape(entry.name or ""),
      csv_escape(entry.prefix or ""),
      csv_escape(entry.category or ""),
      csv_escape(entry.asset_name or ""),
      csv_escape(entry.variation or ""),
      format_decimal(entry.position, 3),
      entry.region_end and format_decimal(entry.region_end, 3) or "",
      entry.length and format_decimal(entry.length, 3) or "",
      entry.length and format_timecode(entry.length) or "",
      csv_escape(entry.status or ""),
    }

    if options.include_audio_analysis then
      row[#row + 1] = entry.peak_dbfs and format_decimal(entry.peak_dbfs, 1) or ""
      row[#row + 1] = entry.rms_dbfs and format_decimal(entry.rms_dbfs, 1) or ""
      row[#row + 1] = entry.has_audio == nil and "" or (entry.has_audio and "true" or "false")
    end

    row[#row + 1] = csv_escape(entry.notes or "")
    file:write(table.concat(row, ",") .. "\r\n")
  end

  file:close()
  return true
end

local function export_pivot_summary_csv(data, filepath, options)
  ensure_directory(dirname(filepath))

  local file = io.open(filepath, "wb")
  if not file then
    return false, "Cannot create pivot file: " .. tostring(filepath)
  end

  if options.add_bom then
    file:write("\xEF\xBB\xBF")
  end

  local summary = summarize_entries(data)
  local pivot_statuses = { "Done", "WIP", "Review", "Revision", "Todo", "Hold", "Approved", "Unset", "Unknown" }
  local headers = { "Category" }
  for _, status in ipairs(pivot_statuses) do
    headers[#headers + 1] = status
  end
  headers[#headers + 1] = "Total"
  file:write(table.concat(headers, ",") .. "\r\n")

  local totals = {}
  for _, status in ipairs(pivot_statuses) do
    totals[status] = 0
  end

  for _, category_key in ipairs(sort_category_keys(summary.categories)) do
    local category = summary.categories[category_key]
    local row = { csv_escape(category_key) }
    local category_total = 0

    for _, status in ipairs(pivot_statuses) do
      local count = category.status_totals[status] or 0
      totals[status] = totals[status] + count
      category_total = category_total + count
      row[#row + 1] = tostring(count)
    end

    row[#row + 1] = tostring(category_total)
    file:write(table.concat(row, ",") .. "\r\n")
  end

  local total_row = { "Total" }
  local grand_total = 0
  for _, status in ipairs(pivot_statuses) do
    total_row[#total_row + 1] = tostring(totals[status])
    grand_total = grand_total + totals[status]
  end
  total_row[#total_row + 1] = tostring(grand_total)
  file:write(table.concat(total_row, ",") .. "\r\n")

  file:close()
  return true
end

local function normalize_header(value)
  local normalized = trim_string(value):lower()
  normalized = normalized:gsub("[^%w]+", "_")
  normalized = normalized:gsub("^_+", "")
  normalized = normalized:gsub("_+$", "")
  return normalized
end

local function parse_csv_content(content)
  local rows = {}
  local row = {}
  local field = {}
  local index = 1
  local length = #content
  local in_quotes = false

  while index <= length do
    local char = content:sub(index, index)

    if in_quotes then
      if char == '"' then
        if content:sub(index + 1, index + 1) == '"' then
          field[#field + 1] = '"'
          index = index + 1
        else
          in_quotes = false
        end
      else
        field[#field + 1] = char
      end
    else
      if char == '"' then
        in_quotes = true
      elseif char == "," then
        row[#row + 1] = table.concat(field)
        field = {}
      elseif char == "\r" or char == "\n" then
        if char == "\r" and content:sub(index + 1, index + 1) == "\n" then
          index = index + 1
        end

        row[#row + 1] = table.concat(field)
        field = {}

        local has_content = false
        for _, value in ipairs(row) do
          if trim_string(value) ~= "" then
            has_content = true
            break
          end
        end

        if has_content then
          rows[#rows + 1] = row
        end

        row = {}
      else
        field[#field + 1] = char
      end
    end

    index = index + 1
  end

  row[#row + 1] = table.concat(field)
  local has_content = false
  for _, value in ipairs(row) do
    if trim_string(value) ~= "" then
      has_content = true
      break
    end
  end
  if has_content then
    rows[#rows + 1] = row
  end

  return rows
end

local function row_is_empty(entry)
  for _, value in pairs(entry) do
    if trim_string(value) ~= "" then
      return false
    end
  end
  return true
end

local function looks_like_header(row)
  if #row <= 1 then
    return normalize_header(row[1] or "") == "name"
  end

  local known = {
    name = true,
    index = true,
    type = true,
    category = true,
    duration_sec = true,
    length_sec = true,
    start_sec = true,
    status = true,
    priority = true,
    prefix = true,
    assetname = true,
    asset_name = true,
  }

  for _, value in ipairs(row) do
    if known[normalize_header(value)] then
      return true
    end
  end

  return false
end

local function parse_import_file(filepath)
  local file = io.open(filepath, "rb")
  if not file then
    return nil, "Cannot open file: " .. tostring(filepath)
  end

  local content = file:read("*a")
  file:close()

  content = tostring(content or ""):gsub("^\xEF\xBB\xBF", "")
  local rows = parse_csv_content(content)
  if #rows == 0 then
    return nil, "The file is empty."
  end

  local data = {}
  if looks_like_header(rows[1]) then
    local headers = {}
    for index, header in ipairs(rows[1]) do
      headers[index] = normalize_header(header)
    end

    for row_index = 2, #rows do
      local row = rows[row_index]
      local entry = {}
      for column_index, header in ipairs(headers) do
        entry[header] = trim_string(row[column_index] or "")
      end
      if not row_is_empty(entry) then
        data[#data + 1] = entry
      end
    end

    return data, "csv"
  end

  for _, row in ipairs(rows) do
    local name = trim_string(row[1] or "")
    if name ~= "" then
      data[#data + 1] = { name = name }
    end
  end

  return data, "list"
end

local function coalesce_value(entry, keys)
  for _, key in ipairs(keys) do
    local value = trim_string(entry[key] or "")
    if value ~= "" then
      return value
    end
  end
  return ""
end

local function to_number_or_nil(value)
  return tonumber(trim_string(value or ""))
end

local function sanitize_name_part(value, fallback)
  local text = trim_string(value)
  text = text:gsub("%s+", "_")
  text = text:gsub("[^%w_%-]", "")
  text = text:gsub("_+", "_")
  text = text:gsub("^_+", "")
  text = text:gsub("_+$", "")

  if text == "" then
    return fallback or ""
  end

  return text
end

local function looks_like_full_region_name(name)
  local prefix, category, asset_name = parse_asset_name(name)
  return prefix ~= nil and category ~= nil and asset_name ~= nil and asset_name ~= ""
end

local function build_region_name(entry, options)
  local raw_name = coalesce_value(entry, { "name", "region_name", "full_name" })
  local prefix = coalesce_value(entry, { "prefix" })
  local category = coalesce_value(entry, { "category" })
  local asset_name = coalesce_value(entry, { "assetname", "asset_name" })
  local variation = coalesce_value(entry, { "variation" })

  local has_structured_fields = prefix ~= "" or category ~= "" or asset_name ~= "" or variation ~= ""
  local looks_like_export_row = coalesce_value(entry, { "index", "type", "start_sec", "end_sec", "length_sec", "length" }) ~= ""

  if raw_name ~= "" and (looks_like_export_row or (not has_structured_fields and (category == "" or looks_like_full_region_name(raw_name)))) then
    return sanitize_name_part(raw_name, "Unnamed")
  end

  prefix = sanitize_name_part(prefix, sanitize_name_part(options.default_prefix, "SFX"))
  category = sanitize_name_part(category, "")
  asset_name = sanitize_name_part(asset_name, "")

  if asset_name == "" and raw_name ~= "" and not looks_like_full_region_name(raw_name) then
    asset_name = sanitize_name_part(raw_name, "Unnamed")
  end

  if asset_name == "" then
    asset_name = "Unnamed"
  end

  variation = sanitize_name_part(variation, "")

  local parts = {}
  if prefix ~= "" then
    parts[#parts + 1] = prefix
  end
  if category ~= "" then
    parts[#parts + 1] = category
  end
  parts[#parts + 1] = asset_name
  if variation ~= "" then
    parts[#parts + 1] = variation
  end

  return table.concat(parts, "_")
end

local function region_exists(region_name)
  local index = 0
  while true do
    local retval, is_region, _, _, name = reaper.EnumProjectMarkers3(0, index)
    if retval == 0 then
      break
    end
    if is_region and tostring(name or "") == tostring(region_name or "") then
      return true
    end
    index = index + 1
  end
  return false
end

local function get_start_position_for_import(entry, current_position, default_mode)
  local start_value = coalesce_value(entry, { "start_sec", "position", "start" })
  local numeric_start = to_number_or_nil(start_value)
  if numeric_start ~= nil then
    return numeric_start, true
  end

  if normalize_token(default_mode) == "cursor" then
    return current_position, false
  end

  local explicit = tonumber(default_mode)
  if explicit ~= nil then
    return explicit, false
  end

  return current_position, false
end

local function get_duration_for_import(entry, region_start, default_duration)
  local explicit_end = to_number_or_nil(coalesce_value(entry, { "end_sec", "region_end", "end" }))
  if explicit_end and explicit_end > region_start then
    return explicit_end - region_start, explicit_end
  end

  local duration = to_number_or_nil(coalesce_value(entry, {
    "duration_sec",
    "durationsec",
    "length_sec",
    "lengthsec",
    "length",
  }))

  if duration and duration > 0 then
    return duration, nil
  end

  return tonumber(default_duration) or 2.0, nil
end

local function has_explicit_variation(entry)
  local explicit = coalesce_value(entry, { "variation" })
  if explicit ~= "" then
    return true
  end

  local raw_name = coalesce_value(entry, { "name", "region_name", "full_name" })
  local _, _, _, variation = parse_asset_name(raw_name)
  return variation ~= nil and variation ~= ""
end

local function detect_variation_count(entry)
  local explicit = tonumber(coalesce_value(entry, {
    "variation_count",
    "variations",
    "variation_total",
    "variationtotal",
  }))
  if explicit and explicit > 1 then
    return math.floor(explicit)
  end

  local search_text = table.concat({
    coalesce_value(entry, { "notes" }),
    coalesce_value(entry, { "memo" }),
    coalesce_value(entry, { "description" }),
    coalesce_value(entry, { "name" }),
  }, " "):lower()

  local patterns = {
    "(%d+)%s*\236\162\133",
    "(%d+)%s*variation[s]?",
    "(%d+)%s*var[s]?",
    "variation[s]?%s*(%d+)",
    "var[s]?%s*(%d+)",
  }

  for _, pattern in ipairs(patterns) do
    local count = tonumber(search_text:match(pattern))
    if count and count > 1 then
      return math.floor(count)
    end
  end

  return 1
end

local function expand_import_entries(data, options)
  if not options.auto_expand_variations then
    return data, 0, 0
  end

  local expanded = {}
  local source_rows_expanded = 0
  local additional_rows = 0

  for _, entry in ipairs(data) do
    local count = detect_variation_count(entry)
    if count > 1 and not has_explicit_variation(entry) then
      source_rows_expanded = source_rows_expanded + 1
      additional_rows = additional_rows + (count - 1)

      for variation_index = 1, count do
        local clone = shallow_copy(entry)
        clone.variation = string.format("%02d", variation_index)
        expanded[#expanded + 1] = clone
      end
    else
      expanded[#expanded + 1] = entry
    end
  end

  return expanded, source_rows_expanded, additional_rows
end

local function import_regions_from_data(data, options)
  local result = {
    created = 0,
    skipped_duplicates = 0,
    skipped_invalid = 0,
  }

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local current_position = normalize_token(options.start_position) == "cursor"
    and reaper.GetCursorPosition()
    or (tonumber(options.start_position) or 0.0)

  for _, entry in ipairs(data) do
    local region_name = build_region_name(entry, options)
    if is_blank(region_name) then
      result.skipped_invalid = result.skipped_invalid + 1
    elseif options.skip_duplicates and region_exists(region_name) then
      log_line(string.format("[Import] Skipped duplicate: %s", region_name))
      result.skipped_duplicates = result.skipped_duplicates + 1
    else
      local region_start, used_explicit_start = get_start_position_for_import(entry, current_position, options.start_position)
      local duration, explicit_end = get_duration_for_import(entry, region_start, options.default_duration)
      duration = math.max(0.01, tonumber(duration) or tonumber(options.default_duration) or 2.0)

      local region_end = explicit_end or (region_start + duration)
      local color = 0
      if options.auto_color_by_status then
        local status = coalesce_value(entry, { "status", "priority" })
        color = get_color_for_status(map_priority_to_status(status))
      end

      reaper.AddProjectMarker2(0, true, region_start, region_end, region_name, -1, color)
      result.created = result.created + 1

      log_line(string.format("[Import] Created region: %s (%.3fs - %.3fs, %.3fs)", region_name, region_start, region_end, region_end - region_start))

      if used_explicit_start then
        current_position = math.max(current_position, region_end + options.gap_between_regions)
      else
        current_position = region_end + options.gap_between_regions
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Import Worksheet Regions", -1)

  return result
end

local function get_entry_type(entry, default_type)
  local token = normalize_token(coalesce_value(entry, { "type" }))
  if token == "marker" then
    return "marker"
  end
  if token == "region" then
    return "region"
  end
  return default_type or "region"
end

local function get_sync_desired_status(entry)
  local status_value = coalesce_value(entry, { "status" })
  if status_value ~= "" then
    return canonicalize_status(status_value)
  end

  local priority_value = coalesce_value(entry, { "priority" })
  if priority_value ~= "" then
    return map_priority_to_status(priority_value)
  end

  return nil
end

local function get_sync_desired_name(entry, options)
  local explicit = coalesce_value(entry, { "new_name", "rename_to", "target_name" })
  if explicit ~= "" then
    return sanitize_name_part(explicit, explicit)
  end
  return build_region_name(entry, options)
end

local function build_marker_lookup(options)
  local lookup = {
    records = {},
    by_id = {},
    by_name = {},
    ambiguous_names = {},
  }

  local index = 0
  while true do
    local retval, is_region, position, region_end, name, marker_index, native_color =
      reaper.EnumProjectMarkers3(0, index)

    if retval == 0 then
      break
    end

    local record_type = is_region and "region" or "marker"
    local include_entry = is_region or options.sync_include_markers
    if include_entry then
      local record = {
        key = record_type .. ":" .. tostring(marker_index),
        type = record_type,
        index = marker_index,
        enum_index = index,
        name = tostring(name or ""),
        position = position,
        region_end = is_region and region_end or nil,
        native_color = native_color or 0,
        status = detect_status_from_color(native_color),
      }

      lookup.records[#lookup.records + 1] = record
      lookup.by_id[record.key] = record

      local name_key = record.type .. ":" .. record.name
      if lookup.ambiguous_names[name_key] then
        -- Keep the name ambiguous.
      elseif lookup.by_name[name_key] then
        lookup.by_name[name_key] = nil
        lookup.ambiguous_names[name_key] = true
      else
        lookup.by_name[name_key] = record
      end
    end

    index = index + 1
  end

  return lookup
end

local function find_record_by_name(lookup, name, preferred_type)
  local target_name = trim_string(name)
  if target_name == "" then
    return nil, "missing"
  end

  local function resolve(type_name)
    local key = type_name .. ":" .. target_name
    if lookup.ambiguous_names[key] then
      return nil, "ambiguous"
    end
    return lookup.by_name[key], lookup.by_name[key] and "name" or "missing"
  end

  if preferred_type == "marker" or preferred_type == "region" then
    return resolve(preferred_type)
  end

  local region_record, region_status = resolve("region")
  local marker_record, marker_status = resolve("marker")

  if region_status == "ambiguous" or marker_status == "ambiguous" then
    return nil, "ambiguous"
  end
  if region_record and marker_record then
    return nil, "ambiguous"
  end
  if region_record then
    return region_record, "name"
  end
  if marker_record then
    return marker_record, "name"
  end

  return nil, "missing"
end

local function resolve_sync_record(entry, lookup, options)
  local preferred_type = get_entry_type(entry, "region")
  local index_value = tonumber(coalesce_value(entry, { "index" }))
  if index_value then
    local record = lookup.by_id[preferred_type .. ":" .. tostring(math.floor(index_value))]
    if record then
      return record, "index"
    end
  end

  local source_name = coalesce_value(entry, { "source_name", "old_name", "current_name", "name" })
  if source_name ~= "" then
    local record, reason = find_record_by_name(lookup, source_name, preferred_type)
    if record then
      return record, reason
    end
    return nil, reason
  end

  return nil, "missing"
end

local function build_sync_preview(csv_data, options)
  local preview = {
    total_rows = #csv_data,
    matches = 0,
    status_changes = {},
    rename_changes = {},
    combined_changes = {},
    unchanged_matches = 0,
    new_in_csv = {},
    missing_in_csv = {},
    ambiguous_entries = {},
    matched_keys = {},
  }

  local lookup = build_marker_lookup(options)

  for _, entry in ipairs(csv_data) do
    local record, match_reason = resolve_sync_record(entry, lookup, options)
    local desired_name = get_sync_desired_name(entry, options)
    local desired_status = get_sync_desired_status(entry)

    if record then
      preview.matches = preview.matches + 1
      preview.matched_keys[record.key] = true

      local name_changed = options.sync_update_names and desired_name ~= "" and desired_name ~= record.name
      local status_changed = options.sync_update_status and desired_status and desired_status ~= record.status

      local change = {
        record = record,
        source = entry,
        match_reason = match_reason,
        desired_name = desired_name,
        desired_status = desired_status,
        old_name = record.name,
        old_status = record.status,
        name_changed = name_changed,
        status_changed = status_changed,
      }

      if name_changed then
        preview.rename_changes[#preview.rename_changes + 1] = change
      end
      if status_changed then
        preview.status_changes[#preview.status_changes + 1] = change
      end
      if name_changed or status_changed then
        preview.combined_changes[#preview.combined_changes + 1] = change
      else
        preview.unchanged_matches = preview.unchanged_matches + 1
      end
    elseif match_reason == "ambiguous" then
      preview.ambiguous_entries[#preview.ambiguous_entries + 1] = {
        name = coalesce_value(entry, { "name", "source_name", "old_name" }),
        entry = entry,
      }
    else
      preview.new_in_csv[#preview.new_in_csv + 1] = {
        name = desired_name,
        entry = entry,
      }
    end
  end

  for _, record in ipairs(lookup.records) do
    if not preview.matched_keys[record.key] then
      preview.missing_in_csv[#preview.missing_in_csv + 1] = record
    end
  end

  return preview
end

local function append_preview_names(lines, items, label, formatter, max_items)
  if #items == 0 then
    return
  end

  max_items = max_items or 8
  lines[#lines + 1] = string.format("%s: %d", label, #items)
  local limit = math.min(#items, max_items)
  for index = 1, limit do
    lines[#lines + 1] = "  " .. formatter(items[index])
  end
  if #items > limit then
    lines[#lines + 1] = string.format("  ... and %d more", #items - limit)
  end
end

local function format_sync_preview(preview)
  local lines = {
    string.rep("=", 54),
    "Sync Preview: CSV -> Project",
    string.rep("=", 54),
    string.format("Rows in CSV:      %d", preview.total_rows),
    string.format("Matches:          %d", preview.matches),
    string.format("Status Changes:   %d", #preview.status_changes),
    string.format("Rename Changes:   %d", #preview.rename_changes),
    string.format("Unchanged:        %d", preview.unchanged_matches),
    string.format("New in CSV:       %d", #preview.new_in_csv),
    string.format("Missing in CSV:   %d", #preview.missing_in_csv),
    string.format("Ambiguous Names:  %d", #preview.ambiguous_entries),
    string.rep("-", 54),
  }

  append_preview_names(lines, preview.status_changes, "Status Changes", function(change)
    return string.format("%s: %s -> %s", change.old_name, change.old_status or "Unset", change.desired_status or "Unset")
  end)

  append_preview_names(lines, preview.rename_changes, "Rename Changes", function(change)
    return string.format("%s -> %s", change.old_name, change.desired_name)
  end)

  append_preview_names(lines, preview.new_in_csv, "New in CSV", function(item)
    return item.name
  end)

  append_preview_names(lines, preview.missing_in_csv, "Missing in CSV", function(item)
    return item.name
  end)

  append_preview_names(lines, preview.ambiguous_entries, "Ambiguous", function(item)
    return item.name
  end)

  lines[#lines + 1] = string.rep("=", 54)
  return table.concat(lines, "\n")
end

local function apply_sync_preview(preview, options)
  local applied = {
    updated = 0,
    status_changes = 0,
    rename_changes = 0,
  }

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, change in ipairs(preview.combined_changes) do
    local record = change.record
    local target_name = change.name_changed and change.desired_name or record.name
    local target_color = change.status_changed and get_color_for_status(change.desired_status) or record.native_color

    reaper.SetProjectMarker3(
      0,
      record.index,
      record.type == "region",
      record.position,
      record.region_end or 0.0,
      target_name,
      target_color
    )

    applied.updated = applied.updated + 1
    if change.status_changed then
      applied.status_changes = applied.status_changes + 1
    end
    if change.name_changed then
      applied.rename_changes = applied.rename_changes + 1
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Sync Worksheet from CSV", -1)

  return applied
end

local function execute_sync(settings, skip_confirm)
  if is_blank(settings.sync_csv_path) then
    reaper.ShowMessageBox("Sync CSV file path is required.", SCRIPT_TITLE, 0)
    return nil
  end

  local data, kind_or_error = parse_import_file(settings.sync_csv_path)
  if not data then
    reaper.ShowMessageBox(kind_or_error or "Failed to parse the sync file.", SCRIPT_TITLE, 0)
    return nil
  end

  if #data == 0 then
    reaper.ShowMessageBox("No sync rows were found.", SCRIPT_TITLE, 0)
    return nil
  end

  local preview = build_sync_preview(data, settings)
  local preview_text = format_sync_preview(preview)

  reaper.ClearConsole()
  reaper.ShowConsoleMsg(preview_text .. "\n")

  local should_apply = skip_confirm
  if not skip_confirm then
    local response = reaper.ShowMessageBox(preview_text .. "\n\nApply these changes?", SCRIPT_TITLE, 4)
    should_apply = response == 6
  end

  if not should_apply then
    return preview
  end

  local applied = apply_sync_preview(preview, settings)
  local message = table.concat({
    string.format("Updated regions/markers: %d", applied.updated),
    string.format("Status changes: %d", applied.status_changes),
    string.format("Rename changes: %d", applied.rename_changes),
    string.format("New in CSV (not created): %d", #preview.new_in_csv),
    string.format("Missing in CSV: %d", #preview.missing_in_csv),
    string.format("Ambiguous names: %d", #preview.ambiguous_entries),
  }, "\n")

  reaper.ShowMessageBox(message, SCRIPT_TITLE, 0)
  return preview, applied
end

local function find_empty_regions()
  local empty = {}
  local regions = collect_all_regions_and_markers({
    include_regions = true,
    include_markers = false,
    only_time_selection = false,
    include_audio_analysis = false,
  })

  for _, region in ipairs(regions) do
    if region.region_end and not range_has_audio(region.position, region.region_end) then
      empty[#empty + 1] = region
    end
  end

  return empty
end

local function batch_set_status(status_name)
  local color = get_color_for_status(status_name)
  local selection_start, selection_end = get_time_selection()
  local has_time_selection = selection_end > selection_start
  local changed = 0
  local index = 0

  if not has_time_selection then
    return 0, false
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  while true do
    local retval, is_region, position, region_end, name, marker_index =
      reaper.EnumProjectMarkers3(0, index)

    if retval == 0 then
      break
    end

    if is_region then
      local in_scope = has_time_selection and position < selection_end and region_end > selection_start
      if in_scope then
        reaper.SetProjectMarker3(0, marker_index, true, position, region_end, name, color)
        changed = changed + 1
      end
    end

    index = index + 1
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Set region status: " .. tostring(status_name), -1)

  return changed, has_time_selection
end

local function collect_scope_regions_for_edit()
  local selection_start, selection_end = get_time_selection()
  local has_time_selection = selection_end > selection_start
  local regions = {}
  local index = 0

  while true do
    local retval, is_region, position, region_end, name, marker_index, native_color =
      reaper.EnumProjectMarkers3(0, index)

    if retval == 0 then
      break
    end

    if is_region and (not has_time_selection or (position < selection_end and region_end > selection_start)) then
      regions[#regions + 1] = {
        index = marker_index,
        name = tostring(name or ""),
        position = position,
        region_end = region_end,
        native_color = native_color or 0,
      }
    end

    index = index + 1
  end

  return regions, has_time_selection
end

local function batch_rename_prefix_category(match_prefix, new_prefix, match_category, new_category)
  local regions, has_time_selection = collect_scope_regions_for_edit()
  local changed = 0

  match_prefix = trim_string(match_prefix)
  new_prefix = sanitize_name_part(new_prefix, "")
  match_category = trim_string(match_category)
  new_category = sanitize_name_part(new_category, "")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, region in ipairs(regions) do
    local prefix, category, asset_name, variation = parse_asset_name(region.name)
    if prefix and asset_name then
      local prefix_matches = match_prefix == "" or prefix == match_prefix
      local category_matches = match_category == "" or category == match_category
      if prefix_matches and category_matches then
        local final_prefix = new_prefix ~= "" and new_prefix or prefix
        local final_category = new_category ~= "" and new_category or category
        local parts = {}
        if final_prefix ~= "" then
          parts[#parts + 1] = final_prefix
        end
        if trim_string(final_category or "") ~= "" then
          parts[#parts + 1] = final_category
        end
        parts[#parts + 1] = asset_name
        if variation and variation ~= "" then
          parts[#parts + 1] = variation
        end
        local new_name = table.concat(parts, "_")

        if new_name ~= region.name then
          reaper.SetProjectMarker3(0, region.index, true, region.position, region.region_end, new_name, region.native_color)
          changed = changed + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Batch rename region prefix/category", -1)

  return changed, has_time_selection, #regions
end

local function renumber_variations_in_scope()
  local regions, has_time_selection = collect_scope_regions_for_edit()
  local groups = {}

  for _, region in ipairs(regions) do
    local prefix, category, asset_name, variation = parse_asset_name(region.name)
    local base_name = region.name
    local group_key = nil
    local existing_width = 2

    if prefix and category and asset_name then
      group_key = table.concat({ prefix or "", category or "", asset_name }, "|")
      base_name = table.concat({ prefix, category, asset_name }, "_")
      existing_width = math.max(existing_width, variation and #variation or 0)
    else
      local stripped, raw_variation = region.name:match("^(.-)_(%d+)$")
      if stripped then
        group_key = stripped
        base_name = stripped
        existing_width = math.max(existing_width, #raw_variation)
        variation = raw_variation
      end
    end

    if group_key then
      if not groups[group_key] then
        groups[group_key] = {
          base_name = base_name,
          items = {},
          has_variation = false,
          width = existing_width,
        }
      end
      local group = groups[group_key]
      group.items[#group.items + 1] = region
      group.has_variation = group.has_variation or (variation ~= nil and variation ~= "")
      group.width = math.max(group.width, existing_width)
    end
  end

  local renamed = 0
  local renamed_groups = 0

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, group in pairs(groups) do
    if #group.items > 1 or group.has_variation then
      table.sort(group.items, function(left, right)
        if left.position == right.position then
          return left.name < right.name
        end
        return left.position < right.position
      end)

      local width = math.max(2, group.width, #tostring(#group.items))
      local group_changed = false

      for index, region in ipairs(group.items) do
        local target_name = string.format("%s_%0" .. tostring(width) .. "d", group.base_name, index)
        if target_name ~= region.name then
          reaper.SetProjectMarker3(0, region.index, true, region.position, region.region_end, target_name, region.native_color)
          renamed = renamed + 1
          group_changed = true
        end
      end

      if group_changed then
        renamed_groups = renamed_groups + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Renumber region variations", -1)

  return renamed, renamed_groups, has_time_selection, #regions
end

local function prompt_edit_status_colors()
  local statuses = { "Done", "WIP", "Review", "Revision", "Todo", "Hold", "Approved" }
  local captions = table.concat({
    "separator=|",
    "extrawidth=220",
    "Done (#RRGGBB)",
    "WIP (#RRGGBB)",
    "Review (#RRGGBB)",
    "Revision (#RRGGBB)",
    "Todo (#RRGGBB)",
    "Hold (#RRGGBB)",
    "Approved (#RRGGBB)",
  }, "|")

  local defaults = {}
  for _, status in ipairs(statuses) do
    defaults[#defaults + 1] = format_hex_color(STATUS_COLORS[status])
  end

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Edit Status Colors", #statuses, captions, table.concat(defaults, "|"))
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", #statuses)
  local updated = clone_status_colors(STATUS_COLORS)

  for index, status in ipairs(statuses) do
    local parsed = parse_hex_color(parts[index])
    if not parsed then
      reaper.ShowMessageBox("Invalid color for " .. status .. ". Use #RRGGBB.", SCRIPT_TITLE, 0)
      return false
    end
    updated[status] = parsed
  end

  STATUS_COLORS = updated
  save_status_colors()
  return true
end

local function prompt_for_mode(settings)
  local captions = table.concat({
    "separator=|",
    "extrawidth=220",
    "Mode (export/import/dashboard/sync/gui)",
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 1, captions, tostring(settings.mode))
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", 1)
  local mode = normalize_mode(parts[1], nil)
  if not mode then
    reaper.ShowMessageBox("Unsupported mode. Use export, import, dashboard, sync, or gui.", SCRIPT_TITLE, 0)
    return false
  end

  settings.mode = mode
  return true
end

local function prompt_export_settings(settings)
  local captions = table.concat({
    "separator=|",
    "extrawidth=300",
    "Include Regions (yes/no)",
    "Include Markers (yes/no)",
    "Only Time Selection (yes/no)",
    "Include Audio Analysis (yes/no)",
    "Include Pivot Summary (yes/no)",
    "Output Format (csv/report/both)",
    "Output Path (empty=auto)",
    "Add UTF-8 BOM (yes/no)",
    "Auto-open after export (yes/no)",
  }, "|")

  local defaults = table.concat({
    bool_to_string(settings.include_regions),
    bool_to_string(settings.include_markers),
    bool_to_string(settings.only_time_selection),
    bool_to_string(settings.include_audio_analysis),
    bool_to_string(settings.include_pivot_summary),
    tostring(settings.output_format),
    tostring(settings.export_path),
    bool_to_string(settings.add_bom),
    bool_to_string(settings.auto_open_export),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Export", 9, captions, defaults)
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", 9)
  settings.include_regions = parse_boolean(parts[1], settings.include_regions)
  settings.include_markers = parse_boolean(parts[2], settings.include_markers)
  settings.only_time_selection = parse_boolean(parts[3], settings.only_time_selection)
  settings.include_audio_analysis = parse_boolean(parts[4], settings.include_audio_analysis)
  settings.include_pivot_summary = parse_boolean(parts[5], settings.include_pivot_summary)
  settings.output_format = normalize_output_format(parts[6], settings.output_format)
  settings.export_path = trim_string(parts[7])
  settings.add_bom = parse_boolean(parts[8], settings.add_bom)
  settings.auto_open_export = parse_boolean(parts[9], settings.auto_open_export)
  return true
end

local function prompt_import_settings(settings)
  local captions = table.concat({
    "separator=|",
    "extrawidth=320",
    "CSV File Path",
    "Start Position (cursor or sec)",
    "Gap Between Regions (sec)",
    "Default Region Duration (sec)",
    "Default Prefix",
    "Skip Duplicates (yes/no)",
    "Auto Color by Status (yes/no)",
    "Auto Expand Variations (yes/no)",
  }, "|")

  local defaults = table.concat({
    tostring(settings.import_csv_path),
    tostring(settings.start_position),
    tostring(settings.gap_between_regions),
    tostring(settings.default_duration),
    tostring(settings.default_prefix),
    bool_to_string(settings.skip_duplicates),
    bool_to_string(settings.auto_color_by_status),
    bool_to_string(settings.auto_expand_variations),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Import", 8, captions, defaults)
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", 8)
  settings.import_csv_path = trim_string(parts[1])
  settings.start_position = trim_string(parts[2])
  settings.gap_between_regions = math.max(0.0, tonumber(parts[3]) or settings.gap_between_regions)
  settings.default_duration = math.max(0.01, tonumber(parts[4]) or settings.default_duration)
  settings.default_prefix = sanitize_name_part(parts[5], settings.default_prefix)
  settings.skip_duplicates = parse_boolean(parts[6], settings.skip_duplicates)
  settings.auto_color_by_status = parse_boolean(parts[7], settings.auto_color_by_status)
  settings.auto_expand_variations = parse_boolean(parts[8], settings.auto_expand_variations)
  return true
end

local function prompt_dashboard_settings(settings)
  local captions = table.concat({
    "separator=|",
    "extrawidth=260",
    "Include Regions (yes/no)",
    "Include Markers (yes/no)",
    "Only Time Selection (yes/no)",
  }, "|")

  local defaults = table.concat({
    bool_to_string(settings.include_regions),
    bool_to_string(settings.include_markers),
    bool_to_string(settings.only_time_selection),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Dashboard", 3, captions, defaults)
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", 3)
  settings.include_regions = parse_boolean(parts[1], settings.include_regions)
  settings.include_markers = parse_boolean(parts[2], settings.include_markers)
  settings.only_time_selection = parse_boolean(parts[3], settings.only_time_selection)
  return true
end

local function prompt_sync_settings(settings)
  local captions = table.concat({
    "separator=|",
    "extrawidth=320",
    "CSV File Path",
    "Update Status Colors (yes/no)",
    "Update Names (yes/no)",
    "Match Markers Too (yes/no)",
  }, "|")

  local defaults = table.concat({
    tostring(settings.sync_csv_path),
    bool_to_string(settings.sync_update_status),
    bool_to_string(settings.sync_update_names),
    bool_to_string(settings.sync_include_markers),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Sync", 4, captions, defaults)
  if not ok then
    return false
  end

  local parts = split_delimited(values, "|", 4)
  settings.sync_csv_path = trim_string(parts[1])
  settings.sync_update_status = parse_boolean(parts[2], settings.sync_update_status)
  settings.sync_update_names = parse_boolean(parts[3], settings.sync_update_names)
  settings.sync_include_markers = parse_boolean(parts[4], settings.sync_include_markers)
  return true
end

local function show_report_in_console(report_text)
  reaper.ClearConsole()
  reaper.ShowConsoleMsg(report_text .. "\n")
end

local function execute_export(settings)
  local data = collect_all_regions_and_markers({
    include_regions = settings.include_regions,
    include_markers = settings.include_markers,
    only_time_selection = settings.only_time_selection,
    include_audio_analysis = settings.include_audio_analysis,
  })

  if #data == 0 then
    reaper.ShowMessageBox("No matching regions or markers were found for export.", SCRIPT_TITLE, 0)
    return
  end

  local csv_path, report_path, pivot_path = resolve_export_paths(settings)
  local output_format = normalize_output_format(settings.output_format, "csv")
  local report_text = build_text_report(data)
  local exported_paths = {}
  local summary = summarize_entries(data)

  show_report_in_console(report_text)

  if output_format == "csv" or output_format == "both" then
    local ok, error_message = export_to_csv(data, csv_path, settings)
    if not ok then
      reaper.ShowMessageBox(error_message, SCRIPT_TITLE, 0)
      return
    end
    exported_paths[#exported_paths + 1] = csv_path
  end

  if output_format == "report" or output_format == "both" then
    local ok, error_message = write_text_file(report_path, report_text, settings.add_bom)
    if not ok then
      reaper.ShowMessageBox(error_message, SCRIPT_TITLE, 0)
      return
    end
    exported_paths[#exported_paths + 1] = report_path
  end

  if settings.include_pivot_summary then
    local ok, error_message = export_pivot_summary_csv(data, pivot_path, settings)
    if not ok then
      reaper.ShowMessageBox(error_message, SCRIPT_TITLE, 0)
      return
    end
    exported_paths[#exported_paths + 1] = pivot_path
  end

  if settings.auto_open_export then
    for _, path in ipairs(exported_paths) do
      open_path_with_shell(path)
    end
  end

  local message_lines = {
    string.format("Collected %d entries.", #data),
    string.format("Regions: %d, Markers: %d", summary.regions, summary.markers),
  }

  if #exported_paths > 0 then
    message_lines[#message_lines + 1] = ""
    message_lines[#message_lines + 1] = "Saved:"
    for _, path in ipairs(exported_paths) do
      message_lines[#message_lines + 1] = path
    end
  end

  if settings.include_audio_analysis then
    message_lines[#message_lines + 1] = ""
    message_lines[#message_lines + 1] = "Peak/RMS region analysis was included in the export."
  end

  if settings.include_pivot_summary then
    message_lines[#message_lines + 1] = "Pivot summary CSV was generated."
  end

  reaper.ShowMessageBox(table.concat(message_lines, "\n"), SCRIPT_TITLE, 0)
end

local function execute_import(settings)
  if is_blank(settings.import_csv_path) then
    reaper.ShowMessageBox("CSV file path is required.", SCRIPT_TITLE, 0)
    return
  end

  local data, import_kind_or_error = parse_import_file(settings.import_csv_path)
  if not data then
    reaper.ShowMessageBox(import_kind_or_error or "Failed to parse the import file.", SCRIPT_TITLE, 0)
    return
  end

  if #data == 0 then
    reaper.ShowMessageBox("No import rows were found.", SCRIPT_TITLE, 0)
    return
  end

  local expanded_rows = 0
  local source_rows_expanded = 0
  data, source_rows_expanded, expanded_rows = expand_import_entries(data, settings)

  reaper.ClearConsole()
  log_line("===========================================")
  log_line("Game Sound Worksheet Import")
  log_line("Source: " .. settings.import_csv_path)
  log_line("Detected format: " .. tostring(import_kind_or_error))
  log_line("Rows: " .. tostring(#data))
  if source_rows_expanded > 0 then
    log_line(string.format("Variation expansion: %d source rows -> +%d extra rows", source_rows_expanded, expanded_rows))
  end
  log_line("===========================================")

  local result = import_regions_from_data(data, settings)
  local message = table.concat({
    string.format("Created regions: %d", result.created),
    string.format("Skipped duplicates: %d", result.skipped_duplicates),
    string.format("Skipped invalid rows: %d", result.skipped_invalid),
    string.format("Variation-expanded rows: %d", expanded_rows),
  }, "\n")

  reaper.ShowMessageBox(message, SCRIPT_TITLE, 0)
end

local function execute_dashboard(settings)
  local data = collect_all_regions_and_markers({
    include_regions = settings.include_regions,
    include_markers = settings.include_markers,
    only_time_selection = settings.only_time_selection,
    include_audio_analysis = false,
  })

  if #data == 0 then
    reaper.ShowMessageBox("No matching regions or markers were found for the dashboard.", SCRIPT_TITLE, 0)
    return
  end

  local report_text = build_text_report(data)
  show_report_in_console(report_text)
  reaper.ShowMessageBox(string.format("Dashboard generated for %d entries.\nSee the ReaScript console for details.", #data), SCRIPT_TITLE, 0)
end

local function execute_gui(settings)
  settings.gui_mode = normalize_mode(settings.gui_mode, "export")

  local gui = {
    tab = settings.gui_mode,
    prev_mouse_down = false,
    mouse_down = false,
    mouse_pressed = false,
    mouse_released = false,
    active_id = nil,
    needs_save = false,
    message = "Ready.",
  }

  local function set_message(text)
    gui.message = tostring(text or "")
  end

  local function mark_dirty(optional_message)
    settings.gui_mode = gui.tab
    gui.needs_save = true
    if optional_message then
      set_message(optional_message)
    end
  end

  local function save_if_needed()
    if gui.needs_save then
      save_settings(settings)
      gui.needs_save = false
    end
  end

  local function set_color(r, g, b, a)
    gfx.set((r or 0) / 255.0, (g or 0) / 255.0, (b or 0) / 255.0, a == nil and 1.0 or a)
  end

  local function rect(x, y, w, h, fill, radius)
    radius = radius or 6
    if gfx.roundrect then
      gfx.roundrect(x, y, w, h, radius, fill and 1 or 0)
    else
      gfx.rect(x, y, w, h, fill and 1 or 0)
    end
  end

  local function point_in_rect(px, py, x, y, w, h)
    return px >= x and px <= (x + w) and py >= y and py <= (y + h)
  end

  local function begin_frame()
    gui.mouse_down = (gfx.mouse_cap & 1) == 1
    gui.mouse_pressed = gui.mouse_down and not gui.prev_mouse_down
    gui.mouse_released = (not gui.mouse_down) and gui.prev_mouse_down
  end

  local function end_frame()
    if gui.mouse_released then
      gui.active_id = nil
    end
    gui.prev_mouse_down = gui.mouse_down
    save_if_needed()
  end

  local function draw_text(x, y, text, color, font_index)
    gfx.x = x
    gfx.y = y
    if font_index then
      gfx.setfont(1, font_index, 16)
    end
    if color then
      set_color(color[1], color[2], color[3], color[4] or 1)
    end
    gfx.drawstr(tostring(text or ""))
  end

  local function button(id, x, y, w, h, label, opts)
    opts = opts or {}
    local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, y, w, h)
    if hovered and gui.mouse_pressed then
      gui.active_id = id
    end

    local triggered = hovered and gui.mouse_released and gui.active_id == id
    local is_active = opts.active or false
    local bg = opts.bg or { 40, 44, 53, 1 }
    local fg = opts.fg or { 232, 236, 242, 1 }

    if is_active then
      bg = opts.active_bg or { 60, 126, 213, 1 }
    elseif gui.active_id == id and gui.mouse_down then
      bg = { 52, 58, 70, 1 }
    elseif hovered then
      bg = opts.hover_bg or { 50, 56, 68, 1 }
    end

    set_color(bg[1], bg[2], bg[3], bg[4])
    rect(x, y, w, h, true, 7)
    set_color(18, 20, 24, 1)
    rect(x, y, w, h, false, 7)
    set_color(fg[1], fg[2], fg[3], fg[4] or 1)
    gfx.x = x + 10
    gfx.y = y + math.floor((h - 16) * 0.5)
    gfx.drawstr(label)

    return triggered
  end

  local function checkbox(id, x, y, label, current_value)
    local text = string.format("%s %s", current_value and "[x]" or "[ ]", label)
    if button(id, x, y, 170, 28, text) then
      return not current_value, true
    end
    return current_value, false
  end

  local function apply_checkbox(current_value, id, x, y, label)
    local updated, changed = checkbox(id, x, y, label, current_value)
    if changed then
      gui.needs_save = true
    end
    return updated
  end

  local function cycle_output_format()
    if settings.output_format == "csv" then
      settings.output_format = "report"
    elseif settings.output_format == "report" then
      settings.output_format = "both"
    else
      settings.output_format = "csv"
    end
    mark_dirty("Export format: " .. settings.output_format)
  end

  local function browse_import_csv()
    local selected = browse_for_read_file(settings.import_csv_path, "Select worksheet import file", "")
    if selected then
      settings.import_csv_path = selected
      mark_dirty("Import file selected.")
    end
  end

  local function browse_sync_csv()
    local selected = browse_for_read_file(settings.sync_csv_path, "Select worksheet sync file", "")
    if selected then
      settings.sync_csv_path = selected
      mark_dirty("Sync file selected.")
    end
  end

  local function edit_export_path()
    local value = prompt_single_value(SCRIPT_TITLE .. " - Export Path", "Output Path (empty=auto)", settings.export_path, 340)
    if value ~= nil then
      settings.export_path = value
      mark_dirty("Export path updated.")
    end
  end

  local function edit_import_details()
    local captions = table.concat({
      "separator=|",
      "extrawidth=260",
      "Start Position (cursor or sec)",
      "Gap Between Regions (sec)",
      "Default Region Duration (sec)",
      "Default Prefix",
    }, "|")
    local defaults = table.concat({
      tostring(settings.start_position),
      tostring(settings.gap_between_regions),
      tostring(settings.default_duration),
      tostring(settings.default_prefix),
    }, "|")

    local ok, values = reaper.GetUserInputs(SCRIPT_TITLE .. " - Import Details", 4, captions, defaults)
    if ok then
      local parts = split_delimited(values, "|", 4)
      settings.start_position = trim_string(parts[1])
      settings.gap_between_regions = math.max(0.0, tonumber(parts[2]) or settings.gap_between_regions)
      settings.default_duration = math.max(0.01, tonumber(parts[3]) or settings.default_duration)
      settings.default_prefix = sanitize_name_part(parts[4], settings.default_prefix)
      mark_dirty("Import defaults updated.")
    end
  end

  local function show_empty_regions()
    local empty = find_empty_regions()
    local lines = {
      string.format("Empty regions: %d", #empty),
      "",
    }
    for index, region in ipairs(empty) do
      if index > 20 then
        lines[#lines + 1] = string.format("... and %d more", #empty - 20)
        break
      end
      lines[#lines + 1] = string.format("%s (%.3f - %.3f)", region.name, region.position, region.region_end or region.position)
    end
    show_report_in_console(table.concat(lines, "\n"))
    set_message(string.format("Empty region scan complete: %d found.", #empty))
  end

  local function execute_current_tab()
    settings.gui_mode = gui.tab
    save_settings(settings)

    if gui.tab == "export" then
      execute_export(settings)
      set_message("Export complete.")
    elseif gui.tab == "import" then
      execute_import(settings)
      set_message("Import complete.")
    elseif gui.tab == "dashboard" then
      execute_dashboard(settings)
      set_message("Dashboard printed to console.")
    elseif gui.tab == "sync" then
      execute_sync(settings, false)
      set_message("Sync preview generated.")
    end
  end

  local function preview_sync_only()
    if is_blank(settings.sync_csv_path) then
      reaper.ShowMessageBox("Sync CSV file path is required.", SCRIPT_TITLE, 0)
      return
    end

    local data, kind_or_error = parse_import_file(settings.sync_csv_path)
    if not data then
      reaper.ShowMessageBox(kind_or_error or "Failed to parse the sync file.", SCRIPT_TITLE, 0)
      return
    end

    local preview = build_sync_preview(data, settings)
    show_report_in_console(format_sync_preview(preview))
    set_message(string.format("Sync preview ready: %d changes.", #preview.combined_changes))
  end

  local function draw_panel_title(x, y, title, subtitle)
    set_color(244, 246, 250, 1)
    gfx.x = x
    gfx.y = y
    gfx.drawstr(title)
    if subtitle then
      set_color(156, 164, 178, 1)
      gfx.x = x
      gfx.y = y + 22
      gfx.drawstr(subtitle)
    end
  end

  local function draw_value_box(x, y, w, label, value)
    set_color(28, 31, 38, 1)
    rect(x, y, w, 54, true, 8)
    set_color(60, 67, 79, 1)
    rect(x, y, w, 54, false, 8)
    set_color(146, 154, 168, 1)
    gfx.x = x + 12
    gfx.y = y + 10
    gfx.drawstr(label)
    set_color(236, 240, 245, 1)
    gfx.x = x + 12
    gfx.y = y + 28
    gfx.drawstr(truncate_string(value, math.max(10, math.floor((w - 24) / 7))))
  end

  local function draw_status_legend(x, y, w)
    set_color(24, 27, 33, 1)
    rect(x, y, w, 214, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, 214, false, 10)
    draw_panel_title(x + 14, y + 12, "Status Colors", "Detected from custom region colors")

    local chip_y = y + 54
    local chip_x = x + 14
    local col = 0
    for _, status in ipairs({ "Done", "WIP", "Review", "Revision", "Todo", "Hold", "Approved" }) do
      local color = STATUS_COLORS[status] or DEFAULT_STATUS_COLORS[status]
      set_color(color.r, color.g, color.b, 1)
      rect(chip_x + (col % 2) * 118, chip_y + math.floor(col / 2) * 30, 18, 18, true, 4)
      set_color(236, 240, 245, 1)
      gfx.x = chip_x + 26 + (col % 2) * 118
      gfx.y = chip_y - 1 + math.floor(col / 2) * 30
      gfx.drawstr(status)
      col = col + 1
    end

    if button("edit_status_colors", x + 14, y + 176, w - 28, 28, "Edit Colors") then
      if prompt_edit_status_colors() then
        gui.needs_save = true
        set_message("Status colors updated.")
      end
    end
  end

  local function draw_status_tools(x, y, w)
    set_color(24, 27, 33, 1)
    rect(x, y, w, 308, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, 308, false, 10)
    draw_panel_title(x + 14, y + 12, "Status Tools", "Applies to regions inside the current time selection")

    local bx = x + 14
    local by = y + 52
    local statuses = { "Done", "WIP", "Review", "Revision", "Todo", "Hold", "Approved" }
    for index, status in ipairs(statuses) do
      local row = math.floor((index - 1) / 2)
      local col = (index - 1) % 2
      if button("status_" .. status, bx + col * 118, by + row * 36, 104, 28, status) then
        local changed, has_time_selection = batch_set_status(status)
        if changed > 0 then
          set_message(string.format("%s applied to %d regions.", status, changed))
        elseif has_time_selection then
          set_message("No regions intersect the current time selection.")
        else
          set_message("Create a time selection to use the status tools.")
        end
      end
    end

    if button("find_empty_regions", x + 14, y + 190, w - 28, 30, "Find Empty Regions") then
      show_empty_regions()
    end

    if button("renumber_variations", x + 14, y + 226, w - 28, 30, "Re-number Variations") then
      local renamed, groups, has_time_selection = renumber_variations_in_scope()
      if renamed > 0 then
        set_message(string.format("Renumbered %d regions across %d groups.", renamed, groups))
      elseif has_time_selection then
        set_message("No renumberable variation groups in the current time selection.")
      else
        set_message("No renumberable variation groups found in the project.")
      end
    end

    if button("batch_rename_fields", x + 14, y + 262, w - 28, 30, "Batch Rename Prefix/Category") then
      local captions = table.concat({
        "separator=|",
        "extrawidth=220",
        "Match Prefix (empty=any)",
        "New Prefix (empty=keep)",
        "Match Category (empty=any)",
        "New Category (empty=keep)",
      }, "|")

      local ok, values = reaper.GetUserInputs(
        SCRIPT_TITLE .. " - Batch Rename",
        4,
        captions,
        "|||"
      )

      if ok then
        local parts = split_delimited(values, "|", 4)
        local changed, has_time_selection = batch_rename_prefix_category(parts[1], parts[2], parts[3], parts[4])
        if changed > 0 then
          set_message(string.format("Batch-renamed %d regions.", changed))
        elseif has_time_selection then
          set_message("No matching parseable regions inside the current time selection.")
        else
          set_message("No matching parseable regions found in the project.")
        end
      end
    end
  end

  local function draw_export_panel(x, y, w, h)
    set_color(24, 27, 33, 1)
    rect(x, y, w, h, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, h, false, 10)
    draw_panel_title(x + 16, y + 14, "Export Worksheet", "Regions/markers -> CSV, text report, or both")

    settings.include_regions = apply_checkbox(settings.include_regions, "exp_regions", x + 16, y + 52, "Include Regions")
    settings.include_markers = apply_checkbox(settings.include_markers, "exp_markers", x + 200, y + 52, "Include Markers")
    settings.only_time_selection = apply_checkbox(settings.only_time_selection, "exp_time", x + 16, y + 88, "Only Time Selection")
    settings.include_audio_analysis = apply_checkbox(settings.include_audio_analysis, "exp_audio", x + 200, y + 88, "Include Audio Analysis")
    settings.add_bom = apply_checkbox(settings.add_bom, "exp_bom", x + 16, y + 124, "Add UTF-8 BOM")
    settings.auto_open_export = apply_checkbox(settings.auto_open_export, "exp_open", x + 200, y + 124, "Auto-open Result")
    settings.include_pivot_summary = apply_checkbox(settings.include_pivot_summary, "exp_pivot", x + 16, y + 160, "Include Pivot CSV")

    draw_value_box(x + 16, y + 206, w - 172, "Output Path", settings.export_path == "" and "(auto: Project/Worksheets/...)" or settings.export_path)
    if button("exp_path_edit", x + w - 144, y + 206, 128, 26, "Edit Path") then
      edit_export_path()
    end
    if button("exp_path_clear", x + w - 144, y + 234, 128, 26, "Use Auto Path") then
      settings.export_path = ""
      mark_dirty("Export path reset to auto.")
    end

    draw_value_box(x + 16, y + 276, 220, "Output Format", settings.output_format)
    if button("exp_format", x + 248, y + 290, 120, 28, "Cycle Format") then
      cycle_output_format()
    end
    if button("exp_dialog", x + 380, y + 290, 146, 28, "Advanced Dialog") then
      if prompt_export_settings(settings) then
        mark_dirty("Export settings updated.")
      end
    end
  end

  local function draw_import_panel(x, y, w, h)
    set_color(24, 27, 33, 1)
    rect(x, y, w, h, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, h, false, 10)
    draw_panel_title(x + 16, y + 14, "Import Worksheet", "CSV/asset list -> empty regions")

    draw_value_box(x + 16, y + 52, w - 172, "Import File", settings.import_csv_path == "" and "(select a CSV or text list)" or settings.import_csv_path)
    if button("imp_browse", x + w - 144, y + 52, 128, 26, "Browse File") then
      browse_import_csv()
    end
    if button("imp_clear", x + w - 144, y + 80, 128, 26, "Clear Path") then
      settings.import_csv_path = ""
      mark_dirty("Import file cleared.")
    end

    draw_value_box(x + 16, y + 122, 170, "Start Position", tostring(settings.start_position))
    draw_value_box(x + 198, y + 122, 120, "Gap (sec)", tostring(settings.gap_between_regions))
    draw_value_box(x + 330, y + 122, 140, "Duration (sec)", tostring(settings.default_duration))
    draw_value_box(x + 482, y + 122, 90, "Prefix", tostring(settings.default_prefix))

    settings.skip_duplicates = apply_checkbox(settings.skip_duplicates, "imp_dup", x + 16, y + 194, "Skip Duplicates")
    settings.auto_color_by_status = apply_checkbox(settings.auto_color_by_status, "imp_color", x + 200, y + 194, "Auto Color by Status")
    settings.auto_expand_variations = apply_checkbox(settings.auto_expand_variations, "imp_expand", x + 16, y + 230, "Auto Expand Variations")

    if button("imp_edit_details", x + 16, y + 274, 170, 28, "Edit Timing/Prefix") then
      edit_import_details()
    end
    if button("imp_dialog", x + 198, y + 274, 150, 28, "Advanced Dialog") then
      if prompt_import_settings(settings) then
        mark_dirty("Import settings updated.")
      end
    end
  end

  local function draw_dashboard_panel(x, y, w, h)
    set_color(24, 27, 33, 1)
    rect(x, y, w, h, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, h, false, 10)
    draw_panel_title(x + 16, y + 14, "Dashboard", "Console progress overview for the current project")

    settings.include_regions = apply_checkbox(settings.include_regions, "dash_regions", x + 16, y + 52, "Include Regions")
    settings.include_markers = apply_checkbox(settings.include_markers, "dash_markers", x + 200, y + 52, "Include Markers")
    settings.only_time_selection = apply_checkbox(settings.only_time_selection, "dash_time", x + 16, y + 88, "Only Time Selection")

    local regions = collect_all_regions_and_markers({
      include_regions = settings.include_regions,
      include_markers = settings.include_markers,
      only_time_selection = settings.only_time_selection,
      include_audio_analysis = false,
    })
    local summary = summarize_entries(regions)

    draw_value_box(x + 16, y + 144, 140, "Entries", tostring(summary.total))
    draw_value_box(x + 168, y + 144, 140, "Regions", tostring(summary.regions))
    draw_value_box(x + 320, y + 144, 140, "Markers", tostring(summary.markers))
    draw_value_box(x + 472, y + 144, 140, "Done+Approved", tostring((summary.status_totals.Done or 0) + (summary.status_totals.Approved or 0)))

    if button("dash_dialog", x + 16, y + 218, 150, 28, "Advanced Dialog") then
      if prompt_dashboard_settings(settings) then
        mark_dirty("Dashboard settings updated.")
      end
    end
  end

  local function draw_sync_panel(x, y, w, h)
    set_color(24, 27, 33, 1)
    rect(x, y, w, h, true, 10)
    set_color(57, 64, 76, 1)
    rect(x, y, w, h, false, 10)
    draw_panel_title(x + 16, y + 14, "Sync Worksheet", "CSV status/name changes -> project regions")

    draw_value_box(x + 16, y + 52, w - 172, "Sync File", settings.sync_csv_path == "" and "(select a sync CSV)" or settings.sync_csv_path)
    if button("sync_browse", x + w - 144, y + 52, 128, 26, "Browse File") then
      browse_sync_csv()
    end
    if button("sync_clear", x + w - 144, y + 80, 128, 26, "Clear Path") then
      settings.sync_csv_path = ""
      mark_dirty("Sync file cleared.")
    end

    settings.sync_update_status = apply_checkbox(settings.sync_update_status, "sync_status", x + 16, y + 126, "Update Status Colors")
    settings.sync_update_names = apply_checkbox(settings.sync_update_names, "sync_names", x + 200, y + 126, "Update Names")
    settings.sync_include_markers = apply_checkbox(settings.sync_include_markers, "sync_markers", x + 16, y + 162, "Match Markers Too")

    if button("sync_preview", x + 16, y + 214, 140, 28, "Preview Sync") then
      preview_sync_only()
    end
    if button("sync_dialog", x + 168, y + 214, 150, 28, "Advanced Dialog") then
      if prompt_sync_settings(settings) then
        mark_dirty("Sync settings updated.")
      end
    end
  end

  gfx.init(SCRIPT_TITLE .. " - GUI", 980, 720, 0)
  gfx.setfont(1, "Segoe UI", 16)

  local function loop()
    local char = gfx.getchar()
    if char < 0 or char == 27 then
      save_settings(settings)
      gfx.quit()
      return
    end

    begin_frame()

    local w = gfx.w
    local h = gfx.h
    local left_w = w - 308
    local right_x = left_w + 24

    set_color(14, 17, 22, 1)
    gfx.rect(0, 0, w, h, 1)

    set_color(22, 26, 33, 1)
    gfx.rect(0, 0, w, 74, 1)
    draw_panel_title(20, 16, "Game Sound Worksheet Generator", get_project_name())

    local tab_y = 26
    local tab_x = 370
    for _, tab in ipairs({ "export", "import", "dashboard", "sync" }) do
      local label = tab:gsub("^%l", string.upper)
      if button("tab_" .. tab, tab_x, tab_y, 112, 32, label, { active = gui.tab == tab }) then
        gui.tab = tab
        mark_dirty("Tab: " .. label)
      end
      tab_x = tab_x + 120
    end

    if gui.tab == "export" then
      draw_export_panel(20, 94, left_w - 24, 324)
    elseif gui.tab == "import" then
      draw_import_panel(20, 94, left_w - 24, 324)
    elseif gui.tab == "dashboard" then
      draw_dashboard_panel(20, 94, left_w - 24, 324)
    elseif gui.tab == "sync" then
      draw_sync_panel(20, 94, left_w - 24, 324)
    end

    draw_status_legend(right_x, 94, w - right_x - 20)
    draw_status_tools(right_x, 320, w - right_x - 20)

    set_color(24, 27, 33, 1)
    rect(20, 438, left_w - 24, 152, true, 10)
    set_color(57, 64, 76, 1)
    rect(20, 438, left_w - 24, 152, false, 10)
    draw_panel_title(34, 452, "Notes", "Current mode executes the same core functions as the dialog flow")
    draw_value_box(34, 490, left_w - 52, "Message", gui.message)

    if button("execute_main", 20, h - 58, 132, 36, "Execute") then
      execute_current_tab()
    end
    if button("close_gui", 164, h - 58, 132, 36, "Close") then
      save_settings(settings)
      gfx.quit()
      return
    end

    if gui.tab == "sync" and button("apply_sync_bottom", 308, h - 58, 170, 36, "Preview / Apply Sync") then
      execute_sync(settings, false)
      set_message("Sync preview generated.")
    end

    end_frame()
    gfx.update()
    reaper.defer(loop)
  end

  loop()
end

local function main()
  local settings = load_settings()

  if not prompt_for_mode(settings) then
    return
  end

  if settings.mode == "gui" then
    save_settings(settings)
    execute_gui(settings)
    return
  end

  local should_continue = false
  if settings.mode == "export" then
    should_continue = prompt_export_settings(settings)
  elseif settings.mode == "import" then
    should_continue = prompt_import_settings(settings)
  elseif settings.mode == "dashboard" then
    should_continue = prompt_dashboard_settings(settings)
  elseif settings.mode == "sync" then
    should_continue = prompt_sync_settings(settings)
  end

  if not should_continue then
    return
  end

  save_settings(settings)

  if settings.mode == "export" then
    execute_export(settings)
  elseif settings.mode == "import" then
    execute_import(settings)
  elseif settings.mode == "dashboard" then
    execute_dashboard(settings)
  elseif settings.mode == "sync" then
    execute_sync(settings, false)
  end
end

main()
