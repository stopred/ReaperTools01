-- Game Sound Project Archiver v1.0
-- Reaper ReaScript (Lua)
-- Cleanup, dependency scan, and archive-prep helper for game audio projects.
--
-- Usage:
-- [Health Check] Scan referenced media, missing files, unused media, and disk usage.
-- [Cleanup]      Move unused media, orphan peak files, and backup files into
--                the project-local _unused_media folder.
-- [Dry Run]      Preview all actions without touching files.
--
-- Requirements: REAPER v7.0+
-- Related workflow: Worksheet, Template, Variation, Audition, Tail,
--                   Loudness, Renderer, Metadata, Recipe

local SCRIPT_TITLE = "Game Sound Project Archiver v1.0"
local EXT_SECTION = "GameSoundProjectArchiver"
local UNUSED_ROOT_NAME = "_unused_media"
local MAX_DETAIL_LINES = 8

local DEFAULTS = {
  mode = "health",
  dry_run = true,
  clean_unused_media = true,
  clean_peak_files = true,
  move_backup_files = true,
  keep_backups = 3,
  report_empty_tracks = true,
  report_muted = true,
  max_scan_depth = 20,
}

local AUDIO_EXTENSIONS = {
  wav = true,
  mp3 = true,
  ogg = true,
  flac = true,
  aif = true,
  aiff = true,
  w64 = true,
  bwf = true,
}

local MIDI_EXTENSIONS = {
  mid = true,
  midi = true,
}

