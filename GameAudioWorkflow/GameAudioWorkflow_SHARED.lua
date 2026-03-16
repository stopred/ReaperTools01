-- Game Audio Workflow System v1.0
-- Reaper ReaScript (Lua)
-- Integrated game audio workflow for REAPER.
--
-- Phase 1:
--   FOLDER_ITEMS - automatic folder-item management
--   RENAME       - batch rename dialog
--   RENDER       - folder-item based WAV render
--   TAKES        - smart take navigation and duplication
--
-- Requirements: REAPER v7.0+
-- Recommended: SWS Extension for future phases

local M = {}

local EXT_SECTION = "GameAudioWorkflow"
local FOLDER_ITEM_ROLE = "folder_item"
local DEFAULT_CLUSTER_GAP = 0.01
local DEFAULT_RENDER_ACTION_ID = 42230 -- File: Render project, using the most recent render settings, auto-close render dialog
local EMPTY_ITEM_MIN_LENGTH = 0.001

math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
math.random()
math.random()

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deep_copy(child)
  end
  return copy
end

local function merge_tables(base, override)
  local result = deep_copy(base)
  if type(override) ~= "table" then
    return result
  end

  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = merge_tables(result[key], value)
    else
      result[key] = deep_copy(value)
    end
  end

  return result
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function clamp(value, minimum, maximum)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

