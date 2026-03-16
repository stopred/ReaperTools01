-- Game Sound Metadata Tagger v1.0
-- Reaper ReaScript (Lua)
-- Auto-tags rendered game-audio WAV files with embedded metadata.
--
-- Usage:
-- 1. Render WAV files with REAPER Batch Renderer.
-- 2. Run this script from Actions -> Load ReaScript.
-- 3. Choose a source folder (default: project/Renders).
-- 4. Configure studio/project fields and run Tag mode.
--
-- Supported metadata:
--   BWF (bext)  - Description, Originator, Date, CodingHistory
--   iXML        - Project, note, category, keywords, custom identifiers
--   LIST-INFO   - INAM, IART, IPRD, ICOP, IKEY, ICMT and more
--
-- Requirements: REAPER v7.0+
-- Related workflow: GameSoundBatchRenderer.lua,
--                   GameSoundWorksheetGenerator.lua

local SCRIPT_TITLE = "Game Sound Metadata Tagger v1.0"
local EXT_SECTION = "GameSoundMetadata"
local MAX_RIFF_SIZE = 4294967295

local DEFAULTS = {
  mode = "tag",
  source_folder = "",
  recursive_scan = true,
  studio_name = "",
  designer_name = "",
  game_project = "",
  project_profile_name = "",
  middleware = "",
  skip_tagged = true,
  overwrite_existing = false,
  include_bext = true,
  include_ixml = true,
  include_info = true,
}

local KEYWORD_DICTIONARY = {
  SFX_Weapon = { "weapon", "combat", "attack", "hit", "fight", "battle" },
  SFX_Footstep = { "footstep", "walk", "run", "step", "movement", "foley" },
  SFX_Explosion = { "explosion", "blast", "boom", "detonate", "fire", "debris" },
  SFX_Impact = { "impact", "hit", "collision", "crash", "slam", "punch" },
  SFX_Creature = { "creature", "monster", "vocal", "growl", "roar", "beast" },
  UI_Menu = { "ui", "interface", "menu", "button", "click", "select" },
  UI_Button = { "ui", "button", "click", "tap", "press", "interface" },
  AMB_Nature = { "ambience", "nature", "outdoor", "environment", "atmosphere" },
  AMB_Indoor = { "ambience", "indoor", "room", "interior", "environment" },
  MUS_BGM = { "music", "bgm", "background", "score", "soundtrack" },
  VO_Dialogue = { "voice", "dialogue", "speech", "vocal", "character" },
  FOL_Cloth = { "foley", "cloth", "fabric", "clothing", "material" },
}

local DEFAULT_STUDIO_PROFILE = {
  studio_name = "Dekatri Studio",
  designer_name = "",
  website = "",
  email = "",
  copyright_template = "(c) {year} {studio_name}. All rights reserved.",
  default_middleware = "Wwise",
}

