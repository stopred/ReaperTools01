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
  check_samplerate = true,
  report_empty_tracks = true,
  report_muted = true,
  remove_empty_tracks = false,
  remove_muted_tracks = false,
  subfolder_mode = "by_library",
  package_mode = "delivery",
  include_renders = true,
  include_worksheets = true,
  include_recipes = true,
  generate_readme = true,
  studio_name = "Dekatri Studio",
  contact_email = "",
  package_output_path = "",
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

local STANDARD_FOLDER_STRUCTURE = {
  "Media",
  "Media/Sources",
  "Media/Recordings",
  "Media/Synthesized",
  "Renders",
  "Renders/SFX",
  "Renders/AMB",
  "Renders/UI",
  "Renders/MUS",
  "Renders/VO",
  "Worksheets",
  "Recipes",
  "Analysis",
  "Delivery",
  "Archive",
  "_unused_media",
}

local SUBFOLDER_MODE_LABELS = {
  flat = "Flat",
  by_library = "By Library",
  by_category = "By Category",
}

local PACKAGE_MODE_LABELS = {
  delivery = "Delivery",
  archive = "Archive",
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

local function normalize_subfolder_mode(raw_value, default_value)
  local lowered = trim_string(raw_value):lower()
  if lowered == "flat" then
    return "flat"
  end
  if lowered == "by_library" or lowered == "library" then
    return "by_library"
  end
  if lowered == "by_category" or lowered == "category" then
    return "by_category"
  end
  return default_value
end

local function normalize_package_mode(raw_value, default_value)
  local lowered = trim_string(raw_value):lower()
  if lowered == "delivery" or lowered == "deliver" then
    return "delivery"
  end
  if lowered == "archive" then
    return "archive"
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
  settings.subfolder_mode = normalize_subfolder_mode(settings.subfolder_mode, DEFAULTS.subfolder_mode)
  settings.package_mode = normalize_package_mode(settings.package_mode, DEFAULTS.package_mode)
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
    "Check Sample Rate (yes/no)",
    "Report Empty Tracks (yes/no)",
    "Report Muted Elements (yes/no)",
    "Remove Empty Tracks (yes/no)",
    "Remove Muted Tracks (yes/no)",
  }, ",")

  local defaults = table.concat({
    current.mode,
    bool_to_string(current.dry_run),
    bool_to_string(current.clean_unused_media),
    bool_to_string(current.clean_peak_files),
    bool_to_string(current.move_backup_files),
    tostring(current.keep_backups),
    bool_to_string(current.check_samplerate),
    bool_to_string(current.report_empty_tracks),
    bool_to_string(current.report_muted),
    bool_to_string(current.remove_empty_tracks),
    bool_to_string(current.remove_muted_tracks),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 11, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 11)
  local settings = {}
  settings.mode = parse_mode(parts[1], current.mode)
  settings.dry_run = parse_boolean(parts[2], current.dry_run)
  settings.clean_unused_media = parse_boolean(parts[3], current.clean_unused_media)
  settings.clean_peak_files = parse_boolean(parts[4], current.clean_peak_files)
  settings.move_backup_files = parse_boolean(parts[5], current.move_backup_files)
  settings.keep_backups = math.max(0, math.floor(tonumber(parts[6]) or current.keep_backups))
  settings.check_samplerate = parse_boolean(parts[7], current.check_samplerate)
  settings.report_empty_tracks = parse_boolean(parts[8], current.report_empty_tracks)
  settings.report_muted = parse_boolean(parts[9], current.report_muted)
  settings.remove_empty_tracks = parse_boolean(parts[10], current.remove_empty_tracks)
  settings.remove_muted_tracks = parse_boolean(parts[11], current.remove_muted_tracks)
  settings.max_scan_depth = current.max_scan_depth

  local raw_mode = trim_string(parts[1]):lower()
  if raw_mode == "consolidate" or raw_mode == "deliver" or raw_mode == "archive" then
    return nil, "Prompt fallback supports health, clean, or all. Use the gfx UI for consolidate, delivery, or archive."
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
              take = take,
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

local function collect_directory_files(base_dir, max_depth)
  local files = {}
  local normalized_base = normalize_path(base_dir)

  if normalized_base == "" then
    return files
  end

  local function recurse(dir_path, depth)
    if depth > (max_depth or DEFAULTS.max_scan_depth) then
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
      local extension = detect_extension(filename)
      files[#files + 1] = {
        path = full_path,
        relative_path = relative_to(normalized_base, full_path) or filename,
        filename = filename,
        extension = extension or "",
        size_bytes = get_file_size(full_path),
        is_audio = AUDIO_EXTENSIONS[extension] or false,
        is_midi = MIDI_EXTENSIONS[extension] or false,
        is_media = (AUDIO_EXTENSIONS[extension] or false) or (MIDI_EXTENSIONS[extension] or false),
        is_peak = extension == "reapeaks",
        is_backup = extension == "rpp-bak",
      }

      file_index = file_index + 1
    end

    local subdir_index = 0
    while true do
      local subdir = reaper.EnumerateSubdirectories(dir_path, subdir_index)
      if not subdir then
        break
      end

      recurse(join_paths(dir_path, subdir), depth + 1)
      subdir_index = subdir_index + 1
    end
  end

  recurse(normalized_base, 0)
  sort_files_by_path(files)
  return files
end

local function ensure_parent_directory(path)
  local parent = parent_path(path)
  if parent ~= "" then
    ensure_directory(parent)
  end
end

local function write_text_file(path, contents)
  ensure_parent_directory(path)

  local handle, open_error = io.open(to_native_path(path), "wb")
  if not handle then
    return false, tostring(open_error or "Failed to open file for writing.")
  end

  local ok, write_error = handle:write(tostring(contents or ""))
  handle:close()

  if not ok then
    return false, tostring(write_error or "Failed to write file.")
  end

  return true
end

local function copy_file(source_path, destination_path)
  local input_handle, input_error = io.open(to_native_path(source_path), "rb")
  if not input_handle then
    return false, tostring(input_error or "Failed to open source file.")
  end

  ensure_parent_directory(destination_path)

  local output_handle, output_error = io.open(to_native_path(destination_path), "wb")
  if not output_handle then
    input_handle:close()
    return false, tostring(output_error or "Failed to open destination file.")
  end

  while true do
    local chunk = input_handle:read(65536)
    if not chunk then
      break
    end
    local ok, write_error = output_handle:write(chunk)
    if not ok then
      input_handle:close()
      output_handle:close()
      return false, tostring(write_error or "Failed to write destination file.")
    end
  end

  input_handle:close()
  output_handle:close()
  return true
end

local function sanitize_dirname(name)
  local sanitized = trim_string(name):gsub("[^%w%s_%-]", ""):gsub("%s+", "_")
  sanitized = sanitized:gsub("_+", "_")
  sanitized = sanitized:gsub("^_+", "")
  sanitized = sanitized:gsub("_+$", "")
  return sanitized ~= "" and sanitized or "Other"
end

local function detect_category(track_name)
  local lowered = trim_string(track_name):lower()
  if lowered:find("amb", 1, true) or lowered:find("ambience", 1, true) then
    return "AMB"
  end
  if lowered:find("ui", 1, true) then
    return "UI"
  end
  if lowered:find("music", 1, true) or lowered:find("mus", 1, true) then
    return "MUS"
  end
  if lowered:find("vo", 1, true) or lowered:find("dialog", 1, true) or lowered:find("voice", 1, true) then
    return "VO"
  end
  return "SFX"
end

local function guess_library_name(path)
  local normalized = normalize_path(path)
  local parent = basename(parent_path(normalized))
  if parent ~= "" and not parent:match("^%a:$") then
    return sanitize_dirname(parent)
  end
  local root = normalized:match("^(%a:)")
  if root then
    return sanitize_dirname(root)
  end
  return "External"
end

local function standardize_folder_structure(project_path, dry_run)
  local created_count = 0

  for _, relative_dir in ipairs(STANDARD_FOLDER_STRUCTURE) do
    local full_path = join_paths(project_path, relative_dir)
    if dry_run then
      log_line("  [DRY RUN] Create folder: " .. full_path)
      created_count = created_count + 1
    else
      ensure_directory(full_path)
      created_count = created_count + 1
    end
  end

  return created_count
end

local function resolve_configured_path(project_dir, configured_path)
  local configured = trim_string(configured_path)
  if configured == "" then
    return ""
  end

  if is_absolute_path(configured) then
    return normalize_path(configured)
  end

  return normalize_path(join_paths(project_dir, configured))
end

local function build_auto_package_path(project_context, package_mode)
  local parent_dir = join_paths(project_context.project_dir, package_mode == "archive" and "Archive" or "Delivery")
  local stamp = os.date("%Y%m%d_%H%M%S")
  local folder_name = string.format("%s_%s_%s", project_context.project_name, package_mode == "archive" and "Archive" or "Delivery", stamp)
  return join_paths(parent_dir, folder_name)
end

local function resolve_package_output_dir(project_context, settings)
  local configured = resolve_configured_path(project_context.project_dir, settings.package_output_path)
  if configured ~= "" then
    return configured
  end
  return build_auto_package_path(project_context, settings.package_mode)
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

local function get_project_sample_rate()
  local project_rate = tonumber(reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 0
  if project_rate <= 0 then
    return 0
  end
  return math.floor(project_rate + 0.5)
end

local function check_samplerate_consistency(project_context, project_sample_rate)
  local mismatches = {}
  local seen = {}

  if project_sample_rate <= 0 then
    return mismatches
  end

  local item_count = reaper.CountMediaItems(0)
  for item_index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, item_index)
    local take_count = reaper.GetMediaItemNumTakes(item)

    for take_index = 0, take_count - 1 do
      local take = reaper.GetMediaItemTake(item, take_index)
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local source_path = resolve_absolute_path(reaper.GetMediaSourceFileName(source), project_context.project_dir)
          local sample_rate = tonumber(reaper.GetMediaSourceSampleRate(source) or 0) or 0

          if source_path ~= "" and sample_rate > 0 and math.floor(sample_rate + 0.5) ~= project_sample_rate then
            local key = path_key(source_path)
            if not seen[key] then
              local track = reaper.GetMediaItemTrack(item)
              mismatches[#mismatches + 1] = {
                path = source_path,
                filename = basename(source_path),
                file_srate = math.floor(sample_rate + 0.5),
                project_srate = project_sample_rate,
                track_name = get_track_name(track),
                take_name = get_take_name(take, source_path),
              }
              seen[key] = true
            end
          end
        end
      end
    end
  end

  table.sort(mismatches, function(left, right)
    return path_key(left.path) < path_key(right.path)
  end)
  return mismatches
end

local function build_track_cleanup_plan(settings)
  local plan = {
    tracks = {},
    counts = {
      empty = 0,
      muted = 0,
    },
  }

  local track_count = reaper.CountTracks(0)
  for track_index = track_count - 1, 0, -1 do
    local track = reaper.GetTrack(0, track_index)
    local item_count = reaper.CountTrackMediaItems(track)
    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    local is_muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
    local is_empty = item_count == 0 and folder_depth ~= 1

    local reasons = {}
    if settings.remove_empty_tracks and is_empty then
      reasons[#reasons + 1] = "empty"
      plan.counts.empty = plan.counts.empty + 1
    end
    if settings.remove_muted_tracks and is_muted and folder_depth ~= 1 then
      reasons[#reasons + 1] = "muted"
      plan.counts.muted = plan.counts.muted + 1
    end

    if #reasons > 0 then
      plan.tracks[#plan.tracks + 1] = {
        track = track,
        index = track_index,
        name = get_track_name(track),
        reasons = reasons,
      }
    end
  end

  plan.total_count = #plan.tracks
  return plan
end

local function print_track_cleanup_preview(plan, settings)
  log_line("")
  log_line("  TRACK CLEANUP PLAN")
  log_line(string.format("  - Empty Tracks To Remove: %d", settings.remove_empty_tracks and plan.counts.empty or 0))
  log_line(string.format("  - Muted Tracks To Remove: %d", settings.remove_muted_tracks and plan.counts.muted or 0))

  local preview_limit = math.min(plan.total_count, MAX_DETAIL_LINES)
  for index = 1, preview_limit do
    local entry = plan.tracks[index]
    log_line(string.format(
      "    * #%d %s [%s]",
      entry.index + 1,
      entry.name,
      table.concat(entry.reasons, ", ")
    ))
  end
  if plan.total_count > preview_limit then
    log_line(string.format("    ... +%d more", plan.total_count - preview_limit))
  end
end

local function confirm_track_cleanup(plan)
  local message = table.concat({
    string.format("Delete %d track(s) from the current REAPER project?", plan.total_count),
    string.format("Empty: %d", plan.counts.empty),
    string.format("Muted: %d", plan.counts.muted),
    "",
    "Track deletion is undoable in REAPER, but it changes the project immediately.",
    "Proceed?",
  }, "\n")

  return reaper.ShowMessageBox(message, SCRIPT_TITLE, 4) == 6
end

local function execute_track_cleanup_plan(plan, settings)
  local result = {
    removed = 0,
    failed = 0,
    failures = {},
  }

  if plan.total_count == 0 then
    return result
  end

  if settings.dry_run then
    return result
  end

  reaper.Undo_BeginBlock()
  for _, entry in ipairs(plan.tracks) do
    local track = reaper.GetTrack(0, entry.index)
    local track_valid = track ~= nil

    if track_valid then
      reaper.DeleteTrack(track)
      result.removed = result.removed + 1
    else
      result.failed = result.failed + 1
      result.failures[#result.failures + 1] = {
        source_path = entry.name,
        destination = "(track delete)",
        error = "Track index no longer resolves to a valid track.",
      }
    end
  end
  reaper.Undo_EndBlock("Game Sound Project Archiver - Cleanup Tracks", -1)
  return result
end

local function analyze_project(project_context, settings)
  local referenced_files, missing_files, external_files, embedded_sources = scan_project_dependencies(project_context)
  local all_folder_files = scan_project_folder(project_context, settings)
  local analysis = cross_reference_analysis(referenced_files, all_folder_files)
  local project_sample_rate = settings.check_samplerate and get_project_sample_rate() or 0
  local sample_rate_mismatches = settings.check_samplerate and check_samplerate_consistency(project_context, project_sample_rate) or {}

  return {
    referenced_files = referenced_files,
    missing_files = missing_files,
    external_files = external_files,
    embedded_sources = embedded_sources,
    all_folder_files = all_folder_files,
    analysis = analysis,
    folder_usage = analyze_folder_usage(all_folder_files),
    project_sample_rate = project_sample_rate,
    sample_rate_mismatches = sample_rate_mismatches,
  }
end

local function sum_file_sizes(files)
  local total = 0
  for _, file in ipairs(files or {}) do
    total = total + (file.size_bytes or 0)
  end
  return total
end

local function run_health_check(project_context, scan_result, settings)
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

  if settings.check_samplerate and scan_result.project_sample_rate > 0 and #scan_result.sample_rate_mismatches > 0 then
    report.warnings[#report.warnings + 1] = {
      category = "Sample Rate Mismatch",
      message = string.format(
        "%d file(s) do not match the project rate (%d Hz).",
        #scan_result.sample_rate_mismatches,
        scan_result.project_sample_rate
      ),
      details = scan_result.sample_rate_mismatches,
      fix = "Review whether these files should be converted or left intentionally mismatched.",
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

  if settings.check_samplerate then
    report.info[#report.info + 1] = {
      category = "Project Sample Rate",
      message = scan_result.project_sample_rate > 0
        and string.format("%d Hz", scan_result.project_sample_rate)
        or "Project rate is not fixed in project settings.",
      details = {},
    }
  end

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
      "%d render file(s), %s. Cleanup only reports them; delivery/archive packaging can include them.",
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

local function format_samplerate_mismatch_line(info, project_context)
  local display_path = is_path_inside(info.path, project_context.project_dir)
    and (relative_to(project_context.project_dir, info.path) or info.path)
    or info.path
  return string.format(
    "%s (%d Hz, project %d Hz) [%s / %s]",
    display_path,
    tonumber(info.file_srate or 0),
    tonumber(info.project_srate or 0),
    tostring(info.track_name or ""),
    tostring(info.take_name or "")
  )
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
        if entry.category == "Sample Rate Mismatch" then
          print_detail_lines(project_context, entry.details, format_samplerate_mismatch_line)
        else
          print_detail_lines(project_context, entry.details, format_reference_file_line)
        end
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

local function build_consolidate_destination(file_info, project_context, settings)
  local media_root = join_paths(project_context.project_dir, "Media")
  local destination_dir = media_root

  if settings.subfolder_mode == "by_library" then
    destination_dir = join_paths(media_root, guess_library_name(file_info.path))
  elseif settings.subfolder_mode == "by_category" then
    local first_ref = file_info.referenced_by and file_info.referenced_by[1] or nil
    local category = detect_category(first_ref and first_ref.track_name or "")
    destination_dir = join_paths(media_root, sanitize_dirname(category))
  end

  local destination_path = join_paths(destination_dir, file_info.filename)
  if file_exists(destination_path) and path_key(destination_path) ~= path_key(file_info.path) then
    destination_path = make_unique_path(destination_path)
  end

  return destination_path
end

local function consolidate_external_files(external_files, project_context, settings)
  local result = {
    copied = 0,
    copied_size = 0,
    updated_takes = 0,
    failed = 0,
    failures = {},
    destination_root = join_paths(project_context.project_dir, "Media"),
  }

  if #external_files == 0 then
    return result
  end

  if not settings.dry_run then
    ensure_directory(result.destination_root)
    reaper.Undo_BeginBlock()
  end

  for _, file_info in ipairs(external_files) do
    local destination_path = build_consolidate_destination(file_info, project_context, settings)

    if settings.dry_run then
      result.copied = result.copied + 1
      result.copied_size = result.copied_size + file_info.size_bytes
      result.updated_takes = result.updated_takes + #(file_info.referenced_by or {})
      log_line(string.format(
        "  [DRY RUN] Consolidate: %s -> %s",
        file_info.path,
        destination_path
      ))
    else
      local copy_ok, copy_error = copy_file(file_info.path, destination_path)
      if not copy_ok then
        result.failed = result.failed + 1
        result.failures[#result.failures + 1] = {
          source_path = file_info.path,
          destination = destination_path,
          error = copy_error or "Copy failed.",
        }
      else
        result.copied = result.copied + 1
        result.copied_size = result.copied_size + file_info.size_bytes
        log_line(string.format("  Consolidated: %s -> %s", file_info.path, destination_path))

        for _, reference in ipairs(file_info.referenced_by or {}) do
          local take = reference.take
          local take_valid = take ~= nil
          if take_valid and reaper.ValidatePtr2 then
            take_valid = reaper.ValidatePtr2(0, take, "MediaItem_Take*")
          end

          if take_valid then
            local new_source = reaper.PCM_Source_CreateFromFile(destination_path)
            if new_source then
              reaper.SetMediaItemTake_Source(take, new_source)
              result.updated_takes = result.updated_takes + 1
            else
              result.failed = result.failed + 1
              result.failures[#result.failures + 1] = {
                source_path = file_info.path,
                destination = destination_path,
                error = "PCM_Source_CreateFromFile failed.",
              }
            end
          end
        end
      end
    end
  end

  if not settings.dry_run then
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Game Sound Project Archiver - Consolidate External Files", -1)
  end

  return result
end

local function render_manifest_text(manifest)
  local lines = {
    "Project: " .. tostring(manifest.project_name or ""),
    "Created: " .. tostring(manifest.created_date or os.date("%Y-%m-%d %H:%M:%S")),
    "",
    "Contents:",
  }

  for _, entry in ipairs(manifest.contents or {}) do
    local suffix = entry.size and (" (" .. format_size(entry.size) .. ")") or ""
    lines[#lines + 1] = string.format("- [%s] %s%s", tostring(entry.type or "file"), tostring(entry.path or ""), suffix)
  end

  return table.concat(lines, "\n")
end

local function render_archive_manifest_text(manifest)
  local lines = {
    "Project: " .. tostring(manifest.project_name or ""),
    "Archive Date: " .. tostring(manifest.archive_date or os.date("%Y-%m-%d %H:%M:%S")),
    "REAPER Version: " .. tostring(manifest.reaper_version or ""),
    "Tracks: " .. tostring(manifest.total_tracks or 0),
    "Items: " .. tostring(manifest.total_items or 0),
    "Regions: " .. tostring(manifest.total_regions or 0),
    "Copied Source Files: " .. tostring(manifest.source_files or 0),
    "Missing References: " .. tostring(manifest.missing_references or 0),
    "",
    "Contents:",
  }

  for _, entry in ipairs(manifest.contents or {}) do
    local suffix = entry.size and (" (" .. format_size(entry.size) .. ")") or ""
    lines[#lines + 1] = string.format("- [%s] %s%s", tostring(entry.type or "file"), tostring(entry.path or ""), suffix)
  end

  return table.concat(lines, "\n")
end

local function generate_delivery_readme_text(manifest, settings)
  local asset_count = 0
  local total_size = 0
  for _, entry in ipairs(manifest.contents or {}) do
    if entry.type == "asset" then
      asset_count = asset_count + 1
      total_size = total_size + (entry.size or 0)
    end
  end

  local lines = {
    "# " .. tostring(manifest.project_name or "Project") .. " - Sound Asset Delivery",
    "",
    "**Date:** " .. tostring(manifest.created_date or os.date("%Y-%m-%d %H:%M:%S")),
    "**Studio:** " .. tostring(settings.studio_name or DEFAULTS.studio_name),
    "**Contact:** " .. tostring(settings.contact_email or ""),
    "",
    "## Contents",
    "",
    string.format("- **Sound Assets:** %d file(s) (%s)", asset_count, format_size(total_size)),
  }

  if settings.include_worksheets then
    lines[#lines + 1] = "- **Documentation:** Worksheets or asset lists"
  end
  if settings.include_recipes then
    lines[#lines + 1] = "- **Recipes:** Sound design notes"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Folder Structure"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "```"
  lines[#lines + 1] = tostring(manifest.project_name or "Project") .. "/"
  lines[#lines + 1] = "|-- Assets/"
  lines[#lines + 1] = "|-- Documentation/"
  lines[#lines + 1] = "|-- Recipes/"
  lines[#lines + 1] = "|-- MANIFEST.txt"
  lines[#lines + 1] = "|-- README.md"
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Generated by Game Sound Project Archiver v1.0"

  return table.concat(lines, "\n")
end

local function copy_files_into_package(file_list, package_root, destination_prefix, manifest, entry_type, dry_run, filter_fn)
  local result = {
    copied = 0,
    copied_size = 0,
    failed = 0,
    failures = {},
  }

  for _, file in ipairs(file_list or {}) do
    if not filter_fn or filter_fn(file) then
      local relative_path = destination_prefix ~= "" and join_paths(destination_prefix, file.relative_path) or file.relative_path
      local destination_path = join_paths(package_root, relative_path)

      if dry_run then
        result.copied = result.copied + 1
        result.copied_size = result.copied_size + file.size_bytes
        manifest.contents[#manifest.contents + 1] = {
          type = entry_type,
          path = relative_path,
          size = file.size_bytes,
        }
      else
        local copy_ok, copy_error = copy_file(file.path, destination_path)
        if copy_ok then
          result.copied = result.copied + 1
          result.copied_size = result.copied_size + file.size_bytes
          manifest.contents[#manifest.contents + 1] = {
            type = entry_type,
            path = relative_path,
            size = file.size_bytes,
          }
        else
          result.failed = result.failed + 1
          result.failures[#result.failures + 1] = {
            source_path = file.path,
            destination = destination_path,
            error = copy_error or "Copy failed.",
          }
        end
      end

    end
  end

  return result
end

local function create_delivery_package(project_context, settings)
  local output_dir = resolve_package_output_dir(project_context, settings)
  local manifest = {
    project_name = project_context.project_name,
    created_date = os.date("%Y-%m-%d %H:%M:%S"),
    contents = {},
  }

  local result = {
    output_dir = output_dir,
    manifest = manifest,
    copied = 0,
    copied_size = 0,
    failed = 0,
    failures = {},
  }

  if not settings.dry_run then
    ensure_directory(output_dir)
  end

  if settings.include_renders then
    local render_files = collect_directory_files(join_paths(project_context.project_dir, "Renders"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(render_files, output_dir, "Assets", manifest, "asset", settings.dry_run, function(file)
      return file.is_media and not file.is_peak
    end)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  if settings.include_worksheets then
    local worksheet_files = collect_directory_files(join_paths(project_context.project_dir, "Worksheets"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(worksheet_files, output_dir, "Documentation", manifest, "documentation", settings.dry_run)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  if settings.include_recipes then
    local recipe_files = collect_directory_files(join_paths(project_context.project_dir, "Recipes"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(recipe_files, output_dir, "Recipes", manifest, "recipe", settings.dry_run)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  if settings.generate_readme then
    manifest.contents[#manifest.contents + 1] = {
      type = "readme",
      path = "README.md",
      size = 0,
    }
  end
  manifest.contents[#manifest.contents + 1] = {
    type = "manifest",
    path = "MANIFEST.txt",
    size = 0,
  }

  if not settings.dry_run then
    local manifest_ok, manifest_error = write_text_file(join_paths(output_dir, "MANIFEST.txt"), render_manifest_text(manifest))
    if not manifest_ok then
      result.failed = result.failed + 1
      result.failures[#result.failures + 1] = {
        source_path = "(generated manifest)",
        destination = join_paths(output_dir, "MANIFEST.txt"),
        error = manifest_error,
      }
    end

    if settings.generate_readme then
      local readme_ok, readme_error = write_text_file(join_paths(output_dir, "README.md"), generate_delivery_readme_text(manifest, settings))
      if not readme_ok then
        result.failed = result.failed + 1
        result.failures[#result.failures + 1] = {
          source_path = "(generated readme)",
          destination = join_paths(output_dir, "README.md"),
          error = readme_error,
        }
      end
    end
  end

  return result
end

local function create_archive_package(project_context, scan_result, settings)
  local output_dir = resolve_package_output_dir(project_context, settings)
  local manifest = {
    project_name = project_context.project_name,
    archive_date = os.date("%Y-%m-%d %H:%M:%S"),
    source_files = 0,
    total_tracks = reaper.CountTracks(0),
    total_items = reaper.CountMediaItems(0),
    total_regions = ({ reaper.CountProjectMarkers(0) })[2],
    missing_references = #scan_result.missing_files,
    reaper_version = reaper.GetAppVersion(),
    contents = {},
  }

  local result = {
    output_dir = output_dir,
    manifest = manifest,
    copied = 0,
    copied_size = 0,
    failed = 0,
    failures = {},
  }

  if not settings.dry_run then
    ensure_directory(output_dir)
  end

  local project_copy_relative = project_context.project_filename
  if settings.dry_run then
    manifest.contents[#manifest.contents + 1] = {
      type = "project",
      path = project_copy_relative,
      size = get_file_size(project_context.project_file),
    }
    result.copied = result.copied + 1
    result.copied_size = result.copied_size + get_file_size(project_context.project_file)
  else
    local project_copy_ok, project_copy_error = copy_file(project_context.project_file, join_paths(output_dir, project_copy_relative))
    if project_copy_ok then
      manifest.contents[#manifest.contents + 1] = {
        type = "project",
        path = project_copy_relative,
        size = get_file_size(project_context.project_file),
      }
      result.copied = result.copied + 1
      result.copied_size = result.copied_size + get_file_size(project_context.project_file)
    else
      result.failed = result.failed + 1
      result.failures[#result.failures + 1] = {
        source_path = project_context.project_file,
        destination = join_paths(output_dir, project_copy_relative),
        error = project_copy_error or "Copy failed.",
      }
    end
  end

  local referenced_list = {}
  for _, info in pairs(scan_result.referenced_files or {}) do
    if info.exists then
      referenced_list[#referenced_list + 1] = info
    end
  end
  table.sort(referenced_list, function(left, right)
    return path_key(left.path) < path_key(right.path)
  end)

  for _, info in ipairs(referenced_list) do
    local relative_path = ""
    if info.is_internal then
      relative_path = join_paths("Media/Internal", relative_to(project_context.project_dir, info.path) or info.filename)
    else
      local external_dir = "External"
      if settings.subfolder_mode == "by_library" then
        external_dir = guess_library_name(info.path)
      elseif settings.subfolder_mode == "by_category" then
        local first_ref = info.referenced_by and info.referenced_by[1] or nil
        external_dir = detect_category(first_ref and first_ref.track_name or "")
      end
      relative_path = join_paths(join_paths("Media/External", sanitize_dirname(external_dir)), info.filename)
    end

    local destination_path = join_paths(output_dir, relative_path)
    if file_exists(destination_path) and path_key(destination_path) ~= path_key(info.path) then
      destination_path = make_unique_path(destination_path)
      relative_path = relative_to(output_dir, destination_path) or relative_path
    end

    if settings.dry_run then
      manifest.contents[#manifest.contents + 1] = {
        type = "source",
        path = relative_path,
        size = info.size_bytes,
      }
      manifest.source_files = manifest.source_files + 1
      result.copied = result.copied + 1
      result.copied_size = result.copied_size + info.size_bytes
    else
      local copy_ok, copy_error = copy_file(info.path, destination_path)
      if copy_ok then
        manifest.contents[#manifest.contents + 1] = {
          type = "source",
          path = relative_path,
          size = info.size_bytes,
        }
        manifest.source_files = manifest.source_files + 1
        result.copied = result.copied + 1
        result.copied_size = result.copied_size + info.size_bytes
      else
        result.failed = result.failed + 1
        result.failures[#result.failures + 1] = {
          source_path = info.path,
          destination = destination_path,
          error = copy_error or "Copy failed.",
        }
      end
    end
  end

  if settings.include_renders then
    local render_files = collect_directory_files(join_paths(project_context.project_dir, "Renders"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(render_files, output_dir, "Renders", manifest, "render", settings.dry_run, function(file)
      return not file.is_peak
    end)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  if settings.include_worksheets then
    local worksheet_files = collect_directory_files(join_paths(project_context.project_dir, "Worksheets"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(worksheet_files, output_dir, "Worksheets", manifest, "worksheet", settings.dry_run)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  if settings.include_recipes then
    local recipe_files = collect_directory_files(join_paths(project_context.project_dir, "Recipes"), settings.max_scan_depth)
    local copy_result = copy_files_into_package(recipe_files, output_dir, "Recipes", manifest, "recipe", settings.dry_run)
    result.copied = result.copied + copy_result.copied
    result.copied_size = result.copied_size + copy_result.copied_size
    result.failed = result.failed + copy_result.failed
    for _, failure in ipairs(copy_result.failures) do
      result.failures[#result.failures + 1] = failure
    end
  end

  manifest.contents[#manifest.contents + 1] = {
    type = "manifest",
    path = "ARCHIVE_MANIFEST.txt",
    size = 0,
  }

  if not settings.dry_run then
    local manifest_ok, manifest_error = write_text_file(join_paths(output_dir, "ARCHIVE_MANIFEST.txt"), render_archive_manifest_text(manifest))
    if not manifest_ok then
      result.failed = result.failed + 1
      result.failures[#result.failures + 1] = {
        source_path = "(generated archive manifest)",
        destination = join_paths(output_dir, "ARCHIVE_MANIFEST.txt"),
        error = manifest_error,
      }
    end
  end

  return result
end

local function copy_settings(base)
  local copy = {}
  for key, default_value in pairs(DEFAULTS) do
    if base and base[key] ~= nil then
      copy[key] = base[key]
    else
      copy[key] = default_value
    end
  end
  return copy
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

local function draw_button(ui, id, label, rect_x, rect_y, rect_w, rect_h, enabled)
  local is_enabled = enabled ~= false
  local hovered = is_enabled and point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)

  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
  end

  local clicked = is_enabled and hovered and ui.mouse_released and ui.active_mouse_id == id
  local fill = is_enabled and (hovered and 68 or 48) or 34
  local border = is_enabled and (hovered and 126 or 84) or 50

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, fill, fill, fill, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, border, border, border, 255)
  draw_text(label, rect_x + 10, rect_y + 7, is_enabled and 240 or 128, is_enabled and 240 or 128, is_enabled and 240 or 128, 255, 1, "Segoe UI", 14)

  return clicked
end

local function draw_checkbox(ui, id, label, rect_x, rect_y, value)
  local box_size = 18
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, box_size + 8 + 280, box_size)

  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
  end

  local changed = hovered and ui.mouse_released and ui.active_mouse_id == id

  draw_rect(rect_x, rect_y, box_size, box_size, true, 35, 35, 35, 255)
  draw_rect(rect_x, rect_y, box_size, box_size, false, 100, 100, 100, 255)
  if value then
    draw_rect(rect_x + 4, rect_y + 4, box_size - 8, box_size - 8, true, 104, 182, 118, 255)
  end
  draw_text(label, rect_x + box_size + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 14)

  if changed then
    return not value
  end
  return value
end

local function draw_value_button(ui, id, label, value, rect_x, rect_y, rect_w, rect_h)
  draw_text(label, rect_x, rect_y - 18, 205, 205, 205, 255, 1, "Segoe UI", 12)
  local display = truncate_text(trim_string(value) ~= "" and tostring(value) or "(empty)", math.max(12, math.floor(rect_w / 8)))
  return draw_button(ui, id, display, rect_x, rect_y, rect_w, rect_h, true)
end

local function draw_section_title(label, x, y)
  draw_text(label, x, y, 240, 240, 240, 255, 1, "Segoe UI Semibold", 16)
end

local function draw_summary_card(title, line_a, line_b, rect_x, rect_y, rect_w, rect_h, accent_r, accent_g, accent_b)
  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 28, 28, 30, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, 58, 58, 64, 255)
  draw_rect(rect_x, rect_y, 5, rect_h, true, accent_r, accent_g, accent_b, 255)
  draw_text(title, rect_x + 14, rect_y + 10, 242, 242, 242, 255, 1, "Segoe UI Semibold", 14)
  draw_text(line_a, rect_x + 14, rect_y + 34, 214, 214, 214, 255, 1, "Segoe UI", 13)
  draw_text(line_b, rect_x + 14, rect_y + 54, 164, 184, 204, 255, 1, "Segoe UI", 12)
end

local function prompt_text_value(title, label, current_value)
  local ok, value = reaper.GetUserInputs(title, 1, label, tostring(current_value or ""))
  if not ok then
    return nil
  end
  return value
end

local function build_settings_from_ui(ui)
  local settings = copy_settings(DEFAULTS)
  settings.mode = "health"
  settings.dry_run = ui.dry_run
  settings.clean_unused_media = ui.clean_unused_media
  settings.clean_peak_files = ui.clean_peak_files
  settings.move_backup_files = ui.move_backup_files
  settings.keep_backups = ui.keep_backups
  settings.check_samplerate = ui.check_samplerate
  settings.report_empty_tracks = ui.report_empty_tracks
  settings.report_muted = ui.report_muted
  settings.remove_empty_tracks = ui.remove_empty_tracks
  settings.remove_muted_tracks = ui.remove_muted_tracks
  settings.subfolder_mode = ui.subfolder_mode
  settings.package_mode = ui.package_mode
  settings.include_renders = ui.include_renders
  settings.include_worksheets = ui.include_worksheets
  settings.include_recipes = ui.include_recipes
  settings.generate_readme = ui.generate_readme
  settings.studio_name = ui.studio_name
  settings.contact_email = ui.contact_email
  settings.package_output_path = ui.package_output_path
  settings.max_scan_depth = ui.max_scan_depth
  return settings
end

local function build_ui_signature(ui)
  return table.concat({
    bool_to_string(ui.dry_run),
    bool_to_string(ui.clean_unused_media),
    bool_to_string(ui.clean_peak_files),
    bool_to_string(ui.move_backup_files),
    tostring(ui.keep_backups),
    bool_to_string(ui.check_samplerate),
    bool_to_string(ui.report_empty_tracks),
    bool_to_string(ui.report_muted),
    bool_to_string(ui.remove_empty_tracks),
    bool_to_string(ui.remove_muted_tracks),
    tostring(ui.subfolder_mode),
    tostring(ui.package_mode),
    bool_to_string(ui.include_renders),
    bool_to_string(ui.include_worksheets),
    bool_to_string(ui.include_recipes),
    bool_to_string(ui.generate_readme),
    tostring(ui.studio_name or ""),
    tostring(ui.contact_email or ""),
    tostring(ui.package_output_path or ""),
  }, "|")
end

local function persist_ui_settings(ui)
  save_settings(build_settings_from_ui(ui))
  ui.last_persist_signature = build_ui_signature(ui)
end

local function persist_ui_settings_if_changed(ui)
  local signature = build_ui_signature(ui)
  if signature ~= ui.last_persist_signature then
    persist_ui_settings(ui)
  end
end

local function refresh_ui_scan(ui, project_context)
  local settings = build_settings_from_ui(ui)
  local scan_result = analyze_project(project_context, settings)
  local report = run_health_check(project_context, scan_result, settings)
  ui.last_scan_result = scan_result
  ui.last_report = report
  set_status(ui, string.format(
    "Scan complete: %d missing, %d external, %d unused, %s saveable.",
    #scan_result.missing_files,
    #scan_result.external_files,
    #scan_result.analysis.unused_media,
    format_size(report.potential_savings)
  ))
  return scan_result, report
end

local function log_failures(header, failures)
  if not failures or #failures == 0 then
    return
  end

  log_line("")
  log_line(header)
  for _, failure in ipairs(failures) do
    log_line(string.format(
      "  - %s -> %s (%s)",
      tostring(failure.source_path or ""),
      tostring(failure.destination or ""),
      tostring(failure.error or "")
    ))
  end
end

local function run_health_action(ui, project_context)
  clear_console()
  local scan_result, report = refresh_ui_scan(ui, project_context)
  print_health_report(project_context, report)
  set_status(ui, string.format(
    "Health check complete: %d error(s), %d warning(s), %d sample-rate mismatch(es), %s potential savings.",
    report.issue_count,
    report.warning_count,
    #(scan_result.sample_rate_mismatches or {}),
    format_size(report.potential_savings)
  ))
  return scan_result, report
end

local function run_cleanup_action(ui, project_context, dry_run_override)
  local settings = build_settings_from_ui(ui)
  if dry_run_override ~= nil then
    settings.dry_run = dry_run_override
  end

  clear_console()
  local scan_result, report = refresh_ui_scan(ui, project_context)
  print_health_report(project_context, report)
  local cleanup_plan = build_cleanup_plan(project_context, scan_result, settings)
  local track_plan = build_track_cleanup_plan(settings)
  print_cleanup_preview(cleanup_plan, settings)
  if track_plan.total_count > 0 then
    print_track_cleanup_preview(track_plan, settings)
  end

  if cleanup_plan.total_count == 0 and track_plan.total_count == 0 then
    set_status(ui, "No files or tracks matched the selected cleanup rules.")
    return cleanup_plan, nil, track_plan, nil
  end

  if cleanup_plan.total_count > 0 and not settings.dry_run and not confirm_cleanup(cleanup_plan) then
    set_status(ui, "File cleanup cancelled.")
    return cleanup_plan, nil, track_plan, nil
  end

  local cleanup_result = {
    moved = 0,
    moved_size = 0,
    failed = 0,
    failures = {},
  }
  if cleanup_plan.total_count > 0 then
    log_line("")
    log_line("  CLEANUP EXECUTION")
    cleanup_result = execute_cleanup_plan(project_context, cleanup_plan, settings)
  end
  log_failures("  CLEANUP FAILURES", cleanup_result.failures)

  local track_cleanup_result = {
    removed = 0,
    failed = 0,
    failures = {},
  }
  if track_plan.total_count > 0 then
    if not settings.dry_run and not confirm_track_cleanup(track_plan) then
      set_status(ui, "Track cleanup cancelled.")
      return cleanup_plan, cleanup_result, track_plan, nil
    end

    if settings.dry_run then
      log_line("")
      log_line("  [DRY RUN] Track cleanup would remove " .. tostring(track_plan.total_count) .. " track(s).")
    else
      log_line("")
      log_line("  TRACK CLEANUP EXECUTION")
      track_cleanup_result = execute_track_cleanup_plan(track_plan, settings)
      log_failures("  TRACK CLEANUP FAILURES", track_cleanup_result.failures)
    end
  end

  if not settings.dry_run and (cleanup_plan.total_count > 0 or track_plan.total_count > 0) then
    refresh_ui_scan(ui, project_context)
  end

  set_status(ui, settings.dry_run
    and string.format(
      "Cleanup dry run: %d file move(s), %d track removal(s), %s.",
      cleanup_plan.total_count,
      track_plan.total_count,
      format_size(cleanup_plan.total_size)
    )
    or string.format(
      "Cleanup complete: %d file(s) moved, %d track(s) removed, %d failure(s).",
      cleanup_result.moved,
      track_cleanup_result.removed,
      cleanup_result.failed + track_cleanup_result.failed
    ))

  return cleanup_plan, cleanup_result, track_plan, track_cleanup_result
end

local function run_standardize_action(ui, project_context, dry_run_override)
  local settings = build_settings_from_ui(ui)
  if dry_run_override ~= nil then
    settings.dry_run = dry_run_override
  end

  clear_console()
  log_line("STANDARDIZE FOLDERS")
  local created_count = standardize_folder_structure(project_context.project_dir, settings.dry_run)
  set_status(ui, settings.dry_run
    and string.format("Folder structure dry run: %d folder(s) planned.", created_count)
    or string.format("Folder structure ensured: %d folder(s).", created_count))
  return created_count
end

local function run_consolidate_action(ui, project_context, dry_run_override)
  local settings = build_settings_from_ui(ui)
  if dry_run_override ~= nil then
    settings.dry_run = dry_run_override
  end

  clear_console()
  local scan_result, report = refresh_ui_scan(ui, project_context)
  print_health_report(project_context, report)

  if #scan_result.external_files == 0 then
    set_status(ui, "No external references to consolidate.")
    return nil
  end

  if not settings.dry_run then
    local total_takes = 0
    for _, info in ipairs(scan_result.external_files) do
      total_takes = total_takes + #(info.referenced_by or {})
    end

    local confirmed = reaper.ShowMessageBox(
      string.format(
        "Consolidate %d external file(s) and relink %d take(s) into the project Media folder?",
        #scan_result.external_files,
        total_takes
      ),
      SCRIPT_TITLE,
      4
    )
    if confirmed ~= 6 then
      set_status(ui, "Consolidate cancelled.")
      return nil
    end
  end

  log_line("")
  log_line("  CONSOLIDATE")
  local result = consolidate_external_files(scan_result.external_files, project_context, settings)
  log_failures("  CONSOLIDATE FAILURES", result.failures)

  if not settings.dry_run then
    refresh_ui_scan(ui, project_context)
  end

  set_status(ui, settings.dry_run
    and string.format("Consolidate dry run: %d external file(s), %d take(s).", result.copied, result.updated_takes)
    or string.format("Consolidate complete: %d file(s) copied, %d take(s) relinked.", result.copied, result.updated_takes))
  return result
end

local function run_package_action(ui, project_context, dry_run_override)
  local settings = build_settings_from_ui(ui)
  if dry_run_override ~= nil then
    settings.dry_run = dry_run_override
  end

  clear_console()
  local scan_result = ui.last_scan_result
  if not scan_result then
    scan_result = refresh_ui_scan(ui, project_context)
  end

  log_line(settings.package_mode == "archive" and "ARCHIVE PACKAGE" or "DELIVERY PACKAGE")
  local result = nil
  if settings.package_mode == "archive" then
    result = create_archive_package(project_context, ui.last_scan_result or scan_result, settings)
  else
    result = create_delivery_package(project_context, settings)
  end

  log_line("  Output: " .. result.output_dir)
  log_line(string.format("  Copied: %d file(s), %s", result.copied, format_size(result.copied_size)))
  log_failures("  PACKAGE FAILURES", result.failures)

  set_status(ui, settings.dry_run
    and string.format("Package dry run: %s -> %s", PACKAGE_MODE_LABELS[settings.package_mode] or settings.package_mode, result.output_dir)
    or string.format("Package created: %s", result.output_dir))

  return result
end

local function run_execute_all_action(ui, project_context, dry_run_override)
  run_standardize_action(ui, project_context, dry_run_override)
  run_health_action(ui, project_context)
  run_cleanup_action(ui, project_context, dry_run_override)
  run_consolidate_action(ui, project_context, dry_run_override)
  return run_package_action(ui, project_context, dry_run_override)
end

local function build_completion_message(report, plan, result, settings, track_result)
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
      "Dry run complete.\n\nPlanned moves: %d\nPlanned track removals: %d\nPotential savings: %s\nCleanup root: %s",
      plan.total_count,
      track_result and (track_result.total_count or 0) or 0,
      format_size(plan.total_size),
      plan.quarantine_root
    )
  end

  return string.format(
    "Cleanup complete.\n\nMoved: %d file(s)\nTracks removed: %d\nFreed from active project tree: %s\nFailures: %d\nCleanup root: %s",
    result.moved,
    track_result and (track_result.removed or 0) or 0,
    format_size(result.moved_size),
    result.failed + (track_result and (track_result.failed or 0) or 0),
    plan.quarantine_root
  )
end

local function show_subfolder_mode_menu(ui, rect_x, rect_y)
  local items = {}
  local mapping = {
    { key = "flat", label = "Flat" },
    { key = "by_library", label = "By Library" },
    { key = "by_category", label = "By Category" },
  }

  for _, item in ipairs(mapping) do
    items[#items + 1] = (ui.subfolder_mode == item.key and "!" or "") .. item.label
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection > 0 and mapping[selection] then
    ui.subfolder_mode = mapping[selection].key
    persist_ui_settings(ui)
    set_status(ui, "Consolidate subfolder mode: " .. mapping[selection].label)
  end
end

local function show_package_mode_menu(ui, rect_x, rect_y)
  local items = {
    (ui.package_mode == "delivery" and "!" or "") .. "Delivery",
    (ui.package_mode == "archive" and "!" or "") .. "Archive",
  }

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection == 1 then
    ui.package_mode = "delivery"
  elseif selection == 2 then
    ui.package_mode = "archive"
  end

  if selection > 0 then
    persist_ui_settings(ui)
    set_status(ui, "Package mode: " .. (PACKAGE_MODE_LABELS[ui.package_mode] or ui.package_mode))
  end
end

local function init_ui_state(current_settings)
  return {
    width = 1180,
    height = 820,
    mouse_x = 0,
    mouse_y = 0,
    mouse_down = false,
    prev_mouse_down = false,
    mouse_pressed = false,
    mouse_released = false,
    active_mouse_id = nil,
    status_message = "Ready.",
    dry_run = current_settings.dry_run,
    clean_unused_media = current_settings.clean_unused_media,
    clean_peak_files = current_settings.clean_peak_files,
    move_backup_files = current_settings.move_backup_files,
    keep_backups = current_settings.keep_backups,
    check_samplerate = current_settings.check_samplerate,
    report_empty_tracks = current_settings.report_empty_tracks,
    report_muted = current_settings.report_muted,
    remove_empty_tracks = current_settings.remove_empty_tracks,
    remove_muted_tracks = current_settings.remove_muted_tracks,
    subfolder_mode = current_settings.subfolder_mode,
    package_mode = current_settings.package_mode,
    include_renders = current_settings.include_renders,
    include_worksheets = current_settings.include_worksheets,
    include_recipes = current_settings.include_recipes,
    generate_readme = current_settings.generate_readme,
    studio_name = current_settings.studio_name,
    contact_email = current_settings.contact_email,
    package_output_path = current_settings.package_output_path,
    max_scan_depth = current_settings.max_scan_depth,
    last_scan_result = nil,
    last_report = nil,
    last_persist_signature = "",
  }
end

local function run_ui_action(ui, action)
  local ok, runtime_error = xpcall(action, function(message)
    if debug and debug.traceback then
      return debug.traceback(message, 2)
    end
    return tostring(message)
  end)

  if not ok then
    set_status(ui, "Action failed. See error dialog.")
    show_error(runtime_error)
  end
end

local function run_gfx_ui(current_settings, project_context)
  if not gfx or not gfx.init then
    return false
  end

  local ui = init_ui_state(current_settings)
  ui.last_persist_signature = build_ui_signature(ui)
  gfx.init(SCRIPT_TITLE, ui.width, ui.height, 0)
  if (gfx.w or 0) <= 0 then
    return false
  end

  run_ui_action(ui, function()
    refresh_ui_scan(ui, project_context)
  end)

  local function loop()
    local key = gfx.getchar()
    if key < 0 then
      persist_ui_settings(ui)
      gfx.quit()
      return
    end

    ui.mouse_x = gfx.mouse_x
    ui.mouse_y = gfx.mouse_y
    ui.mouse_down = ((gfx.mouse_cap or 0) % 2) == 1
    ui.mouse_pressed = ui.mouse_down and not ui.prev_mouse_down
    ui.mouse_released = (not ui.mouse_down) and ui.prev_mouse_down

    draw_rect(0, 0, ui.width, ui.height, true, 16, 18, 22, 255)
    draw_text(SCRIPT_TITLE, 24, 18, 245, 245, 245, 255, 1, "Segoe UI Semibold", 22)
    draw_text(truncate_text(project_context.project_filename .. " | " .. project_context.project_dir, 120), 24, 48, 166, 188, 206, 255, 1, "Consolas", 12)
    draw_text("Phase 3: sample-rate diagnostics, track cleanup, packaging, and folder standardization", 24, 66, 150, 170, 185, 255, 1, "Segoe UI", 13)

    local missing_count = ui.last_scan_result and #ui.last_scan_result.missing_files or 0
    local external_count = ui.last_scan_result and #ui.last_scan_result.external_files or 0
    local unused_count = ui.last_scan_result and #ui.last_scan_result.analysis.unused_media or 0
    local savings_text = ui.last_report and format_size(ui.last_report.potential_savings) or "n/a"
    local score_label = ui.last_report and ui.last_report.score or "Not Scanned"
    local issue_text = ui.last_report and string.format("%d error(s), %d warning(s)", ui.last_report.issue_count, ui.last_report.warning_count) or "Press Refresh Scan"

    draw_summary_card("Health Score", score_label, issue_text, 20, 96, 270, 82, 191, 147, 80)
    draw_summary_card("Missing Files", tostring(missing_count), "Referenced but not found", 304, 96, 200, 82, 184, 92, 92)
    draw_summary_card("External Refs", tostring(external_count), "Outside project folder", 518, 96, 200, 82, 100, 152, 198)
    draw_summary_card("Unused Media", tostring(unused_count), "Potential savings: " .. savings_text, 732, 96, 220, 82, 104, 182, 118)
    draw_summary_card("Package Mode", PACKAGE_MODE_LABELS[ui.package_mode] or ui.package_mode, "Dry Run: " .. bool_to_string(ui.dry_run), 966, 96, 194, 82, 152, 120, 188)

    draw_rect(20, 196, 540, 520, true, 24, 24, 26, 255)
    draw_rect(20, 196, 540, 520, false, 58, 58, 62, 255)
    draw_rect(580, 196, 580, 520, true, 24, 24, 26, 255)
    draw_rect(580, 196, 580, 520, false, 58, 58, 62, 255)

    draw_section_title("Health / Cleanup", 40, 216)
    if draw_button(ui, "refresh_scan", "Refresh Scan", 40, 242, 120, 32, true) then
      run_ui_action(ui, function()
        run_health_action(ui, project_context)
      end)
    end
    if draw_button(ui, "run_health", "Run Health Check", 170, 242, 150, 32, true) then
      run_ui_action(ui, function()
        run_health_action(ui, project_context)
      end)
    end
    ui.dry_run = draw_checkbox(ui, "dry_run", "Dry Run", 340, 248, ui.dry_run)
    ui.check_samplerate = draw_checkbox(ui, "check_samplerate", "Check Sample Rate", 40, 278, ui.check_samplerate)
    ui.report_empty_tracks = draw_checkbox(ui, "report_empty_tracks", "Report Empty Tracks", 40, 308, ui.report_empty_tracks)
    ui.report_muted = draw_checkbox(ui, "report_muted", "Report Muted Elements", 40, 338, ui.report_muted)
    ui.clean_unused_media = draw_checkbox(ui, "clean_unused_media", "Move Unused Media", 40, 384, ui.clean_unused_media)
    ui.clean_peak_files = draw_checkbox(ui, "clean_peak_files", "Move Orphan Peak Files", 40, 414, ui.clean_peak_files)
    ui.move_backup_files = draw_checkbox(ui, "move_backup_files", "Move Backup Files", 40, 444, ui.move_backup_files)
    ui.remove_empty_tracks = draw_checkbox(ui, "remove_empty_tracks", "Remove Empty Tracks", 40, 474, ui.remove_empty_tracks)
    ui.remove_muted_tracks = draw_checkbox(ui, "remove_muted_tracks", "Remove Muted Tracks", 40, 504, ui.remove_muted_tracks)

    if draw_value_button(ui, "keep_backups", "Keep Latest Backups", tostring(ui.keep_backups), 40, 552, 210, 30) then
      local value = prompt_text_value(SCRIPT_TITLE, "Keep Latest Backups", tostring(ui.keep_backups))
      if value then
        ui.keep_backups = math.max(0, math.floor(tonumber(value) or ui.keep_backups))
        persist_ui_settings(ui)
      end
    end

    if draw_button(ui, "run_cleanup", "Clean Up", 40, 598, 120, 34, true) then
      run_ui_action(ui, function()
        run_cleanup_action(ui, project_context, nil)
      end)
    end
    if draw_button(ui, "run_cleanup_dry", "Dry Run Cleanup", 170, 598, 150, 34, true) then
      run_ui_action(ui, function()
        run_cleanup_action(ui, project_context, true)
      end)
    end
    if draw_button(ui, "run_standardize", "Standardize Folders", 40, 644, 170, 34, true) then
      run_ui_action(ui, function()
        run_standardize_action(ui, project_context, nil)
      end)
    end
    if draw_button(ui, "run_standardize_dry", "Dry Run Standardize", 220, 644, 170, 34, true) then
      run_ui_action(ui, function()
        run_standardize_action(ui, project_context, true)
      end)
    end

    draw_text("Cleanup root: " .. project_context.quarantine_root, 40, 690, 166, 188, 206, 255, 1, "Consolas", 12)
    draw_text("Safety: files move to _unused_media; track deletes are undoable in REAPER.", 40, 708, 166, 188, 206, 255, 1, "Segoe UI", 12)

    draw_section_title("Consolidate / Package", 600, 216)
    draw_text(string.format("External refs: %d", external_count), 600, 244, 216, 216, 216, 255, 1, "Segoe UI", 13)
    if draw_button(ui, "subfolder_mode", SUBFOLDER_MODE_LABELS[ui.subfolder_mode] or ui.subfolder_mode, 600, 268, 150, 32, true) then
      show_subfolder_mode_menu(ui, 600, 300)
    end
    if draw_button(ui, "run_consolidate", "Consolidate", 760, 268, 120, 32, true) then
      run_ui_action(ui, function()
        run_consolidate_action(ui, project_context, nil)
      end)
    end
    if draw_button(ui, "run_consolidate_dry", "Dry Run", 890, 268, 90, 32, true) then
      run_ui_action(ui, function()
        run_consolidate_action(ui, project_context, true)
      end)
    end

    if draw_button(ui, "package_mode", PACKAGE_MODE_LABELS[ui.package_mode] or ui.package_mode, 600, 338, 150, 32, true) then
      show_package_mode_menu(ui, 600, 370)
    end
    ui.include_renders = draw_checkbox(ui, "include_renders", "Include Renders", 600, 392, ui.include_renders)
    ui.include_worksheets = draw_checkbox(ui, "include_worksheets", "Include Worksheets", 600, 422, ui.include_worksheets)
    ui.include_recipes = draw_checkbox(ui, "include_recipes", "Include Recipes", 600, 452, ui.include_recipes)
    ui.generate_readme = draw_checkbox(ui, "generate_readme", "Generate README", 600, 482, ui.generate_readme)

    if draw_value_button(ui, "studio_name", "Studio Name", ui.studio_name, 600, 528, 250, 30) then
      local value = prompt_text_value(SCRIPT_TITLE, "Studio Name", ui.studio_name)
      if value ~= nil then
        ui.studio_name = trim_string(value)
        persist_ui_settings(ui)
      end
    end
    if draw_value_button(ui, "contact_email", "Contact Email", ui.contact_email, 870, 528, 250, 30) then
      local value = prompt_text_value(SCRIPT_TITLE, "Contact Email", ui.contact_email)
      if value ~= nil then
        ui.contact_email = trim_string(value)
        persist_ui_settings(ui)
      end
    end
    if draw_value_button(ui, "package_output_path", "Output Path (empty = auto)", ui.package_output_path, 600, 584, 520, 30) then
      local value = prompt_text_value(SCRIPT_TITLE, "Output Path (empty = auto)", ui.package_output_path)
      if value ~= nil then
        ui.package_output_path = trim_string(value)
        persist_ui_settings(ui)
      end
    end
    if draw_button(ui, "output_auto", "Use Auto Output", 600, 626, 160, 32, true) then
      ui.package_output_path = ""
      persist_ui_settings(ui)
      set_status(ui, "Package output path reset to auto.")
    end
    if draw_button(ui, "run_package", "Create Package", 780, 626, 140, 32, true) then
      run_ui_action(ui, function()
        run_package_action(ui, project_context, nil)
      end)
    end
    if draw_button(ui, "run_package_dry", "Dry Run Package", 930, 626, 150, 32, true) then
      run_ui_action(ui, function()
        run_package_action(ui, project_context, true)
      end)
    end

    if draw_button(ui, "run_all_dry", "Dry Run All", 20, 744, 140, 36, true) then
      run_ui_action(ui, function()
        run_execute_all_action(ui, project_context, true)
      end)
    end
    if draw_button(ui, "run_all", "Execute All", 170, 744, 140, 36, true) then
      run_ui_action(ui, function()
        run_execute_all_action(ui, project_context, false)
      end)
    end
    if draw_button(ui, "close", "Close", 1080, 744, 80, 36, true) then
      persist_ui_settings(ui)
      gfx.quit()
      return
    end

    draw_rect(20, 790, 1140, 1, true, 48, 48, 52, 255)
    draw_text(truncate_text(ui.status_message, 150), 24, 798, 176, 205, 220, 255, 1, "Segoe UI", 13)

    persist_ui_settings_if_changed(ui)

    if ui.mouse_released then
      ui.active_mouse_id = nil
    end

    if key == 27 then
      persist_ui_settings(ui)
      gfx.quit()
      return
    end

    ui.prev_mouse_down = ui.mouse_down
    gfx.update()
    reaper.defer(loop)
  end

  loop()
  return true
end

local function run_prompt_flow(project_context)
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
  local report = run_health_check(project_context, scan_result, settings)

  clear_console()
  print_health_report(project_context, report)

  if settings.mode == "health" then
    reaper.ShowMessageBox(build_completion_message(report, nil, nil, settings), SCRIPT_TITLE, 0)
    return
  end

  local cleanup_plan = build_cleanup_plan(project_context, scan_result, settings)
  local track_plan = build_track_cleanup_plan(settings)
  print_cleanup_preview(cleanup_plan, settings)
  if track_plan.total_count > 0 then
    print_track_cleanup_preview(track_plan, settings)
  end

  if cleanup_plan.total_count == 0 and track_plan.total_count == 0 then
    reaper.ShowMessageBox(
      "Health check complete.\n\nNo files or tracks matched the selected cleanup rules.",
      SCRIPT_TITLE,
      0
    )
    return
  end

  if cleanup_plan.total_count > 0 and not settings.dry_run and not confirm_cleanup(cleanup_plan) then
    return
  end

  local cleanup_result = {
    moved = 0,
    moved_size = 0,
    failed = 0,
    failures = {},
  }
  if cleanup_plan.total_count > 0 then
    log_line("")
    log_line("  CLEANUP EXECUTION")
    cleanup_result = execute_cleanup_plan(project_context, cleanup_plan, settings)
  end

  if cleanup_result.failed > 0 then
    log_line("")
    log_line("  FAILURES")
    for _, failure in ipairs(cleanup_result.failures) do
      log_line(string.format("  - %s -> %s (%s)", failure.source_path, failure.destination, failure.error))
    end
  end

  local track_cleanup_result = nil
  if track_plan.total_count > 0 then
    if not settings.dry_run and not confirm_track_cleanup(track_plan) then
      return
    end

    if settings.dry_run then
      log_line("")
      log_line("  [DRY RUN] Track cleanup would remove " .. tostring(track_plan.total_count) .. " track(s).")
    else
      log_line("")
      log_line("  TRACK CLEANUP EXECUTION")
      track_cleanup_result = execute_track_cleanup_plan(track_plan, settings)
      if track_cleanup_result.failed > 0 then
        log_line("")
        log_line("  TRACK CLEANUP FAILURES")
        for _, failure in ipairs(track_cleanup_result.failures) do
          log_line(string.format("  - %s -> %s (%s)", failure.source_path, failure.destination, failure.error))
        end
      end
    end
  end

  reaper.ShowMessageBox(
    build_completion_message(
      report,
      cleanup_plan,
      cleanup_result,
      settings,
      settings.dry_run and track_plan or track_cleanup_result
    ),
    SCRIPT_TITLE,
    0
  )
end

local function main()
  local project_context, context_error = build_project_context()
  if not project_context then
    show_error(context_error)
    return
  end

  local current_settings = load_settings()
  if run_gfx_ui(current_settings, project_context) then
    return
  end

  run_prompt_flow(project_context)
end

main()