local TOP_LEVEL_SKIP_DIRECTORIES = {
  [UNUSED_ROOT_NAME:lower()] = true,
  [".git"] = true,
  ["analysis"] = true,
  ["archive"] = true,
  ["delivery"] = true,
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function clear_console()
  if reaper.ClearConsole then
    reaper.ClearConsole()
  end
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

local function to_native_path(path)
  return normalize_path(path):gsub("/", "\\")
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

local function path_key(path)
  return normalize_path(path):lower()
end

local function basename(path)
  local normalized = normalize_path(path)
  return normalized:match("([^/]+)$") or normalized
end

local function parent_path(path)
  local normalized = normalize_path(path)
  return normalized:match("(.+)/[^/]+$") or ""
end

local function strip_extension(name)
  local lowered = trim_string(name):lower()
  if lowered:sub(-8) == ".rpp-bak" then
    return name:sub(1, #name - 8)
  end
  if lowered:sub(-10) == ".reapeaks" then
    return name:sub(1, #name - 10)
  end
  return tostring(name or ""):gsub("%.[^%.\\/]+$", "")
end

local function relative_to(root, path)
  local normalized_root = normalize_path(root)
  local normalized_path = normalize_path(path)
  local root_key = path_key(normalized_root)
  local path_key_value = path_key(normalized_path)

  if normalized_root == "" or normalized_path == "" then
    return nil
  end

  if path_key_value == root_key then
    return ""
  end

  local prefix = root_key .. "/"
  if path_key_value:sub(1, #prefix) == prefix then
    return normalized_path:sub(#normalized_root + 2)
  end

  return nil
end

local function is_path_inside(path, root)
  return relative_to(root, path) ~= nil
end

local function ensure_directory(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end
  return reaper.RecursiveCreateDirectory(normalized, 0) > 0
end

local function file_exists(path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return false
  end

  if reaper.file_exists then
    return reaper.file_exists(normalized)
  end

  local handle = io.open(to_native_path(normalized), "rb")
  if handle then
    handle:close()
    return true
  end

  return false
end

local function get_file_size(path)
  local handle = io.open(to_native_path(path), "rb")
  if not handle then
    return 0
  end

  local size = handle:seek("end") or 0
  handle:close()
  return tonumber(size) or 0
end

local function format_size(bytes)
  local units = { "bytes", "KB", "MB", "GB", "TB" }
  local size = tonumber(bytes) or 0
  local unit_index = 1

  while size >= 1024 and unit_index < #units do
    size = size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return string.format("%d %s", math.floor(size + 0.5), units[unit_index])
  end

  return string.format("%.2f %s", size, units[unit_index])
end

local function count_keys(map)
  local count = 0
  for _ in pairs(map or {}) do
    count = count + 1
  end
  return count
end

local function sort_files_by_path(list)
  table.sort(list, function(left, right)
    return path_key(left.path) < path_key(right.path)
  end)
end

local function detect_extension(name)
  local lowered = trim_string(name):lower()
  if lowered:sub(-8) == ".rpp-bak" then
    return "rpp-bak"
  end
  if lowered:sub(-10) == ".reapeaks" then
    return "reapeaks"
  end
  return lowered:match("%.([%w_]+)$")
end

local function parse_mode(raw_value, default_value)
  local lowered = trim_string(raw_value):lower()
  if lowered == "health" or lowered == "scan" then
    return "health"
  end
  if lowered == "clean" then
    return "clean"
  end
  if lowered == "all" then
    return "all"
  end
  return default_value
end

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

  settings.mode = parse_mode(settings.mode, DEFAULTS.mode)
  settings.keep_backups = math.max(0, math.floor(tonumber(settings.keep_backups) or DEFAULTS.keep_backups))
  settings.max_scan_depth = math.max(1, math.floor(tonumber(settings.max_scan_depth) or DEFAULTS.max_scan_depth))
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
  local captions = table.concat({
    "separator=|",
    "extrawidth=320",
    "Mode (health/clean/all)",
    "Dry Run (yes/no)",
    "Clean Unused Media (yes/no)",
    "Move Orphan Peak Files (yes/no)",
    "Move Backup Files (yes/no)",
    "Keep Latest Backups",
    "Report Empty Tracks (yes/no)",
    "Report Muted Elements (yes/no)",
  }, ",")

  local defaults = table.concat({
    current.mode,
    bool_to_string(current.dry_run),
    bool_to_string(current.clean_unused_media),
    bool_to_string(current.clean_peak_files),
    bool_to_string(current.move_backup_files),
    tostring(current.keep_backups),
    bool_to_string(current.report_empty_tracks),
    bool_to_string(current.report_muted),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 8, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 8)
  local settings = {}
  settings.mode = parse_mode(parts[1], current.mode)
  settings.dry_run = parse_boolean(parts[2], current.dry_run)
  settings.clean_unused_media = parse_boolean(parts[3], current.clean_unused_media)
  settings.clean_peak_files = parse_boolean(parts[4], current.clean_peak_files)
  settings.move_backup_files = parse_boolean(parts[5], current.move_backup_files)
  settings.keep_backups = math.max(0, math.floor(tonumber(parts[6]) or current.keep_backups))
  settings.report_empty_tracks = parse_boolean(parts[7], current.report_empty_tracks)
  settings.report_muted = parse_boolean(parts[8], current.report_muted)
  settings.max_scan_depth = current.max_scan_depth

  local raw_mode = trim_string(parts[1]):lower()
  if raw_mode == "consolidate" or raw_mode == "deliver" or raw_mode == "archive" then
    return nil, "Phase 1 currently supports health, clean, or all."
  end

  if not settings.mode then
    return nil, "Mode must be health, clean, or all."
  end

  return settings
end

local function show_error(message)
  reaper.ShowMessageBox(tostring(message or "Unknown error."), SCRIPT_TITLE, 0)
end

local function get_project_file_path()
  local _, project_path = reaper.EnumProjects(-1, "")
  project_path = trim_string(project_path)
  if project_path ~= "" then
    return normalize_path(project_path)
  end
  return nil
end

local function build_project_context()
  local project_file = get_project_file_path()
  if not project_file or project_file == "" then
    return nil, "Save the REAPER project first so the script can scan the project folder."
  end

  local project_dir = parent_path(project_file)
  if project_dir == "" then
    return nil, "Could not resolve the current project directory."
  end

  local project_filename = basename(project_file)
  local project_name = strip_extension(project_filename)
  if project_name == "" then
    project_name = "Untitled"
  end

  return {
    project_file = project_file,
    project_filename = project_filename,
    project_dir = project_dir,
    project_name = project_name,
    quarantine_root = join_paths(project_dir, UNUSED_ROOT_NAME),
  }
end

local function get_track_name(track)
  if not track then
    return ""
  end

  local _, name = reaper.GetTrackName(track, "")
  name = trim_string(name)
  if name == "" then
    return "(unnamed track)"
  end

  return name
end

local function get_take_name(take, fallback_path)
  if not take then
    return basename(fallback_path or "")
  end

  local take_name = trim_string(reaper.GetTakeName(take))
  if take_name == "" then
    take_name = basename(fallback_path or "")
  end

  return take_name
end

local function resolve_absolute_path(path, project_dir)
  local trimmed = trim_string(path)
  if trimmed == "" then
    return ""
  end

  if is_absolute_path(trimmed) then
    return normalize_path(trimmed)
  end

  return normalize_path(join_paths(project_dir, trimmed))
end

local function describe_reference(info)
  local first = info and info.referenced_by and info.referenced_by[1] or nil
  if not first then
    return "no item details"
  end

  local parts = {}
  if not is_blank(first.track_name) then
    parts[#parts + 1] = "track " .. first.track_name
  end
  if not is_blank(first.take_name) then
    parts[#parts + 1] = "take " .. first.take_name
  end
  if #parts == 0 then
    parts[#parts + 1] = "item #" .. tostring((first.item_index or 0) + 1)
  end

  local description = table.concat(parts, " / ")
  local extra = #(info.referenced_by or {}) - 1
  if extra > 0 then
    description = description .. string.format(" (+%d more)", extra)
  end

  return description
end

local function create_reference_info(abs_path, exists, is_internal)
  return {
    path = abs_path,
    filename = basename(abs_path),
    exists = exists,
    is_internal = is_internal,
    size_bytes = exists and get_file_size(abs_path) or 0,
    referenced_by = {},
  }
end

local function scan_project_dependencies(project_context)
  local referenced_files = {}
  local missing_files = {}
  local external_files = {}
  local embedded_sources = {}
  local item_count = reaper.CountMediaItems(0)

  for item_index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, item_index)
    local take_count = reaper.GetMediaItemNumTakes(item)

    for take_index = 0, take_count - 1 do
      local take = reaper.GetMediaItemTake(item, take_index)
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local source_path = trim_string(reaper.GetMediaSourceFileName(source))
          local track = reaper.GetMediaItemTrack(item)
          local track_name = get_track_name(track)
          local abs_path = resolve_absolute_path(source_path, project_context.project_dir)

          if abs_path == "" then
            embedded_sources[#embedded_sources + 1] = {
              track_name = track_name,
              take_name = get_take_name(take, ""),
              item_index = item_index,
              take_index = take_index,
            }
          else
            local exists = file_exists(abs_path)
            local is_internal = is_path_inside(abs_path, project_context.project_dir)
            local key = path_key(abs_path)
            local info = referenced_files[key]

            if not info then
              info = create_reference_info(abs_path, exists, is_internal)
              referenced_files[key] = info

              if not exists then
                missing_files[#missing_files + 1] = info
              elseif not is_internal then
                external_files[#external_files + 1] = info
              end
            else
              if exists and info.size_bytes == 0 then
                info.size_bytes = get_file_size(abs_path)
              end
              info.exists = info.exists or exists
            end

            info.referenced_by[#info.referenced_by + 1] = {
              take_name = get_take_name(take, abs_path),
              track_name = track_name,
              item_index = item_index,
              take_index = take_index,
            }
          end
        end
      end
    end
  end

  sort_files_by_path(missing_files)
  sort_files_by_path(external_files)
  table.sort(embedded_sources, function(left, right)
    if left.track_name == right.track_name then
      return left.take_name < right.take_name
    end
    return left.track_name < right.track_name
  end)

  return referenced_files, missing_files, external_files, embedded_sources
end

local function should_skip_directory(subdir_name, depth)
  local lowered = trim_string(subdir_name):lower()
  if lowered == "" then
    return true
  end

  if lowered == UNUSED_ROOT_NAME:lower() or lowered == ".git" then
    return true
  end

  if depth == 0 then
    if TOP_LEVEL_SKIP_DIRECTORIES[lowered] then
      return true
    end
    if lowered:match("^archive[_%-]") or lowered:match("^delivery[_%-]") then
      return true
    end
  end

  return false
end

local function scan_project_folder(project_context, settings)
  local all_files = {}

  local function scan_recursive(dir_path, depth)
    if depth > settings.max_scan_depth then
      return
    end

    reaper.EnumerateFiles(dir_path, -1)
    reaper.EnumerateSubdirectories(dir_path, -1)

    local file_index = 0
    while true do
      local filename = reaper.EnumerateFiles(dir_path, file_index)
      if not filename then
        break
      end

      local full_path = normalize_path(join_paths(dir_path, filename))
      local relative_path = relative_to(project_context.project_dir, full_path) or filename
      local extension = detect_extension(filename)
      local relative_lower = relative_path:lower()
      local size_bytes = get_file_size(full_path)
      local is_peak = extension == "reapeaks"
      local is_backup = extension == "rpp-bak"
      local is_render = relative_lower == "renders" or relative_lower:match("^renders/")
      local is_audio = AUDIO_EXTENSIONS[extension] or false
      local is_midi = MIDI_EXTENSIONS[extension] or false

      all_files[#all_files + 1] = {
        path = full_path,
        relative_path = relative_path,
        filename = filename,
        extension = extension or "",
        size_bytes = size_bytes,
        directory = dir_path,
        is_audio = is_audio,
        is_midi = is_midi,
        is_media = is_audio or is_midi,
        is_peak = is_peak,
        is_backup = is_backup,
        is_render = is_render,
        is_project_file = extension == "rpp",
      }

      file_index = file_index + 1
    end

    local subdir_index = 0
    while true do
      local subdir = reaper.EnumerateSubdirectories(dir_path, subdir_index)
      if not subdir then
        break
      end

      if not should_skip_directory(subdir, depth) then
        scan_recursive(join_paths(dir_path, subdir), depth + 1)
      end

      subdir_index = subdir_index + 1
    end
  end

  scan_recursive(project_context.project_dir, 0)
  sort_files_by_path(all_files)
  return all_files
end

local function analyze_folder_usage(all_files)
  local usage = {
    total = 0,
    media = 0,
    renders = 0,
    peaks = 0,
    other = 0,
  }

  for _, file in ipairs(all_files) do
    usage.total = usage.total + file.size_bytes

    if file.is_peak then
      usage.peaks = usage.peaks + file.size_bytes
    elseif file.is_render then
      usage.renders = usage.renders + file.size_bytes
    elseif file.is_media then
      usage.media = usage.media + file.size_bytes
    else
      usage.other = usage.other + file.size_bytes
    end
  end

  return usage
end

local function cross_reference_analysis(referenced_files, all_folder_files)
  local analysis = {
    used_files = {},
    unused_media = {},
    orphan_peaks = {},
    backup_files = {},
    render_files = {},
    non_media = {},
    total_size = 0,
    used_size = 0,
    unused_size = 0,
    potential_savings = 0,
  }

  for _, file in ipairs(all_folder_files) do
    local key = path_key(file.path)
    analysis.total_size = analysis.total_size + file.size_bytes

    if referenced_files[key] then
      analysis.used_files[#analysis.used_files + 1] = file
      analysis.used_size = analysis.used_size + file.size_bytes
    elseif file.is_peak then
      local original_path = normalize_path(file.path:sub(1, #file.path - 10))
      local original_key = path_key(original_path)

      if not referenced_files[original_key] and not file_exists(original_path) then
        analysis.orphan_peaks[#analysis.orphan_peaks + 1] = file
        analysis.unused_size = analysis.unused_size + file.size_bytes
      end
    elseif file.is_backup then
      analysis.backup_files[#analysis.backup_files + 1] = file
      analysis.unused_size = analysis.unused_size + file.size_bytes
    elseif file.is_render then
      analysis.render_files[#analysis.render_files + 1] = file
    elseif file.is_media then
      analysis.unused_media[#analysis.unused_media + 1] = file
      analysis.unused_size = analysis.unused_size + file.size_bytes
    else
      analysis.non_media[#analysis.non_media + 1] = file
    end
  end

  analysis.potential_savings = analysis.unused_size

  sort_files_by_path(analysis.used_files)
  sort_files_by_path(analysis.unused_media)
  sort_files_by_path(analysis.orphan_peaks)
  sort_files_by_path(analysis.backup_files)
  sort_files_by_path(analysis.render_files)
  sort_files_by_path(analysis.non_media)

  return analysis
end

local function find_empty_tracks()
  local empty_tracks = {}
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    local item_count = reaper.CountTrackMediaItems(track)
    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")

    if item_count == 0 and folder_depth ~= 1 then
      empty_tracks[#empty_tracks + 1] = {
        index = track_index,
        name = get_track_name(track),
      }
    end
  end

  table.sort(empty_tracks, function(left, right)
    return left.index < right.index
  end)
  return empty_tracks
end

local function find_muted_items_and_tracks()
  local result = {
    items = 0,
    tracks = 0,
    muted_item_names = {},
    muted_track_names = {},
  }

  local item_count = reaper.CountMediaItems(0)
  for item_index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, item_index)
    if reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1 then
      result.items = result.items + 1
      local take = reaper.GetActiveTake(item)
      local name = get_take_name(take, "")
      result.muted_item_names[#result.muted_item_names + 1] = name
    end
  end

  local track_count = reaper.CountTracks(0)
  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    if reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1 then
      result.tracks = result.tracks + 1
      result.muted_track_names[#result.muted_track_names + 1] = get_track_name(track)
    end
  end

  table.sort(result.muted_item_names)
  table.sort(result.muted_track_names)
  return result
end

local function analyze_project(project_context, settings)
  local referenced_files, missing_files, external_files, embedded_sources = scan_project_dependencies(project_context)
  local all_folder_files = scan_project_folder(project_context, settings)
  local analysis = cross_reference_analysis(referenced_files, all_folder_files)

  return {
    referenced_files = referenced_files,
    missing_files = missing_files,
    external_files = external_files,
    embedded_sources = embedded_sources,
    all_folder_files = all_folder_files,
    analysis = analysis,
    folder_usage = analyze_folder_usage(all_folder_files),
  }
end

local function sum_file_sizes(files)
  local total = 0
  for _, file in ipairs(files or {}) do
    total = total + (file.size_bytes or 0)
  end
  return total
end

local function run_health_check(scan_result, settings)
  local report = {
    issues = {},
    warnings = {},
    info = {},
    score = "OK",
    issue_count = 0,
    warning_count = 0,
    referenced_total = count_keys(scan_result.referenced_files),
    potential_savings = scan_result.analysis.potential_savings,
    empty_tracks = settings.report_empty_tracks and find_empty_tracks() or {},
    muted = settings.report_muted and find_muted_items_and_tracks() or {
      items = 0,
      tracks = 0,
      muted_item_names = {},
      muted_track_names = {},
    },
  }

  if #scan_result.missing_files > 0 then
    report.issues[#report.issues + 1] = {
      category = "Missing Files",
      message = string.format("%d referenced source file(s) are missing.", #scan_result.missing_files),
      details = scan_result.missing_files,
    }
  end

  if #scan_result.external_files > 0 then
    report.warnings[#report.warnings + 1] = {
      category = "External References",
      message = string.format("%d referenced file(s) are outside the project folder.", #scan_result.external_files),
      details = scan_result.external_files,
      fix = "Phase 2 consolidate mode can copy them into the project later.",
    }
  end

  if reaper.IsProjectDirty(0) == 1 then
    report.warnings[#report.warnings + 1] = {
      category = "Unsaved Changes",
      message = "Project has unsaved changes.",
      details = {},
      fix = "Save the project before final archiving.",
    }
  end

  report.info[#report.info + 1] = {
    category = "Referenced Files",
    message = string.format(
      "%d total reference(s): %d internal, %d external, %d missing.",
      report.referenced_total,
      #scan_result.analysis.used_files,
      #scan_result.external_files,
      #scan_result.missing_files
    ),
    details = {},
  }

  if #scan_result.embedded_sources > 0 then
    report.info[#report.info + 1] = {
      category = "Embedded Sources",
      message = string.format(
        "%d take(s) use embedded or inline sources with no source filename.",
        #scan_result.embedded_sources
      ),
      details = scan_result.embedded_sources,
    }
  end

  report.info[#report.info + 1] = {
    category = "Unused Internal Media",
    message = string.format(
      "%d file(s), %s can be moved to %s.",
      #scan_result.analysis.unused_media,
      format_size(sum_file_sizes(scan_result.analysis.unused_media)),
      UNUSED_ROOT_NAME
    ),
    details = scan_result.analysis.unused_media,
  }

  report.info[#report.info + 1] = {
    category = "Orphan Peak Files",
    message = string.format(
      "%d file(s), %s.",
      #scan_result.analysis.orphan_peaks,
      format_size(sum_file_sizes(scan_result.analysis.orphan_peaks))
    ),
    details = scan_result.analysis.orphan_peaks,
  }

  report.info[#report.info + 1] = {
    category = "Backup Files",
    message = string.format(
      "%d .rpp-bak file(s), %s total.",
      #scan_result.analysis.backup_files,
      format_size(sum_file_sizes(scan_result.analysis.backup_files))
    ),
    details = scan_result.analysis.backup_files,
  }

  report.info[#report.info + 1] = {
    category = "Render Files",
    message = string.format(
      "%d render file(s), %s. Phase 1 reports them but does not move them.",
      #scan_result.analysis.render_files,
      format_size(sum_file_sizes(scan_result.analysis.render_files))
    ),
    details = scan_result.analysis.render_files,
  }

  if settings.report_empty_tracks and #report.empty_tracks > 0 then
    report.info[#report.info + 1] = {
      category = "Empty Tracks",
      message = string.format("%d empty track(s) found.", #report.empty_tracks),
      details = report.empty_tracks,
    }
  end

  if settings.report_muted and (report.muted.items > 0 or report.muted.tracks > 0) then
    report.info[#report.info + 1] = {
      category = "Muted Elements",
      message = string.format("%d muted item(s), %d muted track(s).", report.muted.items, report.muted.tracks),
      details = {},
    }
  end

  report.info[#report.info + 1] = {
    category = "Disk Usage",
    message = string.format(
      "Total %s | Media %s | Renders %s | Peaks %s | Other %s",
      format_size(scan_result.folder_usage.total),
      format_size(scan_result.folder_usage.media),
      format_size(scan_result.folder_usage.renders),
      format_size(scan_result.folder_usage.peaks),
      format_size(scan_result.folder_usage.other)
    ),
    details = {},
  }

  report.issue_count = #report.issues
  report.warning_count = #report.warnings

  if report.issue_count > 0 then
    report.score = "NEEDS ATTENTION"
  elseif report.warning_count > 0 then
    report.score = "REVIEW"
  else
    report.score = "OK"
  end

  return report
end

local function print_detail_lines(project_context, details, formatter)
  local limit = math.min(#details, MAX_DETAIL_LINES)
  for index = 1, limit do
    log_line("    * " .. formatter(details[index], project_context))
  end

  if #details > limit then
    log_line(string.format("    ... +%d more", #details - limit))
  end
end

local function format_reference_file_line(file_info, project_context)
  local display_path = is_path_inside(file_info.path, project_context.project_dir)
    and (relative_to(project_context.project_dir, file_info.path) or file_info.path)
    or file_info.path
  return string.format("%s [%s]", display_path, describe_reference(file_info))
end

local function format_folder_file_line(file_info)
  return string.format("%s (%s)", file_info.relative_path or file_info.path, format_size(file_info.size_bytes))
end

local function format_embedded_source_line(info)
  local track_name = trim_string(info.track_name)
  local take_name = trim_string(info.take_name)
  if track_name == "" and take_name == "" then
    return string.format("item #%d", (info.item_index or 0) + 1)
  end
  return string.format("%s / %s", track_name ~= "" and track_name or "(unnamed track)", take_name ~= "" and take_name or "(unnamed take)")
end

local function format_track_line(info)
  return string.format("#%d %s", (info.index or 0) + 1, info.name or "(unnamed track)")
end

local function print_health_report(project_context, report)
  log_line(string.rep("=", 78))
  log_line("  PROJECT HEALTH CHECK")
  log_line("  Project: " .. project_context.project_filename)
  log_line("  Path:    " .. project_context.project_dir)
  log_line("  Date:    " .. os.date("%Y-%m-%d %H:%M:%S"))
  log_line(string.rep("=", 78))
  log_line("")

  if #report.issues > 0 then
    log_line("  ERRORS")
    for _, entry in ipairs(report.issues) do
      log_line("  - " .. entry.category .. ": " .. entry.message)
      if entry.details and #entry.details > 0 then
        print_detail_lines(project_context, entry.details, format_reference_file_line)
      end
      if entry.fix then
        log_line("    Fix: " .. entry.fix)
      end
      log_line("")
    end
  end

  if #report.warnings > 0 then
    log_line("  WARNINGS")
    for _, entry in ipairs(report.warnings) do
      log_line("  - " .. entry.category .. ": " .. entry.message)
      if entry.details and #entry.details > 0 then
        print_detail_lines(project_context, entry.details, format_reference_file_line)
      end
      if entry.fix then
        log_line("    Fix: " .. entry.fix)
      end
      log_line("")
    end
  end

  log_line("  INFO")
  for _, entry in ipairs(report.info) do
    log_line("  - " .. entry.category .. ": " .. entry.message)
    if entry.details and #entry.details > 0 then
      if entry.category == "Embedded Sources" then
        print_detail_lines(project_context, entry.details, function(item)
          return format_embedded_source_line(item)
        end)
      elseif entry.category == "Empty Tracks" then
        print_detail_lines(project_context, entry.details, function(item)
          return format_track_line(item)
        end)
      else
        print_detail_lines(project_context, entry.details, function(item)
          return format_folder_file_line(item)
        end)
      end
    end
    log_line("")
  end

  log_line(string.rep("-", 78))
  log_line(string.format(
    "  Score: %s (%d error(s), %d warning(s))",
    report.score,
    report.issue_count,
    report.warning_count
  ))
  log_line("  Potential Savings: " .. format_size(report.potential_savings))
  log_line("  Safe Cleanup Root: " .. project_context.quarantine_root)
  log_line("  Safety Rule: cleanup only moves files into _unused_media; nothing is deleted.")
  log_line(string.rep("=", 78))
end

local function extract_backup_sort_key(file)
  local name = (file.filename or ""):lower()
  local year, month, day, hour, minute, second = name:match("(%d%d%d%d)[_%-]?(%d%d)[_%-]?(%d%d)[_%-]?(%d%d)[_%-]?(%d%d)[_%-]?(%d%d)")
  if year then
    return tonumber(year .. month .. day .. hour .. minute .. second) or 0
  end

  local y2, m2, d2 = name:match("(%d%d%d%d)[_%-]?(%d%d)[_%-]?(%d%d)")
  if y2 then
    return tonumber(y2 .. m2 .. d2 .. "000000") or 0
  end

  return 0
end

local function select_backups_to_move(backup_files, keep_count)
  local ordered = {}
  for index, file in ipairs(backup_files or {}) do
    ordered[index] = file
  end

  table.sort(ordered, function(left, right)
    local left_key = extract_backup_sort_key(left)
    local right_key = extract_backup_sort_key(right)
    if left_key ~= right_key then
      return left_key > right_key
    end
    return path_key(left.path) > path_key(right.path)
  end)

  local candidates = {}
  for index = keep_count + 1, #ordered do
    candidates[#candidates + 1] = ordered[index]
  end

  sort_files_by_path(candidates)
  return candidates
end

local function build_cleanup_plan(project_context, scan_result, settings)
  local plan = {
    entries = {},
    counts = {
      unused_media = 0,
      peaks = 0,
      backups = 0,
    },
    sizes = {
      unused_media = 0,
      peaks = 0,
      backups = 0,
    },
    keep_backups = settings.keep_backups,
  }

  local function add_entries(files, bucket)
    for _, file in ipairs(files or {}) do
      plan.entries[#plan.entries + 1] = {
        bucket = bucket,
        source_path = file.path,
        relative_path = file.relative_path,
        filename = file.filename,
        size_bytes = file.size_bytes,
      }
      plan.counts[bucket] = plan.counts[bucket] + 1
      plan.sizes[bucket] = plan.sizes[bucket] + file.size_bytes
    end
  end

  if settings.clean_unused_media then
    add_entries(scan_result.analysis.unused_media, "unused_media")
  end

  if settings.clean_peak_files then
    add_entries(scan_result.analysis.orphan_peaks, "peaks")
  end

  if settings.move_backup_files then
    add_entries(select_backups_to_move(scan_result.analysis.backup_files, settings.keep_backups), "backups")
  end

  table.sort(plan.entries, function(left, right)
    if left.bucket == right.bucket then
      return path_key(left.source_path) < path_key(right.source_path)
    end
    return left.bucket < right.bucket
  end)

  plan.total_count = #plan.entries
  plan.total_size = plan.sizes.unused_media + plan.sizes.peaks + plan.sizes.backups
  plan.quarantine_root = project_context.quarantine_root
  return plan
end

local function make_unique_path(path)
  local candidate = normalize_path(path)
  if not file_exists(candidate) then
    return candidate
  end

  local directory = parent_path(candidate)
  local filename = basename(candidate)
  local stem, extension = filename:match("^(.*)(%.[^%.]+)$")
  if not stem then
    stem = filename
    extension = ""
  end

  local counter = 1
  while true do
    local next_candidate = join_paths(directory, string.format("%s_%03d%s", stem, counter, extension))
    if not file_exists(next_candidate) then
      return next_candidate
    end
    counter = counter + 1
  end
end

local function build_quarantine_destination(project_context, entry)
  local relative_path = relative_to(project_context.project_dir, entry.source_path) or entry.filename
  local bucket_prefix = ""

  if entry.bucket == "peaks" then
    bucket_prefix = "_peaks"
  elseif entry.bucket == "backups" then
    bucket_prefix = "_backups"
  end

  local destination_relative = relative_path
  if bucket_prefix ~= "" then
    destination_relative = join_paths(bucket_prefix, relative_path)
  end

  return make_unique_path(join_paths(project_context.quarantine_root, destination_relative))
end

local function safe_move_file(source_path, destination_path)
  local source_native = to_native_path(source_path)
  local destination_native = to_native_path(destination_path)
  return os.rename(source_native, destination_native)
end

local function print_cleanup_preview(plan, settings)
  log_line("")
  log_line("  CLEANUP PLAN")
  log_line(string.format(
    "  - Unused Media: %d file(s), %s",
    plan.counts.unused_media,
    format_size(plan.sizes.unused_media)
  ))
  log_line(string.format(
    "  - Orphan Peaks: %d file(s), %s",
    plan.counts.peaks,
    format_size(plan.sizes.peaks)
  ))
  log_line(string.format(
    "  - Backup Files To Move: %d file(s), %s (keeping latest %d)",
    plan.counts.backups,
    format_size(plan.sizes.backups),
    plan.keep_backups
  ))
  log_line(string.format(
    "  - Total Planned Moves: %d file(s), %s",
    plan.total_count,
    format_size(plan.total_size)
  ))
  if settings.dry_run then
    log_line("  - Mode: DRY RUN")
  end

  local preview_limit = math.min(plan.total_count, MAX_DETAIL_LINES)
  for index = 1, preview_limit do
    local entry = plan.entries[index]
    log_line(string.format(
      "    * [%s] %s",
      entry.bucket,
      entry.relative_path or entry.source_path
    ))
  end
  if plan.total_count > preview_limit then
    log_line(string.format("    ... +%d more", plan.total_count - preview_limit))
  end
end

local function confirm_cleanup(plan)
  local message = table.concat({
    "Cleanup will move files into:",
    plan.quarantine_root,
    "",
    string.format("Total files: %d", plan.total_count),
    string.format("Total size: %s", format_size(plan.total_size)),
    "",
    "Nothing is deleted, but file moves are not undoable in REAPER.",
    "Proceed?",
  }, "\n")

  return reaper.ShowMessageBox(message, SCRIPT_TITLE, 4) == 6
end

local function execute_cleanup_plan(project_context, plan, settings)
  local result = {
    moved = 0,
    moved_size = 0,
    failed = 0,
    failures = {},
  }

  if plan.total_count == 0 then
    return result
  end

  ensure_directory(project_context.quarantine_root)

  for _, entry in ipairs(plan.entries) do
    local destination = build_quarantine_destination(project_context, entry)

    if settings.dry_run then
      log_line(string.format(
        "  [DRY RUN] %s -> %s (%s)",
        entry.source_path,
        destination,
        format_size(entry.size_bytes)
      ))
    else
      ensure_directory(parent_path(destination))
      local ok, move_error = safe_move_file(entry.source_path, destination)
      if ok then
        result.moved = result.moved + 1
        result.moved_size = result.moved_size + entry.size_bytes
        log_line(string.format(
          "  Moved: %s -> %s (%s)",
          entry.source_path,
          destination,
          format_size(entry.size_bytes)
        ))
      else
        result.failed = result.failed + 1
        result.failures[#result.failures + 1] = {
          source_path = entry.source_path,
          destination = destination,
          error = move_error or "os.rename failed",
        }
        log_line(string.format(
          "  FAILED: %s -> %s (%s)",
          entry.source_path,
          destination,
          tostring(move_error or "os.rename failed")
        ))
      end
    end
  end

  return result
end

local function build_completion_message(report, plan, result, settings)
  if settings.mode == "health" then
    return string.format(
      "Health check complete.\n\nScore: %s\nErrors: %d\nWarnings: %d\nPotential savings: %s",
      report.score,
      report.issue_count,
      report.warning_count,
      format_size(report.potential_savings)
    )
  end

  if settings.dry_run then
    return string.format(
      "Dry run complete.\n\nPlanned moves: %d\nPotential savings: %s\nCleanup root: %s",
      plan.total_count,
      format_size(plan.total_size),
      plan.quarantine_root
    )
  end

  return string.format(
    "Cleanup complete.\n\nMoved: %d file(s)\nFreed from active project tree: %s\nFailures: %d\nCleanup root: %s",
    result.moved,
    format_size(result.moved_size),
    result.failed,
    plan.quarantine_root
  )
end

local function main()
  local project_context, context_error = build_project_context()
  if not project_context then
    show_error(context_error)
    return
  end

  local settings = load_settings()
  local prompted_settings, prompt_error = prompt_for_settings(settings)
  if not prompted_settings then
    if prompt_error and prompt_error ~= "User cancelled." then
      show_error(prompt_error)
    end
    return
  end

  settings = prompted_settings
  save_settings(settings)

  clear_console()
  log_line("Scanning project dependencies and project folder...")
  local scan_result = analyze_project(project_context, settings)
  local report = run_health_check(scan_result, settings)

  clear_console()
  print_health_report(project_context, report)

  if settings.mode == "health" then
    reaper.ShowMessageBox(build_completion_message(report, nil, nil, settings), SCRIPT_TITLE, 0)
    return
  end

  local cleanup_plan = build_cleanup_plan(project_context, scan_result, settings)
  print_cleanup_preview(cleanup_plan, settings)

  if cleanup_plan.total_count == 0 then
    reaper.ShowMessageBox(
      "Health check complete.\n\nNo files matched the selected cleanup rules.",
      SCRIPT_TITLE,
      0
    )
    return
  end

  if not settings.dry_run and not confirm_cleanup(cleanup_plan) then
    return
  end

  log_line("")
  log_line("  CLEANUP EXECUTION")
  local cleanup_result = execute_cleanup_plan(project_context, cleanup_plan, settings)

  if cleanup_result.failed > 0 then
    log_line("")
    log_line("  FAILURES")
    for _, failure in ipairs(cleanup_result.failures) do
      log_line(string.format("  - %s -> %s (%s)", failure.source_path, failure.destination, failure.error))
    end
  end

  reaper.ShowMessageBox(
    build_completion_message(report, cleanup_plan, cleanup_result, settings),
    SCRIPT_TITLE,
    0
  )
end

main()