local DEFAULT_PROJECT_PROFILE = {
  game_project = "",
  client = "",
  middleware = "",
  description_template = "",
  custom_fields = {},
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

local function clean_text(value)
  local text = tostring(value or "")
  text = text:gsub("%z", "")
  text = text:gsub("[\r\n\t]+", " ")
  text = text:gsub("%s+", " ")
  return trim_string(text)
end

local function clone_custom_fields(list)
  local cloned = {}
  for index, field in ipairs(list or {}) do
    cloned[index] = {
      key = tostring(field.key or ""),
      value = tostring(field.value or ""),
    }
  end
  return cloned
end

local function clone_map(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    copy[key] = value
  end
  return copy
end

local function copy_studio_profile(profile)
  local result = clone_map(DEFAULT_STUDIO_PROFILE)
  for key, value in pairs(profile or {}) do
    result[key] = tostring(value or "")
  end
  return result
end

local function copy_project_profile(profile)
  local result = clone_map(DEFAULT_PROJECT_PROFILE)
  for key, value in pairs(profile or {}) do
    if key == "custom_fields" then
      result.custom_fields = clone_custom_fields(value)
    else
      result[key] = tostring(value or "")
    end
  end
  if not result.custom_fields then
    result.custom_fields = {}
  end
  return result
end


local function encode_state_value(value)
  local encoded = tostring(value or "")
  encoded = encoded:gsub("%%", "%%25")
  encoded = encoded:gsub("\r", "%%0D")
  encoded = encoded:gsub("\n", "%%0A")
  encoded = encoded:gsub("\t", "%%09")
  encoded = encoded:gsub("=", "%%3D")
  return encoded
end

local function decode_state_value(value)
  local decoded = tostring(value or "")
  decoded = decoded:gsub("%%3D", "=")
  decoded = decoded:gsub("%%09", "\t")
  decoded = decoded:gsub("%%0A", "\n")
  decoded = decoded:gsub("%%0D", "\r")
  decoded = decoded:gsub("%%25", "%%")
  return decoded
end

local function serialize_string_map(map)
  local keys = {}
  for key in pairs(map or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local lines = {}
  for _, key in ipairs(keys) do
    lines[#lines + 1] = encode_state_value(key) .. "=" .. encode_state_value(map[key])
  end
  return table.concat(lines, "\n")
end

local function deserialize_string_map(serialized)
  local map = {}
  local text = tostring(serialized or "")
  if text == "" then
    return map
  end

  for line in text:gmatch("[^\n]+") do
    local sep = line:find("=", 1, true)
    if sep then
      local key = decode_state_value(line:sub(1, sep - 1))
      local value = decode_state_value(line:sub(sep + 1))
      map[key] = value
    end
  end
  return map
end

local function serialize_string_list(items)
  local lines = {}
  for _, item in ipairs(items or {}) do
    lines[#lines + 1] = encode_state_value(item)
  end
  return table.concat(lines, "\n")
end

local function deserialize_string_list(serialized)
  local items = {}
  local text = tostring(serialized or "")
  if text == "" then
    return items
  end

  for line in text:gmatch("[^\n]+") do
    items[#items + 1] = decode_state_value(line)
  end
  return items
end

local function clone_keyword_dictionary(dictionary)
  local copy = {}
  for key, keywords in pairs(dictionary or {}) do
    copy[key] = {}
    for index, keyword in ipairs(keywords or {}) do
      copy[key][index] = tostring(keyword or "")
    end
  end
  return copy
end

local function split_keywords_csv(value)
  local keywords = {}
  local seen = {}
  for token in tostring(value or ""):gmatch("[^,]+") do
    local keyword = trim_string(token):lower()
    if keyword ~= "" and not seen[keyword] then
      seen[keyword] = true
      keywords[#keywords + 1] = keyword
    end
  end
  return keywords
end

local function join_keywords_csv(keywords)
  return table.concat(keywords or {}, ", ")
end

local function load_keyword_dictionary()
  local raw = reaper.GetExtState(EXT_SECTION, "keyword_dictionary")
  if raw == "" then
    return clone_keyword_dictionary(KEYWORD_DICTIONARY)
  end

  local decoded = deserialize_string_map(raw)
  local dictionary = {}
  for key, value in pairs(decoded) do
    dictionary[key] = split_keywords_csv(value)
  end
  return dictionary
end

local function save_keyword_dictionary(dictionary)
  local serialized = {}
  for key, keywords in pairs(dictionary or {}) do
    serialized[key] = join_keywords_csv(keywords)
  end
  reaper.SetExtState(EXT_SECTION, "keyword_dictionary", serialize_string_map(serialized), true)
end

local function get_sorted_keyword_keys(dictionary)
  local keys = {}
  for key in pairs(dictionary or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return left:lower() < right:lower()
  end)
  return keys
end

local function serialize_custom_fields(fields)
  local lines = {}
  for _, field in ipairs(fields or {}) do
    local key = trim_string(field.key)
    local value = tostring(field.value or "")
    if key ~= "" then
      lines[#lines + 1] = encode_state_value(key) .. "\t" .. encode_state_value(value)
    end
  end
  return table.concat(lines, "\n")
end

local function deserialize_custom_fields(serialized)
  local fields = {}
  local text = tostring(serialized or "")
  if text == "" then
    return fields
  end

  for line in text:gmatch("[^\n]+") do
    local sep = line:find("\t", 1, true)
    if sep then
      fields[#fields + 1] = {
        key = decode_state_value(line:sub(1, sep - 1)),
        value = decode_state_value(line:sub(sep + 1)),
      }
    else
      fields[#fields + 1] = {
        key = decode_state_value(line),
        value = "",
      }
    end
  end

  return fields
end

local function sanitize_extstate_key_fragment(value)
  return encode_state_value(trim_string(value or ""))
end

local function project_profile_ext_key(name)
  return "project_profile_" .. sanitize_extstate_key_fragment(name)
end

local function load_project_profile_names()
  local raw = reaper.GetExtState(EXT_SECTION, "project_profile_names")
  local names = deserialize_string_list(raw)
  table.sort(names, function(left, right)
    return left:lower() < right:lower()
  end)
  return names
end

local function save_project_profile_names(names)
  reaper.SetExtState(EXT_SECTION, "project_profile_names", serialize_string_list(names), true)
end

local function upsert_project_profile_name(name)
  local trimmed = trim_string(name)
  if trimmed == "" then
    return
  end

  local names = load_project_profile_names()
  for _, existing in ipairs(names) do
    if existing == trimmed then
      return
    end
  end
  names[#names + 1] = trimmed
  table.sort(names, function(left, right)
    return left:lower() < right:lower()
  end)
  save_project_profile_names(names)
end

local function remove_project_profile_name(name)
  local trimmed = trim_string(name)
  local names = load_project_profile_names()
  local kept = {}
  for _, existing in ipairs(names) do
    if existing ~= trimmed then
      kept[#kept + 1] = existing
    end
  end
  save_project_profile_names(kept)
end

local function save_studio_profile(profile)
  local data = serialize_string_map({
    studio_name = profile.studio_name or "",
    designer_name = profile.designer_name or "",
    website = profile.website or "",
    email = profile.email or "",
    copyright_template = profile.copyright_template or "",
    default_middleware = profile.default_middleware or "",
  })
  reaper.SetExtState(EXT_SECTION, "studio_profile", data, true)
end

local function load_studio_profile()
  local raw = reaper.GetExtState(EXT_SECTION, "studio_profile")
  if raw == "" then
    return copy_studio_profile(DEFAULT_STUDIO_PROFILE)
  end
  return copy_studio_profile(deserialize_string_map(raw))
end

local function save_project_profile(name, profile)
  local trimmed = trim_string(name)
  if trimmed == "" then
    return false, "Profile name is required."
  end

  local data = serialize_string_map({
    game_project = profile.game_project or "",
    client = profile.client or "",
    middleware = profile.middleware or "",
    description_template = profile.description_template or "",
    custom_fields = serialize_custom_fields(profile.custom_fields or {}),
  })

  reaper.SetExtState(EXT_SECTION, project_profile_ext_key(trimmed), data, true)
  upsert_project_profile_name(trimmed)
  return true
end

local function load_project_profile(name)
  local trimmed = trim_string(name)
  if trimmed == "" then
    return copy_project_profile(DEFAULT_PROJECT_PROFILE)
  end

  local raw = reaper.GetExtState(EXT_SECTION, project_profile_ext_key(trimmed))
  if raw == "" then
    return copy_project_profile(DEFAULT_PROJECT_PROFILE)
  end

  local decoded = deserialize_string_map(raw)
  decoded.custom_fields = deserialize_custom_fields(decoded.custom_fields or "")
  return copy_project_profile(decoded)
end

local function delete_project_profile(name)
  local trimmed = trim_string(name)
  if trimmed == "" then
    return false, "Profile name is required."
  end

  reaper.DeleteExtState(EXT_SECTION, project_profile_ext_key(trimmed), true)
  remove_project_profile_name(trimmed)
  return true
end

local function normalize_custom_field_key(value)
  local key = trim_string(value):gsub("%s+", "_")
  key = key:gsub("[^%w_]", "_")
  key = key:gsub("_+", "_")
  key = key:gsub("^_+", "")
  key = key:gsub("_+$", "")
  return key
end

local function sanitize_xml_tag_name(value)
  local key = normalize_custom_field_key(value)
  if key == "" then
    return nil
  end
  if not key:match("^[A-Za-z_]") then
    key = "_" .. key
  end
  return key
end

local function humanize_name(value)
  local text = strip_extension(value)
  text = text:gsub("[_%-]+", " ")
  text = text:gsub("%s+", " ")
  return trim_string(text)
end

local function normalize_lookup_key(value)
  local key = strip_extension(value):lower()
  key = key:gsub("%s+", " ")
  key = key:gsub("^%s+", "")
  key = key:gsub("%s+$", "")
  return key
end

local function get_default_render_path()
  return join_paths(reaper.GetProjectPath(""), "Renders")
end

local function resolve_source_folder(settings)
  local configured = trim_string(settings.source_folder)
  if configured == "" then
    return get_default_render_path()
  end
  if is_absolute_path(configured) then
    return normalize_path(configured)
  end
  return join_paths(reaper.GetProjectPath(""), configured)
end

local function parse_mode(value, default_value)
  local lowered = trim_string(value):lower()
  if lowered == "tag" or lowered == "t" then
    return "tag"
  end
  if lowered == "verify" or lowered == "v" then
    return "verify"
  end
  if lowered == "read" or lowered == "r" then
    return "read"
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
    else
      settings[key] = stored
    end
  end
  settings.mode = parse_mode(settings.mode, DEFAULTS.mode)
  return settings
end

local function save_settings(settings)
  for key, value in pairs(settings) do
    local encoded = value
    if type(value) == "boolean" then
      encoded = bool_to_string(value)
    elseif type(value) == "table" and key == "custom_fields" then
      encoded = serialize_custom_fields(value)
    elseif type(value) == "table" then
      encoded = nil
    end
    if encoded ~= nil then
      reaper.SetExtState(EXT_SECTION, key, tostring(encoded), true)
    end
  end
end

local function prompt_for_settings(current)
  local captions = table.concat({
    "separator=|",
    "extrawidth=280",
    "Mode (tag/verify/read)",
    "Source Folder (empty=Renders)",
    "Recursive Scan (yes/no)",
    "Studio Name",
    "Designer Name",
    "Game Project",
    "Middleware (Wwise/FMOD/Other)",
    "Skip Already Tagged (yes/no)",
    "Overwrite Existing Metadata (yes/no)",
    "Include bext (yes/no)",
    "Include iXML (yes/no)",
    "Include LIST-INFO (yes/no)",
  }, ",")

  local defaults = table.concat({
    current.mode,
    current.source_folder,
    bool_to_string(current.recursive_scan),
    current.studio_name,
    current.designer_name,
    current.game_project,
    current.middleware,
    bool_to_string(current.skip_tagged),
    bool_to_string(current.overwrite_existing),
    bool_to_string(current.include_bext),
    bool_to_string(current.include_ixml),
    bool_to_string(current.include_info),
  }, "|")

  local ok, values = reaper.GetUserInputs(SCRIPT_TITLE, 12, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(values, "|", 12)
  local settings = {}
  settings.mode = parse_mode(parts[1], current.mode)
  settings.source_folder = trim_string(parts[2])
  settings.recursive_scan = parse_boolean(parts[3], current.recursive_scan)
  settings.studio_name = clean_text(parts[4])
  settings.designer_name = clean_text(parts[5])
  settings.game_project = clean_text(parts[6])
  settings.middleware = clean_text(parts[7])
  settings.skip_tagged = parse_boolean(parts[8], current.skip_tagged)
  settings.overwrite_existing = parse_boolean(parts[9], current.overwrite_existing)
  settings.include_bext = parse_boolean(parts[10], current.include_bext)
  settings.include_ixml = parse_boolean(parts[11], current.include_ixml)
  settings.include_info = parse_boolean(parts[12], current.include_info)

  if settings.overwrite_existing then
    settings.skip_tagged = false
  end

  if settings.mode == nil then
    return nil, "Mode must be tag, verify, or read."
  end

  if settings.mode == "tag" and not (settings.include_bext or settings.include_ixml or settings.include_info) then
    return nil, "At least one metadata chunk must be enabled in tag mode."
  end

  return settings
end

local function show_error(message)
  reaper.ShowMessageBox(tostring(message or "Unknown error."), SCRIPT_TITLE, 0)
end

local function scan_directory_for_wav(dir_path, recursive, accumulator)
  local files = accumulator or {}
  local normalized = normalize_path(dir_path)

  local file_index = 0
  while true do
    local filename = reaper.EnumerateFiles(normalized, file_index)
    if not filename then
      break
    end

    if filename:lower():match("%.wav$") then
      files[#files + 1] = {
        path = join_paths(normalized, filename),
        name = filename,
        dir = normalized,
      }
    end

    file_index = file_index + 1
  end

  if recursive then
    local sub_index = 0
    while true do
      local subdir = reaper.EnumerateSubdirectories(normalized, sub_index)
      if not subdir then
        break
      end
      scan_directory_for_wav(join_paths(normalized, subdir), true, files)
      sub_index = sub_index + 1
    end
  end

  return files
end

local function collect_target_files(settings)
  local files = scan_directory_for_wav(resolve_source_folder(settings), settings.recursive_scan)
  table.sort(files, function(left, right)
    return left.path:lower() < right.path:lower()
  end)
  return files
end

local function get_project_name()
  local _, project_path = reaper.EnumProjects(-1, "")
  if project_path and project_path ~= "" then
    return project_path:match("([^/\\]+)%.RPP$") or project_path:match("([^/\\]+)%.rpp$") or "Untitled"
  end
  return "Untitled"
end

local function collect_regions()
  local regions = {}
  local count = reaper.GetNumRegionsOrMarkers(0)

  for index = 0, count - 1 do
    local region_or_marker = reaper.GetRegionOrMarker(0, index, "")
    if region_or_marker and reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "B_ISREGION") > 0.5 then
      local _, name = reaper.GetSetRegionOrMarkerInfo_String(0, region_or_marker, "P_NAME", "", false)
      regions[#regions + 1] = {
        object = region_or_marker,
        name = clean_text(name),
        start_pos = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_STARTPOS"),
        end_pos = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_ENDPOS"),
      }
    end
  end

  table.sort(regions, function(left, right)
    if left.start_pos == right.start_pos then
      return left.name < right.name
    end
    return left.start_pos < right.start_pos
  end)

  return regions
end

local function build_region_lookup(regions)
  local lookup = {}
  for _, region in ipairs(regions) do
    if not is_blank(region.name) then
      local key = normalize_lookup_key(region.name)
      if lookup[key] == nil then
        lookup[key] = region
      end
    end
  end
  return lookup
end

local function find_matching_region(file_name, region_lookup)
  local basename = normalize_lookup_key(file_name)
  local direct = region_lookup[basename]
  if direct then
    return direct
  end

  local without_variation = basename:gsub("_(%d+)$", "")
  if without_variation ~= basename then
    return region_lookup[without_variation]
  end

  return nil
end

local function parse_filename(filename)
  local name = strip_extension(filename)
  local prefix, category, asset_name, variation = name:match("^(%a+)_([^_]+)_(.+)_(%d+)$")
  if prefix then
    return prefix:upper(), category, asset_name, variation
  end

  prefix, category, asset_name = name:match("^(%a+)_([^_]+)_(.+)$")
  if prefix then
    return prefix:upper(), category, asset_name, nil
  end

  return nil, nil, name, nil
end

local function add_keyword(keywords, seen, value)
  local cleaned = trim_string(tostring(value or "")):lower()
  if cleaned == "" or seen[cleaned] then
    return
  end
  seen[cleaned] = true
  keywords[#keywords + 1] = cleaned
end

local function generate_keywords(meta, keyword_dictionary)
  local keywords = {}
  local seen = {}
  local category_key = ""

  if not is_blank(meta.prefix) and not is_blank(meta.category) then
    category_key = meta.prefix .. "_" .. meta.category
  end

  local dictionary = keyword_dictionary or KEYWORD_DICTIONARY
  local dict_keywords = dictionary[category_key]
  if dict_keywords then
    for _, keyword in ipairs(dict_keywords) do
      add_keyword(keywords, seen, keyword)
    end
  end

  if not is_blank(meta.asset_name) then
    for word in meta.asset_name:gmatch("[^_%-]+") do
      add_keyword(keywords, seen, word)
    end
  end

  add_keyword(keywords, seen, meta.prefix)
  add_keyword(keywords, seen, meta.category)
  add_keyword(keywords, seen, meta.game_project)

  if meta.region_name and meta.region_name ~= meta.filename_no_ext then
    for word in meta.region_name:gmatch("[^_%- %./\\]+") do
      add_keyword(keywords, seen, word)
    end
  end

  return table.concat(keywords, ", ")
end

local function generate_unique_id(meta)
  local studio_code = (meta.studio_name or "STUDIO"):upper():gsub("%s+", ""):gsub("[^A-Z0-9]", "")
  if studio_code == "" then
    studio_code = "STUDIO"
  end
  studio_code = studio_code:sub(1, 6)

  local date_part = os.date("%Y%m%d_%H%M%S")
  local random_part = string.format("%04d", math.random(0, 9999))
  return studio_code .. "_" .. date_part .. "_" .. random_part
end

local function build_asset_description(meta)
  local descriptive = humanize_name(meta.asset_name or meta.filename_no_ext)
  if descriptive ~= "" then
    return descriptive
  end
  if not is_blank(meta.region_name) then
    return humanize_name(meta.region_name)
  end
  return humanize_name(meta.filename_no_ext)
end

local function build_bext_description(meta)
  local identity = {}
  if not is_blank(meta.prefix) then
    identity[#identity + 1] = meta.prefix
  end
  if not is_blank(meta.category) then
    identity[#identity + 1] = meta.category
  end
  if not is_blank(meta.asset_name) then
    identity[#identity + 1] = meta.asset_name
  end

  local head = table.concat(identity, "_")
  local detail = clean_text(meta.description or "")

  if head ~= "" and detail ~= "" then
    return head .. " - " .. detail
  end
  if head ~= "" then
    return head
  end
  if detail ~= "" then
    return detail
  end
  return meta.filename_no_ext or ""
end

local function build_template_context(meta)
  return {
    prefix = meta.prefix or "",
    category = meta.category or "",
    asset_name = meta.asset_name or "",
    variation = meta.variation or "",
    variation_number = meta.variation or "",
    filename = meta.filename or "",
    filename_no_ext = meta.filename_no_ext or "",
    region_name = meta.region_name or "",
    project_name = meta.project_name or "",
    render_date = meta.render_date or "",
    render_time = meta.render_time or "",
    year = meta.year or "",
    studio_name = meta.studio_name or "",
    designer_name = meta.designer_name or "",
    game_project = meta.game_project or "",
    game_project_name = meta.game_project or "",
    middleware = meta.middleware or "",
    client = meta.client or "",
    description = meta.description or "",
    asset_description = meta.description or "",
    keywords = meta.keywords or "",
    unique_id = meta.unique_id or "",
  }
end

local function expand_template_string(template, meta)
  local text = tostring(template or "")
  if text == "" then
    return ""
  end

  local context = build_template_context(meta)
  text = text:gsub("{([%w_]+)}", function(token)
    return tostring(context[token] or "")
  end)
  return clean_text(text)
end

local function build_custom_field_payload(fields, meta)
  local payload = {}
  for _, field in ipairs(fields or {}) do
    local key = sanitize_xml_tag_name(field.key)
    if key then
      local value = expand_template_string(field.value, meta)
      if value ~= "" then
        payload[#payload + 1] = {
          key = key,
          value = value,
          raw_key = field.key,
        }
      end
    end
  end
  return payload
end

local function extract_metadata_from_project(rendered_files, settings)
  local metadata_list = {}
  local project_name = get_project_name()
  local regions = collect_regions()
  local region_lookup = build_region_lookup(regions)
  local keyword_dictionary = settings.keyword_dictionary or load_keyword_dictionary()

  for _, file_info in ipairs(rendered_files) do
    local prefix, category, asset_name, variation = parse_filename(file_info.name)
    local region = find_matching_region(file_info.name, region_lookup)
    local meta = {
      filepath = file_info.path,
      filename = file_info.name,
      filename_no_ext = strip_extension(file_info.name),
      dir = file_info.dir,
      prefix = prefix,
      category = category,
      asset_name = asset_name,
      variation = variation,
      region_name = region and region.name or nil,
      region_start = region and region.start_pos or 0,
      region_end = region and region.end_pos or 0,
      project_name = project_name,
      render_date = os.date("%Y-%m-%d"),
      render_time = os.date("%H:%M:%S"),
      year = os.date("%Y"),
      studio_name = settings.studio_name,
      designer_name = settings.designer_name,
      game_project = settings.game_project,
      client = settings.client,
      website = settings.website,
      email = settings.email,
      middleware = settings.middleware,
      description_template = settings.description_template,
      copyright_template = settings.copyright_template,
    }

    meta.description = build_asset_description(meta)
    meta.keywords = generate_keywords(meta, keyword_dictionary)
    meta.unique_id = generate_unique_id(meta)

    if not is_blank(settings.description_template) then
      meta.description = expand_template_string(settings.description_template, meta)
    end

    meta.keywords = generate_keywords(meta, keyword_dictionary)
    meta.bext_description = build_bext_description(meta)
    meta.custom_fields = build_custom_field_payload(settings.custom_fields, meta)
    meta.copyright = expand_template_string(settings.copyright_template, meta)
    metadata_list[#metadata_list + 1] = meta
  end

  return metadata_list
end

local function bytes_to_uint16_le(bytes)
  local b1, b2 = bytes:byte(1, 2)
  if not b1 or not b2 then
    return 0
  end
  return b1 + b2 * 256
end

local function bytes_to_uint32_le(bytes)
  local b1, b2, b3, b4 = bytes:byte(1, 4)
  if not b1 or not b2 or not b3 or not b4 then
    return 0
  end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function uint16_to_bytes_le(value)
  local n = math.floor(tonumber(value) or 0)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256
  )
end

local function uint32_to_bytes_le(value)
  local n = math.floor(tonumber(value) or 0)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local function uint64_to_bytes_le(value)
  local n = math.floor(tonumber(value) or 0)
  local low = n % 4294967296
  local high = math.floor(n / 4294967296)
  return uint32_to_bytes_le(low) .. uint32_to_bytes_le(high)
end

local function trim_null(value)
  return tostring(value or ""):match("^(.-)%z*$") or tostring(value or "")
end

local function parse_wav_chunks(wav_data)
  if wav_data:sub(1, 4) == "RF64" then
    return nil, "RF64 files are not supported."
  end

  if wav_data:sub(1, 4) ~= "RIFF" or wav_data:sub(9, 12) ~= "WAVE" then
    return nil, "Not a valid RIFF/WAVE file."
  end

  local parsed = {
    chunks = {},
    fmt = nil,
    data = nil,
    bext = nil,
    ixml = nil,
    info = nil,
  }

  local pos = 13
  local total_length = #wav_data

  while pos + 7 <= total_length do
    local chunk_id = wav_data:sub(pos, pos + 3)
    local chunk_size = bytes_to_uint32_le(wav_data:sub(pos + 4, pos + 7))
    local data_start = pos + 8
    local data_end = data_start + chunk_size - 1

    if data_end > total_length then
      return nil, "Encountered a truncated WAV chunk."
    end

    local chunk = {
      id = chunk_id,
      size = chunk_size,
      data = wav_data:sub(data_start, data_end),
    }

    if chunk_id == "LIST" then
      chunk.list_type = chunk.data:sub(1, 4)
      if chunk.list_type == "INFO" then
        parsed.info = chunk
      end
    elseif chunk_id == "fmt " then
      parsed.fmt = chunk
    elseif chunk_id == "data" then
      parsed.data = chunk
    elseif chunk_id == "bext" then
      parsed.bext = chunk
    elseif chunk_id == "iXML" then
      parsed.ixml = chunk
    end

    parsed.chunks[#parsed.chunks + 1] = chunk
    pos = data_end + 1
    if chunk_size % 2 == 1 then
      pos = pos + 1
    end
  end

  if not parsed.fmt or not parsed.data then
    return nil, "Missing fmt or data chunk."
  end

  return parsed
end

local function parse_fmt_chunk(fmt_chunk)
  if not fmt_chunk or fmt_chunk.size < 16 then
    return {
      audio_format = 1,
      channels = 2,
      sample_rate = 48000,
      bit_depth = 24,
    }
  end

  return {
    audio_format = bytes_to_uint16_le(fmt_chunk.data:sub(1, 2)),
    channels = bytes_to_uint16_le(fmt_chunk.data:sub(3, 4)),
    sample_rate = bytes_to_uint32_le(fmt_chunk.data:sub(5, 8)),
    bit_depth = bytes_to_uint16_le(fmt_chunk.data:sub(15, 16)),
  }
end

local function audio_format_label(audio_format)
  if audio_format == 1 then
    return "PCM"
  end
  if audio_format == 3 then
    return "IEEE_FLOAT"
  end
  return tostring(audio_format or 1)
end

local function channel_label(channels)
  if channels == 1 then
    return "mono"
  end
  if channels == 2 then
    return "stereo"
  end
  return tostring(channels or 0) .. "ch"
end

local function pad_string(value, length)
  local text = clean_text(value or "")
  if #text >= length then
    return text:sub(1, length)
  end
  return text .. string.rep("\0", length - #text)
end

local function xml_escape(value)
  local text = tostring(value or "")
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  text = text:gsub('"', "&quot;")
  text = text:gsub("'", "&apos;")
  return text
end

local function build_bext_chunk(meta)
  local time_reference_samples = 0
  if meta.region_start and meta.sample_rate and meta.region_start > 0 and meta.sample_rate > 0 then
    time_reference_samples = math.floor(meta.region_start * meta.sample_rate + 0.5)
  end

  local coding_history = clean_text(meta.coding_history or "")
  if coding_history == "" then
    coding_history = string.format(
      "A=%s,F=%s,W=%s,M=%s,T=REAPER\r\n",
      audio_format_label(meta.audio_format),
      tostring(meta.sample_rate or 48000),
      tostring(meta.bit_depth or 24),
      channel_label(meta.channels)
    )
  elseif not coding_history:match("\r\n$") then
    coding_history = coding_history .. "\r\n"
  end

  local data = table.concat({
    pad_string(meta.bext_description or meta.description or "", 256),
    pad_string(meta.studio_name or "", 32),
    pad_string(meta.unique_id or "", 32),
    pad_string(meta.render_date or os.date("%Y-%m-%d"), 10),
    pad_string(meta.render_time or os.date("%H:%M:%S"), 8),
    uint64_to_bytes_le(time_reference_samples),
    uint16_to_bytes_le(1),
    string.rep("\0", 64),
    uint16_to_bytes_le(0),
    uint16_to_bytes_le(0),
    uint16_to_bytes_le(0),
    uint16_to_bytes_le(0),
    uint16_to_bytes_le(0),
    string.rep("\0", 180),
    coding_history,
  })

  return {
    id = "bext",
    size = #data,
    data = data,
  }
end

local function build_ixml_chunk(meta)
  local category_value = ""
  if not is_blank(meta.prefix) and not is_blank(meta.category) then
    category_value = meta.prefix .. "_" .. meta.category
  end

  local xml_lines = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<BWFXML>",
    "  <IXML_VERSION>1.5</IXML_VERSION>",
    "  <PROJECT>" .. xml_escape(meta.project_name or "") .. "</PROJECT>",
    "  <NOTE>" .. xml_escape(meta.description or "") .. "</NOTE>",
    "  <USER>",
    "    <CATEGORY>" .. xml_escape(category_value) .. "</CATEGORY>",
    "    <SUBCATEGORY>" .. xml_escape(meta.category or "") .. "</SUBCATEGORY>",
    "    <ASSET_NAME>" .. xml_escape(meta.asset_name or meta.filename_no_ext or "") .. "</ASSET_NAME>",
    "    <VARIATION>" .. xml_escape(meta.variation or "") .. "</VARIATION>",
    "    <DESIGNER>" .. xml_escape(meta.designer_name or "") .. "</DESIGNER>",
    "    <STUDIO>" .. xml_escape(meta.studio_name or "") .. "</STUDIO>",
    "    <GAME_PROJECT>" .. xml_escape(meta.game_project or "") .. "</GAME_PROJECT>",
    "    <CLIENT>" .. xml_escape(meta.client or "") .. "</CLIENT>",
    "    <WEBSITE>" .. xml_escape(meta.website or "") .. "</WEBSITE>",
    "    <EMAIL>" .. xml_escape(meta.email or "") .. "</EMAIL>",
    "    <MIDDLEWARE>" .. xml_escape(meta.middleware or "") .. "</MIDDLEWARE>",
    "    <KEYWORDS>" .. xml_escape(meta.keywords or "") .. "</KEYWORDS>",
    "    <UNIQUE_ID>" .. xml_escape(meta.unique_id or "") .. "</UNIQUE_ID>",
    "    <SOURCE_FILE>" .. xml_escape(meta.filename or "") .. "</SOURCE_FILE>",
  }

  for _, field in ipairs(meta.custom_fields or {}) do
    xml_lines[#xml_lines + 1] = "    <" .. field.key .. ">" .. xml_escape(field.value) .. "</" .. field.key .. ">"
  end

  xml_lines[#xml_lines + 1] = "  </USER>"
  xml_lines[#xml_lines + 1] = "</BWFXML>"

  local data = table.concat(xml_lines, "\n")
  return {
    id = "iXML",
    size = #data,
    data = data,
  }
end

local function build_list_info_chunk(meta)
  local info_fields = {
    { "INAM", meta.region_name or meta.filename_no_ext or "" },
    { "IART", meta.designer_name ~= "" and meta.designer_name or meta.studio_name or "" },
    { "IPRD", meta.game_project or meta.project_name or "" },
    { "ICRD", meta.render_date or "" },
    { "IGNR", (not is_blank(meta.prefix) and not is_blank(meta.category)) and (meta.prefix .. "_" .. meta.category) or (meta.category or "") },
    { "ISFT", "REAPER + GameSound Pipeline" },
    { "ICOP", meta.copyright ~= "" and meta.copyright or string.format("(c) %s %s", meta.year or os.date("%Y"), meta.studio_name or "") },
    { "IKEY", meta.keywords or "" },
    { "ICMT", meta.description or "" },
    { "ISBJ", meta.asset_name or meta.filename_no_ext or "" },
  }

  local sub_chunks = {}

  for _, field in ipairs(info_fields) do
    local value = clean_text(field[2])
    if value ~= "" then
      local encoded = value .. "\0"
      if #encoded % 2 == 1 then
        encoded = encoded .. "\0"
      end

      sub_chunks[#sub_chunks + 1] = field[1]
      sub_chunks[#sub_chunks + 1] = uint32_to_bytes_le(#encoded)
      sub_chunks[#sub_chunks + 1] = encoded
    end
  end

  local data = "INFO" .. table.concat(sub_chunks)
  return {
    id = "LIST",
    size = #data,
    data = data,
    list_type = "INFO",
  }
end

local function write_chunk(chunk)
  local result = chunk.id .. uint32_to_bytes_le(chunk.size) .. chunk.data
  if chunk.size % 2 == 1 then
    result = result .. "\0"
  end
  return result
end

local function should_replace_chunk(chunk, replacements)
  if chunk.id == "bext" and replacements.bext then
    return true
  end
  if chunk.id == "iXML" and replacements.ixml then
    return true
  end
  if chunk.id == "LIST" and chunk.list_type == "INFO" and replacements.info then
    return true
  end
  return false
end

local function build_replacement_list(replacements)
  local ordered = {}
  if replacements.bext then
    ordered[#ordered + 1] = replacements.bext
  end
  if replacements.ixml then
    ordered[#ordered + 1] = replacements.ixml
  end
  if replacements.info then
    ordered[#ordered + 1] = replacements.info
  end
  return ordered
end

local function reassemble_wav(parsed, replacements)
  local ordered_replacements = build_replacement_list(replacements)
  local body_parts = {}
  local inserted = false

  for _, chunk in ipairs(parsed.chunks) do
    if not should_replace_chunk(chunk, replacements) then
      body_parts[#body_parts + 1] = write_chunk(chunk)
      if chunk.id == "fmt " and not inserted then
        for _, replacement in ipairs(ordered_replacements) do
          body_parts[#body_parts + 1] = write_chunk(replacement)
        end
        inserted = true
      end
    end
  end

  if not inserted then
    local fallback_parts = {}
    for _, replacement in ipairs(ordered_replacements) do
      fallback_parts[#fallback_parts + 1] = write_chunk(replacement)
    end
    for _, existing in ipairs(body_parts) do
      fallback_parts[#fallback_parts + 1] = existing
    end
    body_parts = fallback_parts
  end

  local body = table.concat(body_parts)
  local riff_size = 4 + #body
  if riff_size > MAX_RIFF_SIZE then
    return nil, "RIFF size exceeds 4 GB. RF64 rewrite is not supported."
  end

  return "RIFF" .. uint32_to_bytes_le(riff_size) .. "WAVE" .. body
end

local function parse_bext_data(data)
  return {
    description = clean_text(trim_null(data:sub(1, 256))),
    originator = clean_text(trim_null(data:sub(257, 288))),
    originator_ref = clean_text(trim_null(data:sub(289, 320))),
    origination_date = clean_text(trim_null(data:sub(321, 330))),
    origination_time = clean_text(trim_null(data:sub(331, 338))),
  }
end

local function parse_info_data(data)
  local fields = {}
  if data:sub(1, 4) ~= "INFO" then
    return fields
  end

  local pos = 5
  while pos + 7 <= #data do
    local chunk_id = data:sub(pos, pos + 3)
    local chunk_size = bytes_to_uint32_le(data:sub(pos + 4, pos + 7))
    local data_start = pos + 8
    local data_end = data_start + chunk_size - 1
    if data_end > #data then
      break
    end

    fields[chunk_id] = clean_text(trim_null(data:sub(data_start, data_end)))
    pos = data_end + 1
    if chunk_size % 2 == 1 then
      pos = pos + 1
    end
  end

  return fields
end

local function read_existing_metadata(filepath)
  local file = io.open(filepath, "rb")
  if not file then
    return nil, "Cannot open file."
  end

  local wav_data = file:read("*a")
  file:close()

  local parsed, parse_error = parse_wav_chunks(wav_data)
  if not parsed then
    return nil, parse_error
  end

  local result = {
    has_bext = parsed.bext ~= nil,
    has_ixml = parsed.ixml ~= nil,
    has_info = parsed.info ~= nil,
  }

  if parsed.bext then
    result.bext = parse_bext_data(parsed.bext.data)
  end
  if parsed.info then
    result.info = parse_info_data(parsed.info.data)
  end
  if parsed.ixml then
    result.ixml_raw = parsed.ixml.data
  end

  return result
end

local function requested_chunks_present(existing, settings)
  if settings.include_bext and not existing.has_bext then
    return false
  end
  if settings.include_ixml and not existing.has_ixml then
    return false
  end
  if settings.include_info and not existing.has_info then
    return false
  end
  return true
end

local function write_metadata_to_wav(filepath, metadata, settings)
  local file = io.open(filepath, "rb")
  if not file then
    return false, "Cannot open file."
  end

  local original_data = file:read("*a")
  file:close()

  local parsed, parse_error = parse_wav_chunks(original_data)
  if not parsed then
    return false, parse_error
  end

  local fmt = parse_fmt_chunk(parsed.fmt)
  metadata.audio_format = fmt.audio_format
  metadata.channels = fmt.channels
  metadata.sample_rate = fmt.sample_rate
  metadata.bit_depth = fmt.bit_depth

  local replacements = {}
  if settings.include_bext and (settings.overwrite_existing or not parsed.bext) then
    replacements.bext = build_bext_chunk(metadata)
  end
  if settings.include_ixml and (settings.overwrite_existing or not parsed.ixml) then
    replacements.ixml = build_ixml_chunk(metadata)
  end
  if settings.include_info and (settings.overwrite_existing or not parsed.info) then
    replacements.info = build_list_info_chunk(metadata)
  end

  local new_wav, build_error = reassemble_wav(parsed, replacements)
  if not new_wav then
    return false, build_error
  end

  local writer = io.open(filepath, "wb")
  if not writer then
    return false, "Cannot write file."
  end

  local ok, write_error = writer:write(new_wav)
  writer:close()

  if not ok then
    local restore = io.open(filepath, "wb")
    if restore then
      restore:write(original_data)
      restore:close()
    end
    return false, write_error or "Write failed."
  end

  return true
end

local function batch_tag_files(metadata_list, settings)
  local success_count = 0
  local fail_count = 0
  local skip_count = 0
  local total = #metadata_list

  log_line("")
  log_line("=== Batch Metadata Tagging ===")
  log_line("Source Folder: " .. resolve_source_folder(settings))
  log_line("Files to process: " .. tostring(total))
  log_line("")

  for index, meta in ipairs(metadata_list) do
    if index == 1 or index % 10 == 0 or index == total then
      log_line(string.format("[Tagger] %d / %d (%.0f%%)", index, total, (index / math.max(total, 1)) * 100))
    end

    if settings.skip_tagged and not settings.overwrite_existing then
      local existing = read_existing_metadata(meta.filepath)
      if existing and requested_chunks_present(existing, settings) then
        skip_count = skip_count + 1
        goto continue
      end
    end

    local ok, err = write_metadata_to_wav(meta.filepath, meta, settings)
    if ok then
      success_count = success_count + 1
    else
      fail_count = fail_count + 1
      log_line(string.format("  FAILED: %s -- %s", meta.filename, tostring(err or "Unknown error")))
    end

    ::continue::
  end

  log_line("")
  log_line("============================================")
  log_line("Metadata Tagging Complete")
  log_line("============================================")
  log_line(string.format("Total Files: %d", total))
  log_line(string.format("Tagged:      %d", success_count))
  log_line(string.format("Skipped:     %d", skip_count))
  log_line(string.format("Failed:      %d", fail_count))
  log_line(string.format("Studio:      %s", settings.studio_name))
  log_line(string.format("Project:     %s", settings.game_project ~= "" and settings.game_project or "N/A"))
  log_line("============================================")

  return success_count, fail_count, skip_count
end

local function verify_files(files)
  local tagged_count = 0
  local missing = {}

  log_line("")
  log_line("=== Metadata Verification Report ===")
  log_line(string.format("Scanned: %d WAV files", #files))
  log_line("")
  log_line(string.format("%-3s %-34s %-4s %-4s %-4s %s", "#", "Filename", "BEXT", "IXML", "INFO", "Keywords"))

  for index, file_info in ipairs(files) do
    local existing, err = read_existing_metadata(file_info.path)
    if existing then
      local has_any = existing.has_bext or existing.has_ixml or existing.has_info
      if has_any then
        tagged_count = tagged_count + 1
      else
        missing[#missing + 1] = file_info.name
      end

      local keywords = existing.info and existing.info.IKEY or ""
      if keywords == "" then
        keywords = has_any and "-" or "NOT TAGGED"
      end

      log_line(string.format(
        "%-3d %-34s %-4s %-4s %-4s %s",
        index,
        truncate_text(file_info.name, 34),
        existing.has_bext and "Y" or "N",
        existing.has_ixml and "Y" or "N",
        existing.has_info and "Y" or "N",
        truncate_text(keywords, 48)
      ))
    else
      missing[#missing + 1] = file_info.name
      log_line(string.format(
        "%-3d %-34s %-4s %-4s %-4s %s",
        index,
        truncate_text(file_info.name, 34),
        "ERR",
        "ERR",
        "ERR",
        truncate_text(tostring(err or "Read failed"), 48)
      ))
    end
  end

  log_line("")
  log_line("Summary:")
  log_line(string.format("  Tagged:   %d / %d", tagged_count, #files))
  log_line(string.format("  Untagged: %d", #missing))

  if #missing > 0 then
    log_line("")
    log_line("Missing Tags:")
    for _, name in ipairs(missing) do
      log_line("  " .. name)
    end
  end
end

local function read_files(files)
  log_line("")
  log_line("=== Metadata Readout ===")
  log_line(string.format("Files: %d", #files))

  for index, file_info in ipairs(files) do
    local existing, err = read_existing_metadata(file_info.path)
    log_line("")
    log_line(string.format("[%d/%d] %s", index, #files, file_info.path))

    if not existing then
      log_line("  Error: " .. tostring(err or "Cannot read metadata."))
      goto continue
    end

    log_line(string.format("  bext: %s", existing.has_bext and "present" or "missing"))
    if existing.bext then
      log_line("    Description: " .. truncate_text(existing.bext.description, 96))
      log_line("    Originator:  " .. truncate_text(existing.bext.originator, 96))
      log_line("    Reference:   " .. truncate_text(existing.bext.originator_ref, 96))
      log_line("    Date:        " .. truncate_text(existing.bext.origination_date, 32))
      log_line("    Time:        " .. truncate_text(existing.bext.origination_time, 32))
    end

    log_line(string.format("  iXML: %s", existing.has_ixml and "present" or "missing"))
    if existing.has_ixml then
      log_line("    Size: " .. tostring(#(existing.ixml_raw or "")) .. " bytes")
    end

    log_line(string.format("  LIST-INFO: %s", existing.has_info and "present" or "missing"))
    if existing.info then
      local ordered_keys = { "INAM", "IART", "IPRD", "ICRD", "IGNR", "ICOP", "IKEY", "ICMT", "ISBJ", "ISFT" }
      for _, key in ipairs(ordered_keys) do
        if existing.info[key] and existing.info[key] ~= "" then
          log_line(string.format("    %s: %s", key, truncate_text(existing.info[key], 96)))
        end
      end
    end

    ::continue::
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

local function draw_section_title(label, x, y)
  draw_text(label, x, y, 238, 238, 238, 255, 1, "Segoe UI Semibold", 16)
end

local function draw_button(ui, id, label, rect_x, rect_y, rect_w, rect_h, enabled)
  local is_enabled = enabled ~= false
  local hovered = is_enabled and point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)

  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end

  local clicked = is_enabled and hovered and ui.mouse_released and ui.active_mouse_id == id
  local fill = is_enabled and (hovered and 64 or 48) or 34
  local border = is_enabled and (hovered and 110 or 82) or 55

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, fill, fill, fill, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, border, border, border, 255)
  draw_text(label, rect_x + 10, rect_y + 7, is_enabled and 240 or 128, is_enabled and 240 or 128, is_enabled and 240 or 128, 255, 1, "Segoe UI", 14)

  return clicked
end

local function draw_checkbox(ui, id, label, rect_x, rect_y, value)
  local box_size = 18
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, box_size + 8 + 220, box_size)
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
  draw_text(label, rect_x + box_size + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 14)

  return changed and not value or value
end

local function draw_text_input(ui, id, label, rect_x, rect_y, rect_w, rect_h, value)
  draw_text(label, rect_x, rect_y - 20, 208, 208, 208, 255, 1, "Segoe UI", 13)

  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)
  if hovered and ui.mouse_pressed then
    ui.focus_field = id
    ui.active_mouse_id = nil
  elseif ui.mouse_pressed and not hovered and ui.focus_field == id then
    ui.focus_field = nil
  end

  local is_focused = ui.focus_field == id
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

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 26, 26, 26, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, is_focused and 106 or 76, is_focused and 138 or 76, is_focused and 204 or 76, 255)
  draw_text(truncate_text(text_value, math.max(8, math.floor(rect_w / 8))), rect_x + 8, rect_y + 6, 240, 240, 240, 255, 1, "Consolas", 14)

  return text_value
end

local function draw_selectable_row(ui, id, label, rect_x, rect_y, rect_w, rect_h, selected)
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)
  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end
  local clicked = hovered and ui.mouse_released and ui.active_mouse_id == id

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, selected and 44 or (hovered and 36 or 28), selected and 58 or (hovered and 36 or 28), selected and 76 or (hovered and 36 or 28), 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, selected and 98 or 58, selected and 132 or 58, selected and 188 or 58, 255)
  draw_text(label, rect_x + 8, rect_y + 5, 232, 232, 232, 255, 1, "Consolas", 13)
  return clicked
end

local function build_runtime_settings_from_ui(ui)
  return {
    mode = ui.mode,
    source_folder = ui.source_folder,
    recursive_scan = ui.recursive_scan,
    studio_name = ui.studio_name,
    designer_name = ui.designer_name,
    website = ui.website,
    email = ui.email,
    copyright_template = ui.copyright_template,
    game_project = ui.game_project,
    client = ui.client,
    project_profile_name = ui.project_profile_name,
    middleware = ui.middleware ~= "" and ui.middleware or ui.default_middleware,
    description_template = ui.description_template,
    skip_tagged = ui.skip_tagged and not ui.overwrite_existing,
    overwrite_existing = ui.overwrite_existing,
    include_bext = ui.include_bext,
    include_ixml = ui.include_ixml,
    include_info = ui.include_info,
    custom_fields = clone_custom_fields(ui.custom_fields),
    keyword_dictionary = clone_keyword_dictionary(ui.keyword_dictionary),
  }
end

local function persist_ui_session(ui)
  local settings = build_runtime_settings_from_ui(ui)
  save_settings(settings)
end

local function build_project_profile_from_ui(ui)
  return {
    game_project = ui.game_project,
    client = ui.client,
    middleware = ui.middleware,
    description_template = ui.description_template,
    custom_fields = clone_custom_fields(ui.custom_fields),
  }
end

local function apply_project_profile_to_ui(ui, name, profile)
  local data = copy_project_profile(profile)
  ui.project_profile_name = trim_string(name or "")
  ui.game_project = data.game_project or ""
  ui.client = data.client or ""
  ui.middleware = data.middleware ~= "" and data.middleware or ui.default_middleware
  ui.description_template = data.description_template or ""
  ui.custom_fields = clone_custom_fields(data.custom_fields)
  ui.custom_field_index = (#ui.custom_fields > 0) and 1 or 0
  ui.custom_field_offset = 0
  ui.custom_key_input = ui.custom_fields[1] and ui.custom_fields[1].key or ""
  ui.custom_value_input = ui.custom_fields[1] and ui.custom_fields[1].value or ""
end

local function refresh_project_profile_names(ui)
  ui.project_profile_names = load_project_profile_names()
end

local function select_project_profile(ui, name)
  local trimmed = trim_string(name)
  apply_project_profile_to_ui(ui, trimmed, load_project_profile(trimmed))
  refresh_project_profile_names(ui)
  persist_ui_session(ui)
  if trimmed == "" then
    set_status(ui, "Using unsaved project settings.")
  else
    set_status(ui, "Loaded project profile: " .. trimmed)
  end
end

local function save_studio_profile_from_ui(ui)
  save_studio_profile({
    studio_name = ui.studio_name,
    designer_name = ui.designer_name,
    website = ui.website,
    email = ui.email,
    copyright_template = ui.copyright_template,
    default_middleware = ui.default_middleware,
  })
  persist_ui_session(ui)
  set_status(ui, "Studio profile saved.")
end

local function save_project_profile_from_ui(ui)
  local name = trim_string(ui.project_profile_name)
  if name == "" then
    local ok, value = reaper.GetUserInputs(SCRIPT_TITLE .. " - Save Project Profile", 1, "Profile Name", "")
    if not ok then
      return
    end
    name = trim_string(value)
    if name == "" then
      set_status(ui, "Project profile name is required.")
      return
    end
    ui.project_profile_name = name
  end

  local ok, err = save_project_profile(name, build_project_profile_from_ui(ui))
  if not ok then
    set_status(ui, err or "Could not save project profile.")
    return
  end

  refresh_project_profile_names(ui)
  persist_ui_session(ui)
  set_status(ui, "Project profile saved: " .. name)
end

local function new_project_profile_in_ui(ui)
  apply_project_profile_to_ui(ui, "", DEFAULT_PROJECT_PROFILE)
  ui.middleware = ui.default_middleware
  set_status(ui, "Started a new unsaved project profile.")
end

local function delete_project_profile_from_ui(ui)
  local name = trim_string(ui.project_profile_name)
  if name == "" then
    set_status(ui, "Select or name a saved project profile first.")
    return
  end

  local confirm = reaper.ShowMessageBox("Delete project profile '" .. name .. "'?", SCRIPT_TITLE, 4)
  if confirm ~= 6 then
    return
  end

  delete_project_profile(name)
  apply_project_profile_to_ui(ui, "", DEFAULT_PROJECT_PROFILE)
  ui.middleware = ui.default_middleware
  refresh_project_profile_names(ui)
  persist_ui_session(ui)
  set_status(ui, "Deleted project profile: " .. name)
end

local function refresh_keyword_dictionary_names(ui)
  ui.keyword_category_names = get_sorted_keyword_keys(ui.keyword_dictionary)
end

local function sync_keyword_editor(ui)
  local key = trim_string(ui.keyword_category_key)
  if key ~= "" and ui.keyword_dictionary[key] then
    ui.keyword_values_input = join_keywords_csv(ui.keyword_dictionary[key])
  end
end

local function show_keyword_category_menu(ui, rect_x, rect_y)
  refresh_keyword_dictionary_names(ui)
  local items = {}
  for _, key in ipairs(ui.keyword_category_names or {}) do
    items[#items + 1] = (key == ui.keyword_category_key and "!" or "") .. key
  end

  if #items == 0 then
    set_status(ui, "No keyword categories saved yet.")
    return
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection > 0 and ui.keyword_category_names[selection] then
    ui.keyword_category_key = ui.keyword_category_names[selection]
    sync_keyword_editor(ui)
    set_status(ui, "Keyword category: " .. ui.keyword_category_key)
  end
end

local function save_keyword_entry_from_ui(ui)
  local key = trim_string(ui.keyword_category_key)
  if key == "" then
    set_status(ui, "Keyword category key is required.")
    return
  end

  ui.keyword_category_key = key
  ui.keyword_dictionary[key] = split_keywords_csv(ui.keyword_values_input)
  ui.keyword_values_input = join_keywords_csv(ui.keyword_dictionary[key])
  refresh_keyword_dictionary_names(ui)
  save_keyword_dictionary(ui.keyword_dictionary)
  persist_ui_session(ui)
  set_status(ui, "Saved keyword category: " .. key)
end

local function delete_keyword_entry_from_ui(ui)
  local key = trim_string(ui.keyword_category_key)
  if key == "" or not ui.keyword_dictionary[key] then
    set_status(ui, "Select a keyword category first.")
    return
  end

  ui.keyword_dictionary[key] = nil
  refresh_keyword_dictionary_names(ui)
  ui.keyword_category_key = ui.keyword_category_names[1] or ""
  sync_keyword_editor(ui)
  save_keyword_dictionary(ui.keyword_dictionary)
  persist_ui_session(ui)
  set_status(ui, "Deleted keyword category: " .. key)
end

local function reset_keyword_dictionary_from_ui(ui)
  local confirm = reaper.ShowMessageBox("Reset the keyword dictionary to built-in defaults?", SCRIPT_TITLE, 4)
  if confirm ~= 6 then
    return
  end

  ui.keyword_dictionary = clone_keyword_dictionary(KEYWORD_DICTIONARY)
  refresh_keyword_dictionary_names(ui)
  ui.keyword_category_key = ui.keyword_category_names[1] or ""
  sync_keyword_editor(ui)
  save_keyword_dictionary(ui.keyword_dictionary)
  persist_ui_session(ui)
  set_status(ui, "Keyword dictionary reset to defaults.")
end

local function sync_custom_field_editor(ui)
  local field = ui.custom_fields[ui.custom_field_index]
  if field then
    ui.custom_key_input = field.key
    ui.custom_value_input = field.value
  else
    ui.custom_key_input = ""
    ui.custom_value_input = ""
  end
end

local function clamp_custom_field_offset(ui, visible_rows)
  local max_offset = math.max(0, #ui.custom_fields - visible_rows)
  if ui.custom_field_offset > max_offset then
    ui.custom_field_offset = max_offset
  end
  if ui.custom_field_offset < 0 then
    ui.custom_field_offset = 0
  end
end

local function add_or_update_custom_field(ui)
  local key = trim_string(ui.custom_key_input)
  local value = tostring(ui.custom_value_input or "")
  if key == "" then
    set_status(ui, "Custom field key is required.")
    return
  end

  local selected = ui.custom_fields[ui.custom_field_index]
  if selected then
    selected.key = key
    selected.value = value
    set_status(ui, "Updated custom field: " .. key)
    return
  end

  for index, field in ipairs(ui.custom_fields) do
    if field.key == key then
      field.value = value
      ui.custom_field_index = index
      set_status(ui, "Updated custom field: " .. key)
      return
    end
  end

  ui.custom_fields[#ui.custom_fields + 1] = { key = key, value = value }
  ui.custom_field_index = #ui.custom_fields
  set_status(ui, "Added custom field: " .. key)
end

local function remove_selected_custom_field(ui)
  local index = ui.custom_field_index or 0
  if index < 1 or index > #ui.custom_fields then
    set_status(ui, "Select a custom field first.")
    return
  end
  local removed = ui.custom_fields[index]
  table.remove(ui.custom_fields, index)
  if index > #ui.custom_fields then
    ui.custom_field_index = #ui.custom_fields
  end
  sync_custom_field_editor(ui)
  set_status(ui, "Removed custom field: " .. tostring(removed and removed.key or ""))
end

local function move_custom_field(ui, direction)
  local index = ui.custom_field_index or 0
  local target = index + direction
  if index < 1 or index > #ui.custom_fields or target < 1 or target > #ui.custom_fields then
    return
  end
  ui.custom_fields[index], ui.custom_fields[target] = ui.custom_fields[target], ui.custom_fields[index]
  ui.custom_field_index = target
  sync_custom_field_editor(ui)
end

local function refresh_file_count(ui)
  local settings = build_runtime_settings_from_ui(ui)
  local files = collect_target_files(settings)
  ui.file_count = #files
  ui.last_scanned_folder = resolve_source_folder(settings)
  set_status(ui, string.format("Found %d WAV file(s).", ui.file_count))
end

local function preview_metadata_from_ui(ui)
  clear_console()
  local settings = build_runtime_settings_from_ui(ui)
  local files = collect_target_files(settings)
  if #files == 0 then
    set_status(ui, "No WAV files found for preview.")
    return
  end

  local metadata_list = extract_metadata_from_project(files, settings)
  local preview_count = math.min(#metadata_list, 8)

  log_line("=== Metadata Preview ===")
  log_line("Folder: " .. resolve_source_folder(settings))
  log_line("Files: " .. tostring(#metadata_list))
  log_line("")

  for index = 1, preview_count do
    local meta = metadata_list[index]
    log_line(string.format("[%d] %s", index, meta.filename))
    log_line("  Description: " .. tostring(meta.description or ""))
    log_line("  bext.Description: " .. tostring(meta.bext_description or ""))
    log_line("  Keywords: " .. tostring(meta.keywords or ""))
    if #meta.custom_fields > 0 then
      for _, field in ipairs(meta.custom_fields) do
        log_line("  " .. tostring(field.key) .. ": " .. tostring(field.value))
      end
    end
    log_line("")
  end

  if #metadata_list > preview_count then
    log_line(string.format("... %d more file(s)", #metadata_list - preview_count))
  end

  set_status(ui, string.format("Previewed %d of %d file(s) in console.", preview_count, #metadata_list))
end

local function run_action_from_ui(ui, mode_override)
  clear_console()
  local settings = build_runtime_settings_from_ui(ui)
  if mode_override then
    settings.mode = mode_override
  end

  if settings.mode == "tag" and not (settings.include_bext or settings.include_ixml or settings.include_info) then
    set_status(ui, "Enable at least one metadata chunk before tagging.")
    return
  end

  local files = collect_target_files(settings)
  if #files == 0 then
    set_status(ui, "No WAV files found.")
    return
  end

  persist_ui_session(ui)

  reaper.PreventUIRefresh(1)
  local ok, runtime_error = xpcall(function()
    if settings.mode == "tag" then
      local metadata_list = extract_metadata_from_project(files, settings)
      local tagged, failed, skipped = batch_tag_files(metadata_list, settings)
      set_status(ui, string.format("Tag complete: %d tagged, %d skipped, %d failed.", tagged, skipped, failed))
    elseif settings.mode == "verify" then
      verify_files(files)
      set_status(ui, string.format("Verified %d file(s).", #files))
    else
      read_files(files)
      set_status(ui, string.format("Read metadata from %d file(s).", #files))
    end
  end, function(message)
    if debug and debug.traceback then
      return debug.traceback(message, 2)
    end
    return tostring(message)
  end)
  reaper.PreventUIRefresh(-1)

  if not ok then
    set_status(ui, "Run failed. See error dialog.")
    show_error(runtime_error)
  end
end

local function init_ui_state(current_settings)
  local studio_profile = load_studio_profile()
  local project_names = load_project_profile_names()
  local keyword_dictionary = load_keyword_dictionary()
  local keyword_keys = get_sorted_keyword_keys(keyword_dictionary)
  local selected_project_name = trim_string(current_settings.project_profile_name)
  local project_name_guess = get_project_name()

  if selected_project_name == "" then
    for _, name in ipairs(project_names) do
      if name == project_name_guess then
        selected_project_name = name
        break
      end
    end
  end

  local project_profile = load_project_profile(selected_project_name)

  local ui = {
    width = 1180,
    height = 900,
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
    mode = current_settings.mode or DEFAULTS.mode,
    source_folder = current_settings.source_folder or "",
    recursive_scan = current_settings.recursive_scan,
    skip_tagged = current_settings.skip_tagged,
    overwrite_existing = current_settings.overwrite_existing,
    include_bext = current_settings.include_bext,
    include_ixml = current_settings.include_ixml,
    include_info = current_settings.include_info,
    studio_name = current_settings.studio_name ~= "" and current_settings.studio_name or studio_profile.studio_name,
    designer_name = current_settings.designer_name ~= "" and current_settings.designer_name or studio_profile.designer_name,
    website = studio_profile.website or "",
    email = studio_profile.email or "",
    copyright_template = studio_profile.copyright_template or DEFAULT_STUDIO_PROFILE.copyright_template,
    default_middleware = studio_profile.default_middleware ~= "" and studio_profile.default_middleware or DEFAULT_STUDIO_PROFILE.default_middleware,
    project_profile_names = project_names,
    project_profile_name = selected_project_name,
    game_project = "",
    client = "",
    middleware = "",
    description_template = "",
    custom_fields = {},
    custom_field_index = 0,
    custom_field_offset = 0,
    custom_key_input = "",
    custom_value_input = "",
    keyword_dictionary = keyword_dictionary,
    keyword_category_names = keyword_keys,
    keyword_category_key = keyword_keys[1] or "",
    keyword_values_input = keyword_keys[1] and join_keywords_csv(keyword_dictionary[keyword_keys[1]]) or "",
    file_count = 0,
    last_scanned_folder = "",
  }

  apply_project_profile_to_ui(ui, selected_project_name, project_profile)

  if selected_project_name == "" then
    if current_settings.game_project ~= "" then
      ui.game_project = current_settings.game_project
    end
    if current_settings.middleware ~= "" then
      ui.middleware = current_settings.middleware
    end
  end

  if ui.middleware == "" then
    ui.middleware = ui.default_middleware
  end

  return ui
end

local function show_mode_menu(ui, rect_x, rect_y)
  local items = {}
  local mapping = {
    { key = "tag", label = "Tag Files" },
    { key = "verify", label = "Verify" },
    { key = "read", label = "Read Metadata" },
  }

  for _, item in ipairs(mapping) do
    items[#items + 1] = (ui.mode == item.key and "!" or "") .. item.label
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection > 0 and mapping[selection] then
    ui.mode = mapping[selection].key
    persist_ui_session(ui)
    set_status(ui, "Mode: " .. mapping[selection].label)
  end
end

local function show_project_profile_menu(ui, rect_x, rect_y)
  local items = { "#Project Profiles" }
  local mapping = { "" }

  if trim_string(ui.project_profile_name) == "" then
    items[#items + 1] = "!Unsaved / Current"
  else
    items[#items + 1] = "Unsaved / Current"
  end
  mapping[#mapping + 1] = ""

  for _, name in ipairs(ui.project_profile_names or {}) do
    items[#items + 1] = (name == ui.project_profile_name and "!" or "") .. name
    mapping[#mapping + 1] = name
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection > 1 and mapping[selection] ~= nil then
    select_project_profile(ui, mapping[selection])
  end
end

local function draw_keyword_dictionary_panel(ui, rect_x, rect_y, rect_w, rect_h)
  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 22, 22, 22, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, 58, 58, 58, 255)
  draw_section_title("Keyword Dictionary", rect_x + 14, rect_y + 12)

  if draw_button(ui, "keyword_menu", ui.keyword_category_key ~= "" and ui.keyword_category_key or "Select Category", rect_x + 12, rect_y + 40, 210, 30, true) then
    show_keyword_category_menu(ui, rect_x + 12, rect_y + 70)
  end
  draw_text(string.format("%d categories", #(ui.keyword_category_names or {})), rect_x + 232, rect_y + 47, 170, 190, 205, 255, 1, "Segoe UI", 12)

  ui.keyword_category_key = draw_text_input(ui, "keyword_category_key", "Category Key", rect_x + 12, rect_y + 92, 180, 30, ui.keyword_category_key)
  ui.keyword_values_input = draw_text_input(ui, "keyword_values_input", "Keywords (comma separated)", rect_x + 204, rect_y + 92, rect_w - 216, 30, ui.keyword_values_input)

  if draw_button(ui, "keyword_save", "Save Entry", rect_x + 12, rect_y + 138, 90, 30, true) then
    save_keyword_entry_from_ui(ui)
  end
  if draw_button(ui, "keyword_delete", "Delete", rect_x + 112, rect_y + 138, 80, 30, ui.keyword_category_key ~= "") then
    delete_keyword_entry_from_ui(ui)
  end
  if draw_button(ui, "keyword_reset", "Reset Defaults", rect_x + 202, rect_y + 138, 110, 30, true) then
    reset_keyword_dictionary_from_ui(ui)
  end
end

local function draw_custom_fields_panel(ui, rect_x, rect_y, rect_w, rect_h)
  local header_h = 28
  local row_h = 24
  local list_h = 190
  local key_col_w = 160
  local visible_rows = math.max(1, math.floor((list_h - header_h) / row_h))

  clamp_custom_field_offset(ui, visible_rows)

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 22, 22, 22, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, 58, 58, 58, 255)
  draw_section_title("Custom Fields", rect_x + 14, rect_y + 12)

  local table_y = rect_y + 44
  draw_rect(rect_x + 12, table_y, rect_w - 24, header_h, true, 32, 32, 32, 255)
  draw_rect(rect_x + 12, table_y, rect_w - 24, header_h, false, 72, 72, 72, 255)
  draw_text("Key", rect_x + 22, table_y + 5, 220, 220, 220, 255, 1, "Segoe UI Semibold", 13)
  draw_text("Value", rect_x + 22 + key_col_w, table_y + 5, 220, 220, 220, 255, 1, "Segoe UI Semibold", 13)

  for row = 0, visible_rows - 1 do
    local index = ui.custom_field_offset + row + 1
    local field = ui.custom_fields[index]
    local row_y = table_y + header_h + row * row_h
    if field then
      local label = truncate_text(field.key, 18) .. string.rep(" ", math.max(1, 22 - math.min(#field.key, 18))) .. truncate_text(field.value, 44)
      if draw_selectable_row(ui, "custom_row_" .. tostring(index), label, rect_x + 12, row_y, rect_w - 24, row_h, index == ui.custom_field_index) then
        ui.custom_field_index = index
        sync_custom_field_editor(ui)
      end
    else
      draw_rect(rect_x + 12, row_y, rect_w - 24, row_h, true, 24, 24, 24, 255)
      draw_rect(rect_x + 12, row_y, rect_w - 24, row_h, false, 52, 52, 52, 255)
    end
  end

  local footer_y = table_y + header_h + visible_rows * row_h + 8
  if draw_button(ui, "custom_prev", "<", rect_x + 12, footer_y, 26, 24, ui.custom_field_offset > 0) then
    ui.custom_field_offset = math.max(0, ui.custom_field_offset - visible_rows)
  end
  if draw_button(ui, "custom_next", ">", rect_x + 44, footer_y, 26, 24, ui.custom_field_offset + visible_rows < #ui.custom_fields) then
    ui.custom_field_offset = ui.custom_field_offset + visible_rows
  end
  draw_text(string.format("%d field(s)", #ui.custom_fields), rect_x + 84, footer_y + 4, 170, 190, 205, 255, 1, "Segoe UI", 12)

  local input_y = footer_y + 46
  ui.custom_key_input = draw_text_input(ui, "custom_key", "Field Key", rect_x + 12, input_y, 180, 30, ui.custom_key_input)
  ui.custom_value_input = draw_text_input(ui, "custom_value", "Field Value", rect_x + 204, input_y, rect_w - 216, 30, ui.custom_value_input)

  local button_y = input_y + 48
  if draw_button(ui, "custom_add", "Add / Update", rect_x + 12, button_y, 120, 30, true) then
    add_or_update_custom_field(ui)
    persist_ui_session(ui)
  end
  if draw_button(ui, "custom_remove", "Remove", rect_x + 142, button_y, 80, 30, ui.custom_field_index > 0) then
    remove_selected_custom_field(ui)
    persist_ui_session(ui)
  end
  if draw_button(ui, "custom_up", "Up", rect_x + 232, button_y, 54, 30, ui.custom_field_index > 1) then
    move_custom_field(ui, -1)
    persist_ui_session(ui)
  end
  if draw_button(ui, "custom_down", "Down", rect_x + 296, button_y, 64, 30, ui.custom_field_index > 0 and ui.custom_field_index < #ui.custom_fields) then
    move_custom_field(ui, 1)
    persist_ui_session(ui)
  end
  if draw_button(ui, "custom_clear", "Clear", rect_x + 370, button_y, 64, 30, true) then
    ui.custom_field_index = 0
    ui.custom_key_input = ""
    ui.custom_value_input = ""
  end
end

local function run_gfx_ui(current_settings)
  if not gfx or not gfx.init then
    return false
  end

  local ui = init_ui_state(current_settings)
  gfx.init(SCRIPT_TITLE, ui.width, ui.height, 0)
  if (gfx.w or 0) <= 0 then
    return false
  end

  refresh_file_count(ui)

  local function loop()
    local key = gfx.getchar()
    if key < 0 then
      persist_ui_session(ui)
      gfx.quit()
      return
    end

    ui.key_char = key
    ui.consume_escape = false
    ui.mouse_x = gfx.mouse_x
    ui.mouse_y = gfx.mouse_y
    ui.mouse_down = (gfx.mouse_cap & 1) == 1
    ui.mouse_pressed = ui.mouse_down and not ui.prev_mouse_down
    ui.mouse_released = (not ui.mouse_down) and ui.prev_mouse_down

    draw_rect(0, 0, ui.width, ui.height, true, 16, 18, 22, 255)
    draw_text(SCRIPT_TITLE, 24, 18, 245, 245, 245, 255, 1, "Segoe UI Semibold", 22)
    draw_text("Phase 3: overwrite control, keyword dictionary editor, advanced profiles", 24, 48, 150, 170, 185, 255, 1, "Segoe UI", 13)

    draw_rect(20, 82, 540, 760, true, 24, 24, 24, 255)
    draw_rect(20, 82, 540, 760, false, 58, 58, 58, 255)
    draw_rect(580, 82, 580, 760, true, 24, 24, 24, 255)
    draw_rect(580, 82, 580, 760, false, 58, 58, 58, 255)

    draw_section_title("Mode / Source", 40, 104)
    local mode_labels = { tag = "Tag Files", verify = "Verify", read = "Read Metadata" }
    if draw_button(ui, "mode_menu", mode_labels[ui.mode] or ui.mode, 40, 132, 180, 32, true) then
      show_mode_menu(ui, 40, 164)
    end
    ui.source_folder = draw_text_input(ui, "source_folder", "Source Folder (empty = project/Renders)", 40, 192, 400, 30, ui.source_folder)
    if draw_button(ui, "source_default", "Use Default", 450, 192, 90, 30, true) then
      ui.source_folder = ""
      refresh_file_count(ui)
      persist_ui_session(ui)
    end
    ui.recursive_scan = draw_checkbox(ui, "recursive_scan", "Include subfolders", 40, 240, ui.recursive_scan)
    draw_text(string.format("Resolved: %s", truncate_text(resolve_source_folder(build_runtime_settings_from_ui(ui)), 68)), 40, 272, 165, 185, 205, 255, 1, "Consolas", 12)
    draw_text(string.format("Files found: %d", ui.file_count or 0), 40, 292, 185, 215, 185, 255, 1, "Segoe UI", 13)
    if draw_button(ui, "refresh_files", "Refresh Scan", 40, 316, 120, 30, true) then
      refresh_file_count(ui)
      persist_ui_session(ui)
    end

    draw_section_title("Studio Profile", 40, 372)
    ui.studio_name = draw_text_input(ui, "studio_name", "Studio Name", 40, 400, 240, 30, ui.studio_name)
    ui.designer_name = draw_text_input(ui, "designer_name", "Designer Name", 300, 400, 240, 30, ui.designer_name)
    ui.website = draw_text_input(ui, "website", "Website", 40, 452, 240, 30, ui.website)
    ui.email = draw_text_input(ui, "email", "Email", 300, 452, 240, 30, ui.email)
    ui.default_middleware = draw_text_input(ui, "default_middleware", "Default Middleware", 40, 504, 240, 30, ui.default_middleware)
    ui.copyright_template = draw_text_input(ui, "copyright_template", "Copyright Template", 40, 556, 500, 30, ui.copyright_template)
    if draw_button(ui, "save_studio", "Save Studio Profile", 40, 608, 150, 32, true) then
      save_studio_profile_from_ui(ui)
    end

    draw_keyword_dictionary_panel(ui, 40, 658, 500, 160)

    draw_section_title("Project Profile", 600, 104)
    if draw_button(ui, "project_profile_menu", ui.project_profile_name ~= "" and ui.project_profile_name or "Unsaved / Current", 600, 132, 230, 32, true) then
      show_project_profile_menu(ui, 600, 164)
    end
    if draw_button(ui, "project_profile_new", "New", 840, 132, 60, 32, true) then
      new_project_profile_in_ui(ui)
      persist_ui_session(ui)
    end
    if draw_button(ui, "project_profile_save", "Save", 910, 132, 60, 32, true) then
      save_project_profile_from_ui(ui)
    end
    if draw_button(ui, "project_profile_delete", "Delete", 980, 132, 70, 32, ui.project_profile_name ~= "") then
      delete_project_profile_from_ui(ui)
    end
    if draw_button(ui, "project_profile_refresh", "Reload", 1060, 132, 80, 32, true) then
      refresh_project_profile_names(ui)
      if ui.project_profile_name ~= "" then
        select_project_profile(ui, ui.project_profile_name)
      else
        set_status(ui, "Project profile list refreshed.")
      end
    end

    ui.project_profile_name = draw_text_input(ui, "project_profile_name", "Profile Name", 600, 190, 220, 30, ui.project_profile_name)
    ui.game_project = draw_text_input(ui, "game_project", "Game Project", 600, 242, 220, 30, ui.game_project)
    ui.client = draw_text_input(ui, "client", "Client", 840, 242, 220, 30, ui.client)
    ui.middleware = draw_text_input(ui, "middleware", "Middleware", 600, 294, 220, 30, ui.middleware)
    ui.description_template = draw_text_input(ui, "description_template", "Description Template", 840, 294, 300, 30, ui.description_template)

    draw_section_title("Metadata Chunks", 600, 350)
    ui.include_bext = draw_checkbox(ui, "include_bext", "Include BWF (bext)", 600, 378, ui.include_bext)
    ui.include_ixml = draw_checkbox(ui, "include_ixml", "Include iXML", 600, 406, ui.include_ixml)
    ui.include_info = draw_checkbox(ui, "include_info", "Include LIST-INFO", 600, 434, ui.include_info)
    ui.skip_tagged = draw_checkbox(ui, "skip_tagged", "Skip already-tagged files", 600, 462, ui.skip_tagged)
    ui.overwrite_existing = draw_checkbox(ui, "overwrite_existing", "Overwrite existing metadata", 600, 490, ui.overwrite_existing)
    if ui.overwrite_existing then
      ui.skip_tagged = false
    end
    draw_custom_fields_panel(ui, 600, 514, 540, 250)

    if draw_button(ui, "preview", "Preview Tags", 600, 778, 110, 34, true) then
      preview_metadata_from_ui(ui)
    end
    if draw_button(ui, "run_mode_action", mode_labels[ui.mode] or "Run", 720, 778, 120, 34, true) then
      run_action_from_ui(ui, nil)
    end
    if draw_button(ui, "run_tag", "Tag All", 850, 778, 90, 34, true) then
      run_action_from_ui(ui, "tag")
    end
    if draw_button(ui, "run_verify", "Verify", 950, 778, 80, 34, true) then
      run_action_from_ui(ui, "verify")
    end
    if draw_button(ui, "run_read", "Read", 1040, 778, 60, 34, true) then
      run_action_from_ui(ui, "read")
    end
    if draw_button(ui, "close", "Close", 1110, 778, 50, 34, true) then
      persist_ui_session(ui)
      gfx.quit()
      return
    end

    draw_rect(20, 858, 1140, 1, true, 48, 48, 48, 255)
    draw_text(truncate_text(ui.status_message, 150), 24, 868, 170, 205, 220, 255, 1, "Segoe UI", 13)

    if ui.mouse_released then
      ui.active_mouse_id = nil
    end

    if key == 27 and not ui.consume_escape and ui.focus_field == nil then
      persist_ui_session(ui)
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

local function main()
  local seed = os.time()
  if reaper.time_precise then
    seed = seed + math.floor(reaper.time_precise() * 1000)
  end
  math.randomseed(seed)

  clear_console()

  local current_settings = load_settings()
  if run_gfx_ui(current_settings) then
    return
  end

  local studio_profile = load_studio_profile()
  local project_profile = load_project_profile(current_settings.project_profile_name)

  if current_settings.studio_name == "" then
    current_settings.studio_name = studio_profile.studio_name
  end
  if current_settings.designer_name == "" then
    current_settings.designer_name = studio_profile.designer_name
  end
  if current_settings.game_project == "" then
    current_settings.game_project = project_profile.game_project
  end
  if current_settings.middleware == "" then
    current_settings.middleware = project_profile.middleware ~= "" and project_profile.middleware or studio_profile.default_middleware
  end

  local settings, prompt_error = prompt_for_settings(current_settings)
  if not settings then
    if prompt_error and prompt_error ~= "User cancelled." then
      show_error(prompt_error)
    end
    return
  end

  settings.website = studio_profile.website
  settings.email = studio_profile.email
  settings.client = project_profile.client
  settings.copyright_template = studio_profile.copyright_template
  settings.description_template = project_profile.description_template
  settings.custom_fields = clone_custom_fields(project_profile.custom_fields)
  settings.keyword_dictionary = load_keyword_dictionary()
  settings.project_profile_name = current_settings.project_profile_name

  save_settings(settings)

  local source_folder = resolve_source_folder(settings)
  local files = collect_target_files(settings)
  if #files == 0 then
    show_error("No WAV files were found in: " .. source_folder)
    return
  end

  reaper.PreventUIRefresh(1)
  local ok, runtime_error = xpcall(function()
    if settings.mode == "tag" then
      local metadata_list = extract_metadata_from_project(files, settings)
      batch_tag_files(metadata_list, settings)
    elseif settings.mode == "verify" then
      verify_files(files)
    else
      read_files(files)
    end
  end, function(message)
    if debug and debug.traceback then
      return debug.traceback(message, 2)
    end
    return tostring(message)
  end)
  reaper.PreventUIRefresh(-1)

  if not ok then
    show_error(runtime_error)
  end
end

main()
