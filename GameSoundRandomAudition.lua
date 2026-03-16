-- Game Sound Random Layer Audition v1.0
-- Reaper ReaScript (Lua)
-- 게임 사운드 랜덤 레이어 조합 오디션 도구
--
-- 사용법:
-- 1. 배리에이션이 준비된 상태에서 스크립트 실행
-- 2. 그룹 감지 -> Randomizer 설정 -> Start Audition
-- 3. Interactive 모드: gfx 창에서 SPACE로 랜덤 재생, R로 Rapid Fire, S로 시퀀스 렌더
-- 4. 설정한 횟수만큼 랜덤 조합을 생성하고 콘솔 로그/통계를 출력
-- 5. 필요하면 타임라인에 오디션 시퀀스를 남겨 배리에이션 조합을 검증
--
-- 요구사항: REAPER v7.0+
-- 연계 스크립트: GameSoundVariationGenerator.lua (배리에이션 생성 후 사용),
--               GameSoundBatchRenderer.lua (검증 완료 후 렌더링)

local SCRIPT_TITLE = "Game Sound Random Audition v1.0"
local EXT_SECTION = "GameSoundRandomAudition"
local REAPER_COLOR_FLAG = 0x1000000
local LIVE_FOLDER_BASE_NAME = "Audition_Live"
local SEQUENCE_FOLDER_BASE_NAME = "Audition_Sequence"
local GUI_WINDOW_W = 680
local GUI_WINDOW_H = 560

local DEFAULTS = {
  group_mode = "track_folder",
  repeat_count = 10,
  interval_ms = 500,
  pitch_range_cents = 100,
  volume_range_db = 3.0,
  no_repeat_mode = "no_immediate",
  output_mode = "interactive",
}

local function log_line(message)
  reaper.ShowConsoleMsg(tostring(message or "") .. "\n")
end

local function trim_string(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
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

local function round_to(value, decimals)
  local power = 10 ^ (decimals or 0)
  if value >= 0 then
    return math.floor(value * power + 0.5) / power
  end
  return math.ceil(value * power - 0.5) / power
end

local function db_to_linear(db_value)
  return 10 ^ (tonumber(db_value or 0.0) / 20.0)
end

local function pad_number(value, width)
  return string.format("%0" .. tostring(width or 2) .. "d", value)
end

local function strip_extension(name)
  local value = trim_string(name)
  return value:gsub("%.[^%.\\/]+$", "")
end

local function sanitize_base_name(name, fallback_index)
  local value = strip_extension(name)
  value = trim_string(value)
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

local function get_track_name(track)
  if not track then
    return ""
  end

  local _, name = reaper.GetTrackName(track, "")
  return trim_string(name)
end

local function set_track_name(track, name)
  if track then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(name or ""), true)
  end
end

local function set_take_name(take, name)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
  end
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function parse_group_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "track_folder" or lowered == "track" or lowered == "folder" then
    return "track_folder"
  end
  if lowered == "item_name" or lowered == "name" or lowered == "names" then
    return "item_name"
  end
  if lowered == "selection" or lowered == "selected" then
    return "selection"
  end
  return nil
end

local function parse_output_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "interactive" or lowered == "live" or lowered == "i" then
    return "interactive"
  end
  if lowered == "play" or lowered == "p" then
    return "play"
  end
  if lowered == "render_sequence" or lowered == "render" or lowered == "sequence" then
    return "render_sequence"
  end
  return nil
end

local function is_audition_folder_name(name)
  local value = trim_string(name)
  return value:match("^" .. LIVE_FOLDER_BASE_NAME) ~= nil or value:match("^" .. SEQUENCE_FOLDER_BASE_NAME) ~= nil
end

local function parse_no_repeat_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "none" then
    return "none", 0
  end
  if lowered == "no_immediate" or lowered == "no_repeat" or lowered == "default" then
    return "no_immediate", 1
  end
  if lowered == "shuffle" then
    return "shuffle", 0
  end

  local avoid_count = lowered:match("^no_last_(%d+)$")
  if avoid_count then
    avoid_count = tonumber(avoid_count) or 0
    if avoid_count >= 1 then
      return "no_last_n", avoid_count
    end
  end

  return nil, 0
end

local function load_settings()
  local no_repeat_mode, no_repeat_count = parse_no_repeat_mode(get_ext_state("no_repeat_mode", DEFAULTS.no_repeat_mode))

  return {
    group_mode = parse_group_mode(get_ext_state("group_mode", DEFAULTS.group_mode)) or DEFAULTS.group_mode,
    repeat_count = tonumber(get_ext_state("repeat_count", tostring(DEFAULTS.repeat_count))) or DEFAULTS.repeat_count,
    interval_ms = tonumber(get_ext_state("interval_ms", tostring(DEFAULTS.interval_ms))) or DEFAULTS.interval_ms,
    pitch_range_cents = tonumber(get_ext_state("pitch_range_cents", tostring(DEFAULTS.pitch_range_cents))) or DEFAULTS.pitch_range_cents,
    volume_range_db = tonumber(get_ext_state("volume_range_db", tostring(DEFAULTS.volume_range_db))) or DEFAULTS.volume_range_db,
    no_repeat_mode = no_repeat_mode or DEFAULTS.no_repeat_mode,
    no_repeat_count = no_repeat_count or 1,
    output_mode = parse_output_mode(get_ext_state("output_mode", DEFAULTS.output_mode)) or DEFAULTS.output_mode,
  }
end

local function save_settings(settings)
  local no_repeat_value = settings.no_repeat_mode
  if settings.no_repeat_mode == "no_last_n" then
    no_repeat_value = "no_last_" .. tostring(settings.no_repeat_count or 2)
  end

  reaper.SetExtState(EXT_SECTION, "group_mode", tostring(settings.group_mode), true)
  reaper.SetExtState(EXT_SECTION, "repeat_count", tostring(settings.repeat_count), true)
  reaper.SetExtState(EXT_SECTION, "interval_ms", tostring(settings.interval_ms), true)
  reaper.SetExtState(EXT_SECTION, "pitch_range_cents", tostring(settings.pitch_range_cents), true)
  reaper.SetExtState(EXT_SECTION, "volume_range_db", tostring(settings.volume_range_db), true)
  reaper.SetExtState(EXT_SECTION, "no_repeat_mode", tostring(no_repeat_value), true)
  reaper.SetExtState(EXT_SECTION, "output_mode", tostring(settings.output_mode), true)
end

