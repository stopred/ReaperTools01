-- Game Sound Seamless Loop Maker v1.0
-- Reaper ReaScript (Lua)
-- 게임 사운드 심리스 루프 자동 생성 도구
--
-- 사용법:
-- 1. 루프로 만들 아이템(들)을 선택
-- 2. (선택) 타임 셀렉션으로 루프 길이 지정
-- 3. 스크립트 실행 -> 파라미터 조절
-- 4. Apply(Enter)로 루프 생성
--
-- 기능:
--   제로크로싱 기반 심리스 루프 자동 생성
--   크로스페이드 베이크/글루
--   루프 네이밍
--   설정 저장
--
-- 요구사항: REAPER v7.0+
-- 권장: ReaImGui (현재 지원). gfx GUI 폴백 포함.

local SCRIPT_TITLE = "Game Sound Seamless Loop Maker v1.0"
local EXT_SECTION = "GameSoundLoopMaker"
local HAS_IMGUI = false
local ImGui = nil

if reaper.ImGui_GetBuiltinPath then
  local ok, library = pcall(function()
    package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
    return require("imgui")("0.9")
  end)
  if ok and library then
    HAS_IMGUI = true
    ImGui = library
  end
end

math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
math.random()
math.random()
math.random()

local GUI = {
  width = 760,
  height = 1040,
  padding = 18,
  section_gap = 14,
  slider_w = 300,
  slider_h = 16,
  button_h = 28,
}

local MIN_LOOP_LENGTH_SEC = 0.050
local MIN_CROSSFADE_SEC = 0.005
local ZERO_CROSSING_BLOCK_SIZE = 4096
local MAX_PAIR_CANDIDATES = 48
local GLUE_ITEMS_COMMAND = 41588
local LENGTH_MATCH_TOLERANCE_SEC = 0.050
local PREVIEW_LOOP_REPETITIONS = 3
local REAPER_COLOR_FLAG = 0x1000000

local DEFAULTS = {
  main = {
    loops = 1,
    glue = true,
    pin = false,
  },
  position = {
    space = 0.0,
    shuffle = false,
    second_snap = false,
    match_length = false,
  },
  crossfade = {
    length = 0.15,
    curve = "equal_power",
    max_length = 10.0,
  },
  zero_crossing = {
    offset = 0.0,
    search_fraction = 0.12,
    max_search_seconds = 3.0,
  },
  name = {
    color_items = false,
    remove_extensions = true,
    prefix = "",
    suffix = "_loop",
    separator = "_",
    number = false,
    starting_number = 1,
    leading_zeros = 2,
  },
  shepard = {
    enabled = false,
    pitch = 12,
    direction = "up",
    layers = 4,
    steps = 12,
  },
}

local preview_state = {
  is_previewing = false,
  source_item = nil,
  source_muted = 0.0,
  preview_items = {},
  preview_tracks = {},
  track_solo_states = {},
  loop_start = nil,
  loop_end = nil,
  cursor_position = nil,
}

local build_selection_signature
local start_loop_preview

local CURVE_OPTIONS = {
  {
    id = "equal_power",
    label = "Equal Power",
    shape = 0,
    fadein_dir = -0.35,
    fadeout_dir = 0.35,
  },
  {
    id = "linear",
    label = "Linear",
    shape = 0,
    fadein_dir = 0.0,
    fadeout_dir = 0.0,
  },
  {
    id = "scurve",
    label = "S-Curve",
    shape = 0,
    fadein_dir = -1.0,
    fadeout_dir = 1.0,
  },
  {
    id = "fast_start",
    label = "Fast Start",
    shape = 0,
    fadein_dir = 1.0,
    fadeout_dir = 1.0,
  },
  {
    id = "slow_start",
    label = "Slow Start",
    shape = 0,
    fadein_dir = -1.0,
    fadeout_dir = -1.0,
  },
}

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

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
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
  local power = 10 ^ (decimals or 0)
  if value >= 0 then
    return math.floor(value * power + 0.5) / power
  end
  return math.ceil(value * power - 0.5) / power
end

local function bool_to_string(value)
  return value and "1" or "0"
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

local function pad_number(value, width)
  return string.format("%0" .. tostring(width or 2) .. "d", value)
end

local function strip_extension(name)
  return trim_string(name):gsub("%.[^%.\\/]+$", "")
end

local function format_seconds(seconds)
  return string.format("%.3f s", tonumber(seconds) or 0.0)
end

local function format_ratio(value)
  return string.format("%.3f", tonumber(value) or 0.0)
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function set_color(r, g, b, a)
  gfx.set((r or 255) / 255.0, (g or 255) / 255.0, (b or 255) / 255.0, (a or 255) / 255.0)
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
    gfx.setfont(1, "Arial", 16)
    draw_text(x + 10, y + 8, title, 236, 239, 243, 255)
  end
end

local function register_hit_region(state, kind, x, y, w, h, data)
  state.hit_regions[#state.hit_regions + 1] = {
    kind = kind,
    x = x,
    y = y,
    w = w,
    h = h,
    data = data or {},
  }
end

local function get_curve_option(curve_id)
  for _, option in ipairs(CURVE_OPTIONS) do
    if option.id == curve_id then
      return option
    end
  end
  return CURVE_OPTIONS[1]
end

local function cycle_curve_option(curve_id)
  for index, option in ipairs(CURVE_OPTIONS) do
    if option.id == curve_id then
      local next_index = index + 1
      if next_index > #CURVE_OPTIONS then
        next_index = 1
      end
      return CURVE_OPTIONS[next_index].id
    end
  end
  return CURVE_OPTIONS[1].id
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function load_settings()
  local settings = deep_copy(DEFAULTS)

  settings.main.loops = math.max(1, math.floor((tonumber(get_ext_state("main_loops", tostring(DEFAULTS.main.loops))) or DEFAULTS.main.loops) + 0.5))
  settings.main.glue = parse_boolean(get_ext_state("main_glue", bool_to_string(DEFAULTS.main.glue)), DEFAULTS.main.glue)
  settings.main.pin = parse_boolean(get_ext_state("main_pin", bool_to_string(DEFAULTS.main.pin)), DEFAULTS.main.pin)

  settings.crossfade.length = tonumber(get_ext_state("crossfade_length", tostring(DEFAULTS.crossfade.length))) or DEFAULTS.crossfade.length
  settings.crossfade.max_length = tonumber(get_ext_state("crossfade_max_length", tostring(DEFAULTS.crossfade.max_length))) or DEFAULTS.crossfade.max_length
  settings.crossfade.curve = trim_string(get_ext_state("crossfade_curve", DEFAULTS.crossfade.curve))
  settings.zero_crossing.offset = tonumber(get_ext_state("zero_crossing_offset", tostring(DEFAULTS.zero_crossing.offset))) or DEFAULTS.zero_crossing.offset
  settings.position.space = tonumber(get_ext_state("position_space", tostring(DEFAULTS.position.space))) or DEFAULTS.position.space
  settings.position.shuffle = parse_boolean(get_ext_state("position_shuffle", bool_to_string(DEFAULTS.position.shuffle)), DEFAULTS.position.shuffle)
  settings.position.second_snap = parse_boolean(get_ext_state("position_second_snap", bool_to_string(DEFAULTS.position.second_snap)), DEFAULTS.position.second_snap)
  settings.position.match_length = parse_boolean(get_ext_state("position_match_length", bool_to_string(DEFAULTS.position.match_length)), DEFAULTS.position.match_length)
  settings.shepard.enabled = parse_boolean(get_ext_state("shepard_enabled", bool_to_string(DEFAULTS.shepard.enabled)), DEFAULTS.shepard.enabled)
  settings.shepard.pitch = tonumber(get_ext_state("shepard_pitch", tostring(DEFAULTS.shepard.pitch))) or DEFAULTS.shepard.pitch
  settings.shepard.layers = math.max(2, math.floor((tonumber(get_ext_state("shepard_layers", tostring(DEFAULTS.shepard.layers))) or DEFAULTS.shepard.layers) + 0.5))
  settings.shepard.steps = math.max(4, math.floor((tonumber(get_ext_state("shepard_steps", tostring(DEFAULTS.shepard.steps))) or DEFAULTS.shepard.steps) + 0.5))
  settings.shepard.direction = trim_string(get_ext_state("shepard_direction", DEFAULTS.shepard.direction))

  settings.name.remove_extensions = parse_boolean(
    get_ext_state("name_remove_extensions", bool_to_string(DEFAULTS.name.remove_extensions)),
    DEFAULTS.name.remove_extensions
  )
  settings.name.color_items = parse_boolean(get_ext_state("name_color_items", bool_to_string(DEFAULTS.name.color_items)), DEFAULTS.name.color_items)
  settings.name.prefix = get_ext_state("name_prefix", DEFAULTS.name.prefix)
  settings.name.suffix = get_ext_state("name_suffix", DEFAULTS.name.suffix)
  settings.name.separator = get_ext_state("name_separator", DEFAULTS.name.separator)
  settings.name.number = parse_boolean(get_ext_state("name_number", bool_to_string(DEFAULTS.name.number)), DEFAULTS.name.number)
  settings.name.starting_number = math.max(1, math.floor((tonumber(get_ext_state("name_starting_number", tostring(DEFAULTS.name.starting_number))) or DEFAULTS.name.starting_number) + 0.5))
  settings.name.leading_zeros = clamp_number(
    math.floor((tonumber(get_ext_state("name_leading_zeros", tostring(DEFAULTS.name.leading_zeros))) or DEFAULTS.name.leading_zeros) + 0.5),
    1,
    6
  )

  settings.main.loops = clamp_number(settings.main.loops, 1, 32)
  settings.crossfade.length = clamp_number(settings.crossfade.length, 0.01, 0.5)
  settings.crossfade.max_length = clamp_number(settings.crossfade.max_length, 0.05, 30.0)
  settings.position.space = clamp_number(settings.position.space, 0.0, 5.0)
  settings.zero_crossing.offset = clamp_number(settings.zero_crossing.offset, -1.0, 1.0)
  settings.shepard.pitch = clamp_number(settings.shepard.pitch, 1.0, 24.0)
  settings.shepard.layers = clamp_number(settings.shepard.layers, 2, 8)
  settings.shepard.steps = clamp_number(settings.shepard.steps, 4, 32)
  if settings.shepard.direction ~= "down" then
    settings.shepard.direction = "up"
  end

  return settings
end

local function save_settings(settings)
  reaper.SetExtState(EXT_SECTION, "main_loops", tostring(settings.main.loops), true)
  reaper.SetExtState(EXT_SECTION, "main_glue", bool_to_string(settings.main.glue), true)
  reaper.SetExtState(EXT_SECTION, "main_pin", bool_to_string(settings.main.pin), true)
  reaper.SetExtState(EXT_SECTION, "crossfade_length", tostring(settings.crossfade.length), true)
  reaper.SetExtState(EXT_SECTION, "crossfade_max_length", tostring(settings.crossfade.max_length), true)
  reaper.SetExtState(EXT_SECTION, "crossfade_curve", tostring(settings.crossfade.curve), true)
  reaper.SetExtState(EXT_SECTION, "zero_crossing_offset", tostring(settings.zero_crossing.offset), true)
  reaper.SetExtState(EXT_SECTION, "position_space", tostring(settings.position.space), true)
  reaper.SetExtState(EXT_SECTION, "position_shuffle", bool_to_string(settings.position.shuffle), true)
  reaper.SetExtState(EXT_SECTION, "position_second_snap", bool_to_string(settings.position.second_snap), true)
  reaper.SetExtState(EXT_SECTION, "position_match_length", bool_to_string(settings.position.match_length), true)
  reaper.SetExtState(EXT_SECTION, "shepard_enabled", bool_to_string(settings.shepard.enabled), true)
  reaper.SetExtState(EXT_SECTION, "shepard_pitch", tostring(settings.shepard.pitch), true)
  reaper.SetExtState(EXT_SECTION, "shepard_layers", tostring(settings.shepard.layers), true)
  reaper.SetExtState(EXT_SECTION, "shepard_steps", tostring(settings.shepard.steps), true)
  reaper.SetExtState(EXT_SECTION, "shepard_direction", tostring(settings.shepard.direction), true)
  reaper.SetExtState(EXT_SECTION, "name_remove_extensions", bool_to_string(settings.name.remove_extensions), true)
  reaper.SetExtState(EXT_SECTION, "name_color_items", bool_to_string(settings.name.color_items), true)
  reaper.SetExtState(EXT_SECTION, "name_prefix", tostring(settings.name.prefix or ""), true)
  reaper.SetExtState(EXT_SECTION, "name_suffix", tostring(settings.name.suffix or ""), true)
  reaper.SetExtState(EXT_SECTION, "name_separator", tostring(settings.name.separator or ""), true)
  reaper.SetExtState(EXT_SECTION, "name_number", bool_to_string(settings.name.number), true)
  reaper.SetExtState(EXT_SECTION, "name_starting_number", tostring(settings.name.starting_number), true)
  reaper.SetExtState(EXT_SECTION, "name_leading_zeros", tostring(settings.name.leading_zeros), true)