local function split_csv(text)
  local values = {}
  local source = tostring(text or "")

  if source == "" then
    return values
  end

  local start_index = 1
  while true do
    local separator_index = source:find(",", start_index, true)
    if not separator_index then
      values[#values + 1] = source:sub(start_index)
      break
    end

    values[#values + 1] = source:sub(start_index, separator_index - 1)
    start_index = separator_index + 1
  end

  return values
end

local function string_to_bool(value, default_value)
  local lowered = trim(value):lower()
  if lowered == "true" or lowered == "1" or lowered == "y" or lowered == "yes" or lowered == "on" then
    return true
  end
  if lowered == "false" or lowered == "0" or lowered == "n" or lowered == "no" or lowered == "off" then
    return false
  end
  return default_value
end

local function serialize_lua(value, indent)
  indent = indent or ""
  local value_type = type(value)

  if value_type == "table" then
    local child_indent = indent .. "  "
    local lines = { "{" }

    local numeric_keys = {}
    local keyed_entries = {}
    for key, child in pairs(value) do
      if type(key) == "number" then
        numeric_keys[#numeric_keys + 1] = key
      else
        keyed_entries[#keyed_entries + 1] = key
      end
    end

    table.sort(numeric_keys)
    table.sort(keyed_entries, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for _, key in ipairs(numeric_keys) do
      lines[#lines + 1] = child_indent .. serialize_lua(value[key], child_indent) .. ","
    end

    for _, key in ipairs(keyed_entries) do
      local serialized_key
      if type(key) == "string" and key:match("^[%a_][%w_]*$") then
        serialized_key = key
      else
        serialized_key = "[" .. serialize_lua(key, child_indent) .. "]"
      end

      lines[#lines + 1] = child_indent .. serialized_key .. " = " .. serialize_lua(value[key], child_indent) .. ","
    end

    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
  end

  if value_type == "string" then
    return string.format("%q", value)
  end

  if value_type == "number" then
    return tostring(value)
  end

  if value_type == "boolean" then
    return value and "true" or "false"
  end

  return "nil"
end

local function deserialize_lua(text)
  local chunk, message = load("return " .. tostring(text or ""))
  if not chunk then
    return nil, message
  end

  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end

  return value
end

local DEFAULT_SETTINGS = {
  folder_items = {
    enabled = true,
    auto_name = true,
    inherit_color = true,
    include_muted_tracks = true,
    include_muted_items = true,
    include_automation = false,
    experimental_auto_grouping = false,
    cluster_gap = DEFAULT_CLUSTER_GAP,
  },
  markers = {
    enabled = false,
    mode = "regions",
    use_item_colors = true,
    variation_markers = false,
    region_render_matrix = false,
  },
  numbering = {
    padding = 2,
    separator = "_",
    start = 1,
  },
  rename = {
    target = "items",
    numbering = true,
    start_number = 1,
    padding = 2,
    separator = "_",
    rename_tracks = false,
    match_mode = false,
    match_pattern = "",
    replace_text = "",
    ucs_enabled = false,
    ucs_category = "",
    presets = {},
    selected_preset = "Default",
  },
  selection = {
    folder_selects_children = true,
    track_follows_item = true,
  },
  editing = {
    reposition_gap = 1.0,
    reposition_presets = { 0.25, 0.5, 1.0 },
    fade_in_ms = 10,
    fade_out_ms = 10,
    overshoot = false,
    trim_mode = "both",
    mousewheel_pitch_step = 1.0,
    mousewheel_volume_step = 1.0,
  },
  render = {
    directory = "Renders",
    file_pattern = "$item",
    format = "wav",
    bit_depth = 24,
    sample_rate = 48000,
    channels = "stereo",
    tail_length_ms = 0,
    preserve_metadata = true,
    sausage_mode = false,
    render_variants = false,
    variants_text = "alt_16|48000|stereo\npreview|24000|mono",
    copy_directories = {},
    copy_rename_pattern = "",
    copy_rename_replace = "",
    presets = {},
    selected_preset = "Default",
  },
  takes = {
    wrap_navigation = true,
    auto_markers = true,
    source_ratio_threshold = 1.5,
    max_markers = 64,
    restart_playback = false,
    ripple_on_duplicate = false,
    disable_take_markers = false,
    search_text = "",
  },
  subproject = {
    tail_length_ms = 500,
    auto_trim = true,
    auto_name = true,
    channels = 2,
    name_track = true,
    use_custom_color = false,
    custom_color = 0,
    update_behavior = "relative",
    master_fx = {},
  },
}

local function get_global_settings_string()
  return reaper.GetExtState(EXT_SECTION, "settings")
end

local function save_global_settings_string(serialized)
  reaper.SetExtState(EXT_SECTION, "settings", serialized or "", true)
end

function M.get_default_settings()
  return deep_copy(DEFAULT_SETTINGS)
end

function M.load_settings()
  local settings = M.get_default_settings()
  local project_ok, project_data = reaper.GetProjExtState(0, EXT_SECTION, "settings")
  if project_ok == 1 and project_data ~= "" then
    local parsed = deserialize_lua(project_data)
    if type(parsed) == "table" then
      return merge_tables(settings, parsed)
    end
  end

  local global_data = get_global_settings_string()
  if global_data ~= "" then
    local parsed = deserialize_lua(global_data)
    if type(parsed) == "table" then
      settings = merge_tables(settings, parsed)
    end
  end

  return settings
end

function M.save_settings(settings, scope)
  local merged = merge_tables(DEFAULT_SETTINGS, settings or {})
  local serialized = serialize_lua(merged)

  if scope == "global" then
    save_global_settings_string(serialized)
  else
    reaper.SetProjExtState(0, EXT_SECTION, "settings", serialized)
  end

  return merged
end

local function get_project_name()
  local _, project_name = reaper.GetProjectName(0, "")
  project_name = trim(project_name)
  if project_name == "" then
    return "Untitled"
  end

  return project_name:gsub("%.[Rr][Pp][Pp]$", "")
end

local function get_project_directory()
  local project_path = select(2, reaper.EnumProjects(-1, ""))
  if project_path and project_path ~= "" then
    local directory = project_path:match("^(.*)[/\\]")
    if directory and directory ~= "" then
      return directory
    end
  end

  local fallback = reaper.GetProjectPath("")
  if fallback and fallback ~= "" then
    return fallback
  end

  return "."
end

local function join_path(base, child)
  if not child or child == "" then
    return base
  end

  if child:match("^%a:[/\\]") or child:match("^[/\\][/\\]?") then
    return child
  end

  local separator = package.config:sub(1, 1)
  if base:sub(-1) == "/" or base:sub(-1) == "\\" then
    return base .. child
  end

  return base .. separator .. child
end

local function sanitize_filename(text)
  local sanitized = tostring(text or ""):gsub("[\\/:*?\"<>|]", "_")
  sanitized = sanitized:gsub("[%c]", "_")
  sanitized = sanitized:gsub("%s+", " ")
  sanitized = trim(sanitized)
  sanitized = sanitized:gsub("%.+$", "")
  if sanitized == "" then
    sanitized = "render"
  end
  return sanitized
end

local function get_item_guid(item)
  local _, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return guid or ""
end

local function get_track_guid(track)
  return reaper.GetTrackGUID(track) or ""
end

local function set_item_ext_string(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, value or "", true)
end

local function get_item_ext_string(item, key)
  local ok, value = reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, "", false)
  if ok then
    return value or ""
  end
  return ""
end

local function set_track_name(track, name)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name or "", true)
end

local function get_track_name(track)
  local _, name = reaper.GetTrackName(track, "")
  name = trim(name)
  if name == "" then
    return "Folder"
  end
  return name
end

local function ensure_item_take(item)
  local take = reaper.GetActiveTake(item)
  if take then
    return take
  end

  take = reaper.AddTakeToMediaItem(item)
  return take
end

local function set_item_name(item, name)
  local take = ensure_item_take(item)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name or "", true)
  end
end

local function get_item_name(item)
  local take = reaper.GetActiveTake(item)
  if take then
    local take_name = reaper.GetTakeName(take)
    if take_name and trim(take_name) ~= "" then
      return trim(take_name)
    end
  end

  return ""
end

local function get_item_notes(item)
  local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  return notes or ""
end

local function get_item_time_range(item)
  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return position, position + length
end

local function collect_selected_items()
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

local function collect_selected_tracks()
  local tracks = {}
  local selected_count = reaper.CountSelectedTracks(0)
  for index = 0, selected_count - 1 do
    local track = reaper.GetSelectedTrack(0, index)
    if track then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

local function clear_track_selection()
  local track_count = reaper.CountTracks(0)
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    reaper.SetTrackSelected(track, false)
  end
end

local function restore_track_selection(selected_tracks)
  clear_track_selection()
  for _, track in ipairs(selected_tracks or {}) do
    if reaper.ValidatePtr(track, "MediaTrack*") then
      reaper.SetTrackSelected(track, true)
    end
  end
end

local function restore_item_selection(selected_items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(selected_items or {}) do
    if reaper.ValidatePtr(item, "MediaItem*") then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function normalize_padding(value, default_value)
  local padding = math.floor(tonumber(value) or default_value or 2)
  return clamp(padding, 1, 8)
end

local function normalize_number(value, default_value)
  return math.floor(tonumber(value) or default_value or 1)
end

local function format_index(index, padding)
  local numeric_index = math.max(0, math.floor(index))
  return string.format("%0" .. tostring(normalize_padding(padding, 2)) .. "d", numeric_index)
end

local function get_track_index(track)
  return reaper.CSurf_TrackToID(track, false) - 1
end

local function is_folder_parent(track)
  return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
end

local function collect_child_tracks(folder_track)
  local children = {}
  if not folder_track then
    return children
  end

  local folder_index = get_track_index(folder_track)
  local track_count = reaper.CountTracks(0)
  local depth = 1

  for index = folder_index + 1, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    if not track then
      break
    end

    children[#children + 1] = track
    depth = depth + reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if depth <= 0 then
      break
    end
  end

  return children
end

local function find_enclosing_folder_track(track)
  if not track then
    return nil
  end

  local track_index = get_track_index(track)
  if track_index <= 0 then
    return nil
  end

  for index = track_index - 1, 0, -1 do
    local candidate = reaper.GetTrack(0, index)
    if candidate and is_folder_parent(candidate) then
      local child_tracks = collect_child_tracks(candidate)
      for _, child_track in ipairs(child_tracks) do
        if child_track == track then
          return candidate
        end
      end
    end
  end

  return nil
end

local function should_skip_child_track(track, settings)
  if not track then
    return true
  end

  if not settings.folder_items.include_muted_tracks and reaper.GetMediaTrackInfo_Value(track, "B_MUTE") >= 1 then
    return true
  end

  return false
end

local function should_skip_child_item(item, settings)
  if not item then
    return true
  end

  if not settings.folder_items.include_muted_items and reaper.GetMediaItemInfo_Value(item, "B_MUTE") >= 1 then
    return true
  end

  return false
end

local function collect_child_items(folder_track, settings)
  local items = {}
  local child_tracks = collect_child_tracks(folder_track)

  for _, track in ipairs(child_tracks) do
    if not should_skip_child_track(track, settings) then
      local item_count = reaper.CountTrackMediaItems(track)
      for item_index = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if item and not should_skip_child_item(item, settings) then
          items[#items + 1] = item
        end
      end
    end
  end

  return items
end

local function get_entry_position(entry)
  if type(entry) == "table" then
    return tonumber(entry.position) or 0
  end
  return reaper.GetMediaItemInfo_Value(entry, "D_POSITION")
end

local function get_entry_end(entry)
  if type(entry) == "table" then
    return (tonumber(entry.position) or 0) + (tonumber(entry.length) or 0)
  end
  local position = reaper.GetMediaItemInfo_Value(entry, "D_POSITION")
  return position + reaper.GetMediaItemInfo_Value(entry, "D_LENGTH")
end

local function collect_child_entries(folder_track, settings)
  local entries = {}
  local child_tracks = collect_child_tracks(folder_track)

  for _, track in ipairs(child_tracks) do
    if not should_skip_child_track(track, settings) then
      local item_count = reaper.CountTrackMediaItems(track)
      for item_index = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if item and not should_skip_child_item(item, settings) then
          entries[#entries + 1] = item
        end
      end

      if settings.folder_items.include_automation then
        local envelope_count = reaper.CountTrackEnvelopes(track)
        for env_index = 0, envelope_count - 1 do
          local envelope = reaper.GetTrackEnvelope(track, env_index)
          local auto_item_count = envelope and reaper.CountAutomationItems(envelope) or 0
          for auto_index = 0, auto_item_count - 1 do
            local position = reaper.GetSetAutomationItemInfo(envelope, auto_index, "D_POSITION", 0, false)
            local length = reaper.GetSetAutomationItemInfo(envelope, auto_index, "D_LENGTH", 0, false)
            if length and length > 0 then
              entries[#entries + 1] = {
                automation = true,
                track = track,
                envelope = envelope,
                position = position,
                length = length,
                color = reaper.GetTrackColor(track),
              }
            end
          end
        end
      end
    end
  end

  return entries
end

function M.is_folder_item(item)
  if not item then
    return false
  end

  return get_item_ext_string(item, "GAW_ROLE") == FOLDER_ITEM_ROLE
end

local function get_folder_items(folder_track)
  local folder_items = {}
  local item_count = reaper.CountTrackMediaItems(folder_track)

  for index = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(folder_track, index)
    if M.is_folder_item(item) then
      folder_items[#folder_items + 1] = item
    end
  end

  table.sort(folder_items, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION") < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)

  return folder_items
end

function M.cluster_items_into_columns(items, gap_seconds, settings)
  local columns = {}
  local gap = tonumber(gap_seconds) or DEFAULT_CLUSTER_GAP

  table.sort(items, function(a, b)
    return get_entry_position(a) < get_entry_position(b)
  end)

  local current = nil

  for _, item in ipairs(items) do
    local position = get_entry_position(item)
    local item_end = get_entry_end(item)
    local merge_gap = gap
    if current and settings and settings.folder_items and settings.folder_items.experimental_auto_grouping then
      merge_gap = math.max(gap, 0.25)
    end

    if not current or position > (current.end_time + merge_gap) then
      current = {
        start_time = position,
        end_time = item_end,
        items = { item },
      }
      columns[#columns + 1] = current
    else
      current.items[#current.items + 1] = item
      if item_end > current.end_time then
        current.end_time = item_end
      end
    end
  end

  return columns
end

local function get_dominant_color(items, folder_track)
  for _, item in ipairs(items or {}) do
    local color = 0
    if type(item) == "table" then
      color = tonumber(item.color) or 0
    else
      color = reaper.GetDisplayedMediaItemColor(item)
    end
    if color and color ~= 0 then
      return color
    end
  end

  if folder_track then
    local track_color = reaper.GetTrackColor(folder_track)
    if track_color and track_color ~= 0 then
      return track_color
    end
  end

  return 0
end

local function create_folder_item(folder_track, position, length)
  local item = reaper.AddMediaItemToTrack(folder_track)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(length, EMPTY_ITEM_MIN_LENGTH))
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  set_item_ext_string(item, "GAW_ROLE", FOLDER_ITEM_ROLE)
  set_item_ext_string(item, "GAW_CREATED_BY", EXT_SECTION)
  ensure_item_take(item)
  return item
end

local function get_folder_item_display_name(folder_track, column_index, settings)
  local start_value = tonumber(settings.numbering.start) or 1
  local number = format_index(start_value + column_index - 1, settings.numbering.padding)
  return get_track_name(folder_track) .. tostring(settings.numbering.separator or "_") .. number
end

function M.update_folder_items_for_track(folder_track, settings)
  settings = settings or M.load_settings()
  if not folder_track or not is_folder_parent(folder_track) then
    return 0
  end

  local child_entries = collect_child_entries(folder_track, settings)
  local columns = M.cluster_items_into_columns(child_entries, settings.folder_items.cluster_gap, settings)
  local existing_items = get_folder_items(folder_track)

  for column_index, column in ipairs(columns) do
    local folder_item = existing_items[column_index]
    local length = math.max(column.end_time - column.start_time, EMPTY_ITEM_MIN_LENGTH)

    if not folder_item then
      folder_item = create_folder_item(folder_track, column.start_time, length)
    else
      reaper.SetMediaItemInfo_Value(folder_item, "D_POSITION", column.start_time)
      reaper.SetMediaItemInfo_Value(folder_item, "D_LENGTH", length)
      set_item_ext_string(folder_item, "GAW_ROLE", FOLDER_ITEM_ROLE)
    end

    if settings.folder_items.auto_name then
      set_item_name(folder_item, get_folder_item_display_name(folder_track, column_index, settings))
    end

    if settings.folder_items.inherit_color then
      local color = get_dominant_color(column.items, folder_track)
      if color ~= 0 then
        reaper.SetMediaItemInfo_Value(folder_item, "I_CUSTOMCOLOR", color | 0x1000000)
      end
    end
  end

  if #columns < #existing_items then
    for index = #columns + 1, #existing_items do
      reaper.DeleteTrackMediaItem(folder_track, existing_items[index])
    end
  end

  reaper.MarkTrackItemsDirty(folder_track, nil)
  return #columns
end

function M.update_all_folder_items(settings)
  settings = settings or M.load_settings()
  if not settings.folder_items.enabled then
    return 0
  end

  local updated = 0
  reaper.PreventUIRefresh(1)

  local track_count = reaper.CountTracks(0)
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    if is_folder_parent(track) then
      updated = updated + M.update_folder_items_for_track(track, settings)
    end
  end

  if settings.markers and settings.markers.enabled and M.update_markers_and_regions then
    M.update_markers_and_regions(settings)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  return updated
end

local function get_selected_folder_items()
  local selected = {}
  for _, item in ipairs(collect_selected_items()) do
    if M.is_folder_item(item) then
      selected[#selected + 1] = item
    end
  end
  return selected
end

local function item_overlaps_range(item, start_pos, end_pos, tolerance)
  tolerance = tolerance or DEFAULT_CLUSTER_GAP
  local item_start, item_end = get_item_time_range(item)
  return item_end > (start_pos - tolerance) and item_start < (end_pos + tolerance)
end

local function collect_children_for_folder_item(folder_item, settings)
  settings = settings or M.load_settings()

  local folder_track = reaper.GetMediaItemTrack(folder_item)
  local start_pos, end_pos = get_item_time_range(folder_item)
  local child_items = collect_child_items(folder_track, settings)
  local result = {}

  for _, child_item in ipairs(child_items) do
    if item_overlaps_range(child_item, start_pos, end_pos, settings.folder_items.cluster_gap) then
      result[#result + 1] = child_item
    end
  end

  return result
end

local function build_selected_item_signature()
  local guids = {}
  for _, item in ipairs(collect_selected_items()) do
    guids[#guids + 1] = get_item_guid(item)
  end
  table.sort(guids)
  return table.concat(guids, ";")
end

local function sync_track_selection_to_items()
  local tracks_by_guid = {}
  for _, item in ipairs(collect_selected_items()) do
    local track = reaper.GetMediaItemTrack(item)
    if track then
      tracks_by_guid[get_track_guid(track)] = track
    end
  end

  if next(tracks_by_guid) then
    clear_track_selection()
    for _, track in pairs(tracks_by_guid) do
      reaper.SetTrackSelected(track, true)
    end
  end
end

function M.handle_folder_item_selection(settings, force_refresh)
  settings = settings or M.load_settings()
  if not settings.selection.folder_selects_children and not settings.selection.track_follows_item then
    return
  end

  M._selection_state = M._selection_state or {
    last_signature = "",
  }

  local signature = build_selected_item_signature()
  if not force_refresh and signature == M._selection_state.last_signature then
    return
  end

  M._selection_state.last_signature = signature

  local folder_items = get_selected_folder_items()
  if settings.selection.folder_selects_children and #folder_items > 0 then
    local keep_selected = {}
    for _, folder_item in ipairs(folder_items) do
      keep_selected[#keep_selected + 1] = folder_item
      local children = collect_children_for_folder_item(folder_item, settings)
      for _, child_item in ipairs(children) do
        keep_selected[#keep_selected + 1] = child_item
      end
    end

    reaper.SelectAllMediaItems(0, false)
    for _, item in ipairs(keep_selected) do
      if reaper.ValidatePtr(item, "MediaItem*") then
        reaper.SetMediaItemSelected(item, true)
      end
    end
  end

  if settings.selection.track_follows_item then
    sync_track_selection_to_items()
  end
end

local function collect_selected_folder_tracks_from_context()
  local unique_tracks = {}
  local ordered_tracks = {}

  for _, track in ipairs(collect_selected_tracks()) do
    local folder_track = is_folder_parent(track) and track or find_enclosing_folder_track(track)
    if folder_track then
      local guid = get_track_guid(folder_track)
      if not unique_tracks[guid] then
        unique_tracks[guid] = true
        ordered_tracks[#ordered_tracks + 1] = folder_track
      end
    end
  end

  for _, item in ipairs(collect_selected_items()) do
    local item_track = reaper.GetMediaItemTrack(item)
    local folder_track = nil
    if item_track then
      if M.is_folder_item(item) and is_folder_parent(item_track) then
        folder_track = item_track
      else
        folder_track = find_enclosing_folder_track(item_track)
      end
    end

    if folder_track then
      local guid = get_track_guid(folder_track)
      if not unique_tracks[guid] then
        unique_tracks[guid] = true
        ordered_tracks[#ordered_tracks + 1] = folder_track
      end
    end
  end

  return ordered_tracks
end

local function prompt_for_inputs(title, captions, defaults)
  local retval, values = reaper.GetUserInputs(title, #captions, table.concat(captions, ","), table.concat(defaults, ","))
  if not retval then
    return nil
  end

  local parts = split_csv(values)
  while #parts < #captions do
    parts[#parts + 1] = ""
  end

  return parts
end

local function show_preview_dialog(title, preview_lines, extra_line)
  local message = {}
  if extra_line and extra_line ~= "" then
    message[#message + 1] = extra_line
    message[#message + 1] = ""
  end

  for _, line in ipairs(preview_lines or {}) do
    message[#message + 1] = line
  end

  return reaper.ShowMessageBox(table.concat(message, "\n"), title, 1) == 1
end

local function parse_list_text(text)
  local values = {}
  for line in tostring(text or ""):gmatch("[^\r\n;]+") do
    local cleaned = trim(line)
    if cleaned ~= "" then
      values[#values + 1] = cleaned
    end
  end
  return values
end

local function join_list_text(values)
  local parts = {}
  for _, value in ipairs(values or {}) do
    local cleaned = trim(value)
    if cleaned ~= "" then
      parts[#parts + 1] = cleaned
    end
  end
  return table.concat(parts, "\n")
end

local function copy_file_binary(source_path, destination_path)
  local input = io.open(source_path, "rb")
  if not input then
    return false
  end

  local data = input:read("*a")
  input:close()

  local destination_dir = destination_path:match("^(.*)[/\\]")
  if destination_dir and destination_dir ~= "" then
    reaper.RecursiveCreateDirectory(destination_dir, 0)
  end

  local output = io.open(destination_path, "wb")
  if not output then
    return false
  end

  output:write(data)
  output:close()
  return true
end

local function get_all_folder_items()
  local all_items = {}
  local track_count = reaper.CountTracks(0)
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    if is_folder_parent(track) then
      local folder_items = get_folder_items(track)
      for _, item in ipairs(folder_items) do
        all_items[#all_items + 1] = item
      end
    end
  end

  table.sort(all_items, function(a, b)
    local a_position = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local b_position = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    if a_position == b_position then
      return get_track_index(reaper.GetMediaItemTrack(a)) < get_track_index(reaper.GetMediaItemTrack(b))
    end
    return a_position < b_position
  end)

  return all_items
end

local function serialize_marker_entries(entries)
  local parts = {}
  for _, entry in ipairs(entries or {}) do
    parts[#parts + 1] = string.format("%s:%s", tostring(entry.id or -1), entry.is_region and "1" or "0")
  end
  return table.concat(parts, ",")
end

local function load_marker_entries()
  local ok, value = reaper.GetProjExtState(0, EXT_SECTION, "auto_markers")
  if ok ~= 1 or value == "" then
    return {}
  end

  local entries = {}
  for token in tostring(value):gmatch("[^,]+") do
    local id_text, region_text = token:match("^([^:]+):([^:]+)$")
    local marker_id = tonumber(id_text)
    if marker_id then
      entries[#entries + 1] = {
        id = marker_id,
        is_region = region_text == "1",
      }
    end
  end
  return entries
end

local function save_marker_entries(entries)
  reaper.SetProjExtState(0, EXT_SECTION, "auto_markers", serialize_marker_entries(entries))
end

function M.clear_auto_generated_markers()
  local entries = load_marker_entries()
  for _, entry in ipairs(entries) do
    reaper.DeleteProjectMarker(0, entry.id, entry.is_region)
  end
  save_marker_entries({})
end

function M.update_markers_and_regions(settings)
  settings = settings or M.load_settings()
  M.clear_auto_generated_markers()

  local created = {}
  local use_regions = settings.markers.mode ~= "markers"

  for _, folder_item in ipairs(get_all_folder_items()) do
    local position = reaper.GetMediaItemInfo_Value(folder_item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(folder_item, "D_LENGTH")
    local color = settings.markers.use_item_colors and reaper.GetMediaItemInfo_Value(folder_item, "I_CUSTOMCOLOR") or 0
    local marker_id = reaper.AddProjectMarker2(
      0,
      use_regions,
      position,
      use_regions and (position + length) or 0,
      get_item_name(folder_item),
      -1,
      color or 0
    )

    if marker_id and marker_id >= 0 then
      created[#created + 1] = {
        id = marker_id,
        is_region = use_regions,
      }
    end
  end

  save_marker_entries(created)
end

local function get_marker_targets(target_key)
  local targets = {}
  local total = reaper.GetNumRegionsOrMarkers(0)

  for index = 0, total - 1 do
    local retval, is_region, position, region_end, name, marker_id = reaper.EnumProjectMarkers2(0, index)
    if retval > 0 then
      if target_key == "markers" and not is_region then
        targets[#targets + 1] = {
          index = index,
          is_region = false,
          position = position,
          region_end = 0,
          name = name or "",
          marker_id = marker_id,
        }
      elseif target_key == "regions" and is_region then
        targets[#targets + 1] = {
          index = index,
          is_region = true,
          position = position,
          region_end = region_end,
          name = name or "",
          marker_id = marker_id,
        }
      end
    end
  end

  return targets
end

local function normalize_rename_target(value)
  local lowered = trim(value):lower()
  if lowered == "track" then
    return "tracks"
  end
  if lowered == "marker" then
    return "markers"
  end
  if lowered == "region" then
    return "regions"
  end
  if lowered == "tracks" or lowered == "markers" or lowered == "regions" then
    return lowered
  end
  return "items"
end

local function build_rename_targets(target_key)
  if target_key == "tracks" then
    local tracks = collect_selected_tracks()
    local targets = {}
    for _, track in ipairs(tracks) do
      targets[#targets + 1] = {
        object = track,
        before = get_track_name(track),
        kind = "track",
      }
    end
    return targets
  end

  if target_key == "markers" or target_key == "regions" then
    local markers = get_marker_targets(target_key)
    local targets = {}
    for _, marker in ipairs(markers) do
      targets[#targets + 1] = {
        object = marker,
        before = marker.name,
        kind = target_key == "markers" and "marker" or "region",
      }
    end
    return targets
  end

  local items = collect_selected_items()
  local targets = {}
  for _, item in ipairs(items) do
    targets[#targets + 1] = {
      object = item,
      before = get_item_name(item),
      kind = "item",
    }
  end
  return targets
end

local function build_name_from_settings(base_name, number_enabled, start_index, index, padding, separator, disable_single_numbering, total_count)
  if not number_enabled then
    return sanitize_filename(base_name)
  end

  if disable_single_numbering and total_count == 1 then
    return sanitize_filename(base_name)
  end

  local numeric_index = start_index + index - 1
  return sanitize_filename(base_name) .. separator .. format_index(numeric_index, padding)
end

local function apply_match_replace_to_name(source_name, options)
  local name = tostring(source_name or "")
  if options.match_mode and trim(options.match_pattern) ~= "" then
    local ok, replaced = pcall(function()
      return name:gsub(options.match_pattern, options.replace_text or "")
    end)
    if ok then
      name = replaced
    end
  end
  return trim(name)
end

local function build_target_name(target, base_name, options, index, total_count)
  local working_name = apply_match_replace_to_name(target.before or "", options)
  if trim(base_name) ~= "" then
    working_name = trim(base_name)
  end
  if options.ucs_enabled and trim(options.ucs_category) ~= "" then
    if working_name ~= "" then
      working_name = trim(options.ucs_category) .. "_" .. working_name
    else
      working_name = trim(options.ucs_category)
    end
  end

  return build_name_from_settings(
    working_name ~= "" and working_name or target.before or "item",
    options.numbering_enabled,
    options.start_number,
    index,
    options.padding,
    options.separator,
    options.disable_single_numbering,
    total_count
  )
end

local function apply_rename_to_track_targets(base_name, targets, options)
  for index, target in ipairs(targets) do
    local new_name = build_target_name(target, base_name, options, index, #targets)
    set_track_name(target.object, new_name)
  end
end

local function apply_rename_to_item_targets(base_name, targets, options)
  for index, target in ipairs(targets) do
    local new_name = build_target_name(target, base_name, options, index, #targets)
    set_item_name(target.object, new_name)
  end

  if options.rename_item_tracks then
    local unique_tracks = {}
    local ordered_tracks = {}
    for _, target in ipairs(targets) do
      local track = reaper.GetMediaItemTrack(target.object)
      local guid = track and get_track_guid(track) or ""
      if track and not unique_tracks[guid] then
        unique_tracks[guid] = true
        ordered_tracks[#ordered_tracks + 1] = track
      end
    end

    if #ordered_tracks > 0 then
      for index, track in ipairs(ordered_tracks) do
        local track_name = build_name_from_settings(
          base_name,
          options.numbering_enabled and #ordered_tracks > 1,
          options.start_number,
          index,
          options.padding,
          options.separator,
          false,
          #ordered_tracks
        )
        set_track_name(track, track_name)
      end
    end
  end
end

local function apply_rename_to_marker_targets(base_name, targets, options)
  for index, target in ipairs(targets) do
    local marker = target.object
    local new_name = build_target_name(target, base_name, options, index, #targets)
    reaper.SetProjectMarker3(0, marker.marker_id, marker.is_region, marker.position, marker.region_end, new_name, 0)
  end
end

local function run_rename_dialog_basic()
  local settings = M.load_settings()
  local defaults = {
    get_project_name(),
    settings.rename.target or "items",
    settings.rename.numbering ~= false and "y" or "n",
    tostring(settings.rename.start_number or settings.numbering.start),
    tostring(settings.rename.padding or settings.numbering.padding),
    tostring(settings.rename.separator or settings.numbering.separator),
    settings.rename.rename_tracks and "y" or "n",
    settings.rename.match_mode and "y" or "n",
    settings.rename.match_pattern or "",
    settings.rename.replace_text or "",
    settings.rename.ucs_enabled and "y" or "n",
    settings.rename.ucs_category or "",
  }

  local captions = {
    "Base name",
    "Target (items/tracks/markers/regions)",
    "Numbering? (y/n)",
    "Start number",
    "Padding",
    "Separator",
    "Rename item tracks? (y/n)",
    "Match mode? (y/n)",
    "Match pattern",
    "Replace text",
    "UCS enabled? (y/n)",
    "UCS category",
  }

  local values = prompt_for_inputs("GameAudioWorkflow Rename", captions, defaults)
  if not values then
    return
  end

  local base_name = trim(values[1])
  if base_name == "" then
    reaper.ShowMessageBox("Base name cannot be empty.", "Game Audio Workflow Rename", 0)
    return
  end

  local target_key = normalize_rename_target(values[2])
  local targets = build_rename_targets(target_key)
  if #targets == 0 then
    reaper.ShowMessageBox("No valid targets found for rename.", "Game Audio Workflow Rename", 0)
    return
  end

  local options = {
    numbering_enabled = string_to_bool(values[3], true),
    start_number = normalize_number(values[4], settings.numbering.start),
    padding = normalize_padding(values[5], settings.numbering.padding),
    separator = values[6] ~= "" and values[6] or settings.numbering.separator,
    disable_single_numbering = false,
    rename_item_tracks = string_to_bool(values[7], false),
    match_mode = string_to_bool(values[8], false),
    match_pattern = values[9] or "",
    replace_text = values[10] or "",
    ucs_enabled = string_to_bool(values[11], false),
    ucs_category = values[12] or "",
  }

  local preview = {}
  local preview_count = math.min(#targets, 10)
  for index = 1, preview_count do
    local target = targets[index]
    preview[#preview + 1] = string.format(
      "%s -> %s",
      target.before ~= "" and target.before or "(empty)",
      build_target_name(target, base_name, options, index, #targets)
    )
  end

  if #targets > preview_count then
    preview[#preview + 1] = string.format("... and %d more", #targets - preview_count)
  end

  local confirmed = show_preview_dialog(
    "Game Audio Workflow Rename Preview",
    preview,
    string.format("Target: %s\nObjects: %d", target_key, #targets)
  )

  if not confirmed then
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if target_key == "tracks" then
    apply_rename_to_track_targets(base_name, targets, options)
  elseif target_key == "markers" or target_key == "regions" then
    apply_rename_to_marker_targets(base_name, targets, options)
  else
    apply_rename_to_item_targets(base_name, targets, options)
  end

  settings.rename.target = target_key
  settings.rename.numbering = options.numbering_enabled
  settings.rename.start_number = options.start_number
  settings.rename.padding = options.padding
  settings.rename.separator = options.separator
  settings.rename.rename_tracks = options.rename_item_tracks
  settings.rename.match_mode = options.match_mode
  settings.rename.match_pattern = options.match_pattern
  settings.rename.replace_text = options.replace_text
  settings.rename.ucs_enabled = options.ucs_enabled
  settings.rename.ucs_category = options.ucs_category
  M.save_settings(settings, "project")

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow Rename", -1)
end

local function resolve_render_directory(directory_value)
  local raw_directory = trim(directory_value)
  if raw_directory == "" then
    raw_directory = DEFAULT_SETTINGS.render.directory
  end

  if raw_directory:match("^%a:[/\\]") or raw_directory:match("^[/\\][/\\]?") then
    return raw_directory
  end

  return join_path(get_project_directory(), raw_directory)
end

local function get_render_snapshot()
  local snapshot = {
    strings = {},
    numbers = {},
  }

  local string_keys = {
    "RENDER_FILE",
    "RENDER_PATTERN",
    "RENDER_FORMAT",
  }

  local number_keys = {
    "RENDER_SETTINGS",
    "RENDER_BOUNDSFLAG",
    "RENDER_STARTPOS",
    "RENDER_ENDPOS",
    "RENDER_CHANNELS",
    "RENDER_SRATE",
    "RENDER_ADDTOPROJ",
    "RENDER_TAILFLAG",
    "RENDER_TAILMS",
  }

  for _, key in ipairs(string_keys) do
    snapshot.strings[key] = select(2, reaper.GetSetProjectInfo_String(0, key, "", false))
  end

  for _, key in ipairs(number_keys) do
    snapshot.numbers[key] = reaper.GetSetProjectInfo(0, key, 0, false)
  end

  return snapshot
end

local function restore_render_snapshot(snapshot)
  if not snapshot then
    return
  end

  for key, value in pairs(snapshot.strings or {}) do
    reaper.GetSetProjectInfo_String(0, key, value or "", true)
  end

  for key, value in pairs(snapshot.numbers or {}) do
    reaper.GetSetProjectInfo(0, key, value or 0, true)
  end
end

local function evaluate_render_pattern(pattern, folder_item)
  local folder_track = reaper.GetMediaItemTrack(folder_item)
  local replacements = {
    ["$item"] = get_item_name(folder_item),
    ["$track"] = get_track_name(folder_track),
    ["$project"] = get_project_name(),
    ["$date"] = os.date("%Y%m%d"),
    ["$itemnotes"] = get_item_notes(folder_item),
  }

  local resolved = pattern or DEFAULT_SETTINGS.render.file_pattern
  for token, replacement in pairs(replacements) do
    resolved = resolved:gsub(token, replacement ~= "" and replacement or token:sub(2))
  end

  return sanitize_filename(resolved)
end

local function render_target_list_to_table(targets_text)
  local targets = {}
  for line in tostring(targets_text or ""):gmatch("[^\r\n;]+") do
    local cleaned = trim(line)
    if cleaned ~= "" then
      targets[#targets + 1] = cleaned
    end
  end
  return targets
end

local function configure_render_for_folder_item(folder_item, render_directory, pattern, sample_rate, channels, tail_ms, preserve_metadata)
  local start_pos, end_pos = get_item_time_range(folder_item)
  local folder_track = reaper.GetMediaItemTrack(folder_item)
  local render_name = evaluate_render_pattern(pattern, folder_item)
  local render_settings_flags = 128

  if preserve_metadata then
    render_settings_flags = render_settings_flags | 32768
  end

  reaper.SetOnlyTrackSelected(folder_track)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", render_directory, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", render_name, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "evaw", true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", render_settings_flags, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", start_pos, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", end_pos, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", channels, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", sample_rate, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", tail_ms > 0 and 1 or 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILMS", math.max(0, tail_ms), true)

  local targets_text = select(2, reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false))
  return render_name, render_target_list_to_table(targets_text)
end

local function run_render_smart_dialog_basic()
  local settings = M.load_settings()
  local folder_items = get_selected_folder_items()
  if #folder_items == 0 then
    local track_count = reaper.CountTracks(0)
    for index = 0, track_count - 1 do
      local track = reaper.GetTrack(0, index)
      if is_folder_parent(track) then
        local track_folder_items = get_folder_items(track)
        for _, item in ipairs(track_folder_items) do
          folder_items[#folder_items + 1] = item
        end
      end
    end
  end

  if #folder_items == 0 then
    reaper.ShowMessageBox("No folder items found. Run the folder-item updater first.", "Game Audio Workflow Render", 0)
    return
  end

  table.sort(folder_items, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION") < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)

  local values = prompt_for_inputs(
    "GameAudioWorkflow Render SMART",
    {
      "Output directory",
      "File pattern ($item/$track/$project/$date/$itemnotes)",
      "Sample rate",
      "Tail ms",
    },
    {
      settings.render.directory,
      settings.render.file_pattern,
      tostring(settings.render.sample_rate),
      tostring(settings.render.tail_length_ms),
    }
  )

  if not values then
    return
  end

  local render_directory = resolve_render_directory(values[1])
  local pattern = trim(values[2])
  if pattern == "" then
    pattern = settings.render.file_pattern
  end

  local sample_rate = math.max(8000, math.floor(tonumber(values[3]) or settings.render.sample_rate))
  local tail_ms = math.max(0, math.floor(tonumber(values[4]) or settings.render.tail_length_ms))
  local channels = settings.render.channels == "mono" and 1 or 2

  reaper.RecursiveCreateDirectory(render_directory, 0)

  local preview = {}
  local preview_count = math.min(#folder_items, 8)
  for index = 1, preview_count do
    preview[#preview + 1] = evaluate_render_pattern(pattern, folder_items[index]) .. ".wav"
  end
  if #folder_items > preview_count then
    preview[#preview + 1] = string.format("... and %d more", #folder_items - preview_count)
  end

  if not show_preview_dialog(
    "Game Audio Workflow Render Preview",
    preview,
    string.format("Directory: %s\nItems: %d", render_directory, #folder_items)
  ) then
    return
  end

  local render_snapshot = get_render_snapshot()
  local selected_tracks = collect_selected_tracks()
  local selected_items = collect_selected_items()
  local rendered_paths = {}

  reaper.PreventUIRefresh(1)

  for _, folder_item in ipairs(folder_items) do
    local _, predicted_targets = configure_render_for_folder_item(
      folder_item,
      render_directory,
      pattern,
      sample_rate,
      channels,
      tail_ms,
      settings.render.preserve_metadata
    )

    reaper.Main_OnCommand(DEFAULT_RENDER_ACTION_ID, 0)

    if #predicted_targets == 0 then
      local fallback_path = join_path(render_directory, evaluate_render_pattern(pattern, folder_item) .. ".wav")
      rendered_paths[#rendered_paths + 1] = fallback_path
    else
      for _, path in ipairs(predicted_targets) do
        rendered_paths[#rendered_paths + 1] = path
      end
    end
  end

  restore_render_snapshot(render_snapshot)
  restore_track_selection(selected_tracks)
  restore_item_selection(selected_items)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  local message_lines = {
    string.format("Rendered %d folder item(s).", #folder_items),
    "Output folder: " .. render_directory,
  }

  local preview_lines = math.min(#rendered_paths, 5)
  for index = 1, preview_lines do
    message_lines[#message_lines + 1] = rendered_paths[index]
  end
  if #rendered_paths > preview_lines then
    message_lines[#message_lines + 1] = string.format("... and %d more", #rendered_paths - preview_lines)
  end

  reaper.ShowMessageBox(table.concat(message_lines, "\n"), "Game Audio Workflow Render", 0)
end

function M.has_imgui()
  return type(reaper.ImGui_CreateContext) == "function"
end

local function run_imgui_window(title, width, height, draw_fn, state)
  if not M.has_imgui() then
    return false
  end

  local ctx = reaper.ImGui_CreateContext(title)
  state = state or {}
  state.ctx = ctx
  state.open = true

  local function loop()
    if not state.open then
      reaper.ImGui_DestroyContext(ctx)
      return
    end

    reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_FirstUseEver())
    local visible
    visible, state.open = reaper.ImGui_Begin(ctx, title, state.open)
    if visible then
      local ok, err = pcall(draw_fn, state)
      if not ok then
        reaper.ImGui_TextWrapped(ctx, tostring(err))
        state.open = false
      end
      reaper.ImGui_End(ctx)
    end

    if state.open then
      reaper.defer(loop)
    else
      reaper.ImGui_DestroyContext(ctx)
    end
  end

  reaper.defer(loop)
  return true
end

local function imgui_input_int(ctx, label, value, min_value, max_value)
  local changed
  changed, value = reaper.ImGui_InputInt(ctx, label, math.floor(tonumber(value) or 0))
  if changed then
    value = clamp(math.floor(tonumber(value) or 0), min_value or -2147483648, max_value or 2147483647)
  end
  return changed, value
end

local function imgui_section(ctx, title)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, title)
end

local function get_folder_items_for_render()
  local folder_items = get_selected_folder_items()
  if #folder_items == 0 then
    folder_items = get_all_folder_items()
  end
  return folder_items
end

local function copy_render_outputs(rendered_paths, render_settings)
  local copied = {}
  local directories = parse_list_text(join_list_text(render_settings.copy_directories or {}))
  if #directories == 0 then
    return copied
  end

  for _, source_path in ipairs(rendered_paths or {}) do
    local file_name = source_path:match("[/\\]([^/\\]+)$") or source_path
    if render_settings.copy_rename_pattern and render_settings.copy_rename_pattern ~= "" then
      file_name = file_name:gsub(render_settings.copy_rename_pattern, render_settings.copy_rename_replace or "")
    end

    for _, directory in ipairs(directories) do
      local resolved_dir = resolve_render_directory(directory)
      local destination_path = join_path(resolved_dir, file_name)
      if copy_file_binary(source_path, destination_path) then
        copied[#copied + 1] = destination_path
      end
    end
  end

  return copied
end

local function parse_render_variants_text(text, fallback_sample_rate, fallback_channels)
  local variants = {}
  for _, line in ipairs(parse_list_text(text)) do
    local suffix, sample_rate_text, channels_text = line:match("^([^|]+)|([^|]+)|([^|]+)$")
    if suffix then
      variants[#variants + 1] = {
        suffix = trim(suffix),
        sample_rate = tonumber(sample_rate_text) or fallback_sample_rate,
        channels = trim(channels_text) ~= "" and trim(channels_text) or fallback_channels,
      }
    else
      variants[#variants + 1] = {
        suffix = trim(line),
        sample_rate = fallback_sample_rate,
        channels = fallback_channels,
      }
    end
  end
  return variants
end

local function render_groups(render_groups, render_settings)
  local render_snapshot = get_render_snapshot()
  local selected_tracks = collect_selected_tracks()
  local selected_items = collect_selected_items()
  local rendered_paths = {}

  reaper.PreventUIRefresh(1)

  local variants = {}
  if render_settings.render_variants then
    variants = parse_render_variants_text(render_settings.variants_text, render_settings.sample_rate, render_settings.channels)
  end

  local render_passes = {
    {
      suffix = "",
      sample_rate = render_settings.sample_rate,
      channels = render_settings.channels,
    },
  }
  for _, variant in ipairs(variants) do
    render_passes[#render_passes + 1] = variant
  end

  for _, group in ipairs(render_groups) do
    for _, pass in ipairs(render_passes) do
    local render_settings_flags = 128
    if render_settings.preserve_metadata then
      render_settings_flags = render_settings_flags | 32768
    end

    reaper.SetOnlyTrackSelected(group.track)
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", render_settings.directory, true)
      local render_name = group.name
      if pass.suffix and pass.suffix ~= "" then
        render_name = render_name .. "_" .. sanitize_filename(pass.suffix)
      end
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", render_name, true)
    reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "evaw", true)
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", render_settings_flags, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", group.start_pos, true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", group.end_pos, true)
      local pass_channels = pass.channels == "mono" and 1 or 2
    reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", pass_channels, true)
    reaper.GetSetProjectInfo(0, "RENDER_SRATE", pass.sample_rate, true)
    reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", render_settings.tail_length_ms > 0 and 1 or 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILMS", math.max(0, render_settings.tail_length_ms), true)

    local targets_text = select(2, reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false))
    local predicted_targets = parse_list_text(targets_text)
    reaper.Main_OnCommand(DEFAULT_RENDER_ACTION_ID, 0)

    if #predicted_targets == 0 then
        rendered_paths[#rendered_paths + 1] = join_path(render_settings.directory, render_name .. ".wav")
    else
      for _, path in ipairs(predicted_targets) do
        rendered_paths[#rendered_paths + 1] = path
      end
    end
    end
  end

  restore_render_snapshot(render_snapshot)
  restore_track_selection(selected_tracks)
  restore_item_selection(selected_items)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  local copied_paths = copy_render_outputs(rendered_paths, render_settings)
  return rendered_paths, copied_paths
end

local function build_render_groups_from_items(folder_items, render_settings)
  local groups = {}
  local sorted_items = {}
  for _, item in ipairs(folder_items or {}) do
    sorted_items[#sorted_items + 1] = item
  end

  table.sort(sorted_items, function(a, b)
    local a_position = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local b_position = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    if a_position == b_position then
      return get_track_index(reaper.GetMediaItemTrack(a)) < get_track_index(reaper.GetMediaItemTrack(b))
    end
    return a_position < b_position
  end)

  if render_settings.sausage_mode then
    local by_track = {}
    for _, item in ipairs(sorted_items) do
      local track = reaper.GetMediaItemTrack(item)
      local guid = get_track_guid(track)
      by_track[guid] = by_track[guid] or {
        track = track,
        items = {},
        start_pos = math.huge,
        end_pos = 0,
      }
      local entry = by_track[guid]
      local start_pos, end_pos = get_item_time_range(item)
      entry.items[#entry.items + 1] = item
      entry.start_pos = math.min(entry.start_pos, start_pos)
      entry.end_pos = math.max(entry.end_pos, end_pos)
    end

    for _, entry in pairs(by_track) do
      local first_item = entry.items[1]
      groups[#groups + 1] = {
        track = entry.track,
        start_pos = entry.start_pos,
        end_pos = entry.end_pos,
        name = evaluate_render_pattern(render_settings.file_pattern, first_item) .. "_sausage",
        items = entry.items,
      }
    end
  else
    for _, item in ipairs(sorted_items) do
      local start_pos, end_pos = get_item_time_range(item)
      groups[#groups + 1] = {
        track = reaper.GetMediaItemTrack(item),
        start_pos = start_pos,
        end_pos = end_pos,
        name = evaluate_render_pattern(render_settings.file_pattern, item),
        items = { item },
      }
    end
  end

  table.sort(groups, function(a, b)
    if a.start_pos == b.start_pos then
      return get_track_index(a.track) < get_track_index(b.track)
    end
    return a.start_pos < b.start_pos
  end)

  return groups
end

local function apply_rename_from_options(base_name, target_key, options)
  local targets = build_rename_targets(target_key)
  if #targets == 0 then
    return false, "No valid targets found for rename."
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if target_key == "tracks" then
    apply_rename_to_track_targets(base_name, targets, options)
  elseif target_key == "markers" or target_key == "regions" then
    apply_rename_to_marker_targets(base_name, targets, options)
  else
    apply_rename_to_item_targets(base_name, targets, options)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow Rename", -1)
  return true, string.format("Renamed %d %s.", #targets, target_key)
end

local function draw_rename_window(state)
  local ctx = state.ctx
  local settings = state.settings

  reaper.ImGui_Text(ctx, "Target")
  if reaper.ImGui_Button(ctx, "Items") then state.target = "items" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Tracks") then state.target = "tracks" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Markers") then state.target = "markers" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Regions") then state.target = "regions" end
  reaper.ImGui_Text(ctx, "Current target: " .. state.target)

  local changed
  changed, state.base_name = reaper.ImGui_InputText(ctx, "Base Name", state.base_name or "")
  changed, state.separator = reaper.ImGui_InputText(ctx, "Separator", state.separator or "_")
  changed, state.numbering_enabled = reaper.ImGui_Checkbox(ctx, "Enable Numbering", state.numbering_enabled)
  changed, state.rename_tracks = reaper.ImGui_Checkbox(ctx, "Rename Item Tracks", state.rename_tracks)
  changed, state.start_number = imgui_input_int(ctx, "Start Number", state.start_number, 0, 99999)
  changed, state.padding = imgui_input_int(ctx, "Padding", state.padding, 1, 8)
  imgui_section(ctx, "Match / UCS")
  changed, state.match_mode = reaper.ImGui_Checkbox(ctx, "Match / Replace Mode", state.match_mode)
  changed, state.match_pattern = reaper.ImGui_InputText(ctx, "Match Pattern", state.match_pattern or "")
  changed, state.replace_text = reaper.ImGui_InputText(ctx, "Replace Text", state.replace_text or "")
  changed, state.ucs_enabled = reaper.ImGui_Checkbox(ctx, "UCS Enabled", state.ucs_enabled)
  changed, state.ucs_category = reaper.ImGui_InputText(ctx, "UCS Category", state.ucs_category or "")

  imgui_section(ctx, "Preset")
  changed, state.preset_name = reaper.ImGui_InputText(ctx, "Preset Name", state.preset_name or "Default")
  if reaper.ImGui_Button(ctx, "Load Preset") then
    local preset = settings.rename.presets[state.preset_name or ""]
    if preset then
      state.target = preset.target or state.target
      state.base_name = preset.base_name or state.base_name
      state.separator = preset.separator or state.separator
      state.numbering_enabled = preset.numbering_enabled ~= false
      state.rename_tracks = preset.rename_tracks == true
      state.start_number = preset.start_number or state.start_number
      state.padding = preset.padding or state.padding
      state.match_mode = preset.match_mode == true
      state.match_pattern = preset.match_pattern or ""
      state.replace_text = preset.replace_text or ""
      state.ucs_enabled = preset.ucs_enabled == true
      state.ucs_category = preset.ucs_category or ""
      state.status = "Preset loaded."
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Save Preset") then
    settings.rename.presets[state.preset_name or "Default"] = {
      target = state.target,
      base_name = state.base_name,
      separator = state.separator,
      numbering_enabled = state.numbering_enabled,
      rename_tracks = state.rename_tracks,
      start_number = state.start_number,
      padding = state.padding,
      match_mode = state.match_mode,
      match_pattern = state.match_pattern,
      replace_text = state.replace_text,
      ucs_enabled = state.ucs_enabled,
      ucs_category = state.ucs_category,
    }
    settings.rename.selected_preset = state.preset_name
    M.save_settings(settings, "project")
    state.status = "Preset saved."
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Delete Preset") then
    settings.rename.presets[state.preset_name or ""] = nil
    M.save_settings(settings, "project")
    state.status = "Preset deleted."
  end

  imgui_section(ctx, "Preview")
  local preview_targets = build_rename_targets(state.target)
  local preview_count = math.min(#preview_targets, 10)
  for index = 1, preview_count do
    local target = preview_targets[index]
    reaper.ImGui_Text(
      ctx,
      string.format(
        "%s -> %s",
        target.before ~= "" and target.before or "(empty)",
        build_target_name(target, state.base_name, {
          numbering_enabled = state.numbering_enabled,
          start_number = state.start_number,
          padding = state.padding,
          separator = state.separator,
          disable_single_numbering = false,
          match_mode = state.match_mode,
          match_pattern = state.match_pattern,
          replace_text = state.replace_text,
          ucs_enabled = state.ucs_enabled,
          ucs_category = state.ucs_category,
        }, index, #preview_targets)
      )
    )
  end
  if #preview_targets > preview_count then
    reaper.ImGui_Text(ctx, string.format("... and %d more", #preview_targets - preview_count))
  end

  imgui_section(ctx, "Actions")
  if reaper.ImGui_Button(ctx, "Apply Rename") then
    local ok, message = apply_rename_from_options(state.base_name, state.target, {
      numbering_enabled = state.numbering_enabled,
      start_number = state.start_number,
      padding = state.padding,
      separator = state.separator,
      disable_single_numbering = false,
      rename_item_tracks = state.rename_tracks,
      match_mode = state.match_mode,
      match_pattern = state.match_pattern,
      replace_text = state.replace_text,
      ucs_enabled = state.ucs_enabled,
      ucs_category = state.ucs_category,
    })
    state.status = message
    if ok then
      settings.rename.target = state.target
      settings.rename.numbering = state.numbering_enabled
      settings.rename.start_number = state.start_number
      settings.rename.padding = state.padding
      settings.rename.separator = state.separator
      settings.rename.rename_tracks = state.rename_tracks
      settings.rename.match_mode = state.match_mode
      settings.rename.match_pattern = state.match_pattern
      settings.rename.replace_text = state.replace_text
      settings.rename.ucs_enabled = state.ucs_enabled
      settings.rename.ucs_category = state.ucs_category
      M.save_settings(settings, "project")
    end
  end

  if state.status and state.status ~= "" then
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, state.status)
  end
end

local function draw_render_window(state)
  local ctx = state.ctx
  local settings = state.settings

  local changed
  changed, state.directory = reaper.ImGui_InputText(ctx, "Directory", state.directory or "")
  changed, state.file_pattern = reaper.ImGui_InputText(ctx, "Pattern", state.file_pattern or "$item")
  changed, state.sample_rate = imgui_input_int(ctx, "Sample Rate", state.sample_rate, 8000, 384000)
  changed, state.tail_length_ms = imgui_input_int(ctx, "Tail (ms)", state.tail_length_ms, 0, 300000)
  changed, state.sausage_mode = reaper.ImGui_Checkbox(ctx, "Sausage Mode", state.sausage_mode)
  changed, state.preserve_metadata = reaper.ImGui_Checkbox(ctx, "Preserve Metadata", state.preserve_metadata)
  if reaper.ImGui_Button(ctx, "Mono") then state.channels = "mono" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Stereo") then state.channels = "stereo" end
  reaper.ImGui_Text(ctx, "Channels: " .. (state.channels or "stereo"))
  changed, state.render_variants = reaper.ImGui_Checkbox(ctx, "Render Variants", state.render_variants)
  changed, state.variants_text = reaper.ImGui_InputTextMultiline(ctx, "Variants (suffix|rate|channels)", state.variants_text or "", 420, 90)
  changed, state.copy_directories_text = reaper.ImGui_InputTextMultiline(ctx, "Copy To", state.copy_directories_text or "", 420, 90)
  changed, state.copy_rename_pattern = reaper.ImGui_InputText(ctx, "Copy Rename Pattern", state.copy_rename_pattern or "")
  changed, state.copy_rename_replace = reaper.ImGui_InputText(ctx, "Copy Rename Replace", state.copy_rename_replace or "")

  imgui_section(ctx, "Preset")
  changed, state.preset_name = reaper.ImGui_InputText(ctx, "Preset Name", state.preset_name or "Default")
  if reaper.ImGui_Button(ctx, "Load Preset") then
    local preset = settings.render.presets[state.preset_name or ""]
    if preset then
      state.directory = preset.directory or state.directory
      state.file_pattern = preset.file_pattern or state.file_pattern
      state.sample_rate = preset.sample_rate or state.sample_rate
      state.tail_length_ms = preset.tail_length_ms or state.tail_length_ms
      state.sausage_mode = preset.sausage_mode == true
      state.preserve_metadata = preset.preserve_metadata ~= false
      state.channels = preset.channels or state.channels
      state.render_variants = preset.render_variants == true
      state.variants_text = preset.variants_text or ""
      state.copy_directories_text = join_list_text(preset.copy_directories or {})
      state.copy_rename_pattern = preset.copy_rename_pattern or ""
      state.copy_rename_replace = preset.copy_rename_replace or ""
      state.status = "Preset loaded."
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Save Preset") then
    settings.render.presets[state.preset_name or "Default"] = {
      directory = state.directory,
      file_pattern = state.file_pattern,
      sample_rate = state.sample_rate,
      tail_length_ms = state.tail_length_ms,
      sausage_mode = state.sausage_mode,
      preserve_metadata = state.preserve_metadata,
      channels = state.channels,
      render_variants = state.render_variants,
      variants_text = state.variants_text,
      copy_directories = parse_list_text(state.copy_directories_text),
      copy_rename_pattern = state.copy_rename_pattern,
      copy_rename_replace = state.copy_rename_replace,
    }
    settings.render.selected_preset = state.preset_name
    M.save_settings(settings, "project")
    state.status = "Preset saved."
  end

  local folder_items = get_folder_items_for_render()
  imgui_section(ctx, "Preview")
  reaper.ImGui_Text(ctx, string.format("Folder items: %d", #folder_items))
  local groups = build_render_groups_from_items(folder_items, {
    file_pattern = state.file_pattern,
    sausage_mode = state.sausage_mode,
  })
  local preview_count = math.min(#groups, 10)
  for index = 1, preview_count do
    reaper.ImGui_Text(ctx, groups[index].name .. ".wav")
  end
  if #groups > preview_count then
    reaper.ImGui_Text(ctx, string.format("... and %d more", #groups - preview_count))
  end

  imgui_section(ctx, "Actions")
  if reaper.ImGui_Button(ctx, "Render") then
    if #folder_items == 0 then
      state.status = "No folder items found."
    else
      local render_settings = {
        directory = resolve_render_directory(state.directory),
        file_pattern = state.file_pattern,
        sample_rate = state.sample_rate,
        tail_length_ms = state.tail_length_ms,
        preserve_metadata = state.preserve_metadata,
        sausage_mode = state.sausage_mode,
        channels = state.channels,
        render_variants = state.render_variants,
        variants_text = state.variants_text,
        copy_directories = parse_list_text(state.copy_directories_text),
        copy_rename_pattern = state.copy_rename_pattern,
        copy_rename_replace = state.copy_rename_replace,
      }
      reaper.RecursiveCreateDirectory(render_settings.directory, 0)
      local rendered_paths, copied_paths = render_groups(build_render_groups_from_items(folder_items, render_settings), render_settings)
      settings.render.directory = state.directory
      settings.render.file_pattern = state.file_pattern
      settings.render.sample_rate = state.sample_rate
      settings.render.tail_length_ms = state.tail_length_ms
      settings.render.sausage_mode = state.sausage_mode
      settings.render.preserve_metadata = state.preserve_metadata
      settings.render.channels = state.channels
      settings.render.render_variants = state.render_variants
      settings.render.variants_text = state.variants_text
      settings.render.copy_directories = parse_list_text(state.copy_directories_text)
      settings.render.copy_rename_pattern = state.copy_rename_pattern
      settings.render.copy_rename_replace = state.copy_rename_replace
      M.save_settings(settings, "project")
      state.status = string.format("Rendered %d file(s), copied %d file(s).", #rendered_paths, #copied_paths)
    end
  end

  if state.status and state.status ~= "" then
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, state.status)
  end
end

function M.run_rename_dialog()
  if not M.has_imgui() then
    run_rename_dialog_basic()
    return
  end

  local settings = M.load_settings()
  run_imgui_window("Game Audio Workflow Rename", 640, 520, draw_rename_window, {
    settings = settings,
    base_name = get_project_name(),
    target = settings.rename.target or "items",
    numbering_enabled = settings.rename.numbering ~= false,
    start_number = settings.rename.start_number or settings.numbering.start,
    padding = settings.rename.padding or settings.numbering.padding,
    separator = settings.rename.separator or settings.numbering.separator,
    rename_tracks = settings.rename.rename_tracks == true,
    match_mode = settings.rename.match_mode == true,
    match_pattern = settings.rename.match_pattern or "",
    replace_text = settings.rename.replace_text or "",
    ucs_enabled = settings.rename.ucs_enabled == true,
    ucs_category = settings.rename.ucs_category or "",
    preset_name = settings.rename.selected_preset or "Default",
    status = "",
  })
end

function M.run_render_smart_dialog()
  if not M.has_imgui() then
    run_render_smart_dialog_basic()
    return
  end

  local settings = M.load_settings()
  run_imgui_window("Game Audio Workflow Render SMART", 700, 580, draw_render_window, {
    settings = settings,
    directory = settings.render.directory,
    file_pattern = settings.render.file_pattern,
    sample_rate = settings.render.sample_rate,
    tail_length_ms = settings.render.tail_length_ms,
    sausage_mode = settings.render.sausage_mode == true,
    preserve_metadata = settings.render.preserve_metadata ~= false,
    channels = settings.render.channels or "stereo",
    render_variants = settings.render.render_variants == true,
    variants_text = settings.render.variants_text or "",
    copy_directories_text = join_list_text(settings.render.copy_directories or {}),
    copy_rename_pattern = settings.render.copy_rename_pattern or "",
    copy_rename_replace = settings.render.copy_rename_replace or "",
    preset_name = settings.render.selected_preset or "Default",
    status = "",
  })
end

function M.run_folder_items_settings_window()
  if not M.has_imgui() then
    local settings = M.load_settings()
    local values = prompt_for_inputs(
      "GameAudioWorkflow Settings",
      {
        "Folder items enabled? (y/n)",
        "Auto name? (y/n)",
        "Markers enabled? (y/n)",
        "Marker mode (regions/markers)",
        "Padding",
        "Separator",
        "Include automation? (y/n)",
        "Experimental auto grouping? (y/n)",
      },
      {
        settings.folder_items.enabled and "y" or "n",
        settings.folder_items.auto_name and "y" or "n",
        settings.markers.enabled and "y" or "n",
        settings.markers.mode,
        tostring(settings.numbering.padding),
        settings.numbering.separator,
        settings.folder_items.include_automation and "y" or "n",
        settings.folder_items.experimental_auto_grouping and "y" or "n",
      }
    )
    if not values then
      return
    end
    settings.folder_items.enabled = string_to_bool(values[1], settings.folder_items.enabled)
    settings.folder_items.auto_name = string_to_bool(values[2], settings.folder_items.auto_name)
    settings.markers.enabled = string_to_bool(values[3], settings.markers.enabled)
    settings.markers.mode = normalize_rename_target(values[4]) == "markers" and "markers" or "regions"
    settings.numbering.padding = normalize_padding(values[5], settings.numbering.padding)
    settings.numbering.separator = values[6] ~= "" and values[6] or settings.numbering.separator
    settings.folder_items.include_automation = string_to_bool(values[7], settings.folder_items.include_automation)
    settings.folder_items.experimental_auto_grouping = string_to_bool(values[8], settings.folder_items.experimental_auto_grouping)
    M.save_settings(settings, "project")
    return
  end

  local settings = M.load_settings()
  run_imgui_window("Game Audio Workflow Settings", 620, 520, function(state)
    local ctx = state.ctx
    local changed

    imgui_section(ctx, "Folder Items")
    changed, settings.folder_items.enabled = reaper.ImGui_Checkbox(ctx, "Enable Folder Items", settings.folder_items.enabled)
    changed, settings.folder_items.auto_name = reaper.ImGui_Checkbox(ctx, "Auto Name", settings.folder_items.auto_name)
    changed, settings.folder_items.inherit_color = reaper.ImGui_Checkbox(ctx, "Inherit Color", settings.folder_items.inherit_color)
    changed, settings.folder_items.include_muted_tracks = reaper.ImGui_Checkbox(ctx, "Include Muted Tracks", settings.folder_items.include_muted_tracks)
    changed, settings.folder_items.include_muted_items = reaper.ImGui_Checkbox(ctx, "Include Muted Items", settings.folder_items.include_muted_items)
    changed, settings.folder_items.include_automation = reaper.ImGui_Checkbox(ctx, "Include Automation Items (Experimental)", settings.folder_items.include_automation)
    changed, settings.folder_items.experimental_auto_grouping = reaper.ImGui_Checkbox(ctx, "Experimental Auto Grouping", settings.folder_items.experimental_auto_grouping)
    changed, settings.folder_items.cluster_gap = reaper.ImGui_InputDouble(ctx, "Cluster Gap", settings.folder_items.cluster_gap or DEFAULT_CLUSTER_GAP)

    imgui_section(ctx, "Markers")
    changed, settings.markers.enabled = reaper.ImGui_Checkbox(ctx, "Enable Markers/Regions", settings.markers.enabled)
    if reaper.ImGui_Button(ctx, "Use Regions") then settings.markers.mode = "regions" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Use Markers") then settings.markers.mode = "markers" end
    reaper.ImGui_Text(ctx, "Current mode: " .. settings.markers.mode)
    changed, settings.markers.use_item_colors = reaper.ImGui_Checkbox(ctx, "Use Item Colors", settings.markers.use_item_colors)

    imgui_section(ctx, "Numbering")
    changed, settings.numbering.padding = imgui_input_int(ctx, "Padding", settings.numbering.padding, 1, 8)
    changed, settings.numbering.start = imgui_input_int(ctx, "Start", settings.numbering.start, 0, 99999)
    changed, settings.numbering.separator = reaper.ImGui_InputText(ctx, "Separator", settings.numbering.separator or "_")

    imgui_section(ctx, "Selection")
    changed, settings.selection.folder_selects_children = reaper.ImGui_Checkbox(ctx, "Folder Selects Children", settings.selection.folder_selects_children)
    changed, settings.selection.track_follows_item = reaper.ImGui_Checkbox(ctx, "Track Follows Item", settings.selection.track_follows_item)

    imgui_section(ctx, "Editing")
    changed, settings.editing.mousewheel_pitch_step = reaper.ImGui_InputDouble(ctx, "Mousewheel Pitch Step", settings.editing.mousewheel_pitch_step or 1.0, 0, 0, "%.2f")
    changed, settings.editing.mousewheel_volume_step = reaper.ImGui_InputDouble(ctx, "Mousewheel Volume Step", settings.editing.mousewheel_volume_step or 1.0, 0, 0, "%.2f")

    imgui_section(ctx, "Save")
    if reaper.ImGui_Button(ctx, "Save to Project") then
      M.save_settings(settings, "project")
      state.status = "Saved to project."
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save to Global") then
      M.save_settings(settings, "global")
      state.status = "Saved to global defaults."
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Update Folder Items Now") then
      M.update_all_folder_items(settings)
      state.status = "Folder items updated."
    end

    if state.status and state.status ~= "" then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, state.status)
    end
  end, { status = "" })
end

local function get_take_marker_positions(take)
  local positions = {}
  local marker_count = reaper.GetNumTakeMarkers(take)
  for index = 0, marker_count - 1 do
    local marker_position = reaper.GetTakeMarker(take, index)
    if marker_position and marker_position >= 0 then
      positions[#positions + 1] = marker_position
    end
  end
  table.sort(positions)
  return positions
end

local function get_take_index(item, take)
  local take_count = reaper.CountTakes(item)
  for index = 0, take_count - 1 do
    if reaper.GetTake(item, index) == take then
      return index
    end
  end
  return 0
end

local function find_next_marker_offset(positions, current_offset, direction, wrap)
  if direction > 0 then
    for _, position in ipairs(positions) do
      if position > (current_offset + 1e-7) then
        return position
      end
    end
    if wrap and #positions > 0 then
      return positions[1]
    end
  else
    for index = #positions, 1, -1 do
      if positions[index] < (current_offset - 1e-7) then
        return positions[index]
      end
    end
    if wrap and #positions > 0 then
      return positions[#positions]
    end
  end

  return nil
end

local function navigate_item_take(item, direction, settings)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return false
  end

  local positions = get_take_marker_positions(take)
  if #positions > 0 then
    local current_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local next_offset = find_next_marker_offset(positions, current_offset, direction, settings.takes.wrap_navigation)
    if next_offset ~= nil then
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", next_offset)
      return true
    end
    return false
  end

  local take_count = reaper.CountTakes(item)
  if take_count <= 1 then
    return false
  end

  local current_index = get_take_index(item, take)
  local next_index = current_index + direction
  if next_index < 0 then
    next_index = settings.takes.wrap_navigation and (take_count - 1) or 0
  elseif next_index >= take_count then
    next_index = settings.takes.wrap_navigation and 0 or (take_count - 1)
  end

  if next_index == current_index then
    return false
  end

  local next_take = reaper.GetTake(item, next_index)
  if next_take then
    reaper.SetActiveTake(next_take)
    return true
  end

  return false
end

function M.run_take_navigation(direction)
  local settings = M.load_settings()
  local selected_items = collect_selected_items()
  if #selected_items == 0 then
    reaper.ShowMessageBox("Select at least one media item.", "Game Audio Workflow Takes", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local changed = 0
  local earliest_position = math.huge
  for _, item in ipairs(selected_items) do
    earliest_position = math.min(earliest_position, reaper.GetMediaItemInfo_Value(item, "D_POSITION"))
    if navigate_item_take(item, direction, settings) then
      changed = changed + 1
    end
  end

  if changed > 0 and settings.takes.restart_playback and (reaper.GetPlayState() & 1) == 1 and earliest_position < math.huge then
    reaper.SetEditCurPos(earliest_position, false, false)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(direction > 0 and "Game Audio Workflow: Next Take" or "Game Audio Workflow: Previous Take", -1)

  if changed == 0 then
    reaper.ShowMessageBox("No take markers or alternate takes were available on the selected items.", "Game Audio Workflow Takes", 0)
  end
end

function M.run_take_random()
  local settings = M.load_settings()
  local selected_items = collect_selected_items()
  if #selected_items == 0 then
    reaper.ShowMessageBox("Select at least one media item.", "Game Audio Workflow Takes", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local changed = 0
  for _, item in ipairs(selected_items) do
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local positions = get_take_marker_positions(take)
      if #positions > 1 then
        local current_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local choices = {}
        for _, position in ipairs(positions) do
          if math.abs(position - current_offset) > 1e-7 then
            choices[#choices + 1] = position
          end
        end
        if #choices > 0 then
          local selected = choices[math.random(#choices)]
          reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", selected)
          changed = changed + 1
        end
      else
        local take_count = reaper.CountTakes(item)
        if take_count > 1 then
          local current_index = get_take_index(item, take)
          local next_index = current_index
          if take_count == 2 then
            next_index = current_index == 0 and 1 or 0
          else
            while next_index == current_index do
              next_index = math.random(0, take_count - 1)
            end
          end
          reaper.SetActiveTake(reaper.GetTake(item, next_index))
          changed = changed + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Random Take", -1)

  if changed == 0 then
    reaper.ShowMessageBox("No alternate takes or take markers were available.", "Game Audio Workflow Takes", 0)
  end
end

local function regenerate_chunk_guids(chunk)
  local lines = {}
  for line in chunk:gmatch("[^\r\n]+") do
    local prefix = line:match("^([A-Z_]*GUID)%s+")
    if prefix then
      lines[#lines + 1] = prefix .. " " .. reaper.genGuid()
    else
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

local function duplicate_item(item)
  local track = reaper.GetMediaItemTrack(item)
  if not track then
    return nil
  end

  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then
    return nil
  end

  local duplicated_item = reaper.AddMediaItemToTrack(track)
  if not duplicated_item then
    return nil
  end

  local success = reaper.SetItemStateChunk(duplicated_item, regenerate_chunk_guids(chunk), false)
  if not success then
    reaper.DeleteTrackMediaItem(track, duplicated_item)
    return nil
  end

  return duplicated_item
end

local function collect_selected_items_with_bounds()
  local items = {}
  local earliest_position = math.huge
  local latest_end = 0

  for _, item in ipairs(collect_selected_items()) do
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = position + length
    earliest_position = math.min(earliest_position, position)
    latest_end = math.max(latest_end, item_end)
    items[#items + 1] = {
      item = item,
      position = position,
      length = length,
    }
  end

  table.sort(items, function(a, b)
    if a.position == b.position then
      return get_track_index(reaper.GetMediaItemTrack(a.item)) < get_track_index(reaper.GetMediaItemTrack(b.item))
    end
    return a.position < b.position
  end)

  return items, earliest_position, latest_end
end

function M.run_duplicate_next_take()
  local settings = M.load_settings()
  local source_items, earliest_position, latest_end = collect_selected_items_with_bounds()
  if #source_items == 0 then
    reaper.ShowMessageBox("Select at least one media item.", "Game Audio Workflow Takes", 0)
    return
  end

  local offset = math.max(EMPTY_ITEM_MIN_LENGTH, latest_end - earliest_position)
  local duplicated_items = {}

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if settings.takes.ripple_on_duplicate then
    local affected_tracks = {}
    for _, source in ipairs(source_items) do
      local track = reaper.GetMediaItemTrack(source.item)
      if track then
        affected_tracks[get_track_guid(track)] = track
      end
    end

    for _, track in pairs(affected_tracks) do
      local items_to_shift = {}
      local item_count = reaper.CountTrackMediaItems(track)
      for index = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, index)
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        if position >= latest_end then
          items_to_shift[#items_to_shift + 1] = item
        end
      end
      table.sort(items_to_shift, function(a, b)
        return reaper.GetMediaItemInfo_Value(a, "D_POSITION") > reaper.GetMediaItemInfo_Value(b, "D_POSITION")
      end)
      for _, item in ipairs(items_to_shift) do
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", position + offset)
      end
    end
  end

  for _, source in ipairs(source_items) do
    local duplicate = duplicate_item(source.item)
    if duplicate then
      local new_position = source.position + offset
      reaper.SetMediaItemInfo_Value(duplicate, "D_POSITION", new_position)
      navigate_item_take(duplicate, 1, settings)
      duplicated_items[#duplicated_items + 1] = duplicate
    end
  end

  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(duplicated_items) do
    reaper.SetMediaItemSelected(item, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Duplicate and Next Take", -1)
end

local function get_take_source_length(take)
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return 0
  end
  return select(1, reaper.GetMediaSourceLength(source)) or 0
end

local function clear_take_markers_for_item(item)
  local selected_items = collect_selected_items()
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(42387, 0) -- Item: Delete take markers
  restore_item_selection(selected_items)
end

local function detect_take_marker_positions(item, take, settings)
  local source_length = get_take_source_length(take)
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local threshold = tonumber(settings.takes.source_ratio_threshold) or 1.5
  if source_length <= 0 or item_length <= 0 or source_length < item_length * threshold then
    return {}
  end

  local positions = { 0 }
  local marker_position = item_length
  local max_markers = math.max(2, math.floor(tonumber(settings.takes.max_markers) or 64))
  while marker_position < (source_length - (item_length * 0.25)) and #positions < max_markers do
    positions[#positions + 1] = marker_position
    marker_position = marker_position + item_length
  end
  return positions
end

function M.auto_add_take_markers(item, settings)
  settings = settings or M.load_settings()
  if settings.takes.disable_take_markers then
    return false
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return false
  end

  if reaper.GetNumTakeMarkers(take) > 0 then
    return false
  end

  local positions = detect_take_marker_positions(item, take, settings)
  if #positions <= 1 then
    return false
  end

  for index, position in ipairs(positions) do
    reaper.SetTakeMarker(take, -1, tostring(index), position)
  end
  return true
end

local takes_background_state = {
  last_take_key = "",
}

function M.run_takes_background()
  local function loop()
    local settings = M.load_settings()
    if settings.takes.auto_markers then
      local item = reaper.GetSelectedMediaItem(0, 0)
      if item then
        local take = reaper.GetActiveTake(item)
        local key = take and (get_item_guid(item) .. "::" .. tostring(take)) or ""
        if key ~= takes_background_state.last_take_key then
          takes_background_state.last_take_key = key
          M.auto_add_take_markers(item, settings)
        end
      else
        takes_background_state.last_take_key = ""
      end
    end

    reaper.defer(loop)
  end

  loop()
end

function M.find_takes_by_name(search_text)
  local results = {}
  local lowered = trim(search_text):lower()
  if lowered == "" then
    return results
  end

  local item_count = reaper.CountMediaItems(0)
  for index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, index)
    local take_count = reaper.CountTakes(item)
    for take_index = 0, take_count - 1 do
      local take = reaper.GetTake(item, take_index)
      local take_name = take and reaper.GetTakeName(take) or ""
      if take_name and take_name:lower():find(lowered, 1, true) then
        results[#results + 1] = {
          item = item,
          take = take,
          name = take_name,
        }
        break
      end
    end
  end

  reaper.SelectAllMediaItems(0, false)
  for _, result in ipairs(results) do
    reaper.SetMediaItemSelected(result.item, true)
  end
  if #results > 0 then
    reaper.Main_OnCommand(41622, 0)
  end

  return results
end

function M.run_take_find_window()
  local settings = M.load_settings()

  if not M.has_imgui() then
    local values = prompt_for_inputs("GameAudioWorkflow Find Takes", { "Search text" }, { settings.takes.search_text or "" })
    if not values then
      return
    end
    settings.takes.search_text = values[1]
    M.save_settings(settings, "project")
    local results = M.find_takes_by_name(values[1])
    reaper.ShowMessageBox(string.format("Found %d item(s).", #results), "Game Audio Workflow Takes", 0)
    return
  end

  run_imgui_window("Game Audio Workflow Takes Find", 520, 260, function(state)
    local ctx = state.ctx
    local changed
    changed, state.search_text = reaper.ImGui_InputText(ctx, "Search", state.search_text or "")
    if reaper.ImGui_Button(ctx, "Find") then
      local results = M.find_takes_by_name(state.search_text)
      state.status = string.format("Found %d item(s).", #results)
      settings.takes.search_text = state.search_text
      M.save_settings(settings, "project")
    end

    if state.status and state.status ~= "" then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, state.status)
    end
  end, {
    search_text = settings.takes.search_text or "",
    status = "",
  })
end

function M.run_take_reverse()
  local items = collect_selected_items()
  if #items == 0 then
    reaper.ShowMessageBox("Select at least one media item.", "Game Audio Workflow Takes", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local source_length = get_take_source_length(take)
      local saved_markers = {}
      local marker_count = reaper.GetNumTakeMarkers(take)
      for marker_index = 0, marker_count - 1 do
        local marker_position, marker_name = reaper.GetTakeMarker(take, marker_index)
        saved_markers[#saved_markers + 1] = {
          position = marker_position,
          name = marker_name or "",
        }
      end

      local selected_items_snapshot = collect_selected_items()
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(41051, 0) -- Item properties: Toggle take reverse

      if #saved_markers > 0 then
        clear_take_markers_for_item(item)
        table.sort(saved_markers, function(a, b)
          return a.position > b.position
        end)
        for _, marker in ipairs(saved_markers) do
          local reversed_position = math.max(0, source_length - marker.position)
          reaper.SetTakeMarker(take, -1, marker.name, reversed_position)
        end
      end

      restore_item_selection(selected_items_snapshot)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Reverse SMART", -1)
end

function M.run_takes_settings_window()
  local settings = M.load_settings()

  if not M.has_imgui() then
    local values = prompt_for_inputs(
      "GameAudioWorkflow TAKES Settings",
      {
        "Auto markers? (y/n)",
        "Disable markers? (y/n)",
        "Wrap navigation? (y/n)",
        "Restart playback? (y/n)",
        "Ripple duplicate? (y/n)",
        "Source ratio threshold",
        "Max markers",
      },
      {
        settings.takes.auto_markers and "y" or "n",
        settings.takes.disable_take_markers and "y" or "n",
        settings.takes.wrap_navigation and "y" or "n",
        settings.takes.restart_playback and "y" or "n",
        settings.takes.ripple_on_duplicate and "y" or "n",
        tostring(settings.takes.source_ratio_threshold),
        tostring(settings.takes.max_markers),
      }
    )
    if not values then
      return
    end
    settings.takes.auto_markers = string_to_bool(values[1], settings.takes.auto_markers)
    settings.takes.disable_take_markers = string_to_bool(values[2], settings.takes.disable_take_markers)
    settings.takes.wrap_navigation = string_to_bool(values[3], settings.takes.wrap_navigation)
    settings.takes.restart_playback = string_to_bool(values[4], settings.takes.restart_playback)
    settings.takes.ripple_on_duplicate = string_to_bool(values[5], settings.takes.ripple_on_duplicate)
    settings.takes.source_ratio_threshold = tonumber(values[6]) or settings.takes.source_ratio_threshold
    settings.takes.max_markers = normalize_number(values[7], settings.takes.max_markers)
    M.save_settings(settings, "project")
    return
  end

  run_imgui_window("Game Audio Workflow TAKES Settings", 560, 380, function(state)
    local ctx = state.ctx
    local changed
    changed, settings.takes.auto_markers = reaper.ImGui_Checkbox(ctx, "Auto Add Take Markers", settings.takes.auto_markers)
    changed, settings.takes.disable_take_markers = reaper.ImGui_Checkbox(ctx, "Disable Marker Creation", settings.takes.disable_take_markers)
    changed, settings.takes.wrap_navigation = reaper.ImGui_Checkbox(ctx, "Wrap Navigation", settings.takes.wrap_navigation)
    changed, settings.takes.restart_playback = reaper.ImGui_Checkbox(ctx, "Restart Playback Position", settings.takes.restart_playback)
    changed, settings.takes.ripple_on_duplicate = reaper.ImGui_Checkbox(ctx, "Ripple on Duplicate", settings.takes.ripple_on_duplicate)
    changed, settings.takes.source_ratio_threshold = reaper.ImGui_InputDouble(ctx, "Source Ratio Threshold", settings.takes.source_ratio_threshold or 1.5)
    changed, settings.takes.max_markers = imgui_input_int(ctx, "Max Markers", settings.takes.max_markers, 2, 512)

    if reaper.ImGui_Button(ctx, "Save to Project") then
      M.save_settings(settings, "project")
      state.status = "Saved to project."
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save to Global") then
      M.save_settings(settings, "global")
      state.status = "Saved to global defaults."
    end

    if state.status and state.status ~= "" then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, state.status)
    end
  end, { status = "" })
end

local function collect_selected_groups(settings)
  settings = settings or M.load_settings()
  local groups = {}
  local folder_items = get_selected_folder_items()

  if #folder_items > 0 then
    for _, folder_item in ipairs(folder_items) do
      local members = { folder_item }
      local children = collect_children_for_folder_item(folder_item, settings)
      local start_pos = reaper.GetMediaItemInfo_Value(folder_item, "D_POSITION")
      local end_pos = start_pos + reaper.GetMediaItemInfo_Value(folder_item, "D_LENGTH")

      for _, child in ipairs(children) do
        members[#members + 1] = child
        local child_start, child_end = get_item_time_range(child)
        start_pos = math.min(start_pos, child_start)
        end_pos = math.max(end_pos, child_end)
      end

      groups[#groups + 1] = {
        leader = folder_item,
        members = members,
        start_pos = start_pos,
        end_pos = end_pos,
      }
    end
  else
    for _, item in ipairs(collect_selected_items()) do
      local start_pos, end_pos = get_item_time_range(item)
      groups[#groups + 1] = {
        leader = item,
        members = { item },
        start_pos = start_pos,
        end_pos = end_pos,
      }
    end
  end

  table.sort(groups, function(a, b)
    return a.start_pos < b.start_pos
  end)

  return groups
end

local function move_group(group, delta)
  for _, item in ipairs(group.members or {}) do
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", position + delta)
  end
end

local function refresh_folder_items_from_selection(settings)
  local folder_tracks = collect_selected_folder_tracks_from_context()
  for _, folder_track in ipairs(folder_tracks) do
    M.update_folder_items_for_track(folder_track, settings)
  end
end

function M.run_reposition_dialog()
  local settings = M.load_settings()
  local groups = collect_selected_groups(settings)
  if #groups == 0 then
    reaper.ShowMessageBox("Select items or folder items first.", "Game Audio Workflow Reposition", 0)
    return
  end

  local values = prompt_for_inputs(
    "GameAudioWorkflow Reposition",
    { "Gap seconds" },
    { tostring(settings.editing.reposition_gap or 1.0) }
  )
  if not values then
    return
  end

  local gap = tonumber(values[1]) or settings.editing.reposition_gap or 1.0
  settings.editing.reposition_gap = gap
  M.save_settings(settings, "project")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local next_start = groups[1].start_pos
  for index, group in ipairs(groups) do
    if index == 1 then
      next_start = group.end_pos + gap
    else
      local delta = next_start - group.start_pos
      move_group(group, delta)
      local length = group.end_pos - group.start_pos
      next_start = next_start + length + gap
    end
  end

  refresh_folder_items_from_selection(settings)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Reposition", -1)
end

function M.run_reposition_preset(index)
  local settings = M.load_settings()
  local presets = settings.editing.reposition_presets or {}
  local gap = tonumber(presets[index]) or tonumber(settings.editing.reposition_gap) or 1.0
  settings.editing.reposition_gap = gap
  M.save_settings(settings, "project")

  local groups = collect_selected_groups(settings)
  if #groups == 0 then
    reaper.ShowMessageBox("Select items or folder items first.", "Game Audio Workflow Reposition", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local next_start = groups[1].start_pos
  for group_index, group in ipairs(groups) do
    if group_index == 1 then
      next_start = group.end_pos + gap
    else
      local delta = next_start - group.start_pos
      move_group(group, delta)
      local length = group.end_pos - group.start_pos
      next_start = next_start + length + gap
    end
  end
  refresh_folder_items_from_selection(settings)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Reposition Preset " .. tostring(index), -1)
end

function M.run_fade_smart()
  local settings = M.load_settings()
  local values = prompt_for_inputs(
    "GameAudioWorkflow Fade SMART",
    { "Fade in ms", "Fade out ms" },
    {
      tostring(settings.editing.fade_in_ms or 10),
      tostring(settings.editing.fade_out_ms or 10),
    }
  )
  if not values then
    return
  end

  local fade_in = math.max(0, tonumber(values[1]) or settings.editing.fade_in_ms or 10) / 1000.0
  local fade_out = math.max(0, tonumber(values[2]) or settings.editing.fade_out_ms or 10) / 1000.0
  settings.editing.fade_in_ms = fade_in * 1000.0
  settings.editing.fade_out_ms = fade_out * 1000.0
  M.save_settings(settings, "project")

  local groups = collect_selected_groups(settings)
  if #groups == 0 then
    reaper.ShowMessageBox("Select items or folder items first.", "Game Audio Workflow Fade", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for _, group in ipairs(groups) do
    for _, item in ipairs(group.members) do
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_in)
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Fade SMART", -1)
end

function M.run_trim_smart()
  local settings = M.load_settings()
  local groups = collect_selected_groups(settings)
  if #groups == 0 then
    reaper.ShowMessageBox("Select items or folder items first.", "Game Audio Workflow Trim", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local folder_items = get_selected_folder_items()
  if #folder_items > 0 then
    for _, folder_item in ipairs(folder_items) do
      local children = collect_children_for_folder_item(folder_item, settings)
      if #children > 0 then
        local start_pos = math.huge
        local end_pos = 0
        for _, child in ipairs(children) do
          local child_start, child_end = get_item_time_range(child)
          start_pos = math.min(start_pos, child_start)
          end_pos = math.max(end_pos, child_end)
        end
        reaper.SetMediaItemInfo_Value(folder_item, "D_POSITION", start_pos)
        reaper.SetMediaItemInfo_Value(folder_item, "D_LENGTH", math.max(EMPTY_ITEM_MIN_LENGTH, end_pos - start_pos))
      end
    end
  else
    for _, group in ipairs(groups) do
      local item = group.leader
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
        local start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local source_length = get_take_source_length(take)

        if snap_offset > 0 and settings.editing.trim_mode ~= "right" then
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", position + snap_offset)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(EMPTY_ITEM_MIN_LENGTH, length - snap_offset))
          reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", 0)
        end

        if source_length > 0 and settings.editing.trim_mode ~= "left" then
          local max_length = math.max(EMPTY_ITEM_MIN_LENGTH, source_length - start_offset)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.min(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), max_length))
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Trim SMART", -1)
end

function M.run_shuffle()
  local settings = M.load_settings()
  local groups = collect_selected_groups(settings)
  if #groups <= 1 then
    reaper.ShowMessageBox("Select at least two items or folder items.", "Game Audio Workflow Shuffle", 0)
    return
  end

  local positions = {}
  for index, group in ipairs(groups) do
    positions[index] = group.start_pos
  end

  math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
  for index = #positions, 2, -1 do
    local swap_index = math.random(index)
    positions[index], positions[swap_index] = positions[swap_index], positions[index]
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for index, group in ipairs(groups) do
    move_group(group, positions[index] - group.start_pos)
  end
  refresh_folder_items_from_selection(settings)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Shuffle", -1)
end

function M.run_join()
  local settings = M.load_settings()
  local folder_items = get_selected_folder_items()
  if #folder_items == 0 then
    reaper.ShowMessageBox("Select at least one folder item.", "Game Audio Workflow Join", 0)
    return
  end

  local tracks = {}
  for _, folder_item in ipairs(folder_items) do
    local track = reaper.GetMediaItemTrack(folder_item)
    local guid = get_track_guid(track)
    tracks[guid] = tracks[guid] or {
      track = track,
      items = {},
      start_pos = math.huge,
      end_pos = 0,
    }
    local entry = tracks[guid]
    local start_pos, end_pos = get_item_time_range(folder_item)
    entry.items[#entry.items + 1] = folder_item
    entry.start_pos = math.min(entry.start_pos, start_pos)
    entry.end_pos = math.max(entry.end_pos, end_pos)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, entry in pairs(tracks) do
    local item = create_folder_item(entry.track, entry.start_pos, entry.end_pos - entry.start_pos)
    set_item_name(item, get_track_name(entry.track) .. settings.numbering.separator .. "JOIN")
    for _, old_item in ipairs(entry.items) do
      reaper.DeleteTrackMediaItem(entry.track, old_item)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Join", -1)
end

function M.run_remove()
  local settings = M.load_settings()
  local folder_items = get_selected_folder_items()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if #folder_items > 0 then
    for _, folder_item in ipairs(folder_items) do
      local track = reaper.GetMediaItemTrack(folder_item)
      local children = collect_children_for_folder_item(folder_item, settings)
      for _, child in ipairs(children) do
        local child_track = reaper.GetMediaItemTrack(child)
        reaper.DeleteTrackMediaItem(child_track, child)
      end
      reaper.DeleteTrackMediaItem(track, folder_item)
    end
  else
    local items = collect_selected_items()
    if #items > 0 then
      for index = #items, 1, -1 do
        local item = items[index]
        local track = reaper.GetMediaItemTrack(item)
        reaper.DeleteTrackMediaItem(track, item)
      end
    else
      local tracks = collect_selected_tracks()
      for index = #tracks, 1, -1 do
        reaper.DeleteTrack(tracks[index])
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Remove", -1)
end

local function apply_pitch_shift(item, semitones)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local current_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", current_pitch + semitones)
  end
end

local function db_to_linear(db_value)
  return 10 ^ ((tonumber(db_value) or 0) / 20.0)
end

local function apply_volume_shift(item, delta_db)
  local current_volume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  reaper.SetMediaItemInfo_Value(item, "D_VOL", current_volume * db_to_linear(delta_db))
end

local function apply_to_selected_with_folder_children(settings, fn)
  local processed = {}
  for _, item in ipairs(collect_selected_items()) do
    local guid = get_item_guid(item)
    if not processed[guid] then
      processed[guid] = true
      if M.is_folder_item(item) then
        local children = collect_children_for_folder_item(item, settings)
        for _, child in ipairs(children) do
          local child_guid = get_item_guid(child)
          if not processed[child_guid] then
            processed[child_guid] = true
            fn(child)
          end
        end
      else
        fn(item)
      end
    end
  end
end

function M.run_mousewheel_pitch()
  local settings = M.load_settings()
  local _, _, _, _, _, _, val = reaper.get_action_context()
  if not val or val == 0 then
    return
  end

  local direction = val > 0 and 1 or -1
  local semitones = (tonumber(settings.editing.mousewheel_pitch_step) or 1.0) * direction

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  apply_to_selected_with_folder_children(settings, function(item)
    apply_pitch_shift(item, semitones)
  end)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Mousewheel Pitch", -1)
end

function M.run_mousewheel_volume()
  local settings = M.load_settings()
  local _, _, _, _, _, _, val = reaper.get_action_context()
  if not val or val == 0 then
    return
  end

  local direction = val > 0 and 1 or -1
  local delta_db = (tonumber(settings.editing.mousewheel_volume_step) or 1.0) * direction

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  apply_to_selected_with_folder_children(settings, function(item)
    apply_volume_shift(item, delta_db)
  end)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Mousewheel Volume", -1)
end

local function remove_markers_by_exact_name(name)
  for index = reaper.GetNumRegionsOrMarkers(0) - 1, 0, -1 do
    local retval, is_region, _, _, marker_name, marker_id = reaper.EnumProjectMarkers2(0, index)
    if retval > 0 and marker_name == name then
      reaper.DeleteProjectMarker(0, marker_id, is_region)
    end
  end
end

local function has_exact_marker(name)
  for index = 0, reaper.GetNumRegionsOrMarkers(0) - 1 do
    local retval, _, _, _, marker_name = reaper.EnumProjectMarkers2(0, index)
    if retval > 0 and marker_name == name then
      return true
    end
  end
  return false
end

local function get_subproject_source_path(item)
  local take = reaper.GetActiveTake(item)
  if not take then
    return nil
  end
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil
  end
  local source_type = reaper.GetMediaSourceType(source, "")
  if source_type ~= "RPP_PROJECT" then
    return nil
  end
  local file_name = reaper.GetMediaSourceFileName(source, "")
  if file_name and file_name ~= "" then
    return file_name
  end
  return nil
end

local function apply_subproject_master_fx(settings)
  local fx_names = settings.subproject.master_fx or {}
  if #fx_names == 0 then
    return
  end

  local master_track = reaper.GetMasterTrack(0)
  for _, fx_name in ipairs(fx_names) do
    local cleaned = trim(fx_name)
    if cleaned ~= "" then
      local existing = reaper.TrackFX_AddByName(master_track, cleaned, false, 0)
      if existing < 0 then
        reaper.TrackFX_AddByName(master_track, cleaned, false, -1)
      end
    end
  end
end

local function fix_subproject_markers_internal(settings, wrap_undo)
  local content_start = math.huge
  local content_end = 0

  local item_count = reaper.CountMediaItems(0)
  for index = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, index)
    local track = reaper.GetMediaItemTrack(item)
    local track_name = get_track_name(track):upper()
    if track_name ~= "VIDEO" and reaper.GetMediaTrackInfo_Value(track, "B_MUTE") < 1 then
      local start_pos, end_pos = get_item_time_range(item)
      content_start = math.min(content_start, start_pos)
      content_end = math.max(content_end, end_pos)
    end
  end

  if content_start == math.huge then
    return false
  end

  content_end = content_end + ((settings.subproject.tail_length_ms or 0) / 1000.0)

  if wrap_undo then
    reaper.Undo_BeginBlock()
  end
  remove_markers_by_exact_name("=START")
  remove_markers_by_exact_name("=END")
  reaper.AddProjectMarker(0, false, content_start, 0, "=START", -1)
  reaper.AddProjectMarker(0, false, content_end, 0, "=END", -1)
  apply_subproject_master_fx(settings)
  if wrap_undo then
    reaper.Undo_EndBlock("Game Audio Workflow: Fix Subproject Markers", -1)
  end
  return true
end

function M.run_subproject_fix_markers()
  local settings = M.load_settings()
  if not fix_subproject_markers_internal(settings, true) then
    reaper.ShowMessageBox("No unmuted content found.", "Game Audio Workflow Subproject", 0)
  end
end

local function collect_subproject_target_tracks()
  local ordered = {}
  local seen = {}

  local function add_track(track)
    if not track then
      return
    end
    local guid = get_track_guid(track)
    if seen[guid] then
      return
    end
    seen[guid] = true
    ordered[#ordered + 1] = track
  end

  for _, track in ipairs(collect_selected_tracks()) do
    add_track(track)
    if is_folder_parent(track) then
      for _, child in ipairs(collect_child_tracks(track)) do
        add_track(child)
      end
    end
  end

  if #ordered == 0 then
    for _, folder_item in ipairs(get_selected_folder_items()) do
      local track = reaper.GetMediaItemTrack(folder_item)
      add_track(track)
      for _, child in ipairs(collect_child_tracks(track)) do
        add_track(child)
      end
    end
  end

  if #ordered == 0 then
    for _, item in ipairs(collect_selected_items()) do
      add_track(reaper.GetMediaItemTrack(item))
    end
  end

  table.sort(ordered, function(a, b)
    return get_track_index(a) < get_track_index(b)
  end)

  return ordered
end

function M.run_subproject_settings_window()
  local settings = M.load_settings()

  if not M.has_imgui() then
    local values = prompt_for_inputs(
      "GameAudioWorkflow SUBPROJECT Settings",
      {
        "Tail ms",
        "Auto trim? (y/n)",
        "Auto name? (y/n)",
        "Channels",
        "Name track? (y/n)",
        "Master FX (; separated)",
      },
      {
        tostring(settings.subproject.tail_length_ms or 500),
        settings.subproject.auto_trim and "y" or "n",
        settings.subproject.auto_name and "y" or "n",
        tostring(settings.subproject.channels or 2),
        settings.subproject.name_track and "y" or "n",
        table.concat(settings.subproject.master_fx or {}, ";"),
      }
    )
    if not values then
      return
    end
    settings.subproject.tail_length_ms = normalize_number(values[1], settings.subproject.tail_length_ms)
    settings.subproject.auto_trim = string_to_bool(values[2], settings.subproject.auto_trim)
    settings.subproject.auto_name = string_to_bool(values[3], settings.subproject.auto_name)
    settings.subproject.channels = normalize_number(values[4], settings.subproject.channels)
    settings.subproject.name_track = string_to_bool(values[5], settings.subproject.name_track)
    settings.subproject.master_fx = parse_list_text((values[6] or ""):gsub(";", "\n"))
    M.save_settings(settings, "project")
    return
  end

  run_imgui_window("Game Audio Workflow SUBPROJECT Settings", 560, 360, function(state)
    local ctx = state.ctx
    local changed
    changed, settings.subproject.tail_length_ms = imgui_input_int(ctx, "Tail (ms)", settings.subproject.tail_length_ms, 0, 600000)
    changed, settings.subproject.auto_trim = reaper.ImGui_Checkbox(ctx, "Auto Trim", settings.subproject.auto_trim)
    changed, settings.subproject.auto_name = reaper.ImGui_Checkbox(ctx, "Auto Name", settings.subproject.auto_name)
    changed, settings.subproject.channels = imgui_input_int(ctx, "Channels", settings.subproject.channels, 1, 64)
    changed, settings.subproject.name_track = reaper.ImGui_Checkbox(ctx, "Name Track", settings.subproject.name_track)
    changed, state.master_fx_text = reaper.ImGui_InputTextMultiline(ctx, "Master FX", state.master_fx_text or "", 420, 100)
    settings.subproject.master_fx = parse_list_text(state.master_fx_text)

    if reaper.ImGui_Button(ctx, "Save to Project") then
      M.save_settings(settings, "project")
      state.status = "Saved to project."
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save to Global") then
      M.save_settings(settings, "global")
      state.status = "Saved to global defaults."
    end

    if state.status and state.status ~= "" then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, state.status)
    end
  end, {
    status = "",
    master_fx_text = join_list_text(settings.subproject.master_fx or {}),
  })
end

function M.run_subproject_basic()
  local settings = M.load_settings()
  local tracks = collect_subproject_target_tracks()

  if #tracks == 0 then
    M.run_subproject_fix_markers()
    return
  end

  local default_name = get_track_name(tracks[1])
  local values = prompt_for_inputs(
    "GameAudioWorkflow SUBPROJECT",
    { "Subproject name" },
    { default_name }
  )
  if not values then
    return
  end

  local subproject_name = trim(values[1])
  if subproject_name == "" then
    subproject_name = default_name
  end

  clear_track_selection()
  for _, track in ipairs(tracks) do
    reaper.SetTrackSelected(track, true)
  end

  if settings.subproject.name_track and tracks[1] then
    set_track_name(tracks[1], subproject_name)
  end

  if settings.subproject.channels and settings.subproject.channels > 0 then
    reaper.SetMediaTrackInfo_Value(tracks[1], "I_NCHAN", settings.subproject.channels)
  end

  reaper.Undo_BeginBlock()
  reaper.Main_OnCommand(41997, 0) -- Move tracks to subproject
  apply_subproject_master_fx(settings)
  if settings.subproject.auto_trim then
    fix_subproject_markers_internal(settings, false)
  end
  reaper.Undo_EndBlock("Game Audio Workflow: Create Subproject", -1)
  reaper.ShowMessageBox("Track-based subproject creation requested. Open the subproject and run FixMarkers if needed.", "Game Audio Workflow Subproject", 0)
end

function M.run_subproject_render()
  local settings = M.load_settings()

  if has_exact_marker("=START") and has_exact_marker("=END") then
    if settings.subproject.auto_trim then
      fix_subproject_markers_internal(settings, false)
    else
      apply_subproject_master_fx(settings)
    end
    reaper.Main_SaveProject(0, false)
    reaper.ShowMessageBox("Current subproject saved to trigger rerender.", "Game Audio Workflow Subproject", 0)
    return
  end

  local current_project_path = select(2, reaper.EnumProjects(-1, ""))
  local source_paths = {}
  local seen = {}
  for _, item in ipairs(collect_selected_items()) do
    local path = get_subproject_source_path(item)
    if path and not seen[path] then
      seen[path] = true
      source_paths[#source_paths + 1] = path
    end
  end

  if #source_paths == 0 then
    reaper.ShowMessageBox("Select subproject items in the main project, or run this inside a subproject.", "Game Audio Workflow Subproject", 0)
    return
  end

  for _, source_path in ipairs(source_paths) do
    reaper.Main_openProject("noprompt:" .. source_path)
    if settings.subproject.auto_trim then
      fix_subproject_markers_internal(settings, false)
    else
      apply_subproject_master_fx(settings)
    end
    reaper.Main_SaveProject(0, false)
  end

  if current_project_path and current_project_path ~= "" then
    reaper.Main_openProject("noprompt:" .. current_project_path)
  end

  reaper.ShowMessageBox(string.format("Triggered rerender for %d subproject(s).", #source_paths), "Game Audio Workflow Subproject", 0)
end

local folder_background_state = {
  last_project_state = -1,
}

function M.run_folder_items_background()
  local settings = M.load_settings()
  folder_background_state.last_project_state = reaper.GetProjectStateChangeCount(0)
  M.update_all_folder_items(settings)
  M.handle_folder_item_selection(settings, true)
  folder_background_state.last_project_state = reaper.GetProjectStateChangeCount(0)

  local function loop()
    local current_settings = M.load_settings()
    if current_settings.folder_items.enabled then
      local play_state = reaper.GetPlayState()
      local is_playing_or_recording = (play_state & 1) == 1 or (play_state & 4) == 4

      if not is_playing_or_recording then
        local current_state = reaper.GetProjectStateChangeCount(0)
        if current_state ~= folder_background_state.last_project_state then
          M.update_all_folder_items(current_settings)
          folder_background_state.last_project_state = reaper.GetProjectStateChangeCount(0)
        end

        M.handle_folder_item_selection(current_settings, false)
      end
    end

    reaper.defer(loop)
  end

  loop()
end

function M.run_folder_items_update_all()
  local settings = M.load_settings()
  reaper.Undo_BeginBlock()
  M.update_all_folder_items(settings)
  reaper.Undo_EndBlock("Game Audio Workflow: Update Folder Items", -1)
end

function M.run_folder_items_update_selected()
  local settings = M.load_settings()
  local folder_tracks = collect_selected_folder_tracks_from_context()
  if #folder_tracks == 0 then
    reaper.ShowMessageBox("Select a folder track, a child track, or items inside a folder.", "Game Audio Workflow Folder Items", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for _, folder_track in ipairs(folder_tracks) do
    M.update_folder_items_for_track(folder_track, settings)
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Game Audio Workflow: Update Selected Folder Items", -1)
end

return M