local function save_session_summary(history, groups, render_info)
  local summary = string.format(
    "plays=%d;groups=%d;track=%s",
    #history,
    #groups,
    render_info and render_info.folder_name or ""
  )

  reaper.SetExtState(EXT_SECTION, "last_total_plays", tostring(#history), true)
  reaper.SetExtState(EXT_SECTION, "last_group_count", tostring(#groups), true)
  reaper.SetExtState(EXT_SECTION, "last_output_track", render_info and render_info.folder_name or "", true)
  reaper.SetExtState(EXT_SECTION, "last_summary", summary, true)
end

local function prompt_for_settings(current)
  local defaults = {
    current.group_mode or DEFAULTS.group_mode,
    tostring(current.repeat_count or DEFAULTS.repeat_count),
    tostring(current.interval_ms or DEFAULTS.interval_ms),
    tostring(current.pitch_range_cents or DEFAULTS.pitch_range_cents),
    tostring(current.volume_range_db or DEFAULTS.volume_range_db),
    current.no_repeat_mode == "no_last_n" and ("no_last_" .. tostring(current.no_repeat_count or 2)) or current.no_repeat_mode,
    current.output_mode or DEFAULTS.output_mode,
  }

  while true do
    local ok, values = reaper.GetUserInputs(
      SCRIPT_TITLE,
      7,
      table.concat({
        "extrawidth=300",
        "separator=|",
        "Group Detection (track_folder/item_name/selection)",
        "Repeat Count",
        "Interval (ms)",
        "Pitch Range (+/- cents)",
        "Volume Range (+/- dB)",
        "No-Repeat (none/no_immediate/shuffle/no_last_2...)",
        "Output Mode (interactive/play/render_sequence)",
      }, ","),
      table.concat(defaults, "|")
    )

    if not ok then
      return nil, "User cancelled."
    end

    local parts = split_delimited(values, "|", 7)
    defaults = parts

    local group_mode = parse_group_mode(parts[1])
    local repeat_count = math.floor((tonumber(parts[2]) or -1) + 0.5)
    local interval_ms = math.floor((tonumber(parts[3]) or -1) + 0.5)
    local pitch_range_cents = tonumber(parts[4])
    local volume_range_db = tonumber(parts[5])
    local no_repeat_mode, no_repeat_count = parse_no_repeat_mode(parts[6])
    local output_mode = parse_output_mode(parts[7])

    if not group_mode then
      reaper.ShowMessageBox("Group Detection must be track_folder, item_name, or selection.", SCRIPT_TITLE, 0)
    elseif repeat_count < 1 or repeat_count > 512 then
      reaper.ShowMessageBox("Repeat Count must be between 1 and 512.", SCRIPT_TITLE, 0)
    elseif interval_ms < 0 or interval_ms > 60000 then
      reaper.ShowMessageBox("Interval must be between 0 and 60000 ms.", SCRIPT_TITLE, 0)
    elseif not pitch_range_cents or pitch_range_cents < 0 or pitch_range_cents > 2400 then
      reaper.ShowMessageBox("Pitch Range must be between 0 and 2400 cents.", SCRIPT_TITLE, 0)
    elseif not volume_range_db or volume_range_db < 0 or volume_range_db > 24 then
      reaper.ShowMessageBox("Volume Range must be between 0 and 24 dB.", SCRIPT_TITLE, 0)
    elseif not no_repeat_mode then
      reaper.ShowMessageBox("No-Repeat must be none, no_immediate, shuffle, or no_last_2 style.", SCRIPT_TITLE, 0)
    elseif not output_mode then
      reaper.ShowMessageBox("Output Mode must be interactive, play, or render_sequence.", SCRIPT_TITLE, 0)
    else
      return {
        group_mode = group_mode,
        repeat_count = repeat_count,
        interval_ms = interval_ms,
        pitch_range_cents = pitch_range_cents,
        volume_range_db = volume_range_db,
        no_repeat_mode = no_repeat_mode,
        no_repeat_count = no_repeat_count,
        output_mode = output_mode,
      }
    end
  end
end

local function seed_random()
  local seed = math.floor(reaper.time_precise() * 1000000) % 2147483647
  math.randomseed(seed)
  math.random()
  math.random()
  math.random()
end

local function build_track_snapshot()
  local snapshot = {}
  local running_depth = 0
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    local folder_delta = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))

    snapshot[#snapshot + 1] = {
      track = track,
      index = track_index,
      depth = running_depth,
      folder_delta = folder_delta,
      name = get_track_name(track),
    }

    running_depth = running_depth + folder_delta
  end

  return snapshot
end

local function is_folder_parent(snapshot, track_index)
  local current_entry = snapshot[track_index + 1]
  local next_entry = snapshot[track_index + 2]
  if not current_entry or not next_entry then
    return false
  end
  return next_entry.depth > current_entry.depth
end

local function get_immediate_child_folder_entries(snapshot, parent_index)
  local children = {}
  local parent_entry = snapshot[parent_index + 1]
  if not parent_entry then
    return children
  end

  for track_index = parent_index + 1, #snapshot - 1 do
    local entry = snapshot[track_index + 1]
    if entry.depth <= parent_entry.depth then
      break
    end

    if entry.depth == parent_entry.depth + 1 and is_folder_parent(snapshot, track_index) then
      children[#children + 1] = entry
    end
  end

  return children
end

local function collect_items_from_folder_entry(snapshot, folder_entry)
  local items = {}
  local fallback_index = 1

  for track_index = folder_entry.index, #snapshot - 1 do
    local entry = snapshot[track_index + 1]

    if track_index > folder_entry.index and entry.depth <= folder_entry.depth then
      break
    end

    local item_count = reaper.CountTrackMediaItems(entry.track)
    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(entry.track, item_index)
      local take = reaper.GetActiveTake(item)
      if take then
        local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local raw_name = get_take_name_or_fallback(take, fallback_index)

        items[#items + 1] = {
          item = item,
          take = take,
          track = entry.track,
          track_name = entry.name,
          name = raw_name,
          display_name = raw_name,
          key = string.format("%s|%d|%.6f|%.6f", raw_name, entry.index, item_position, item_length),
          position = item_position,
          length = item_length,
          track_index = entry.index,
        }

        fallback_index = fallback_index + 1
      end
    end
  end

  table.sort(items, function(left, right)
    if left.track_index ~= right.track_index then
      return left.track_index < right.track_index
    end
    if math.abs(left.position - right.position) > 0.000001 then
      return left.position < right.position
    end
    return left.name < right.name
  end)

  return items
end

local function assign_unique_item_display_names(group)
  local counts = {}
  for _, item in ipairs(group.items) do
    counts[item.name] = (counts[item.name] or 0) + 1
  end

  local used = {}
  for _, item in ipairs(group.items) do
    if counts[item.name] <= 1 then
      item.display_name = item.name
    else
      used[item.name] = (used[item.name] or 0) + 1
      item.display_name = string.format("%s [%d]", item.name, used[item.name])
    end
  end
end

local function build_group_from_folder_entry(snapshot, folder_entry)
  local items = collect_items_from_folder_entry(snapshot, folder_entry)
  if #items == 0 then
    return nil
  end

  local group_name = folder_entry.name
  if group_name == "" then
    group_name = "Group_" .. pad_number(folder_entry.index + 1, 2)
  end

  local group = {
    name = group_name,
    display_name = group_name,
    type = "track_folder",
    track = folder_entry.track,
    track_index = folder_entry.index,
    items = items,
    history = {},
    shuffle_bag = nil,
  }

  assign_unique_item_display_names(group)
  return group
end

local function get_selected_track_entries(snapshot)
  local entries = {}
  local selected_count = reaper.CountSelectedTracks(0)

  for selected_index = 0, selected_count - 1 do
    local selected_track = reaper.GetSelectedTrack(0, selected_index)
    if selected_track then
      local track_number = math.floor(reaper.GetMediaTrackInfo_Value(selected_track, "IP_TRACKNUMBER")) - 1
      if track_number >= 0 and snapshot[track_number + 1] then
        entries[#entries + 1] = snapshot[track_number + 1]
      end
    end
  end

  return entries
end

local function finalize_groups(groups)
  table.sort(groups, function(left, right)
    if left.track_index ~= nil and right.track_index ~= nil and left.track_index ~= right.track_index then
      return left.track_index < right.track_index
    end
    return left.name < right.name
  end)

  local name_counts = {}
  for _, group in ipairs(groups) do
    name_counts[group.name] = (name_counts[group.name] or 0) + 1
  end

  local name_used = {}
  for index, group in ipairs(groups) do
    name_used[group.name] = (name_used[group.name] or 0) + 1
    if name_counts[group.name] > 1 then
      group.display_name = string.format("%s [%d]", group.name, name_used[group.name])
    else
      group.display_name = group.name
    end
    group.output_track_name = "Audition_" .. group.display_name
    group.group_index = index
  end
end

local function detect_track_folder_groups()
  local snapshot = build_track_snapshot()
  local selected_entries = get_selected_track_entries(snapshot)
  local groups = {}
  local seen_by_track_index = {}

  local function add_group_from_entry(folder_entry)
    if not folder_entry or seen_by_track_index[folder_entry.index] then
      return
    end

    if is_audition_folder_name(folder_entry.name) then
      return
    end

    local group = build_group_from_folder_entry(snapshot, folder_entry)
    if group then
      groups[#groups + 1] = group
      seen_by_track_index[folder_entry.index] = true
    end
  end

  if #selected_entries > 0 then
    local any_valid_selection = false

    for _, selected_entry in ipairs(selected_entries) do
      if is_folder_parent(snapshot, selected_entry.index) then
        any_valid_selection = true
        local child_folders = get_immediate_child_folder_entries(snapshot, selected_entry.index)

        if #child_folders > 0 then
          for _, child_entry in ipairs(child_folders) do
            add_group_from_entry(child_entry)
          end
        else
          add_group_from_entry(selected_entry)
        end
      end
    end

    if not any_valid_selection then
      return nil, "Track Folder mode expects a selected folder track or no selected tracks."
    end
  else
    for _, entry in ipairs(snapshot) do
      if is_folder_parent(snapshot, entry.index) then
        local child_folders = get_immediate_child_folder_entries(snapshot, entry.index)
        if #child_folders == 0 then
          add_group_from_entry(entry)
        end
      end
    end
  end

  if #groups == 0 then
    return nil, "No layer groups were found. Select the event folder track or build folder-based variation groups first."
  end

  finalize_groups(groups)
  return groups
end

local function detect_item_name_groups()
  local raw_groups = {}
  local all_items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)
  local total_items = selected_count > 0 and selected_count or reaper.CountMediaItems(0)

  for item_index = 0, total_items - 1 do
    local item = selected_count > 0 and reaper.GetSelectedMediaItem(0, item_index) or reaper.GetMediaItem(0, item_index)
    if item then
      all_items[#all_items + 1] = item
    end
  end

  for index, item in ipairs(all_items) do
    local take = reaper.GetActiveTake(item)
    if take then
      local take_name = get_take_name_or_fallback(take, index)
      local group_name = take_name:match("^(.+)_Var%d+$") or take_name:match("^(.+)_%d+$")

      if group_name then
        local track = reaper.GetMediaItemTrack(item)
        local track_index = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
        local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

        if not raw_groups[group_name] then
          raw_groups[group_name] = {
            name = group_name,
            display_name = group_name,
            type = "item_name",
            track = track,
            track_index = track_index,
            items = {},
            history = {},
            shuffle_bag = nil,
          }
        end

        raw_groups[group_name].items[#raw_groups[group_name].items + 1] = {
          item = item,
          take = take,
          track = track,
          track_name = get_track_name(track),
          name = take_name,
          display_name = take_name,
          key = string.format("%s|%d|%.6f|%.6f", take_name, track_index, item_position, item_length),
          position = item_position,
          length = item_length,
          track_index = track_index,
        }
      end
    end
  end

  local groups = {}
  for _, group in pairs(raw_groups) do
    if #group.items >= 2 then
      table.sort(group.items, function(left, right)
        if left.track_index ~= right.track_index then
          return left.track_index < right.track_index
        end
        if math.abs(left.position - right.position) > 0.000001 then
          return left.position < right.position
        end
        return left.name < right.name
      end)
      assign_unique_item_display_names(group)
      groups[#groups + 1] = group
    end
  end

  if #groups == 0 then
    return nil, "No name-based groups were found. Use names like Attack_Var01 or Attack_01."
  end

  finalize_groups(groups)
  return groups
end

local function detect_selection_group()
  local items = {}
  local selected_count = reaper.CountSelectedMediaItems(0)

  for item_index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, item_index)
    local take = item and reaper.GetActiveTake(item) or nil
    if take then
      local track = reaper.GetMediaItemTrack(item)
      local track_index = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
      local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_name = get_take_name_or_fallback(take, item_index + 1)

      items[#items + 1] = {
        item = item,
        take = take,
        track = track,
        track_name = get_track_name(track),
        name = item_name,
        display_name = item_name,
        key = string.format("%s|%d|%.6f|%.6f", item_name, track_index, item_position, item_length),
        position = item_position,
        length = item_length,
        track_index = track_index,
      }
    end
  end

  if #items < 2 then
    return nil, "Selection mode needs at least two selected media items."
  end

  table.sort(items, function(left, right)
    if left.track_index ~= right.track_index then
      return left.track_index < right.track_index
    end
    if math.abs(left.position - right.position) > 0.000001 then
      return left.position < right.position
    end
    return left.name < right.name
  end)

  local group = {
    name = "Selected Items",
    display_name = "Selected Items",
    type = "selection",
    track = nil,
    track_index = items[1].track_index or 0,
    items = items,
    history = {},
    shuffle_bag = nil,
  }

  assign_unique_item_display_names(group)
  finalize_groups({ group })
  return { group }
end

local function detect_layer_groups(mode)
  if mode == "track_folder" then
    return detect_track_folder_groups()
  end
  if mode == "item_name" then
    return detect_item_name_groups()
  end
  if mode == "selection" then
    return detect_selection_group()
  end
  return nil, "Unsupported group detection mode."
end

local function find_global_origin_position(groups)
  local earliest_position = nil

  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do
      if not earliest_position or item.position < earliest_position then
        earliest_position = item.position
      end
    end
  end

  return earliest_position or reaper.GetCursorPosition()
end

local function shallow_copy_array(source)
  local copy = {}
  for index = 1, #source do
    copy[index] = source[index]
  end
  return copy
end

local function shuffle_array(items)
  for index = #items, 2, -1 do
    local swap_index = math.random(1, index)
    items[index], items[swap_index] = items[swap_index], items[index]
  end
  return items
end

local function filter_out_recent_items(items, history, count)
  if not history or #history == 0 or count <= 0 then
    return shallow_copy_array(items)
  end

  local recent = {}
  for history_index = math.max(1, #history - count + 1), #history do
    recent[history[history_index]] = true
  end

  local available = {}
  for _, item in ipairs(items) do
    if not recent[item.key] then
      available[#available + 1] = item
    end
  end

  if #available == 0 then
    return shallow_copy_array(items)
  end

  return available
end

local function pick_from_group(group, settings)
  if #group.items == 1 then
    local only_item = group.items[1]
    group.history[#group.history + 1] = only_item.key
    return only_item
  end

  local picked = nil

  if settings.no_repeat_mode == "shuffle" then
    if not group.shuffle_bag or #group.shuffle_bag == 0 then
      group.shuffle_bag = shuffle_array(shallow_copy_array(group.items))
    end
    picked = table.remove(group.shuffle_bag, 1)
  elseif settings.no_repeat_mode == "no_immediate" then
    local available = filter_out_recent_items(group.items, group.history, 1)
    picked = available[math.random(1, #available)]
  elseif settings.no_repeat_mode == "no_last_n" then
    local avoid_count = clamp_number(settings.no_repeat_count or 2, 1, math.max(1, #group.items - 1))
    local available = filter_out_recent_items(group.items, group.history, avoid_count)
    picked = available[math.random(1, #available)]
  else
    picked = group.items[math.random(1, #group.items)]
  end

  group.history[#group.history + 1] = picked.key
  return picked
end

local function pick_random_combination(groups, settings)
  local combination = {}

  for _, group in ipairs(groups) do
    local picked = pick_from_group(group, settings)
    combination[#combination + 1] = {
      group_name = group.display_name,
      group_ref = group,
      item = picked.item,
      take = picked.take,
      track = picked.track,
      name = picked.display_name,
      source_name = picked.name,
      key = picked.key,
      position = picked.position,
      length = picked.length,
      track_index = picked.track_index,
    }
  end

  return combination
end

local function random_uniform(min_value, max_value)
  return min_value + math.random() * (max_value - min_value)
end

local function sample_pitch_cents(settings)
  local range_value = tonumber(settings.pitch_range_cents or 0) or 0
  if range_value <= 0 then
    return nil
  end
  return random_uniform(-range_value, range_value)
end

local function sample_volume_db(settings)
  local range_value = tonumber(settings.volume_range_db or 0) or 0
  if range_value <= 0 then
    return nil
  end
  return random_uniform(-range_value, range_value)
end

local function apply_random_modifiers(combination, settings)
  local applied = {}

  for _, pick in ipairs(combination) do
    local pitch_cents = sample_pitch_cents(settings)
    local volume_db = sample_volume_db(settings)

    applied[#applied + 1] = {
      pick = pick,
      mods = {
        pitch_cents = pitch_cents,
        pitch_semitones = pitch_cents and (pitch_cents / 100.0) or nil,
        volume_db = volume_db,
      },
    }
  end

  return applied
end

local function format_modifier_value(value, decimals, prefix, suffix)
  if value == nil then
    return nil
  end
  local fmt = "%s%+." .. tostring(decimals or 0) .. "f%s"
  return string.format(fmt, prefix or "", round_to(value, decimals), suffix or "")
end

local function log_detected_groups(groups)
  log_line("===========================================")
  log_line("Detected Layer Groups")
  log_line("===========================================")

  for _, group in ipairs(groups) do
    local names = {}
    for item_index, item in ipairs(group.items) do
      names[#names + 1] = item.display_name
      if item_index >= 8 and #group.items > 8 then
        names[#names + 1] = "..."
        break
      end
    end

    log_line(string.format(
      "- %s (%d item%s): %s",
      group.display_name,
      #group.items,
      #group.items == 1 and "" or "s",
      table.concat(names, ", ")
    ))
  end

  log_line("")
end

local function log_play_entry(play_index, applied)
  local log_parts = { string.format("Play #%02d:", play_index) }
  for _, entry in ipairs(applied) do
    local part = string.format("[%s: %s", entry.pick.group_name, entry.pick.name)
    if entry.mods.pitch_cents ~= nil then
      part = part .. " " .. format_modifier_value(entry.mods.pitch_cents, 0, "P", "c")
    end
    if entry.mods.volume_db ~= nil then
      part = part .. " " .. format_modifier_value(entry.mods.volume_db, 1, "V", "dB")
    end
    part = part .. "]"
    log_parts[#log_parts + 1] = part
  end

  log_line(table.concat(log_parts, " "))
end

local function build_rapid_fire_history(groups, settings, start_index)
  local history = {}
  local first_index = start_index or 1

  log_line("===========================================")
  log_line("Rapid Fire Audition")
  log_line("===========================================")
  log_line(string.format(
    "Repeats: %d | Interval: %d ms | Groups: %d | Output: %s",
    settings.repeat_count,
    settings.interval_ms,
    #groups,
    settings.output_mode
  ))
  log_line("")

  for offset_index = 0, settings.repeat_count - 1 do
    local play_index = first_index + offset_index
    local combination = pick_random_combination(groups, settings)
    local applied = apply_random_modifiers(combination, settings)

    log_play_entry(play_index, applied)

    history[#history + 1] = {
      index = play_index,
      combination = combination,
      applied_mods = applied,
    }
  end

  log_line("")
  return history
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
    return nil, "Failed to apply duplicated media item state chunk."
  end

  reaper.SetMediaItemSelected(new_item, false)
  return new_item
end

local function collect_existing_track_names()
  local names = {}
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    names[get_track_name(track)] = true
  end

  return names
end

local function build_unique_track_name(base_name)
  local existing = collect_existing_track_names()
  if not existing[base_name] then
    return base_name
  end

  local suffix = 2
  while true do
    local candidate = string.format("%s_%02d", base_name, suffix)
    if not existing[candidate] then
      return candidate
    end
    suffix = suffix + 1
  end
end

local function create_output_tracks(groups, folder_base_name, folder_color, child_color)
  local insert_index = reaper.CountTracks(0)
  local folder_name = build_unique_track_name(folder_base_name or SEQUENCE_FOLDER_BASE_NAME)
  local child_tracks = {}
  local header_color = folder_color or reaper.ColorToNative(180, 100, 220)
  local lane_color = child_color or reaper.ColorToNative(120, 170, 230)

  reaper.InsertTrackAtIndex(insert_index, true)
  local folder_track = reaper.GetTrack(0, insert_index)
  set_track_name(folder_track, folder_name)
  reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)
  reaper.SetMediaTrackInfo_Value(folder_track, "I_CUSTOMCOLOR", header_color | REAPER_COLOR_FLAG)

  for group_index, group in ipairs(groups) do
    local child_index = insert_index + group_index
    reaper.InsertTrackAtIndex(child_index, true)
    local child_track = reaper.GetTrack(0, child_index)

    set_track_name(child_track, build_unique_track_name(group.output_track_name))
    reaper.SetMediaTrackInfo_Value(child_track, "I_FOLDERDEPTH", group_index == #groups and -1 or 0)
    reaper.SetMediaTrackInfo_Value(child_track, "I_CUSTOMCOLOR", lane_color | REAPER_COLOR_FLAG)

    child_tracks[group.group_index] = child_track
  end

  reaper.TrackList_AdjustWindows(false)
  return {
    folder_name = folder_name,
    folder_track = folder_track,
    child_tracks = child_tracks,
  }
end

local function clear_track_media_items(track)
  if not track then
    return
  end

  for item_index = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, item_index)
    if item then
      reaper.DeleteTrackMediaItem(track, item)
    end
  end
end

local function render_audition_sequence(history, groups, settings)
  local output = create_output_tracks(groups, SEQUENCE_FOLDER_BASE_NAME)
  local origin_position = find_global_origin_position(groups)
  local start_position = reaper.GetCursorPosition()
  local interval_seconds = (settings.interval_ms or 0) / 1000.0
  local max_end_position = start_position

  for history_index, play in ipairs(history) do
    local play_number = play.index or history_index
    local play_start = start_position + ((history_index - 1) * interval_seconds)

    for _, entry in ipairs(play.applied_mods) do
      local dest_track = output.child_tracks[entry.pick.group_ref.group_index]
      local new_item, err = duplicate_item_to_track(entry.pick.item, dest_track)
      if not new_item then
        error(err)
      end

      local relative_offset = entry.pick.position - origin_position
      local new_position = play_start + relative_offset
      reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", new_position)

      local take = reaper.GetActiveTake(new_item)
      if take then
        if entry.mods.pitch_semitones ~= nil then
          local original_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
          reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", original_pitch + entry.mods.pitch_semitones)
        end

        if entry.mods.volume_db ~= nil then
          local original_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
          reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", original_volume * db_to_linear(entry.mods.volume_db))
        end

        set_take_name(take, string.format("Aud%02d_%s", play_number, entry.pick.name))
      end

      local item_end = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + reaper.GetMediaItemInfo_Value(new_item, "D_LENGTH")
      if item_end > max_end_position then
        max_end_position = item_end
      end
    end

    reaper.AddProjectMarker(0, false, play_start, 0, "#" .. tostring(play_number), -1)
  end

  reaper.GetSet_LoopTimeRange(true, false, start_position, max_end_position, false)
  reaper.SetEditCurPos(start_position, false, false)

  return {
    folder_name = output.folder_name,
    folder_track = output.folder_track,
    start_pos = start_position,
    end_pos = max_end_position,
  }
end

local function point_in_rect(x, y, rect_x, rect_y, rect_w, rect_h)
  return x >= rect_x and x <= (rect_x + rect_w) and y >= rect_y and y <= (rect_y + rect_h)
end

local function ensure_live_output_tracks(state)
  if state.live_output then
    return state.live_output
  end

  state.live_output = create_output_tracks(
    state.groups,
    LIVE_FOLDER_BASE_NAME,
    reaper.ColorToNative(65, 150, 110),
    reaper.ColorToNative(90, 185, 150)
  )

  return state.live_output
end

local function render_live_play(state, play)
  local output = ensure_live_output_tracks(state)
  local start_position = reaper.GetCursorPosition()
  local max_end_position = start_position

  for _, track in pairs(output.child_tracks) do
    clear_track_media_items(track)
  end

  for _, entry in ipairs(play.applied_mods) do
    local dest_track = output.child_tracks[entry.pick.group_ref.group_index]
    local new_item, err = duplicate_item_to_track(entry.pick.item, dest_track)
    if not new_item then
      error(err)
    end

    local relative_offset = entry.pick.position - state.origin_position
    local new_position = start_position + relative_offset
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", new_position)

    local take = reaper.GetActiveTake(new_item)
    if take then
      if entry.mods.pitch_semitones ~= nil then
        local original_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", original_pitch + entry.mods.pitch_semitones)
      end

      if entry.mods.volume_db ~= nil then
        local original_volume = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", original_volume * db_to_linear(entry.mods.volume_db))
      end

      set_take_name(take, string.format("Live%02d_%s", play.index, entry.pick.name))
    end

    local item_end = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + reaper.GetMediaItemInfo_Value(new_item, "D_LENGTH")
    if item_end > max_end_position then
      max_end_position = item_end
    end
  end

  reaper.GetSet_LoopTimeRange(true, false, start_position, max_end_position, false)
  reaper.SetEditCurPos(start_position, false, false)

  return {
    folder_name = output.folder_name,
    folder_track = output.folder_track,
    start_pos = start_position,
    end_pos = max_end_position,
  }
end

local function perform_single_interactive_play(state)
  local play_index = #state.history + 1
  local combination = pick_random_combination(state.groups, state.settings)
  local applied = apply_random_modifiers(combination, state.settings)
  local play = {
    index = play_index,
    combination = combination,
    applied_mods = applied,
  }

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local render_info = nil
  local ok, err = pcall(function()
    render_info = render_live_play(state, play)
  end)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if not ok then
    reaper.Undo_EndBlock("Interactive Random Audition (failed)", -1)
    state.status_message = "Trigger failed: " .. tostring(err)
    return false
  end

  reaper.Undo_EndBlock("Interactive Random Audition", -1)

  state.history[#state.history + 1] = play
  state.play_count = #state.history
  state.last_play = play
  state.last_render_info = render_info
  state.status_message = string.format("Triggered play #%d on %s", play.index, render_info.folder_name)

  log_play_entry(play.index, applied)
  start_sequence_playback(render_info)
  return true
end

local function append_history(target_history, chunk)
  for _, entry in ipairs(chunk) do
    target_history[#target_history + 1] = entry
  end
end

local function perform_interactive_sequence(state, should_play)
  local chunk = build_rapid_fire_history(state.groups, state.settings, #state.history + 1)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local render_info = nil
  local ok, err = pcall(function()
    render_info = render_audition_sequence(chunk, state.groups, state.settings)
  end)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if not ok then
    reaper.Undo_EndBlock("Interactive Rapid Fire (failed)", -1)
    state.status_message = "Rapid fire failed: " .. tostring(err)
    return false
  end

  reaper.Undo_EndBlock("Interactive Rapid Fire", -1)

  append_history(state.history, chunk)
  state.play_count = #state.history
  state.last_play = chunk[#chunk]
  state.last_render_info = render_info
  state.status_message = string.format(
    "%s created: %s",
    should_play and "Rapid fire sequence" or "Render sequence",
    render_info.folder_name
  )

  if should_play then
    start_sequence_playback(render_info)
  end

  return true
end

local ACTIVE_INTERACTIVE_STATE = nil

local function build_interactive_buttons(window_height)
  local base_y = (window_height or GUI_WINDOW_H) - 58
  return {
    { id = "trigger", label = "Trigger [SPACE]", x = 18, y = base_y, w = 124, h = 30 },
    { id = "rapid", label = "Rapid Fire [R]", x = 150, y = base_y, w = 118, h = 30 },
    { id = "render", label = "Render Seq [S]", x = 276, y = base_y, w = 120, h = 30 },
    { id = "redetect", label = "Re-Detect [D]", x = 404, y = base_y, w = 118, h = 30 },
    { id = "stats", label = "Stats [T]", x = 530, y = base_y, w = 70, h = 30 },
    { id = "exit", label = "Exit", x = 608, y = base_y, w = 54, h = 30 },
  }
end

local function draw_text(x, y, text, r, g, b, a, font_index)
  if font_index then
    gfx.setfont(font_index)
  end
  gfx.set(r or 1, g or 1, b or 1, a or 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(text or "")
end

local function draw_button(button, hovered)
  local fill = hovered and { 0.28, 0.42, 0.38, 1 } or { 0.20, 0.25, 0.28, 1 }
  local border = hovered and { 0.60, 0.85, 0.74, 1 } or { 0.45, 0.55, 0.62, 1 }

  gfx.set(fill[1], fill[2], fill[3], fill[4])
  gfx.rect(button.x, button.y, button.w, button.h, true)
  gfx.set(border[1], border[2], border[3], border[4])
  gfx.rect(button.x, button.y, button.w, button.h, false)

  gfx.setfont(2)
  local text_w, text_h = gfx.measurestr(button.label)
  draw_text(
    button.x + math.floor((button.w - text_w) / 2),
    button.y + math.floor((button.h - text_h) / 2),
    button.label,
    0.94,
    0.97,
    0.98,
    1,
    2
  )
end

local function draw_interactive_gui(state)
  gfx.set(0.08, 0.09, 0.11, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, true)

  gfx.set(0.18, 0.50, 0.39, 1)
  gfx.rect(0, 0, gfx.w, 64, true)
  draw_text(18, 14, "Random Layer Audition", 0.98, 0.99, 1.0, 1, 3)
  draw_text(18, 38, "Interactive audition for game-audio variation groups", 0.86, 0.95, 0.91, 1, 2)

  gfx.set(0.14, 0.16, 0.19, 1)
  gfx.rect(18, 80, 280, 132, true)
  gfx.set(0.34, 0.40, 0.46, 1)
  gfx.rect(18, 80, 280, 132, false)
  draw_text(30, 92, "Session", 0.97, 0.98, 0.99, 1, 2)
  draw_text(30, 118, string.format("Plays: %d", state.play_count), 0.82, 0.92, 0.98, 1, 2)
  draw_text(30, 140, string.format("Groups: %d", #state.groups), 0.82, 0.92, 0.98, 1, 2)
  draw_text(30, 162, string.format("Mode: %s", state.settings.output_mode), 0.82, 0.92, 0.98, 1, 2)
  draw_text(30, 184, state.status_message or "", 0.72, 0.84, 0.78, 1, 2)

  gfx.set(0.14, 0.16, 0.19, 1)
  gfx.rect(314, 80, 348, 132, true)
  gfx.set(0.34, 0.40, 0.46, 1)
  gfx.rect(314, 80, 348, 132, false)
  draw_text(326, 92, "Settings", 0.97, 0.98, 0.99, 1, 2)
  draw_text(326, 118, string.format("Detect: %s", state.settings.group_mode), 0.92, 0.92, 0.83, 1, 2)
  draw_text(326, 140, string.format("Repeat / Interval: %d / %d ms", state.settings.repeat_count, state.settings.interval_ms), 0.92, 0.92, 0.83, 1, 2)
  draw_text(326, 162, string.format("Pitch / Volume: +/-%.0f c / +/-%.1f dB", state.settings.pitch_range_cents, state.settings.volume_range_db), 0.92, 0.92, 0.83, 1, 2)
  local no_repeat_label = state.settings.no_repeat_mode
  if no_repeat_label == "no_last_n" then
    no_repeat_label = no_repeat_label .. " (" .. tostring(state.settings.no_repeat_count or 2) .. ")"
  end
  draw_text(326, 184, string.format("No-Repeat: %s", no_repeat_label), 0.92, 0.92, 0.83, 1, 2)

  gfx.set(0.12, 0.13, 0.16, 1)
  gfx.rect(18, 228, 280, 250, true)
  gfx.set(0.34, 0.40, 0.46, 1)
  gfx.rect(18, 228, 280, 250, false)
  draw_text(30, 240, "Detected Groups", 0.97, 0.98, 0.99, 1, 2)
  local group_y = 268
  for _, group in ipairs(state.groups) do
    local item_names = {}
    for item_index, item in ipairs(group.items) do
      item_names[#item_names + 1] = item.display_name
      if item_index >= 4 and #group.items > 4 then
        item_names[#item_names + 1] = "..."
        break
      end
    end

    draw_text(30, group_y, string.format("%s (%d)", group.display_name, #group.items), 0.78, 0.92, 0.86, 1, 2)
    draw_text(40, group_y + 18, table.concat(item_names, ", "), 0.70, 0.76, 0.80, 1, 2)
    group_y = group_y + 42
    if group_y > 430 then
      break
    end
  end

  gfx.set(0.12, 0.13, 0.16, 1)
  gfx.rect(314, 228, 348, 250, true)
  gfx.set(0.34, 0.40, 0.46, 1)
  gfx.rect(314, 228, 348, 250, false)
  draw_text(326, 240, "Current Combination", 0.97, 0.98, 0.99, 1, 2)

  local combo_y = 268
  if state.last_play then
    for _, entry in ipairs(state.last_play.applied_mods) do
      local line = string.format("%s: %s", entry.pick.group_name, entry.pick.name)
      if entry.mods.pitch_cents ~= nil then
        line = line .. "  " .. format_modifier_value(entry.mods.pitch_cents, 0, "P", "c")
      end
      if entry.mods.volume_db ~= nil then
        line = line .. "  " .. format_modifier_value(entry.mods.volume_db, 1, "V", "dB")
      end

      draw_text(326, combo_y, line, 0.78, 0.92, 0.86, 1, 2)
      combo_y = combo_y + 24
    end
  else
    draw_text(326, 268, "No trigger yet. Press SPACE or click Trigger.", 0.70, 0.76, 0.80, 1, 2)
  end

  if state.last_render_info then
    draw_text(326, 436, string.format("Last output: %s", state.last_render_info.folder_name or ""), 0.92, 0.92, 0.83, 1, 2)
  end

  draw_text(18, gfx.h - 84, "SPACE trigger | R rapid fire+play | S render only | D re-detect | T stats | ESC exit", 0.74, 0.78, 0.84, 1, 2)

  local buttons = build_interactive_buttons(gfx.h)
  for _, button in ipairs(buttons) do
    local hovered = point_in_rect(gfx.mouse_x, gfx.mouse_y, button.x, button.y, button.w, button.h)
    draw_button(button, hovered)
  end

  return buttons
end

local function print_interactive_statistics(state)
  if #state.history == 0 then
    log_line("No interactive plays were recorded.")
    state.status_message = "No plays recorded yet."
    return
  end

  print_statistics(state.history, state.groups, state.settings, state.last_render_info)
  save_session_summary(state.history, state.groups, state.last_render_info)
  state.status_message = string.format("Printed statistics for %d plays", #state.history)
end

local function refresh_interactive_groups(state)
  local groups, detect_err = detect_layer_groups(state.settings.group_mode)
  if not groups then
    state.status_message = detect_err or "Re-detect failed."
    return false
  end

  state.groups = groups
  state.origin_position = find_global_origin_position(groups)
  state.live_output = nil
  state.history = {}
  state.play_count = 0
  state.last_play = nil
  state.last_render_info = nil
  state.status_message = string.format("Detected %d groups. Session history reset.", #groups)
  log_detected_groups(groups)
  return true
end

local function stop_interactive_audition(state)
  if not state or not state.running then
    return
  end

  state.running = false
  ACTIVE_INTERACTIVE_STATE = nil
  reaper.OnStopButton()

  if #state.history > 0 then
    print_statistics(state.history, state.groups, state.settings, state.last_render_info)
    save_session_summary(state.history, state.groups, state.last_render_info)
  else
    log_line("Interactive session ended with no plays.")
  end

  gfx.quit()
end

local function handle_interactive_action(state, action_id)
  if action_id == "trigger" then
    perform_single_interactive_play(state)
  elseif action_id == "rapid" then
    perform_interactive_sequence(state, true)
  elseif action_id == "render" then
    perform_interactive_sequence(state, false)
  elseif action_id == "stats" then
    print_interactive_statistics(state)
  elseif action_id == "redetect" then
    refresh_interactive_groups(state)
  elseif action_id == "exit" then
    stop_interactive_audition(state)
  end
end

local function interactive_defer_loop()
  local state = ACTIVE_INTERACTIVE_STATE
  if not state or not state.running then
    return
  end

  local buttons = draw_interactive_gui(state)
  local char = gfx.getchar()
  if char < 0 then
    stop_interactive_audition(state)
    return
  end

  if char == 27 then
    stop_interactive_audition(state)
    return
  elseif char == 32 then
    handle_interactive_action(state, "trigger")
  elseif char == string.byte("r") or char == string.byte("R") then
    handle_interactive_action(state, "rapid")
  elseif char == string.byte("s") or char == string.byte("S") then
    handle_interactive_action(state, "render")
  elseif char == string.byte("t") or char == string.byte("T") then
    handle_interactive_action(state, "stats")
  elseif char == string.byte("d") or char == string.byte("D") then
    handle_interactive_action(state, "redetect")
  end

  if not state.running then
    return
  end

  local mouse_down = (gfx.mouse_cap % 2) == 1
  if mouse_down and not state.mouse_was_down then
    for _, button in ipairs(buttons) do
      if point_in_rect(gfx.mouse_x, gfx.mouse_y, button.x, button.y, button.w, button.h) then
        handle_interactive_action(state, button.id)
        break
      end
    end
  end

  if not state.running then
    return
  end

  state.mouse_was_down = mouse_down

  gfx.update()
  reaper.defer(interactive_defer_loop)
end

local function start_interactive_audition(groups, settings)
  local state = {
    groups = groups,
    settings = settings,
    origin_position = find_global_origin_position(groups),
    history = {},
    play_count = 0,
    last_play = nil,
    last_render_info = nil,
    live_output = nil,
    status_message = "Interactive mode ready.",
    mouse_was_down = false,
    running = true,
  }

  ACTIVE_INTERACTIVE_STATE = state

  gfx.init(SCRIPT_TITLE .. " - Interactive", GUI_WINDOW_W, GUI_WINDOW_H, 0)
  gfx.setfont(1, "Arial", 14)
  gfx.setfont(2, "Arial", 13)
  gfx.setfont(3, "Arial", 22)

  log_line("===========================================")
  log_line("Interactive Audition Mode")
  log_line("===========================================")
  log_line("SPACE: trigger random play")
  log_line("R: rapid fire render + playback")
  log_line("S: render sequence only")
  log_line("D: re-detect groups")
  log_line("T: print session statistics")
  log_line("ESC: exit interactive mode")
  log_line("")

  reaper.atexit(function()
    if ACTIVE_INTERACTIVE_STATE and ACTIVE_INTERACTIVE_STATE.running then
      stop_interactive_audition(ACTIVE_INTERACTIVE_STATE)
    end
  end)

  interactive_defer_loop()
end

local function build_bar(percent, width)
  local max_width = width or 20
  local clamped = clamp_number(percent, 0, 100)
  local filled = math.floor((clamped / 100.0) * max_width + 0.5)
  if filled > max_width then
    filled = max_width
  end
  return string.rep("#", filled) .. string.rep(".", max_width - filled)
end

local function analyze_distribution(history, groups)
  local report = {}

  for _, group in ipairs(groups) do
    local counts = {}
    local total_picks = 0

    for _, play in ipairs(history) do
      for _, pick in ipairs(play.combination) do
        if pick.group_name == group.display_name then
          counts[pick.name] = (counts[pick.name] or 0) + 1
          total_picks = total_picks + 1
        end
      end
    end

    local expected = total_picks > 0 and (total_picks / #group.items) or 0
    local max_deviation = 0
    local item_stats = {}

    for _, item in ipairs(group.items) do
      local count = counts[item.display_name] or 0
      local percent = total_picks > 0 and (count / total_picks * 100.0) or 0.0
      local deviation = expected > 0 and (math.abs(count - expected) / expected * 100.0) or 0.0

      if deviation > max_deviation then
        max_deviation = deviation
      end

      item_stats[#item_stats + 1] = {
        name = item.display_name,
        count = count,
        percent = percent,
        deviation = deviation,
      }
    end

    report[#report + 1] = {
      group_name = group.display_name,
      total_picks = total_picks,
      item_count = #group.items,
      max_deviation_pct = max_deviation,
      is_even = max_deviation <= 20.0,
      item_stats = item_stats,
    }
  end

  return report
end

local function analyze_repeats(history, groups)
  local result = {
    total_consecutive_same = 0,
    longest_run = 1,
    longest_group = nil,
    longest_name = nil,
    longest_start_index = nil,
    longest_end_index = nil,
  }

  for _, group in ipairs(groups) do
    local last_key = nil
    local run_length = 0
    local run_start = 1

    for play_index, play in ipairs(history) do
      local picked_key = nil
      local picked_name = nil

      for _, pick in ipairs(play.combination) do
        if pick.group_name == group.display_name then
          picked_key = pick.key
          picked_name = pick.name
          break
        end
      end

      if picked_key == last_key then
        run_length = run_length + 1
        result.total_consecutive_same = result.total_consecutive_same + 1
      else
        run_length = 1
        run_start = play_index
      end

      if run_length > result.longest_run then
        result.longest_run = run_length
        result.longest_group = group.display_name
        result.longest_name = picked_name
        result.longest_start_index = run_start
        result.longest_end_index = play_index
      end

      last_key = picked_key
    end
  end

  return result
end

local function collect_modifier_ranges(history)
  local result = {
    pitch_min = nil,
    pitch_max = nil,
    volume_min = nil,
    volume_max = nil,
  }

  for _, play in ipairs(history) do
    for _, entry in ipairs(play.applied_mods) do
      if entry.mods.pitch_cents ~= nil then
        result.pitch_min = result.pitch_min and math.min(result.pitch_min, entry.mods.pitch_cents) or entry.mods.pitch_cents
        result.pitch_max = result.pitch_max and math.max(result.pitch_max, entry.mods.pitch_cents) or entry.mods.pitch_cents
      end

      if entry.mods.volume_db ~= nil then
        result.volume_min = result.volume_min and math.min(result.volume_min, entry.mods.volume_db) or entry.mods.volume_db
        result.volume_max = result.volume_max and math.max(result.volume_max, entry.mods.volume_db) or entry.mods.volume_db
      end
    end
  end

  return result
end

local function print_statistics(history, groups, settings, render_info)
  local report = analyze_distribution(history, groups)
  local repeats = analyze_repeats(history, groups)
  local modifiers = collect_modifier_ranges(history)
  local duration_seconds = (math.max(0, #history - 1) * settings.interval_ms) / 1000.0

  log_line("================================================================")
  log_line("Audition Statistics - Session Report")
  log_line("================================================================")
  log_line(string.format(
    "Total Plays: %d | Duration: %.2f sec | Groups: %d | Track: %s",
    #history,
    duration_seconds,
    #groups,
    render_info and render_info.folder_name or "(none)"
  ))
  log_line("")

  for _, group_report in ipairs(report) do
    log_line(string.format("-- Group: %s (%d variations) --", group_report.group_name, group_report.item_count))

    for _, item_stat in ipairs(group_report.item_stats) do
      log_line(string.format(
        "%-24s %s %3d times (%5.1f%%)",
        item_stat.name .. ":",
        build_bar(item_stat.percent, 12),
        item_stat.count,
        item_stat.percent
      ))
    end

    log_line(string.format(
      "Distribution: %s (max deviation: %.1f%%)",
      group_report.is_even and "Even" or "Uneven",
      group_report.max_deviation_pct
    ))
    log_line("")
  end

  log_line("-- Repeat Analysis --")
  log_line(string.format("Consecutive same picks: %d", repeats.total_consecutive_same))
  if repeats.longest_run > 1 and repeats.longest_group and repeats.longest_name then
    log_line(string.format(
      "Longest run: %d (%s / %s at plays #%d-#%d)",
      repeats.longest_run,
      repeats.longest_group,
      repeats.longest_name,
      repeats.longest_start_index or 1,
      repeats.longest_end_index or 1
    ))
  else
    log_line("Longest run: 1 (no consecutive repeats detected)")
  end
  log_line("")

  log_line("-- Modifier Ranges Applied --")
  if modifiers.pitch_min ~= nil then
    log_line(string.format(
      "Pitch:  %.0f to %.0f cents (target: +/-%.0f)",
      modifiers.pitch_min,
      modifiers.pitch_max,
      settings.pitch_range_cents
    ))
  else
    log_line("Pitch:  Off")
  end

  if modifiers.volume_min ~= nil then
    log_line(string.format(
      "Volume: %.1f to %.1f dB (target: +/-%.1f)",
      modifiers.volume_min,
      modifiers.volume_max,
      settings.volume_range_db
    ))
  else
    log_line("Volume: Off")
  end

  log_line("================================================================")
end

local function start_sequence_playback(render_info)
  if not render_info then
    return
  end

  reaper.OnStopButton()
  reaper.SetEditCurPos(render_info.start_pos, false, false)
  reaper.GetSet_LoopTimeRange(true, false, render_info.start_pos, render_info.end_pos, false)
  reaper.OnPlayButton()
end

local function main()
  local current_settings = load_settings()
  local settings, prompt_err = prompt_for_settings(current_settings)
  if not settings then
    if prompt_err and prompt_err ~= "User cancelled." then
      reaper.ShowMessageBox(prompt_err, SCRIPT_TITLE, 0)
    end
    return
  end

  save_settings(settings)
  seed_random()
  reaper.ClearConsole()

  local groups, detect_err = detect_layer_groups(settings.group_mode)
  if not groups then
    reaper.ShowMessageBox(detect_err or "No groups detected.", SCRIPT_TITLE, 0)
    return
  end

  log_detected_groups(groups)

  if settings.output_mode == "interactive" then
    start_interactive_audition(groups, settings)
    return
  end

  local history = build_rapid_fire_history(groups, settings)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local render_info = nil
  local ok, err = pcall(function()
    render_info = render_audition_sequence(history, groups, settings)
  end)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if not ok then
    reaper.Undo_EndBlock("Random Layer Audition (failed)", -1)
    reaper.ShowMessageBox("Failed to render audition sequence:\n\n" .. tostring(err), SCRIPT_TITLE, 0)
    return
  end

  reaper.Undo_EndBlock("Random Layer Audition", -1)

  if settings.output_mode == "play" then
    start_sequence_playback(render_info)
  end

  print_statistics(history, groups, settings, render_info)
  save_session_summary(history, groups, render_info)
end

main()