end

local function sanitize_base_name(name, fallback_index)
  local value = trim_string(name)
  if value == "" then
    value = "Item_" .. pad_number(fallback_index or 1, 2)
  end
  return value
end

local function get_take_name_or_fallback(take, fallback_index)
  if not take then
    return sanitize_base_name("", fallback_index)
  end

  local take_name = trim_string(reaper.GetTakeName(take))
  if take_name ~= "" then
    return sanitize_base_name(take_name, fallback_index)
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if source then
    local source_name = trim_string(reaper.GetMediaSourceFileName(source))
    if source_name ~= "" then
      local basename = source_name:match("([^\\/]+)$") or source_name
      return sanitize_base_name(basename, fallback_index)
    end
  end

  return sanitize_base_name("", fallback_index)
end

local function set_take_name(take, name)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
  end
end

local function join_with_separator(left, right, separator)
  local lhs = tostring(left or "")
  local rhs = tostring(right or "")
  local sep = tostring(separator or "")

  if lhs == "" then
    return rhs
  end
  if rhs == "" then
    return lhs
  end
  if sep == "" then
    return lhs .. rhs
  end

  local lhs_has_sep = lhs:sub(-#sep) == sep
  local rhs_has_sep = rhs:sub(1, #sep) == sep
  if lhs_has_sep or rhs_has_sep then
    return lhs .. rhs
  end
  return lhs .. sep .. rhs
end

local function build_loop_name(original_name, index, settings)
  local name_settings = settings.name or DEFAULTS.name
  local base_name = trim_string(original_name)

  if name_settings.remove_extensions then
    base_name = strip_extension(base_name)
  end

  base_name = sanitize_base_name(base_name, index)
  base_name = join_with_separator(name_settings.prefix or "", base_name, name_settings.separator or "")
  base_name = join_with_separator(base_name, name_settings.suffix or "", name_settings.separator or "")

  if name_settings.number then
    local number = math.max(1, math.floor((name_settings.starting_number or 1) + index - 1))
    local formatted = pad_number(number, name_settings.leading_zeros or 2)
    base_name = join_with_separator(base_name, formatted, name_settings.separator or "")
  end

  return base_name
end

local function regenerate_chunk_guids(chunk)
  local lines = {}

  for line in tostring(chunk or ""):gmatch("[^\r\n]+") do
    local prefix = line:match("^([A-Z]*GUID)%s+")
    if prefix then
      lines[#lines + 1] = prefix .. " " .. reaper.genGuid()
    else
      lines[#lines + 1] = line
    end
  end

  return table.concat(lines, "\n")
end

local function duplicate_item_to_track(source_item, dest_track)
  if not source_item or not dest_track then
    return nil, "Invalid source item or destination track."
  end

  local ok, chunk = reaper.GetItemStateChunk(source_item, "", false)
  if not ok then
    return nil, "Failed to read source item state chunk."
  end

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  if not new_item then
    return nil, "Failed to create duplicated media item."
  end

  if not reaper.SetItemStateChunk(new_item, regenerate_chunk_guids(chunk), false) then
    reaper.DeleteTrackMediaItem(dest_track, new_item)
    return nil, "Failed to apply duplicated item state chunk."
  end

  reaper.SetMediaItemSelected(new_item, false)
  return new_item
end

local function duplicate_chunk_to_track(chunk, dest_track)
  if not chunk or not dest_track then
    return nil, "Invalid source chunk or destination track."
  end

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  if not new_item then
    return nil, "Failed to create duplicated media item."
  end

  if not reaper.SetItemStateChunk(new_item, regenerate_chunk_guids(chunk), false) then
    reaper.DeleteTrackMediaItem(dest_track, new_item)
    return nil, "Failed to apply duplicated media item state."
  end

  reaper.SetMediaItemSelected(new_item, false)
  return new_item
end

local function shuffle_array(list)
  for index = #list, 2, -1 do
    local swap_index = math.random(1, index)
    list[index], list[swap_index] = list[swap_index], list[index]
  end
end

local function get_time_selection()
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if start_time == end_time then
    return nil
  end
  return start_time, end_time
end

local function round_to_second(value)
  return math.floor((tonumber(value) or 0.0) + 0.5)
end

local function hsv_to_rgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)

  i = i % 6
  if i == 0 then
    return v, t, p
  elseif i == 1 then
    return q, v, p
  elseif i == 2 then
    return p, v, t
  elseif i == 3 then
    return p, q, v
  elseif i == 4 then
    return t, p, v
  end
  return v, p, q
end

local function get_loop_color(index, total)
  local hue = ((tonumber(index) or 1) - 1) / math.max(tonumber(total) or 1, 1)
  local r, g, b = hsv_to_rgb(hue, 0.60, 0.92)
  return reaper.ColorToNative(
    math.floor(r * 255),
    math.floor(g * 255),
    math.floor(b * 255)
  ) | REAPER_COLOR_FLAG
end

local function apply_item_color(item, color)
  if item and color then
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
  end
end

local function apply_track_color(track, color)
  if track and color then
    reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
  end
end

local function delete_media_item(item)
  if not item then
    return
  end
  if reaper.ValidatePtr2 and not reaper.ValidatePtr2(0, item, "MediaItem*") then
    return
  end
  local track = reaper.GetMediaItemTrack(item)
  if track then
    reaper.DeleteTrackMediaItem(track, item)
  end
end

local function get_track_number(track)
  if not track then
    return 0
  end
  return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
end

local function collect_selected_audio_items()
  local items = {}
  local skipped_no_take = 0
  local skipped_midi = 0
  local selected_count = reaper.CountSelectedMediaItems(0)

  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    local take = item and reaper.GetActiveTake(item) or nil

    if item and take then
      if reaper.TakeIsMIDI and reaper.TakeIsMIDI(take) then
        skipped_midi = skipped_midi + 1
      else
        local track = reaper.GetMediaItemTrack(item)
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

        items[#items + 1] = {
          item = item,
          take = take,
          track = track,
          position = position,
          length = length,
          track_number = get_track_number(track),
          base_name = get_take_name_or_fallback(take, index + 1),
          source_index = index + 1,
        }
      end
    else
      skipped_no_take = skipped_no_take + 1
    end
  end

  table.sort(items, function(left, right)
    if left.track_number ~= right.track_number then
      return left.track_number < right.track_number
    end
    if left.position ~= right.position then
      return left.position < right.position
    end
    return left.source_index < right.source_index
  end)

  return items, skipped_no_take, skipped_midi
end

local function save_selected_media_items()
  local selected = {}
  local count = reaper.CountSelectedMediaItems(0)
  for index = 0, count - 1 do
    selected[#selected + 1] = reaper.GetSelectedMediaItem(0, index)
  end
  return selected
end

local function restore_selected_media_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items or {}) do
    if item and ((not reaper.ValidatePtr2) or reaper.ValidatePtr2(0, item, "MediaItem*")) then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function calculate_search_span(item_length, settings)
  local zero_settings = settings.zero_crossing or DEFAULTS.zero_crossing
  local proportional = item_length * (zero_settings.search_fraction or DEFAULTS.zero_crossing.search_fraction)
  local limited = math.min(proportional, zero_settings.max_search_seconds or DEFAULTS.zero_crossing.max_search_seconds)
  local minimum = math.min(item_length * 0.5, 0.050)
  return clamp_number(limited, minimum, math.max(minimum, item_length * 0.5))
end

local function get_take_audio_format(take)
  local source = take and reaper.GetMediaItemTake_Source(take) or nil
  local sample_rate = source and reaper.GetMediaSourceSampleRate(source) or 0
  local channels = source and reaper.GetMediaSourceNumChannels(source) or 1

  if sample_rate == nil or sample_rate <= 0 then
    sample_rate = 44100
  end
  if channels == nil or channels < 1 then
    channels = 1
  end

  return sample_rate, channels
end

local function select_nearest_candidates(crossings, target_time, max_candidates)
  local best = {}
  local limit = math.max(1, math.floor(max_candidates or MAX_PAIR_CANDIDATES))

  for _, crossing in ipairs(crossings or {}) do
    local candidate = {
      time = crossing.time,
      direction = crossing.direction,
      distance = math.abs((crossing.time or 0.0) - target_time),
    }

    local inserted = false
    for insert_index = 1, #best do
      if candidate.distance < best[insert_index].distance then
        table.insert(best, insert_index, candidate)
        inserted = true
        break
      end
    end

    if not inserted and #best < limit then
      best[#best + 1] = candidate
    end

    if #best > limit then
      table.remove(best)
    end
  end

  for _, candidate in ipairs(best) do
    candidate.distance = nil
  end

  return best
end

local function scan_zero_crossings(accessor, item_position, sample_rate, channels, local_start, local_end)
  local zero_crossings = {}
  local accessor_start = reaper.GetAudioAccessorStartTime(accessor)
  local accessor_end = reaper.GetAudioAccessorEndTime(accessor)
  local project_start = clamp_number(item_position + local_start, accessor_start, accessor_end)
  local project_end = clamp_number(item_position + local_end, accessor_start, accessor_end)

  if project_end <= project_start then
    return zero_crossings
  end

  local buffer = reaper.new_array(ZERO_CROSSING_BLOCK_SIZE * channels)
  local position = project_start
  local prev_sample = nil

  while position < project_end do
    local samples_remaining = math.floor(((project_end - position) * sample_rate) + 0.00001)
    local samples_to_read = math.min(ZERO_CROSSING_BLOCK_SIZE, samples_remaining)
    if samples_to_read <= 0 then
      break
    end

    buffer.clear()
    local retval = reaper.GetAudioAccessorSamples(accessor, sample_rate, channels, position, samples_to_read, buffer)
    if retval < 0 then
      break
    end
    if retval == 0 then
      break
    end

    local local_block_start = position - item_position
    for sample_index = 1, samples_to_read do
      local mixed = 0.0
      local base_index = (sample_index - 1) * channels
      for channel_index = 1, channels do
        mixed = mixed + buffer[base_index + channel_index]
      end
      mixed = mixed / channels

      if prev_sample ~= nil then
        local crossed = (prev_sample >= 0.0 and mixed < 0.0) or (prev_sample < 0.0 and mixed >= 0.0)
        if crossed then
          local sample_time = local_block_start + ((sample_index - 1) / sample_rate)
          local exact_time = sample_time

          if prev_sample ~= mixed then
            local denominator = math.abs(prev_sample) + math.abs(mixed)
            if denominator > 0 then
              local fraction = math.abs(prev_sample) / denominator
              exact_time = sample_time - ((1.0 - fraction) / sample_rate)
            end
          end

          if exact_time >= local_start and exact_time <= local_end then
            zero_crossings[#zero_crossings + 1] = {
              time = exact_time,
              direction = mixed >= 0.0 and "rising" or "falling",
            }
          end
        end
      end

      prev_sample = mixed
    end

    position = position + (samples_to_read / sample_rate)
  end

  return zero_crossings
end

local function build_search_window(target_time, range_start, range_end, search_span)
  local span = math.max((range_end or 0.0) - (range_start or 0.0), 0.0)
  local width = clamp_number(search_span or 0.0, MIN_LOOP_LENGTH_SEC, math.max(MIN_LOOP_LENGTH_SEC, span))
  local window_start = clamp_number((target_time or range_start) - (width * 0.5), range_start, range_end)
  local window_end = clamp_number(window_start + width, range_start, range_end)

  if (window_end - window_start) < width then
    window_start = math.max(range_start, window_end - width)
  end

  return window_start, window_end
end

local function resolve_target_span(range_start, range_end, desired_length, offset)
  local source_start = tonumber(range_start) or 0.0
  local source_end = tonumber(range_end) or source_start
  local available = math.max(source_end - source_start, 0.0)
  local target_length = desired_length and clamp_number(desired_length, MIN_LOOP_LENGTH_SEC, available) or available
  local clamped_offset = clamp_number(offset or 0.0, -1.0, 1.0)

  if target_length < available then
    local normalized = (clamped_offset + 1.0) * 0.5
    local max_shift = available - target_length
    local shift = max_shift * normalized
    local target_start = source_start + shift
    return target_start, target_start + target_length
  end

  local bias = clamped_offset * math.min(available * 0.20, 1.0)
  local target_start = clamp_number(source_start + math.max(0.0, bias), source_start, math.max(source_start, source_end - MIN_LOOP_LENGTH_SEC))
  local target_end = clamp_number(source_end + math.min(0.0, bias), target_start + MIN_LOOP_LENGTH_SEC, source_end)
  return target_start, target_end
end

local function choose_best_loop_pair(start_candidates, end_candidates, start_target, end_target)
  local synthetic_start = { time = start_target, direction = "any" }
  local synthetic_end = { time = end_target, direction = "any" }
  local starts = (#start_candidates > 0) and start_candidates or { synthetic_start }
  local ends = (#end_candidates > 0) and end_candidates or { synthetic_end }

  local best_start = synthetic_start
  local best_end = synthetic_end
  local best_score = math.huge
  local best_same_direction = false

  for _, start_candidate in ipairs(starts) do
    for _, end_candidate in ipairs(ends) do
      local loop_span = (end_candidate.time or 0.0) - (start_candidate.time or 0.0)
      if loop_span > MIN_LOOP_LENGTH_SEC then
        local start_penalty = math.abs((start_candidate.time or 0.0) - (start_target or 0.0))
        local end_penalty = math.abs((end_candidate.time or 0.0) - (end_target or 0.0))
        local same_direction = (
          start_candidate.direction == "any" or
          end_candidate.direction == "any" or
          start_candidate.direction == end_candidate.direction
        )
        local direction_penalty = same_direction and 0.0 or 0.05
        local score = start_penalty + end_penalty + direction_penalty

        if score < best_score or (math.abs(score - best_score) < 1e-9 and loop_span > (best_end.time - best_start.time)) then
          best_start = start_candidate
          best_end = end_candidate
          best_score = score
          best_same_direction = same_direction
        end
      end
    end
  end

  return best_start, best_end, best_same_direction
end

local function find_best_loop_points_in_range(item, settings, range_start, range_end, desired_length)
  local take = item and reaper.GetActiveTake(item) or nil
  if not item or not take then
    return nil, "No active take."
  end

  if reaper.TakeIsMIDI and reaper.TakeIsMIDI(take) then
    return nil, "MIDI items are not supported."
  end

  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local source_start = clamp_number(range_start or 0.0, 0.0, item_length)
  local source_end = clamp_number(range_end or item_length, source_start, item_length)
  local source_span = source_end - source_start

  if source_span <= MIN_LOOP_LENGTH_SEC then
    return nil, "Item is too short for loop generation."
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local sample_rate, channels = get_take_audio_format(take)
  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    return nil, "Unable to create audio accessor."
  end

  local target_start, target_end = resolve_target_span(
    source_start,
    source_end,
    desired_length,
    settings.zero_crossing and settings.zero_crossing.offset or DEFAULTS.zero_crossing.offset
  )
  local search_span = math.min(calculate_search_span(source_span, settings), source_span)
  local start_window_start, start_window_end = build_search_window(target_start, source_start, source_end, search_span)
  local end_window_start, end_window_end = build_search_window(target_end, source_start, source_end, search_span)
  local start_crossings = scan_zero_crossings(accessor, item_position, sample_rate, channels, start_window_start, start_window_end)
  local end_crossings = scan_zero_crossings(accessor, item_position, sample_rate, channels, end_window_start, end_window_end)

  reaper.DestroyAudioAccessor(accessor)

  local nearest_starts = select_nearest_candidates(start_crossings, target_start, MAX_PAIR_CANDIDATES)
  local nearest_ends = select_nearest_candidates(end_crossings, target_end, MAX_PAIR_CANDIDATES)
  local best_start, best_end, same_direction = choose_best_loop_pair(nearest_starts, nearest_ends, target_start, target_end)

  if not best_start or not best_end or best_end.time <= best_start.time then
    best_start = { time = target_start, direction = "any" }
    best_end = { time = target_end, direction = "any" }
    same_direction = false
  end

  return {
    loop_start = best_start.time or 0.0,
    loop_end = best_end.time or item_length,
    search_span = search_span,
    target_start = target_start,
    target_end = target_end,
    source_start = source_start,
    source_end = source_end,
    start_window_start = start_window_start,
    start_window_end = start_window_end,
    end_window_start = end_window_start,
    end_window_end = end_window_end,
    start_crossings = start_crossings,
    end_crossings = end_crossings,
    matched_same_direction = same_direction,
  }
end

local function find_best_loop_points(item, settings)
  local item_length = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0.0
  return find_best_loop_points_in_range(item, settings, 0.0, item_length, nil)
end

local function calculate_crossfade_length(loop_length, settings)
  local target_length = math.max(tonumber(loop_length) or 0.0, 0.0)
  if target_length <= 0 then
    return 0.0
  end

  local ratio = clamp_number(settings.crossfade.length or DEFAULTS.crossfade.length, 0.01, 0.5)
  local proportional = target_length * ratio
  local max_length = clamp_number(settings.crossfade.max_length or DEFAULTS.crossfade.max_length, 0.05, 30.0)
  local hard_limit = target_length * 0.45

  if hard_limit <= 0 then
    return 0.0
  end

  if hard_limit <= MIN_CROSSFADE_SEC then
    return hard_limit
  end

  return clamp_number(math.min(proportional, max_length), MIN_CROSSFADE_SEC, hard_limit)
end

local function apply_fade_shape(item, is_fade_in, length, curve_option)
  if not item then
    return
  end

  local curve = curve_option or get_curve_option(DEFAULTS.crossfade.curve)
  if is_fade_in then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", math.max(0.0, length or 0.0))
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", -1.0)
    reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", curve.shape or 0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", curve.fadein_dir or 0.0)
  else
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.max(0.0, length or 0.0))
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", -1.0)
    reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", curve.shape or 0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", curve.fadeout_dir or 0.0)
  end
end

local function glue_pair(main_item, overlay_item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(main_item, true)
  reaper.SetMediaItemSelected(overlay_item, true)
  reaper.Main_OnCommand(GLUE_ITEMS_COMMAND, 0)
  return reaper.GetSelectedMediaItem(0, 0)
end

local function create_seamless_loop(item, settings, index, options)
  options = options or {}

  local take = item and reaper.GetActiveTake(item) or nil
  if not item or not take then
    return false, "No active take."
  end

  if reaper.TakeIsMIDI and reaper.TakeIsMIDI(take) then
    return false, "MIDI items are not supported."
  end

  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local track = reaper.GetMediaItemTrack(item)
  local destination_position = tonumber(options.dest_position)
  local desired_target_length = tonumber(options.target_length)
  local source_range_start = clamp_number(options.range_start or 0.0, 0.0, item_length)
  local source_range_end = clamp_number(options.range_end or item_length, source_range_start, item_length)
  local use_glue = options.force_glue
  if use_glue == nil then
    use_glue = settings.main.glue
  end

  if not track then
    return false, "Item has no destination track."
  end
  if destination_position == nil then
    destination_position = item_position
  end

  local has_chunk, original_chunk = reaper.GetItemStateChunk(item, "", false)
  if not has_chunk then
    return false, "Failed to cache the original item state."
  end

  local function restore_original_item()
    reaper.SetItemStateChunk(item, original_chunk, false)
  end

  local loop_points, loop_err = find_best_loop_points_in_range(item, settings, source_range_start, source_range_end, desired_target_length)
  if not loop_points then
    return false, loop_err or "Failed to find loop points."
  end

  local loop_start = clamp_number(loop_points.loop_start or source_range_start, source_range_start, source_range_end)
  local loop_end = clamp_number(loop_points.loop_end or source_range_end, source_range_start, source_range_end)
  local loop_span = loop_end - loop_start
  local crossfade_length = calculate_crossfade_length(loop_span, settings)
  local final_length = loop_span

  if loop_span <= MIN_LOOP_LENGTH_SEC then
    return false, "Loop span is too short after zero-crossing trim."
  end
  if crossfade_length <= 0.0 then
    return false, "Crossfade length resolved to zero."
  end
  if loop_span <= (crossfade_length + MIN_LOOP_LENGTH_SEC) then
    return false, "Crossfade is too long for the detected loop span."
  end

  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate == nil or playrate <= 0.0 then
    playrate = 1.0
  end

  local original_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local trimmed_offset = original_offset + (loop_start * playrate)
  local loop_name = build_loop_name(get_take_name_or_fallback(take, index), index, settings)
  local curve = get_curve_option(settings.crossfade.curve)

  if desired_target_length and desired_target_length > 0.0 then
    if desired_target_length > loop_span and use_glue then
      final_length = desired_target_length
    elseif math.abs(desired_target_length - loop_span) <= LENGTH_MATCH_TOLERANCE_SEC then
      final_length = desired_target_length
    end
  end

  if settings.position.second_snap then
    destination_position = round_to_second(destination_position)
    local rounded_length = round_to_second(final_length)
    if rounded_length > MIN_LOOP_LENGTH_SEC and math.abs(rounded_length - final_length) <= LENGTH_MATCH_TOLERANCE_SEC then
      final_length = rounded_length
    end
  end

  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", destination_position)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", loop_span)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", trimmed_offset)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0.0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0.0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", -1.0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", -1.0)
  apply_fade_shape(item, false, crossfade_length, curve)
  set_take_name(take, loop_name)

  local overlay_item, duplicate_err = duplicate_item_to_track(item, track)
  if not overlay_item then
    restore_original_item()
    return false, duplicate_err or "Failed to duplicate head segment."
  end

  local overlay_take = reaper.GetActiveTake(overlay_item)
  if not overlay_take then
    reaper.DeleteTrackMediaItem(track, overlay_item)
    restore_original_item()
    return false, "Failed to access duplicated take."
  end

  reaper.SetMediaItemInfo_Value(overlay_item, "B_LOOPSRC", 0)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_POSITION", destination_position + loop_span - crossfade_length)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_LENGTH", crossfade_length)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_FADEINLEN", 0.0)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_FADEOUTLEN", 0.0)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_FADEINLEN_AUTO", -1.0)
  reaper.SetMediaItemInfo_Value(overlay_item, "D_FADEOUTLEN_AUTO", -1.0)
  reaper.SetMediaItemTakeInfo_Value(overlay_take, "D_STARTOFFS", trimmed_offset)
  apply_fade_shape(overlay_item, true, crossfade_length, curve)
  set_take_name(overlay_take, loop_name .. "__xfade")

  local result_item = item
  if use_glue then
    local glued_item = glue_pair(item, overlay_item)
    if not glued_item then
      if overlay_item then
        reaper.DeleteTrackMediaItem(track, overlay_item)
      end
      restore_original_item()
      return false, "Glue command failed."
    end

    result_item = glued_item
    local result_take = reaper.GetActiveTake(result_item)
    if result_take then
      set_take_name(result_take, loop_name)
    end
    reaper.SetMediaItemInfo_Value(result_item, "D_POSITION", destination_position)
    reaper.SetMediaItemInfo_Value(result_item, "D_LENGTH", final_length)
    reaper.SetMediaItemInfo_Value(result_item, "B_LOOPSRC", 1)
    reaper.SetMediaItemInfo_Value(result_item, "D_FADEINLEN_AUTO", -1.0)
    reaper.SetMediaItemInfo_Value(result_item, "D_FADEOUTLEN_AUTO", -1.0)
  else
    reaper.SetMediaItemInfo_Value(result_item, "D_POSITION", destination_position)
  end

  if settings.name.color_items then
    apply_item_color(result_item, get_loop_color(index, math.max(settings.main.loops or 1, 1)))
  end

  return true, {
    item = result_item,
    loop_name = loop_name,
    loop_length = loop_span,
    final_length = final_length,
    crossfade_length = crossfade_length,
    start_count = #loop_points.start_crossings,
    end_count = #loop_points.end_crossings,
    loop_points = loop_points,
  }
end

local function build_source_windows(source_length, loop_count, settings)
  local windows = {}
  local count = math.max(1, math.floor(loop_count or 1))
  local total_length = math.max(tonumber(source_length) or 0.0, 0.0)

  if count <= 1 or total_length <= MIN_LOOP_LENGTH_SEC then
    windows[1] = {
      range_start = 0.0,
      range_end = total_length,
      order = 1,
    }
    return windows
  end

  local segment_length = total_length / count
  for index = 1, count do
    local range_start = (index - 1) * segment_length
    local range_end = (index == count) and total_length or (range_start + segment_length)
    windows[#windows + 1] = {
      range_start = range_start,
      range_end = range_end,
      order = index,
    }
  end

  if settings.position.shuffle then
    shuffle_array(windows)
  end

  return windows
end

local function resolve_batch_target_length(selected_items, settings)
  local ts_start, ts_end = get_time_selection()
  if ts_start and ts_end then
    return {
      target_length = ts_end - ts_start,
      time_selection_start = ts_start,
      time_selection_end = ts_end,
      use_time_selection_start = #selected_items == 1,
    }
  end

  if settings.position.match_length and #selected_items > 1 then
    local shortest = nil
    for _, entry in ipairs(selected_items) do
      local length = tonumber(entry.length) or 0.0
      if not shortest or length < shortest then
        shortest = length
      end
    end

    if shortest and shortest > MIN_LOOP_LENGTH_SEC then
      return {
        target_length = shortest,
        use_time_selection_start = false,
      }
    end
  end

  return {
    target_length = nil,
    use_time_selection_start = false,
  }
end

local function get_track_insert_index_after(track)
  return math.max(0, get_track_number(track))
end

local function delete_track_if_valid(track)
  if not track then
    return
  end
  if reaper.ValidatePtr2 and not reaper.ValidatePtr2(0, track, "MediaTrack*") then
    return
  end
  reaper.DeleteTrack(track)
end

local function clear_preview_tracks()
  for _, track in ipairs(preview_state.preview_tracks or {}) do
    delete_track_if_valid(track)
  end
  preview_state.preview_tracks = {}
end

local function build_shepard_phase(layer_index, layer_count, step_index, step_count)
  local base_phase = (step_index - 0.5) / math.max(step_count, 1)
  local layer_offset = (layer_index - 1) / math.max(layer_count, 1)
  local phase = (base_phase + layer_offset) % 1.0
  if phase < 0.0 then
    phase = phase + 1.0
  end
  return phase
end

local function get_shepard_pitch_for_phase(phase, settings)
  local pitch_span = clamp_number(math.abs(settings.shepard.pitch or DEFAULTS.shepard.pitch), 1.0, 24.0)
  local centered = (phase * pitch_span) - (pitch_span * 0.5)
  if settings.shepard.direction == "down" then
    centered = -centered
  end
  return centered
end

local function get_shepard_gain_for_phase(phase)
  local gain = math.sin(math.pi * clamp_number(phase, 0.0, 1.0))
  gain = gain * gain
  return clamp_number(gain, 0.05, 1.0)
end

local function build_shepard_layer_name(base_name, layer_index)
  return string.format("%s_SH%02d", tostring(base_name or "Shepard"), layer_index)
end

local function create_track_after(reference_track, track_name, color, preview_mode, insert_offset)
  local insert_index = get_track_insert_index_after(reference_track) + (insert_offset or 0)
  reaper.InsertTrackAtIndex(insert_index, true)
  local new_track = reaper.GetTrack(0, insert_index)
  if new_track then
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", tostring(track_name or ""), true)
    if color then
      apply_track_color(new_track, color)
    end
    if preview_mode then
      preview_state.preview_tracks[#preview_state.preview_tracks + 1] = new_track
    end
  end
  return new_track
end

local function build_base_seamless_chunk(entry, settings, batch_context)
  local source_track = entry.track
  local ok, source_chunk = reaper.GetItemStateChunk(entry.item, "", false)
  if not ok then
    return nil, nil, "Failed to cache source item for Shepard base."
  end

  local temp_item, duplicate_err = duplicate_chunk_to_track(source_chunk, source_track)
  if not temp_item then
    return nil, nil, duplicate_err or "Failed to duplicate Shepard base source."
  end

  local ok_loop, base_result_or_err = create_seamless_loop(temp_item, settings, 1, {
    dest_position = batch_context.base_position or entry.position,
    target_length = batch_context.target_length or entry.length,
    force_glue = true,
  })
  if not ok_loop then
    delete_media_item(temp_item)
    return nil, nil, tostring(base_result_or_err or "Failed to create Shepard base loop.")
  end

  local base_item = base_result_or_err.item
  local base_take = base_item and reaper.GetActiveTake(base_item) or nil
  local base_length = base_item and reaper.GetMediaItemInfo_Value(base_item, "D_LENGTH") or (batch_context.target_length or entry.length)
  local base_offset = base_take and reaper.GetMediaItemTakeInfo_Value(base_take, "D_STARTOFFS") or 0.0
  local playrate = base_take and reaper.GetMediaItemTakeInfo_Value(base_take, "D_PLAYRATE") or 1.0
  if playrate == nil or playrate <= 0.0 then
    playrate = 1.0
  end

  local has_chunk, base_chunk = base_item and reaper.GetItemStateChunk(base_item, "", false)
  delete_media_item(base_item)

  if not has_chunk then
    return nil, nil, "Failed to cache Shepard base loop chunk."
  end

  return {
    chunk = base_chunk,
    base_length = base_length,
    base_offset = base_offset,
    playrate = playrate,
  }
end

local function glue_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items or {}) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end
  reaper.Main_OnCommand(GLUE_ITEMS_COMMAND, 0)
  return reaper.GetSelectedMediaItem(0, 0)
end

local function create_shepard_layer_items(entry, layer_track, base_info, settings, batch_context, layer_index, layer_color)
  local cycle_length = batch_context.target_length or base_info.base_length or entry.length
  local step_count = clamp_number(math.floor(settings.shepard.steps or DEFAULTS.shepard.steps), 4, 32)
  local step_length = cycle_length / step_count
  local overlap = math.min(step_length * 0.35, 0.08, step_length * 0.49)
  local layer_items = {}
  local layer_name = build_shepard_layer_name(build_loop_name(entry.base_name, batch_context.name_index + layer_index - 1, settings), layer_index)
  local function cleanup_layer_items()
    for _, layer_item in ipairs(layer_items) do
      delete_media_item(layer_item)
    end
    layer_items = {}
  end

  for step_index = 1, step_count do
    local item, err = duplicate_chunk_to_track(base_info.chunk, layer_track)
    if not item then
      cleanup_layer_items()
      return nil, tostring(err or "Failed to duplicate Shepard slice.")
    end

    local take = reaper.GetActiveTake(item)
    if not take then
      delete_media_item(item)
      cleanup_layer_items()
      return nil, "Duplicated Shepard slice has no active take."
    end

    local phase = build_shepard_phase(layer_index, settings.shepard.layers, step_index, step_count)
    local pitch = get_shepard_pitch_for_phase(phase, settings)
    local gain = get_shepard_gain_for_phase(phase)
    local position = (batch_context.base_position or entry.position) + ((step_index - 1) * step_length) - (overlap * 0.5)
    if step_index == 1 then
      position = batch_context.base_position or entry.position
    end
    local length = step_length + overlap
    local source_offset = base_info.base_offset + (phase * cycle_length * base_info.playrate)

    reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", math.min(overlap, length * 0.45))
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.min(overlap, length * 0.45))
    reaper.SetMediaItemInfo_Value(item, "D_VOL", gain)
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", source_offset)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch)
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
    set_take_name(take, string.format("%s_S%02d", layer_name, step_index))

    if settings.name.color_items then
      apply_item_color(item, layer_color)
    end

    layer_items[#layer_items + 1] = item
  end

  local glued_item = glue_items(layer_items)
  if not glued_item then
    cleanup_layer_items()
    return nil, "Failed to glue Shepard layer items."
  end

  local glued_take = reaper.GetActiveTake(glued_item)
  if glued_take then
    set_take_name(glued_take, layer_name)
  end
  reaper.SetMediaItemInfo_Value(glued_item, "D_POSITION", batch_context.base_position or entry.position)
  reaper.SetMediaItemInfo_Value(glued_item, "D_LENGTH", cycle_length)
  reaper.SetMediaItemInfo_Value(glued_item, "B_LOOPSRC", 1)
  if settings.name.color_items then
    apply_item_color(glued_item, layer_color)
  end

  return {
    item = glued_item,
    loop_name = layer_name,
    final_length = cycle_length,
    loop_length = cycle_length,
    crossfade_length = overlap,
    layer_index = layer_index,
  }
end

local function generate_shepard_for_entry(entry, settings, batch_context)
  local created = {}
  local errors = {}
  local layer_count = clamp_number(math.floor(settings.shepard.layers or DEFAULTS.shepard.layers), 2, 8)
  local base_info, _, base_err = build_base_seamless_chunk(entry, settings, batch_context)
  if not base_info then
    return nil, { tostring(base_err or "Failed to build Shepard source.") }, batch_context.name_index
  end

  for layer_index = 1, layer_count do
    local layer_color = settings.name.color_items and get_loop_color(layer_index, layer_count) or nil
    local layer_track = create_track_after(
      entry.track,
      build_shepard_layer_name(entry.base_name, layer_index),
      layer_color,
      batch_context.preview_mode,
      layer_index - 1
    )
    if not layer_track then
      errors[#errors + 1] = "Failed to create Shepard layer track."
      break
    end

    local result, err = create_shepard_layer_items(entry, layer_track, base_info, settings, batch_context, layer_index, layer_color)
    if result then
      created[#created + 1] = result
    else
      delete_track_if_valid(layer_track)
      errors[#errors + 1] = tostring(err or "Failed to create Shepard layer.")
    end
  end

  return created, errors, batch_context.name_index + layer_count
end

local function generate_loops_for_entry(entry, settings, batch_context)
  if settings.shepard.enabled then
    return generate_shepard_for_entry(entry, settings, batch_context)
  end

  local source_item = entry.item
  local source_track = entry.track
  local loop_count = math.max(1, math.floor(settings.main.loops or 1))
  local windows = build_source_windows(entry.length, loop_count, settings)
  local current_position = batch_context.base_position or entry.position
  local created = {}
  local errors = {}
  local source_chunk = nil

  if loop_count > 1 or batch_context.force_copy then
    local ok, chunk = reaper.GetItemStateChunk(source_item, "", false)
    if not ok then
      return nil, { "Failed to cache source item for loop duplication." }, batch_context.name_index
    end
    source_chunk = chunk
  end

  for window_index, window in ipairs(windows) do
    local working_item = source_item

    if batch_context.force_copy or window_index > 1 then
      local duplicated_item, duplicate_err = duplicate_chunk_to_track(source_chunk, source_track)
      working_item = duplicated_item
      if not working_item then
        errors[#errors + 1] = tostring(duplicate_err or "Failed to duplicate source item.")
        break
      end
    end

    local ok, result_or_err = create_seamless_loop(working_item, settings, batch_context.name_index, {
      range_start = window.range_start,
      range_end = window.range_end,
      dest_position = current_position,
      target_length = batch_context.target_length,
      force_glue = batch_context.force_glue,
    })

    if ok then
      created[#created + 1] = result_or_err
      batch_context.name_index = batch_context.name_index + 1

      local actual_item = result_or_err.item
      local actual_position = actual_item and reaper.GetMediaItemInfo_Value(actual_item, "D_POSITION") or current_position
      local actual_length = actual_item and reaper.GetMediaItemInfo_Value(actual_item, "D_LENGTH") or (result_or_err.final_length or result_or_err.loop_length)
      current_position = actual_position + actual_length + (settings.position.space or 0.0)
    else
      errors[#errors + 1] = tostring(result_or_err or "Loop generation failed.")
    end
  end

  return created, errors, batch_context.name_index
end

local function apply_loop_to_selection(settings)
  local selected_items, skipped_no_take, skipped_midi = collect_selected_audio_items()
  if #selected_items == 0 then
    return false, "No selected audio items with active takes.", nil
  end

  local length_context = resolve_batch_target_length(selected_items, settings)
  local undo_label = settings.shepard.enabled and "Create Shepard Tone Loop" or "Create Seamless Loop"
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local results = {}
  local errors = {}
  local name_index = 1

  for index, entry in ipairs(selected_items) do
    local batch_context = {
      base_position = (length_context.use_time_selection_start and length_context.time_selection_start) or entry.position,
      target_length = length_context.target_length,
      force_copy = false,
      force_glue = nil,
      name_index = name_index,
    }
    local created, entry_errors, next_name_index = generate_loops_for_entry(entry, settings, batch_context)
    name_index = next_name_index or name_index

    if created then
      for _, result in ipairs(created) do
        results[#results + 1] = result
      end
    end

    for _, err in ipairs(entry_errors or {}) do
      errors[#errors + 1] = string.format("%s: %s", entry.base_name, tostring(err))
    end
  end

  reaper.SelectAllMediaItems(0, false)
  for _, result in ipairs(results) do
    if result.item then
      reaper.SetMediaItemSelected(result.item, not settings.main.pin)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(undo_label, -1)

  return true, {
    processed_count = #results,
    skipped_no_take = skipped_no_take,
    skipped_midi = skipped_midi,
    errors = errors,
    results = results,
  }
end

local function is_valid_media_item(item)
  if not item then
    return false
  end
  if reaper.ValidatePtr2 then
    return reaper.ValidatePtr2(0, item, "MediaItem*")
  end
  return true
end

local function save_track_solo_states()
  preview_state.track_solo_states = {}
  local track_count = reaper.CountTracks(0)
  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    if track then
      preview_state.track_solo_states[#preview_state.track_solo_states + 1] = {
        track = track,
        solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO"),
      }
    end
  end
end

local function restore_track_solo_states()
  for _, entry in ipairs(preview_state.track_solo_states or {}) do
    if entry.track then
      reaper.SetMediaTrackInfo_Value(entry.track, "I_SOLO", entry.solo or 0.0)
    end
  end
  preview_state.track_solo_states = {}
end

local function clear_preview_items()
  for _, item in ipairs(preview_state.preview_items or {}) do
    if is_valid_media_item(item) then
      local track = reaper.GetMediaItemTrack(item)
      if track then
        reaper.DeleteTrackMediaItem(track, item)
      end
    end
  end
  preview_state.preview_items = {}
end

local function reset_preview_runtime()
  preview_state.is_previewing = false
  preview_state.source_item = nil
  preview_state.source_muted = 0.0
  preview_state.loop_start = nil
  preview_state.loop_end = nil
  preview_state.cursor_position = nil
end

local function stop_loop_preview()
  local has_preview_items = preview_state.preview_items and #preview_state.preview_items > 0
  local has_preview_tracks = preview_state.preview_tracks and #preview_state.preview_tracks > 0
  local has_source_item = is_valid_media_item(preview_state.source_item)
  local has_saved_solo = preview_state.track_solo_states and #preview_state.track_solo_states > 0

  if not preview_state.is_previewing and not has_preview_items and not has_preview_tracks and not has_source_item and not has_saved_solo then
    return
  end

  if preview_state.is_previewing then
    reaper.OnStopButton()
  end
  clear_preview_items()

  if is_valid_media_item(preview_state.source_item) then
    reaper.SetMediaItemInfo_Value(preview_state.source_item, "B_MUTE", preview_state.source_muted or 0.0)
  end

  restore_track_solo_states()
  clear_preview_tracks()

  if preview_state.loop_start and preview_state.loop_end then
    reaper.GetSet_LoopTimeRange(true, false, preview_state.loop_start, preview_state.loop_end, false)
  end

  if preview_state.cursor_position then
    reaper.SetEditCurPos(preview_state.cursor_position, false, false)
  end

  reset_preview_runtime()
  reaper.UpdateArrange()
end

start_loop_preview = function(settings)
  stop_loop_preview()
  local original_selection = save_selected_media_items()

  local selected_items = collect_selected_audio_items()
  if #selected_items == 0 then
    return false, "No selected audio item to preview."
  end

  local entry = selected_items[1]
  local length_context = resolve_batch_target_length({ entry }, settings)
  local batch_context = {
    base_position = (length_context.use_time_selection_start and length_context.time_selection_start) or entry.position,
    target_length = length_context.target_length,
    force_copy = true,
    force_glue = true,
    name_index = 1,
  }

  preview_state.source_item = entry.item
  preview_state.source_muted = reaper.GetMediaItemInfo_Value(entry.item, "B_MUTE")
  preview_state.cursor_position = reaper.GetCursorPosition()
  preview_state.loop_start, preview_state.loop_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  save_track_solo_states()

  reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", 1)

  local created, errors = generate_loops_for_entry(entry, settings, batch_context)
  if not created or #created == 0 then
    stop_loop_preview()
    restore_selected_media_items(original_selection)
    return false, table.concat(errors or { "Preview generation failed." }, "; ")
  end

  local preview_start = math.huge
  local preview_end = -math.huge
  local preview_tracks = {}
  preview_state.preview_items = {}

  for _, result in ipairs(created) do
    if result.item then
      preview_state.preview_items[#preview_state.preview_items + 1] = result.item
      local item_position = reaper.GetMediaItemInfo_Value(result.item, "D_POSITION")
      local item_length = reaper.GetMediaItemInfo_Value(result.item, "D_LENGTH")
      local preview_length = length_context.target_length or (item_length * PREVIEW_LOOP_REPETITIONS)
      reaper.SetMediaItemInfo_Value(result.item, "B_LOOPSRC", 1)
      reaper.SetMediaItemInfo_Value(result.item, "D_LENGTH", preview_length)
      preview_start = math.min(preview_start, item_position)
      preview_end = math.max(preview_end, item_position + preview_length)
      local item_track = reaper.GetMediaItemTrack(result.item)
      if item_track then
        preview_tracks[tostring(item_track)] = item_track
      end
    end
  end

  if preview_start == math.huge or preview_end <= preview_start then
    stop_loop_preview()
    restore_selected_media_items(original_selection)
    return false, "Preview range could not be calculated."
  end

  for _, track in pairs(preview_tracks) do
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1)
  end

  reaper.OnStopButton()
  reaper.SetEditCurPos(preview_start, false, false)
  reaper.GetSet_LoopTimeRange(true, false, preview_start, preview_end, false)
  reaper.OnPlayButton()

  preview_state.is_previewing = true
  restore_selected_media_items(original_selection)
  reaper.UpdateArrange()
  return true
end

local function toggle_loop_preview(settings)
  if preview_state.is_previewing then
    stop_loop_preview()
    return true
  end
  return start_loop_preview(settings)
end

local function analyze_selected_item(settings)
  local selected_items, skipped_no_take, skipped_midi = collect_selected_audio_items()

  if #selected_items == 0 then
    return {
      selected_count = 0,
      skipped_no_take = skipped_no_take,
      skipped_midi = skipped_midi,
      message = "Select at least one audio item with an active take.",
    }
  end

  local first = selected_items[1]
  local length_context = resolve_batch_target_length({ first }, settings)
  local windows = build_source_windows(first.length, settings.main.loops, settings)
  local first_window = windows[1] or { range_start = 0.0, range_end = first.length, order = 1 }
  local loop_points, err = find_best_loop_points_in_range(
    first.item,
    settings,
    first_window.range_start,
    first_window.range_end,
    length_context.target_length
  )
  if not loop_points then
    return {
      selected_count = #selected_items,
      skipped_no_take = skipped_no_take,
      skipped_midi = skipped_midi,
      item_name = first.base_name,
      message = err or "Unable to analyze selected item.",
    }
  end

  local loop_length = (loop_points.loop_end or first.length) - (loop_points.loop_start or 0.0)
  local crossfade_length = calculate_crossfade_length(loop_length, settings)

  return {
    selected_count = #selected_items,
    skipped_no_take = skipped_no_take,
    skipped_midi = skipped_midi,
    item_name = first.base_name,
    item_length = first.length,
    loop_length = loop_length,
    crossfade_length = crossfade_length,
    start_crossings = loop_points.start_crossings,
    end_crossings = loop_points.end_crossings,
    start_count = #loop_points.start_crossings,
    end_count = #loop_points.end_crossings,
    matched_same_direction = loop_points.matched_same_direction,
    source_window = first_window,
    target_length = length_context.target_length,
    loops = settings.main.loops,
    shepard_enabled = settings.shepard.enabled,
    shepard_layers = settings.shepard.layers,
    shepard_steps = settings.shepard.steps,
    shepard_pitch = settings.shepard.pitch,
    shepard_direction = settings.shepard.direction,
    message = settings.shepard.enabled and string.format(
      "Shepard base %s | Layers %d | Steps %d | Pitch %s %.0f st | Base ZC %d/%d",
      format_seconds(loop_length),
      settings.shepard.layers,
      settings.shepard.steps,
      settings.shepard.direction == "down" and "down" or "up",
      settings.shepard.pitch,
      #loop_points.start_crossings,
      #loop_points.end_crossings
    ) or string.format(
      "Start ZC %d / End ZC %d | Loop %s | XFade %s",
      #loop_points.start_crossings,
      #loop_points.end_crossings,
      format_seconds(loop_length),
      format_seconds(crossfade_length)
    ),
  }
end

build_selection_signature = function(settings)
  local count = reaper.CountSelectedMediaItems(0)
  local first_item = count > 0 and reaper.GetSelectedMediaItem(0, 0) or nil
  local first_take = first_item and reaper.GetActiveTake(first_item) or nil
  local item_position = first_item and reaper.GetMediaItemInfo_Value(first_item, "D_POSITION") or -1
  local item_length = first_item and reaper.GetMediaItemInfo_Value(first_item, "D_LENGTH") or -1
  local take_name = first_take and trim_string(reaper.GetTakeName(first_take)) or ""

  return table.concat({
    tostring(count),
    tostring(first_item),
    tostring(item_position),
    tostring(item_length),
    take_name,
    tostring(settings.main.loops),
    tostring(settings.crossfade.length),
    tostring(settings.crossfade.max_length),
    tostring(settings.crossfade.curve),
    tostring(settings.position.space),
    tostring(settings.position.shuffle),
    tostring(settings.position.second_snap),
    tostring(settings.position.match_length),
    tostring(settings.zero_crossing.offset),
    tostring(settings.shepard.enabled),
    tostring(settings.shepard.pitch),
    tostring(settings.shepard.layers),
    tostring(settings.shepard.steps),
    tostring(settings.shepard.direction),
    tostring(settings.name.remove_extensions),
    tostring(settings.name.color_items),
    tostring(settings.name.number),
  }, "|")
end

local function update_analysis_cache(state)
  local signature = build_selection_signature(state.settings)
  if signature ~= state.analysis_signature then
    state.analysis = analyze_selected_item(state.settings)
    state.analysis_signature = signature
  end
end

local function example_loop_name(state)
  local source_name = "Example.wav"
  if state.analysis and state.analysis.item_name and state.analysis.item_name ~= "" then
    source_name = state.analysis.item_name
  end
  return build_loop_name(source_name, state.settings.name.starting_number or 1, state.settings)
end

local function prompt_name_settings(settings)
  local current = settings.name
  local captions = table.concat({
    "extrawidth=360",
    "separator=|",
    "Prefix",
    "Suffix",
    "Separator",
    "Number (y/n)",
    "Start Number",
    "Pad",
    "Remove Extensions (y/n)",
    "Color Items (y/n)",
  }, ",")

  local defaults = table.concat({
    tostring(current.prefix or ""),
    tostring(current.suffix or ""),
    tostring(current.separator or ""),
    bool_to_string(current.number),
    tostring(current.starting_number or 1),
    tostring(current.leading_zeros or 2),
    bool_to_string(current.remove_extensions),
    bool_to_string(current.color_items),
  }, "|")

  local ok, csv = reaper.GetUserInputs(SCRIPT_TITLE .. " - Name Settings", 8, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = {}
  local start_index = 1
  local source = tostring(csv or "")
  while true do
    local found = source:find("|", start_index, true)
    if not found then
      parts[#parts + 1] = source:sub(start_index)
      break
    end
    parts[#parts + 1] = source:sub(start_index, found - 1)
    start_index = found + 1
  end
  while #parts < 8 do
    parts[#parts + 1] = ""
  end

  local updated = deep_copy(settings)
  updated.name.prefix = parts[1] or ""
  updated.name.suffix = parts[2] or ""
  updated.name.separator = parts[3] or ""
  updated.name.number = parse_boolean(parts[4], current.number)
  updated.name.starting_number = math.max(1, math.floor((tonumber(parts[5]) or current.starting_number or 1) + 0.5))
  updated.name.leading_zeros = clamp_number(math.floor((tonumber(parts[6]) or current.leading_zeros or 2) + 0.5), 1, 6)
  updated.name.remove_extensions = parse_boolean(parts[7], current.remove_extensions)
  updated.name.color_items = parse_boolean(parts[8], current.color_items)

  return updated
end

local function prompt_phase2_settings(settings)
  local captions = table.concat({
    "extrawidth=320",
    "separator=|",
    "Loops",
    "Space (sec)",
    "Shuffle (y/n)",
    "Second Snap (y/n)",
    "Match Length (y/n)",
    "Zero Offset (-1..1)",
    "Shepard Mode (y/n)",
    "Shepard Pitch",
    "Shepard Direction (up/down)",
    "Shepard Layers",
    "Shepard Steps",
  }, ",")

  local defaults = table.concat({
    tostring(settings.main.loops),
    tostring(settings.position.space),
    bool_to_string(settings.position.shuffle),
    bool_to_string(settings.position.second_snap),
    bool_to_string(settings.position.match_length),
    tostring(settings.zero_crossing.offset),
    bool_to_string(settings.shepard.enabled),
    tostring(settings.shepard.pitch),
    tostring(settings.shepard.direction),
    tostring(settings.shepard.layers),
    tostring(settings.shepard.steps),
  }, "|")

  local ok, csv = reaper.GetUserInputs(SCRIPT_TITLE .. " - Advanced Settings", 11, captions, defaults)
  if not ok then
    return nil, "User cancelled."
  end

  local parts = {}
  local start_index = 1
  local source = tostring(csv or "")
  while true do
    local found = source:find("|", start_index, true)
    if not found then
      parts[#parts + 1] = source:sub(start_index)
      break
    end
    parts[#parts + 1] = source:sub(start_index, found - 1)
    start_index = found + 1
  end
  while #parts < 11 do
    parts[#parts + 1] = ""
  end

  local updated = deep_copy(settings)
  updated.main.loops = clamp_number(math.floor((tonumber(parts[1]) or settings.main.loops) + 0.5), 1, 32)
  updated.position.space = clamp_number(tonumber(parts[2]) or settings.position.space, 0.0, 5.0)
  updated.position.shuffle = parse_boolean(parts[3], settings.position.shuffle)
  updated.position.second_snap = parse_boolean(parts[4], settings.position.second_snap)
  updated.position.match_length = parse_boolean(parts[5], settings.position.match_length)
  updated.zero_crossing.offset = clamp_number(tonumber(parts[6]) or settings.zero_crossing.offset, -1.0, 1.0)
  updated.shepard.enabled = parse_boolean(parts[7], settings.shepard.enabled)
  updated.shepard.pitch = clamp_number(math.abs(tonumber(parts[8]) or settings.shepard.pitch), 1.0, 24.0)
  updated.shepard.direction = trim_string(parts[9]):lower() == "down" and "down" or "up"
  updated.shepard.layers = clamp_number(math.floor((tonumber(parts[10]) or settings.shepard.layers) + 0.5), 2, 8)
  updated.shepard.steps = clamp_number(math.floor((tonumber(parts[11]) or settings.shepard.steps) + 0.5), 4, 32)
  return updated
end

local function create_gui_state()
  return {
    settings = load_settings(),
    should_close = false,
    prev_mouse_down = false,
    active_slider = nil,
    hit_regions = {},
    pending_action = nil,
    status_message = "Phase 3 ready. Space previews the first selected item.",
    analysis_signature = nil,
    analysis = nil,
    imgui_context = nil,
    imgui_open = true,
    pin_waiting_for_selection = false,
    auto_preview_signature = nil,
  }
end

local function set_status(state, message)
  state.status_message = tostring(message or "")
end

local function mark_dirty(state)
  state.analysis_signature = nil
end

local function maybe_auto_preview(state)
  if not state.settings.main.pin or not state.pin_waiting_for_selection then
    return
  end

  local current_signature = build_selection_signature(state.settings)
  if current_signature ~= state.auto_preview_signature and reaper.CountSelectedMediaItems(0) > 0 then
    state.auto_preview_signature = current_signature
    state.pin_waiting_for_selection = false
    local ok, err = start_loop_preview(state.settings)
    if ok then
      set_status(state, "Preview playing.")
    elseif err then
      set_status(state, tostring(err))
    end
  end
end

local function get_slider_value(settings, slider_id)
  if slider_id == "main_loops" then
    return settings.main.loops
  end
  if slider_id == "position_space" then
    return settings.position.space
  end
  if slider_id == "zero_offset" then
    return settings.zero_crossing.offset
  end
  if slider_id == "crossfade_length" then
    return settings.crossfade.length
  end
  if slider_id == "crossfade_max_length" then
    return settings.crossfade.max_length
  end
  if slider_id == "shepard_pitch" then
    return settings.shepard.pitch
  end
  if slider_id == "shepard_layers" then
    return settings.shepard.layers
  end
  if slider_id == "shepard_steps" then
    return settings.shepard.steps
  end
  return 0.0
end

local function set_slider_value(settings, slider_id, value)
  if slider_id == "main_loops" then
    settings.main.loops = clamp_number(math.floor(value + 0.5), 1, 32)
  elseif slider_id == "position_space" then
    settings.position.space = clamp_number(round_to(value, 2), 0.0, 5.0)
  elseif slider_id == "zero_offset" then
    settings.zero_crossing.offset = clamp_number(round_to(value, 2), -1.0, 1.0)
  elseif slider_id == "crossfade_length" then
    settings.crossfade.length = clamp_number(round_to(value, 3), 0.01, 0.5)
  elseif slider_id == "crossfade_max_length" then
    settings.crossfade.max_length = clamp_number(round_to(value, 2), 0.05, 30.0)
  elseif slider_id == "shepard_pitch" then
    settings.shepard.pitch = clamp_number(math.floor(value + 0.5), 1, 24)
  elseif slider_id == "shepard_layers" then
    settings.shepard.layers = clamp_number(math.floor(value + 0.5), 2, 8)
  elseif slider_id == "shepard_steps" then
    settings.shepard.steps = clamp_number(math.floor(value + 0.5), 4, 32)
  end
end

local function draw_checkbox(state, x, y, key, value, label)
  local size = 16
  set_color(34, 38, 44, 255)
  gfx.rect(x, y, size, size, true)
  set_color(88, 96, 108, 255)
  gfx.rect(x, y, size, size, false)

  if value then
    set_color(84, 168, 255, 255)
    gfx.rect(x + 3, y + 3, size - 6, size - 6, true)
  end

  gfx.setfont(1, "Arial", 14)
  draw_text(x + size + 8, y - 1, label, 230, 234, 240, 255)
  local label_w = gfx.measurestr(label)
  register_hit_region(state, "checkbox", x, y, size + 8 + label_w, size, { key = key })
end

local function draw_button(state, x, y, w, h, label, action, options)
  options = options or {}
  local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, y, w, h)
  local active = options.active == true
  local bg = { 58, 64, 74, 255 }
  local border = { 92, 100, 110, 255 }

  if options.primary then
    bg = hovered and { 66, 126, 214, 255 } or { 54, 108, 198, 255 }
    border = { 96, 152, 236, 255 }
  elseif active then
    bg = hovered and { 88, 118, 72, 255 } or { 72, 102, 58, 255 }
    border = { 132, 178, 114, 255 }
  elseif hovered then
    bg = { 70, 78, 90, 255 }
  end

  set_color(bg[1], bg[2], bg[3], bg[4])
  gfx.rect(x, y, w, h, true)
  set_color(border[1], border[2], border[3], border[4])
  gfx.rect(x, y, w, h, false)

  gfx.setfont(1, "Arial", 14)
  local text_w, text_h = gfx.measurestr(label)
  draw_text(x + ((w - text_w) * 0.5), y + ((h - text_h) * 0.5), label, 245, 247, 250, 255)
  register_hit_region(state, "button", x, y, w, h, { action = action })
end

local function draw_slider(state, slider_id, label, value, min_value, max_value, step, formatter, x, y)
  local normalized = 0.0
  local track_y = y + 18
  local value_x = x + GUI.slider_w + 22
  local hit_y = track_y - 6
  local hit_h = GUI.slider_h + 12

  if max_value > min_value then
    normalized = (value - min_value) / (max_value - min_value)
  end
  normalized = clamp_number(normalized, 0.0, 1.0)

  gfx.setfont(1, "Arial", 14)
  draw_text(x, y, label, 234, 236, 241, 255)
  draw_text(value_x, y, formatter(value), 205, 211, 220, 255)

  set_color(34, 38, 44, 255)
  gfx.rect(x, track_y, GUI.slider_w, GUI.slider_h, true)
  set_color(18, 22, 26, 255)
  gfx.rect(x, track_y, GUI.slider_w, GUI.slider_h, false)
  set_color(84, 168, 255, 255)
  gfx.rect(x, track_y, GUI.slider_w * normalized, GUI.slider_h, true)

  local handle_x = x + (GUI.slider_w * normalized)
  set_color(244, 247, 250, 255)
  gfx.rect(handle_x - 4, track_y - 3, 8, GUI.slider_h + 6, true)

  register_hit_region(state, "slider", x, hit_y, GUI.slider_w, hit_h, {
    id = slider_id,
    min = min_value,
    max = max_value,
    step = step,
  })
end

local function begin_frame(state)
  state.hit_regions = {}
end

local function update_slider_from_mouse(state, slider_data)
  if not slider_data then
    return
  end

  local normalized = clamp_number((gfx.mouse_x - slider_data.x) / slider_data.w, 0.0, 1.0)
  local raw_value = slider_data.min + ((slider_data.max - slider_data.min) * normalized)
  local stepped_value = round_to(raw_value / slider_data.step, 0) * slider_data.step
  local old_value = get_slider_value(state.settings, slider_data.id)

  set_slider_value(state.settings, slider_data.id, stepped_value)
  local new_value = get_slider_value(state.settings, slider_data.id)

  if math.abs(new_value - old_value) > 1e-9 then
    save_settings(state.settings)
    mark_dirty(state)
  end
end

local function handle_mouse(state)
  local mouse_down = (gfx.mouse_cap % 2) == 1
  local just_pressed = mouse_down and not state.prev_mouse_down

  if just_pressed then
    local hit = nil
    for index = #state.hit_regions, 1, -1 do
      local region = state.hit_regions[index]
      if point_in_rect(gfx.mouse_x, gfx.mouse_y, region.x, region.y, region.w, region.h) then
        hit = region
        break
      end
    end

    if hit then
      if hit.kind == "checkbox" then
        if hit.data.key == "main_glue" then
          state.settings.main.glue = not state.settings.main.glue
        elseif hit.data.key == "main_pin" then
          state.settings.main.pin = not state.settings.main.pin
        elseif hit.data.key == "position_shuffle" then
          state.settings.position.shuffle = not state.settings.position.shuffle
        elseif hit.data.key == "position_second_snap" then
          state.settings.position.second_snap = not state.settings.position.second_snap
        elseif hit.data.key == "position_match_length" then
          state.settings.position.match_length = not state.settings.position.match_length
        elseif hit.data.key == "shepard_enabled" then
          state.settings.shepard.enabled = not state.settings.shepard.enabled
        elseif hit.data.key == "name_remove_extensions" then
          state.settings.name.remove_extensions = not state.settings.name.remove_extensions
        elseif hit.data.key == "name_color_items" then
          state.settings.name.color_items = not state.settings.name.color_items
        elseif hit.data.key == "name_number" then
          state.settings.name.number = not state.settings.name.number
        end
        save_settings(state.settings)
        mark_dirty(state)
      elseif hit.kind == "button" then
        state.pending_action = hit.data.action
      elseif hit.kind == "slider" then
        state.active_slider = {
          id = hit.data.id,
          min = hit.data.min,
          max = hit.data.max,
          step = hit.data.step,
          x = hit.x,
          y = hit.y,
          w = hit.w,
          h = hit.h,
        }
        update_slider_from_mouse(state, state.active_slider)
      end
    end
  elseif mouse_down and state.active_slider then
    update_slider_from_mouse(state, state.active_slider)
  elseif not mouse_down then
    state.active_slider = nil
  end

  state.prev_mouse_down = mouse_down
end

local function handle_key(state, key)
  if key == 13 then
    state.pending_action = "apply"
  elseif key == 32 then
    state.pending_action = "preview"
  elseif key == 27 then
    state.should_close = true
  elseif key == string.byte("g") or key == string.byte("G") then
    state.settings.main.glue = not state.settings.main.glue
    save_settings(state.settings)
    mark_dirty(state)
  elseif key == string.byte("p") or key == string.byte("P") then
    state.pending_action = "preview"
  elseif key == string.byte("a") or key == string.byte("A") then
    state.pending_action = "advanced"
  elseif key == string.byte("n") or key == string.byte("N") then
    state.pending_action = "edit_name"
  elseif key == string.byte("r") or key == string.byte("R") then
    state.pending_action = "reset"
  end
end

local function draw_header(state)
  gfx.setfont(1, "Arial", 20)
  draw_text(GUI.padding, 16, "Seamless Loop Maker", 240, 243, 247, 255)
  gfx.setfont(1, "Arial", 12)
  draw_text(GUI.padding, 42, "Phase 3: seamless loops, live preview, variations, and Shepard tone layers", 166, 175, 186, 255)
  draw_checkbox(state, GUI.width - 210, 18, "main_glue", state.settings.main.glue, "Glue")
  draw_checkbox(state, GUI.width - 120, 18, "main_pin", state.settings.main.pin, "Pin")
end

local function draw_selection_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, "Selection")
  gfx.setfont(1, "Arial", 14)

  local analysis = state.analysis or {}
  local line_y = y + 36
  draw_text(x + 14, line_y, string.format("Selected audio items: %d", analysis.selected_count or 0), 228, 232, 238, 255)

  if analysis.item_name and analysis.item_name ~= "" then
    draw_text(x + 14, line_y + 24, "Active item: " .. analysis.item_name, 205, 211, 220, 255)
  end

  if analysis.message then
    draw_text(x + 14, line_y + 48, analysis.message, 176, 186, 198, 255)
  end

  if analysis.skipped_no_take and analysis.skipped_no_take > 0 then
    draw_text(x + 14, line_y + 72, string.format("Skipped empty items: %d", analysis.skipped_no_take), 170, 146, 120, 255)
  elseif analysis.skipped_midi and analysis.skipped_midi > 0 then
    draw_text(x + 14, line_y + 72, string.format("Skipped MIDI items: %d", analysis.skipped_midi), 170, 146, 120, 255)
  elseif state.settings.shepard.enabled then
    draw_text(x + 14, line_y + 72, "Shepard mode bakes a seamless base, then spreads pitched layers onto new tracks.", 145, 154, 165, 255)
  elseif (state.settings.main.loops or 1) > 1 then
    draw_text(x + 14, line_y + 72, "Variation mode active. Analysis shows the first source window for the first selected item.", 145, 154, 165, 255)
  else
    draw_text(x + 14, line_y + 72, "Preview uses the first selected item. Apply processes all selected audio items.", 145, 154, 165, 255)
  end
end

local function draw_position_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, "Position / Variations")
  local inner_x = x + 14
  local row_y = y + 34

  draw_slider(
    state,
    "main_loops",
    "Loops",
    state.settings.main.loops,
    1,
    32,
    1,
    function(value)
      return string.format("%d", math.floor(value + 0.5))
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 56
  draw_slider(
    state,
    "position_space",
    "Space",
    state.settings.position.space,
    0.0,
    5.0,
    0.05,
    function(value)
      return string.format("%.2f sec", value)
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 58
  draw_checkbox(state, inner_x, row_y, "position_shuffle", state.settings.position.shuffle, "Shuffle variation positions")
  draw_checkbox(state, inner_x + 270, row_y, "position_second_snap", state.settings.position.second_snap, "Second snap")
  row_y = row_y + 28
  draw_checkbox(state, inner_x, row_y, "position_match_length", state.settings.position.match_length, "Match length of selected items")
end

local function draw_shepard_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, "Shepard Tone")
  local inner_x = x + 14
  local row_y = y + 34

  draw_checkbox(state, inner_x, row_y, "shepard_enabled", state.settings.shepard.enabled, "Enable Shepard tone mode")

  row_y = row_y + 34
  draw_slider(
    state,
    "shepard_pitch",
    "Pitch Span",
    state.settings.shepard.pitch,
    1,
    24,
    1,
    function(value)
      return string.format("%d st", math.floor(value + 0.5))
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 56
  draw_slider(
    state,
    "shepard_layers",
    "Layers",
    state.settings.shepard.layers,
    2,
    8,
    1,
    function(value)
      return string.format("%d", math.floor(value + 0.5))
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 56
  draw_slider(
    state,
    "shepard_steps",
    "Steps",
    state.settings.shepard.steps,
    4,
    32,
    1,
    function(value)
      return string.format("%d", math.floor(value + 0.5))
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 58
  draw_text(inner_x, row_y + 4, "Direction", 234, 236, 241, 255)
  draw_button(
    state,
    inner_x + 104,
    row_y,
    140,
    GUI.button_h,
    state.settings.shepard.direction == "down" and "Down" or "Up",
    "toggle_shepard_direction",
    { active = state.settings.shepard.enabled }
  )
  draw_text(
    inner_x + 264,
    row_y + 4,
    state.settings.shepard.enabled and "Creates pitched layer tracks from the baked base loop." or "Disabled. Regular seamless loop generation stays active.",
    176,
    186,
    198,
    255
  )
end

local function draw_zero_crossing_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, state.settings.shepard.enabled and "Zero-Crossing / Base Source" or "Zero-Crossing")
  local inner_x = x + 14
  local row_y = y + 34
  local analysis = state.analysis or {}

  if state.settings.shepard.enabled then
    draw_text(
      inner_x,
      row_y,
      string.format("Base loop offset is locked while Shepard mode is active. Current offset: %.2f", state.settings.zero_crossing.offset),
      176,
      186,
      198,
      255
    )
    row_y = row_y + 28
  else
    draw_slider(
      state,
      "zero_offset",
      "Offset",
      state.settings.zero_crossing.offset,
      -1.0,
      1.0,
      0.05,
      function(value)
        return string.format("%.2f", value)
      end,
      inner_x,
      row_y
    )
    row_y = row_y + 58
  end

  draw_text(inner_x, row_y, string.format("Start list (%d)", analysis.start_count or 0), 228, 232, 238, 255)
  draw_text(inner_x + 220, row_y, string.format("End list (%d)", analysis.end_count or 0), 228, 232, 238, 255)

  local start_crossings = analysis.start_crossings or {}
  local end_crossings = analysis.end_crossings or {}
  for index = 1, 6 do
    local start_entry = start_crossings[index]
    local end_entry = end_crossings[index]
    local line_y = row_y + (index * 20)
    draw_text(
      inner_x,
      line_y,
      start_entry and string.format("%02d. %.4f  %s", index, start_entry.time or 0.0, start_entry.direction or "") or "-",
      176,
      186,
      198,
      255
    )
    draw_text(
      inner_x + 220,
      line_y,
      end_entry and string.format("%02d. %.4f  %s", index, end_entry.time or 0.0, end_entry.direction or "") or "-",
      176,
      186,
      198,
      255
    )
  end
end

local function draw_crossfade_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, "Crossfade")
  local inner_x = x + 14
  local row_y = y + 34

  draw_slider(
    state,
    "crossfade_length",
    "Length",
    state.settings.crossfade.length,
    0.01,
    0.50,
    0.005,
    function(value)
      return format_ratio(value)
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 56
  draw_slider(
    state,
    "crossfade_max_length",
    "Max",
    state.settings.crossfade.max_length,
    0.05,
    10.0,
    0.05,
    function(value)
      return string.format("%.2f sec", value)
    end,
    inner_x,
    row_y
  )

  row_y = row_y + 58
  gfx.setfont(1, "Arial", 14)
  draw_text(inner_x, row_y + 4, "Curve", 234, 236, 241, 255)
  draw_button(state, inner_x + 104, row_y, 170, GUI.button_h, get_curve_option(state.settings.crossfade.curve).label, "cycle_curve", nil)
end

local function draw_name_panel(state, x, y, w, h)
  draw_panel(x, y, w, h, "Name")

  local inner_x = x + 14
  local row_y = y + 38
  draw_checkbox(state, inner_x, row_y, "name_remove_extensions", state.settings.name.remove_extensions, "Remove extensions")
  draw_checkbox(state, inner_x + 210, row_y, "name_number", state.settings.name.number, "Append numbers")

  row_y = row_y + 34
  draw_checkbox(state, inner_x, row_y, "name_color_items", state.settings.name.color_items, "Color created items / tracks")

  row_y = row_y + 34
  draw_text(inner_x, row_y, "Pattern", 228, 232, 238, 255)
  draw_text(
    inner_x + 84,
    row_y,
    string.format(
      "prefix='%s' suffix='%s' sep='%s'",
      tostring(state.settings.name.prefix or ""),
      tostring(state.settings.name.suffix or ""),
      tostring(state.settings.name.separator or "")
    ),
    190,
    197,
    206,
    255
  )

  row_y = row_y + 26
  draw_text(inner_x, row_y, "Example", 228, 232, 238, 255)
  draw_text(inner_x + 84, row_y, example_loop_name(state), 92, 198, 138, 255)

  row_y = row_y + 34
  draw_button(state, inner_x, row_y, 164, GUI.button_h, "Edit Name...", "edit_name", nil)
end

local function draw_footer(state)
  local footer_y = GUI.height - 56
  draw_text(GUI.padding, footer_y - 10, state.status_message, 170, 178, 188, 255)
  draw_button(state, GUI.width - 462, footer_y - 8, 84, 30, preview_state.is_previewing and "Stop" or "Preview", "preview", nil)
  draw_button(state, GUI.width - 368, footer_y - 8, 84, 30, "Advanced", "advanced", nil)
  draw_button(state, GUI.width - 274, footer_y - 8, 84, 30, "Reset", "reset", nil)
  draw_button(state, GUI.width - 180, footer_y - 8, 84, 30, "Close", "close", nil)
  draw_button(state, GUI.width - 86, footer_y - 8, 76, 30, "Apply", "apply", { primary = true })
end

local function draw_gui(state)
  begin_frame(state)
  set_color(18, 20, 24, 255)
  gfx.rect(0, 0, GUI.width, GUI.height, true)

  draw_header(state)

  local x = GUI.padding
  local y = 72
  local w = GUI.width - (GUI.padding * 2)

  draw_selection_panel(state, x, y, w, 124)
  y = y + 124 + GUI.section_gap
  draw_position_panel(state, x, y, w, 150)
  y = y + 150 + GUI.section_gap
  draw_crossfade_panel(state, x, y, w, 170)
  y = y + 170 + GUI.section_gap
  draw_shepard_panel(state, x, y, w, 184)
  y = y + 184 + GUI.section_gap
  draw_zero_crossing_panel(state, x, y, w, 194)
  y = y + 194 + GUI.section_gap
  draw_name_panel(state, x, y, w, 162)
  draw_footer(state)
end

local function summarize_apply_result(result)
  local processed = result.processed_count or 0
  local errors = result.errors or {}

  if processed <= 0 then
    return "No items were processed."
  end
  if #errors > 0 then
    return string.format("Processed %d item(s), %d skipped.", processed, #errors)
  end
  return string.format("Processed %d item(s).", processed)
end

local function perform_action(state, action)
  if action == "close" then
    stop_loop_preview()
    state.should_close = true
    return
  end

  if action == "reset" then
    stop_loop_preview()
    state.settings = deep_copy(DEFAULTS)
    save_settings(state.settings)
    mark_dirty(state)
    set_status(state, "Settings reset to defaults.")
    return
  end

  if action == "cycle_curve" then
    state.settings.crossfade.curve = cycle_curve_option(state.settings.crossfade.curve)
    save_settings(state.settings)
    mark_dirty(state)
    set_status(state, "Crossfade curve updated.")
    return
  end

  if action == "toggle_shepard_direction" then
    state.settings.shepard.direction = state.settings.shepard.direction == "down" and "up" or "down"
    save_settings(state.settings)
    mark_dirty(state)
    set_status(state, "Shepard direction updated.")
    return
  end

  if action == "advanced" then
    local updated, err = prompt_phase2_settings(state.settings)
    if updated then
      state.settings = updated
      save_settings(state.settings)
      mark_dirty(state)
      set_status(state, "Advanced settings updated.")
    elseif err and err ~= "User cancelled." then
      set_status(state, err)
    end
    return
  end

  if action == "edit_name" then
    local updated, err = prompt_name_settings(state.settings)
    if updated then
      state.settings = updated
      save_settings(state.settings)
      mark_dirty(state)
      set_status(state, "Name settings updated.")
    elseif err and err ~= "User cancelled." then
      set_status(state, err)
    end
    return
  end

  if action == "preview" then
    local ok, err = toggle_loop_preview(state.settings)
    if ok then
      state.auto_preview_signature = build_selection_signature(state.settings)
      state.pin_waiting_for_selection = false
      set_status(state, preview_state.is_previewing and "Preview playing." or "Preview stopped.")
    elseif err then
      set_status(state, tostring(err))
    end
    return
  end

  if action == "apply" then
    stop_loop_preview()
    save_settings(state.settings)
    local ok, result_or_err = apply_loop_to_selection(state.settings)
    mark_dirty(state)

    if not ok then
      set_status(state, tostring(result_or_err or "Loop creation failed."))
      reaper.ShowMessageBox(tostring(result_or_err or "Loop creation failed."), SCRIPT_TITLE, 0)
      return
    end

    local result = result_or_err or {}
    set_status(state, summarize_apply_result(result))

    if #result.errors > 0 then
      local summary_lines = {
        summarize_apply_result(result),
        "",
        "Skipped items:",
      }
      for _, err in ipairs(result.errors) do
        summary_lines[#summary_lines + 1] = "- " .. err
      end
      reaper.ShowMessageBox(table.concat(summary_lines, "\n"), SCRIPT_TITLE, 0)
    end

    if result.processed_count > 0 and not state.settings.main.pin then
      state.should_close = true
    elseif result.processed_count > 0 and state.settings.main.pin then
      state.pin_waiting_for_selection = true
      state.auto_preview_signature = build_selection_signature(state.settings)
    end
  end
end

local function commit_imgui_change(state, changed)
  if changed then
    save_settings(state.settings)
    mark_dirty(state)
  end
end

local function imgui_space_pressed(ctx)
  if not ImGui or not ImGui.IsKeyPressed or not ImGui.Key_Space then
    return false
  end
  return ImGui.IsKeyPressed(ctx, ImGui.Key_Space())
end

local function draw_imgui_crossings(ctx, label, list)
  ImGui.Text(ctx, label)
  local shown = 0
  for index, entry in ipairs(list or {}) do
    ImGui.Text(ctx, string.format("%02d. %.4f  %s", index, entry.time or 0.0, entry.direction or ""))
    shown = shown + 1
    if shown >= 8 then
      break
    end
  end
  if shown == 0 then
    ImGui.Text(ctx, "-")
  end
end

local function draw_imgui_gui(state)
  local ctx = state.imgui_context
  local analysis = state.analysis or {}
  local changed

  if imgui_space_pressed(ctx) then
    state.pending_action = "preview"
  end

  ImGui.Text(ctx, string.format("Selected audio items: %d", analysis.selected_count or 0))
  if analysis.item_name and analysis.item_name ~= "" then
    ImGui.Text(ctx, "Active item: " .. analysis.item_name)
  end
  ImGui.Text(ctx, analysis.message or "Select an item.")
  ImGui.Separator(ctx)

  ImGui.Text(ctx, "Main")
  changed, state.settings.main.loops = ImGui.SliderInt(ctx, "Loops", state.settings.main.loops, 1, 32)
  commit_imgui_change(state, changed)
  changed, state.settings.main.glue = ImGui.Checkbox(ctx, "Glue", state.settings.main.glue)
  commit_imgui_change(state, changed)
  ImGui.SameLine(ctx)
  changed, state.settings.main.pin = ImGui.Checkbox(ctx, "Pin", state.settings.main.pin)
  commit_imgui_change(state, changed)
  if state.settings.shepard.enabled then
    ImGui.Text(ctx, "Regular variation count is ignored while Shepard mode is enabled.")
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Position")
  changed, state.settings.position.space = ImGui.SliderDouble(ctx, "Space", state.settings.position.space, 0.0, 5.0, "%.2f sec")
  commit_imgui_change(state, changed)
  changed, state.settings.position.shuffle = ImGui.Checkbox(ctx, "Shuffle variation positions", state.settings.position.shuffle)
  commit_imgui_change(state, changed)
  changed, state.settings.position.second_snap = ImGui.Checkbox(ctx, "Second snap", state.settings.position.second_snap)
  commit_imgui_change(state, changed)
  changed, state.settings.position.match_length = ImGui.Checkbox(ctx, "Match length of selected items", state.settings.position.match_length)
  commit_imgui_change(state, changed)

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Crossfade")
  changed, state.settings.crossfade.length = ImGui.SliderDouble(ctx, "Length", state.settings.crossfade.length, 0.01, 0.50, "%.3f")
  commit_imgui_change(state, changed)
  changed, state.settings.crossfade.max_length = ImGui.SliderDouble(ctx, "Max", state.settings.crossfade.max_length, 0.05, 10.0, "%.2f sec")
  commit_imgui_change(state, changed)
  if ImGui.Button(ctx, "Curve: " .. get_curve_option(state.settings.crossfade.curve).label, 180, 0) then
    state.pending_action = "cycle_curve"
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Shepard Tone")
  changed, state.settings.shepard.enabled = ImGui.Checkbox(ctx, "Enable Shepard tone mode", state.settings.shepard.enabled)
  commit_imgui_change(state, changed)
  changed, state.settings.shepard.pitch = ImGui.SliderDouble(ctx, "Pitch Span", state.settings.shepard.pitch, 1.0, 24.0, "%.0f st")
  commit_imgui_change(state, changed)
  changed, state.settings.shepard.layers = ImGui.SliderInt(ctx, "Layers", state.settings.shepard.layers, 2, 8)
  commit_imgui_change(state, changed)
  changed, state.settings.shepard.steps = ImGui.SliderInt(ctx, "Steps", state.settings.shepard.steps, 4, 32)
  commit_imgui_change(state, changed)
  if ImGui.Button(ctx, "Direction: " .. (state.settings.shepard.direction == "down" and "Down" or "Up"), 180, 0) then
    state.pending_action = "toggle_shepard_direction"
  end
  ImGui.Text(ctx, state.settings.shepard.enabled and "Shepard mode creates new pitched layer tracks from the baked base loop." or "Disabled. Apply builds standard seamless loops.")

  ImGui.Separator(ctx)
  ImGui.Text(ctx, state.settings.shepard.enabled and "Zero-Crossing / Base Source" or "Zero-Crossing")
  if state.settings.shepard.enabled then
    ImGui.Text(ctx, string.format("Offset locked at %.2f while Shepard mode is active.", state.settings.zero_crossing.offset))
  else
    changed, state.settings.zero_crossing.offset = ImGui.SliderDouble(ctx, "Offset", state.settings.zero_crossing.offset, -1.0, 1.0, "%.2f")
    commit_imgui_change(state, changed)
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Naming")
  changed, state.settings.name.remove_extensions = ImGui.Checkbox(ctx, "Remove extensions", state.settings.name.remove_extensions)
  commit_imgui_change(state, changed)
  ImGui.SameLine(ctx)
  changed, state.settings.name.number = ImGui.Checkbox(ctx, "Append numbers", state.settings.name.number)
  commit_imgui_change(state, changed)
  changed, state.settings.name.color_items = ImGui.Checkbox(ctx, "Color items / tracks", state.settings.name.color_items)
  commit_imgui_change(state, changed)
  ImGui.Text(ctx, "Example: " .. example_loop_name(state))
  if ImGui.Button(ctx, "Edit Name...", 120, 0) then
    state.pending_action = "edit_name"
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Advanced...", 120, 0) then
    state.pending_action = "advanced"
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Zero-Crossing List")
  draw_imgui_crossings(ctx, string.format("Start (%d)", analysis.start_count or 0), analysis.start_crossings or {})
  ImGui.Separator(ctx)
  draw_imgui_crossings(ctx, string.format("End (%d)", analysis.end_count or 0), analysis.end_crossings or {})

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, preview_state.is_previewing and "Stop Preview (Space)" or "Preview (Space)", 170, 0) then
    state.pending_action = "preview"
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Apply", 120, 0) then
    state.pending_action = "apply"
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Close", 120, 0) then
    state.pending_action = "close"
  end

  ImGui.Text(ctx, state.status_message or "")
end

local function run_imgui_loop(state)
  update_analysis_cache(state)
  maybe_auto_preview(state)

  local ctx = state.imgui_context
  if not ctx then
    return
  end

  ImGui.SetNextWindowSize(ctx, 700, 980, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, SCRIPT_TITLE, state.imgui_open)
  state.imgui_open = open

  if visible then
    draw_imgui_gui(state)
  end

  ImGui.End(ctx)

  if state.pending_action then
    local action = state.pending_action
    state.pending_action = nil
    perform_action(state, action)
  end

  if not open or state.should_close then
    stop_loop_preview()
    if ImGui.DestroyContext then
      ImGui.DestroyContext(ctx)
    end
    state.imgui_context = nil
    return
  end

  reaper.defer(function()
    run_imgui_loop(state)
  end)
end

local function main()
  local state = create_gui_state()

  if HAS_IMGUI and ImGui then
    state.imgui_context = ImGui.CreateContext(SCRIPT_TITLE)
    state.imgui_open = true
    run_imgui_loop(state)
    return
  end

  gfx.init(SCRIPT_TITLE, GUI.width, GUI.height, 0)
  gfx.setfont(1, "Arial", 14)

  local function run_loop()
    local key = gfx.getchar()
    if key < 0 or state.should_close then
      stop_loop_preview()
      return
    end

    if key > 0 then
      handle_key(state, key)
    end

    update_analysis_cache(state)
    maybe_auto_preview(state)
    draw_gui(state)
    handle_mouse(state)

    if state.pending_action then
      local action = state.pending_action
      state.pending_action = nil
      perform_action(state, action)
    end

    gfx.update()
    if not state.should_close then
      reaper.defer(run_loop)
    else
      stop_loop_preview()
    end
  end

  run_loop()
end

main()
