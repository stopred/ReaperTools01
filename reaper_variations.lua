--[[
  Selected Item Variations Generator
  - Uses selected media items in project tab 0 as sources.
  - Duplicates each selected item for each variation.
  - Places each variation group at 1-second intervals from 0 seconds.
  - Randomizes active take pitch / volume / pan per duplicate.
]]

math.randomseed(math.floor(reaper.time_precise() * 1000000) % 2147483647)
math.random()
math.random()
math.random()

local WINDOW_W = 460
local WINDOW_H = 392 -- MOD
local PADDING = 20
local ROW_H = 42
local SLIDER_W = 240
local SLIDER_H = 18
local BUTTON_W = 120
local BUTTON_H = 30
local ENVELOPE_SHAPE_SQUARE = 1 -- MOD
local LOW_SHELF_API_BANDTYPE = 1 -- MOD
local PRESENCE_API_BANDTYPE = 2 -- MOD
local LOW_PASS_API_BANDTYPE = 5 -- MOD
local LOW_SHELF_CONFIG_BANDTYPE = 0 -- MOD
local PRESENCE_CONFIG_BANDTYPE = 8 -- MOD
local LOW_PASS_CONFIG_BANDTYPE = 3 -- MOD
local LOW_SHELF_FREQ = 100.0 -- MOD
local PRESENCE_Q = 1.0 -- MOD
local LOW_PASS_Q = 0.707 -- MOD

local state = {
  variationCount = 10,
  pitchRangeSemitones = 4,
  volRangeDb = 3,
  panRangePercent = 20,
  tone = 0.0, -- MOD
  muteProbability = 0.0, -- MOD
  reverseProbability = 0.0, -- MOD
  activeSlider = nil,
  prevMouseDown = false,
  statusText = "Ready",
}

local sliders = {
  {
    key = "variationCount",
    label = "VariationCount",
    min = 1,
    max = 64,
    step = 1,
    format = function(value) return string.format("%d", value) end,
  },
  {
    key = "pitchRangeSemitones",
    label = "PitchRangeSemitones",
    min = 0,
    max = 24,
    step = 1,
    format = function(value) return string.format("%d st", value) end,
  },
  {
    key = "volRangeDb",
    label = "VolRangeDb",
    min = 0,
    max = 24,
    step = 1,
    format = function(value) return string.format("%d dB", value) end,
  },
  {
    key = "panRangePercent",
    label = "PanRangePercent",
    min = 0,
    max = 100,
    step = 1,
    format = function(value) return string.format("%d%%", value) end,
  },
  {
    key = "tone",
    label = "Tone",
    min = 0,
    max = 1,
    step = 0.01,
    format = function(value) return string.format("%.2f", value) end,
  }, -- MOD
  {
    key = "muteProbability",
    label = "MuteProbability",
    min = 0,
    max = 1,
    step = 0.01,
    format = function(value) return string.format("%.2f", value) end,
  }, -- MOD
  {
    key = "reverseProbability",
    label = "ReverseProbability",
    min = 0,
    max = 1,
    step = 0.01,
    format = function(value) return string.format("%.2f", value) end,
  }, -- MOD
}

local generateButton = {
  x = PADDING,
  y = WINDOW_H - PADDING - BUTTON_H,
  w = BUTTON_W,
  h = BUTTON_H,
}

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function point_in_rect(x, y, rectX, rectY, rectW, rectH)
  return x >= rectX and x <= (rectX + rectW) and y >= rectY and y <= (rectY + rectH)
end

local function random_symmetric(maxAbs)
  return (math.random() * 2.0 - 1.0) * maxAbs
end

local function db_to_amplitude(dbValue)
  return 10 ^ (dbValue / 20.0)
end

local function regenerate_chunk_guids(chunk)
  local outLines = {}

  for line in chunk:gmatch("[^\r\n]+") do
    local prefix = line:match("^([A-Z]*GUID)%s+")
    if prefix then
      outLines[#outLines + 1] = prefix .. " " .. reaper.genGuid()
    else
      outLines[#outLines + 1] = line
    end
  end

  return table.concat(outLines, "\n")
end

local function duplicate_item(sourceItem)
  local track = reaper.GetMediaItemTrack(sourceItem)
  if not track then
    return nil
  end

  local ok, chunk = reaper.GetItemStateChunk(sourceItem, "", false)
  if not ok then
    return nil
  end

  local duplicatedItem = reaper.AddMediaItemToTrack(track)
  if not duplicatedItem then
    return nil
  end

  local setOk = reaper.SetItemStateChunk(duplicatedItem, regenerate_chunk_guids(chunk), false)
  if not setOk then
    reaper.DeleteTrackMediaItem(track, duplicatedItem)
    return nil
  end

  return duplicatedItem
end

local function collect_selected_items()
  local items = {}
  local selectedCount = reaper.CountSelectedMediaItems(0)
  local earliestPosition = nil

  for index = 0, selectedCount - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)
    if item then
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") -- MOD
      local track = reaper.GetMediaItemTrack(item) -- MOD
      items[#items + 1] = {
        item = item,
        position = position,
        length = length,
        track = track, -- MOD
      }

      if not earliestPosition or position < earliestPosition then
        earliestPosition = position
      end
    end
  end

  return items, earliestPosition
end

local function ensure_reaeq_tone_bands(track) -- MOD
  local fxIndex = reaper.TrackFX_GetEQ(track, true)
  if fxIndex < 0 then
    return nil
  end

  local hasLowShelf = false
  local hasPresence = false
  local hasLowPass = false
  local bandCount = 0

  while true do
    local ok, bandType = reaper.TrackFX_GetNamedConfigParm(track, fxIndex, "BANDTYPE" .. bandCount)
    if not ok then
      break
    end

    bandType = tonumber(bandType)
    if bandType == LOW_SHELF_CONFIG_BANDTYPE then
      hasLowShelf = true
    elseif bandType == PRESENCE_CONFIG_BANDTYPE then
      hasPresence = true
    elseif bandType == LOW_PASS_CONFIG_BANDTYPE then
      hasLowPass = true
    end

    bandCount = bandCount + 1
  end

  if bandCount >= 1 and not hasLowShelf then
    reaper.TrackFX_SetNamedConfigParm(track, fxIndex, "BANDTYPE0", LOW_SHELF_CONFIG_BANDTYPE)
  end
  if bandCount >= 2 and not hasPresence then
    reaper.TrackFX_SetNamedConfigParm(track, fxIndex, "BANDTYPE1", PRESENCE_CONFIG_BANDTYPE)
  end
  if bandCount >= 3 and not hasLowPass then
    reaper.TrackFX_SetNamedConfigParm(track, fxIndex, "BANDTYPE2", LOW_PASS_CONFIG_BANDTYPE)
  end

  reaper.TrackFX_SetEQBandEnabled(track, fxIndex, LOW_SHELF_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQBandEnabled(track, fxIndex, PRESENCE_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQBandEnabled(track, fxIndex, LOW_PASS_API_BANDTYPE, 0, true)

  reaper.TrackFX_SetEQParam(track, fxIndex, LOW_SHELF_API_BANDTYPE, 0, 0, LOW_SHELF_FREQ, false)
  reaper.TrackFX_SetEQParam(track, fxIndex, PRESENCE_API_BANDTYPE, 0, 2, PRESENCE_Q, false)
  reaper.TrackFX_SetEQParam(track, fxIndex, LOW_PASS_API_BANDTYPE, 0, 2, LOW_PASS_Q, false)

  return fxIndex
end

local function find_reaeq_param_index(track, fxIndex, bandtype, bandidx, paramtype) -- MOD
  local paramCount = reaper.TrackFX_GetNumParams(track, fxIndex)

  for paramIndex = 0, paramCount - 1 do
    local ok, currentBandType, currentBandIndex, currentParamType = reaper.TrackFX_GetEQParam(track, fxIndex, paramIndex)
    if ok and currentBandType == bandtype and currentBandIndex == bandidx and currentParamType == paramtype then
      return paramIndex
    end
  end

  return nil
end

local function get_track_eq_context(track, cache) -- MOD
  if cache[track] then
    return cache[track]
  end

  local fxIndex = ensure_reaeq_tone_bands(track)
  if not fxIndex then
    return nil
  end

  local context = {
    track = track,
    fxIndex = fxIndex,
    lowShelfGainParam = find_reaeq_param_index(track, fxIndex, LOW_SHELF_API_BANDTYPE, 0, 1),
    presenceFreqParam = find_reaeq_param_index(track, fxIndex, PRESENCE_API_BANDTYPE, 0, 0),
    presenceGainParam = find_reaeq_param_index(track, fxIndex, PRESENCE_API_BANDTYPE, 0, 1),
    lowPassFreqParam = find_reaeq_param_index(track, fxIndex, LOW_PASS_API_BANDTYPE, 0, 0),
  }

  if not context.lowShelfGainParam
    or not context.presenceFreqParam
    or not context.presenceGainParam
    or not context.lowPassFreqParam then
    return nil
  end

  context.lowShelfGainEnv = reaper.GetFXEnvelope(track, fxIndex, context.lowShelfGainParam, true)
  context.presenceFreqEnv = reaper.GetFXEnvelope(track, fxIndex, context.presenceFreqParam, true)
  context.presenceGainEnv = reaper.GetFXEnvelope(track, fxIndex, context.presenceGainParam, true)
  context.lowPassFreqEnv = reaper.GetFXEnvelope(track, fxIndex, context.lowPassFreqParam, true)

  if not context.lowShelfGainEnv
    or not context.presenceFreqEnv
    or not context.presenceGainEnv
    or not context.lowPassFreqEnv then
    return nil
  end

  cache[track] = context
  return context
end

local function write_fx_envelope_segment(envelope, startTime, endTime, normalizedValue) -- MOD
  reaper.DeleteEnvelopePointRange(envelope, startTime, endTime)
  reaper.InsertEnvelopePoint(
    envelope,
    startTime,
    normalizedValue,
    ENVELOPE_SHAPE_SQUARE,
    0,
    false,
    true
  )
  reaper.InsertEnvelopePoint(
    envelope,
    endTime,
    normalizedValue,
    ENVELOPE_SHAPE_SQUARE,
    0,
    false,
    true
  )
end

local function apply_tone_variation(context, startTime, endTime, tone) -- MOD
  local shelfGainDb = random_symmetric(6.0 * tone)
  local presenceGainDb = random_symmetric(6.0 * tone)
  local presenceFreq = 2000.0 + (math.random() * 2000.0)
  local highCutFreq = 22000.0 - (10000.0 * tone) - (math.random() * 4000.0 * tone)

  reaper.TrackFX_SetEQBandEnabled(context.track, context.fxIndex, LOW_SHELF_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQBandEnabled(context.track, context.fxIndex, PRESENCE_API_BANDTYPE, 0, true)
  reaper.TrackFX_SetEQBandEnabled(context.track, context.fxIndex, LOW_PASS_API_BANDTYPE, 0, true)

  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, LOW_SHELF_API_BANDTYPE, 0, 0, LOW_SHELF_FREQ, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, LOW_SHELF_API_BANDTYPE, 0, 1, shelfGainDb, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, PRESENCE_API_BANDTYPE, 0, 0, presenceFreq, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, PRESENCE_API_BANDTYPE, 0, 1, presenceGainDb, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, PRESENCE_API_BANDTYPE, 0, 2, PRESENCE_Q, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, LOW_PASS_API_BANDTYPE, 0, 0, highCutFreq, false)
  reaper.TrackFX_SetEQParam(context.track, context.fxIndex, LOW_PASS_API_BANDTYPE, 0, 2, LOW_PASS_Q, false)

  write_fx_envelope_segment(
    context.lowShelfGainEnv,
    startTime,
    endTime,
    reaper.TrackFX_GetParamNormalized(context.track, context.fxIndex, context.lowShelfGainParam)
  )
  write_fx_envelope_segment(
    context.presenceFreqEnv,
    startTime,
    endTime,
    reaper.TrackFX_GetParamNormalized(context.track, context.fxIndex, context.presenceFreqParam)
  )
  write_fx_envelope_segment(
    context.presenceGainEnv,
    startTime,
    endTime,
    reaper.TrackFX_GetParamNormalized(context.track, context.fxIndex, context.presenceGainParam)
  )
  write_fx_envelope_segment(
    context.lowPassFreqEnv,
    startTime,
    endTime,
    reaper.TrackFX_GetParamNormalized(context.track, context.fxIndex, context.lowPassFreqParam)
  )

  reaper.Envelope_SortPoints(context.lowShelfGainEnv)
  reaper.Envelope_SortPoints(context.presenceFreqEnv)
  reaper.Envelope_SortPoints(context.presenceGainEnv)
  reaper.Envelope_SortPoints(context.lowPassFreqEnv)
end

local function apply_random_take_variation(item, pitchRange, volRangeDb, panRangePercent)
  local take = reaper.GetActiveTake(item)
  if not take then
    return
  end

  local basePitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
  local baseVol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
  local basePan = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")

  local pitchOffset = random_symmetric(pitchRange)
  local volumeOffsetDb = random_symmetric(volRangeDb)
  local panOffset = random_symmetric(panRangePercent) / 100.0

  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", basePitch + pitchOffset)
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", baseVol * db_to_amplitude(volumeOffsetDb))
  reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", clamp(basePan + panOffset, -1.0, 1.0))
end

local function reverse_generated_items(itemsToReverse, sourceItems) -- MOD
  if #itemsToReverse == 0 then
    return
  end

  reaper.SelectAllMediaItems(0, false)

  for _, item in ipairs(itemsToReverse) do
    if item then
      reaper.SetMediaItemSelected(item, true)
    end
  end

  reaper.Main_OnCommand(41051, 0)

  reaper.SelectAllMediaItems(0, false)

  for _, source in ipairs(sourceItems) do
    if source.item then
      reaper.SetMediaItemSelected(source.item, true)
    end
  end
end

local function generate_variations()
  local sourceItems, earliestPosition = collect_selected_items()
  if #sourceItems == 0 or not earliestPosition then
    state.statusText = "No selected media items in project tab 0."
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local createdCount = 0
  local eqContexts = {} -- MOD
  local itemsToReverse = {} -- MOD
  local ok, errorMessage = pcall(function() -- MOD
    for variationIndex = 1, state.variationCount do
      local variationBasePosition = variationIndex - 1
      local variationTrackRanges = {} -- MOD

      for _, source in ipairs(sourceItems) do
        local duplicatedItem = duplicate_item(source.item)
        if duplicatedItem then
          local relativeOffset = source.position - earliestPosition
          local newPosition = variationBasePosition + relativeOffset
          local trackRange = variationTrackRanges[source.track] -- MOD
          if not trackRange then
            trackRange = {
              startTime = newPosition,
              endTime = newPosition + source.length,
            }
            variationTrackRanges[source.track] = trackRange
          else
            if newPosition < trackRange.startTime then
              trackRange.startTime = newPosition
            end
            if (newPosition + source.length) > trackRange.endTime then
              trackRange.endTime = newPosition + source.length
            end
          end

          reaper.SetMediaItemInfo_Value(duplicatedItem, "D_POSITION", newPosition)
          reaper.SetMediaItemSelected(duplicatedItem, false)
          apply_random_take_variation(
            duplicatedItem,
            state.pitchRangeSemitones,
            state.volRangeDb,
            state.panRangePercent
          )
          if math.random() < state.muteProbability then -- MOD
            reaper.SetMediaItemInfo_Value(duplicatedItem, "B_MUTE", 1)
          end
          if math.random() < state.reverseProbability and reaper.GetActiveTake(duplicatedItem) then -- MOD
            itemsToReverse[#itemsToReverse + 1] = duplicatedItem
          end
          createdCount = createdCount + 1
        end
      end

      for track, range in pairs(variationTrackRanges) do -- MOD
        local eqContext = get_track_eq_context(track, eqContexts)
        if eqContext then
          apply_tone_variation(eqContext, range.startTime, range.endTime, state.tone)
        end
      end
    end

    reverse_generated_items(itemsToReverse, sourceItems) -- MOD
  end)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if ok then -- MOD
    reaper.Undo_EndBlock("Generate selected item variations", -1) -- MOD
    state.statusText = string.format( -- MOD
      "Generated %d item copies across %d variations.",
      createdCount,
      state.variationCount
    )
  else
    reaper.Undo_EndBlock("Generate selected item variations (failed)", -1) -- MOD
    state.statusText = "Error: " .. tostring(errorMessage) -- MOD
  end
end

local function draw_label(text, x, y)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(text)
end

local function draw_slider(slider, x, y)
  local value = state[slider.key]
  local normalized = 0.0

  if slider.max > slider.min then
    normalized = (value - slider.min) / (slider.max - slider.min)
  end

  normalized = clamp(normalized, 0.0, 1.0)

  draw_label(slider.label, x, y)
  draw_label(slider.format(value), x + SLIDER_W + 16, y)

  local sliderY = y + 18
  local handleX = x + (SLIDER_W * normalized)

  gfx.set(0.22, 0.22, 0.22, 1.0)
  gfx.rect(x, sliderY, SLIDER_W, SLIDER_H, true)

  gfx.set(0.36, 0.68, 0.96, 1.0)
  gfx.rect(x, sliderY, handleX - x, SLIDER_H, true)

  gfx.set(0.95, 0.95, 0.95, 1.0)
  gfx.rect(handleX - 4, sliderY - 3, 8, SLIDER_H + 6, true)

  slider.x = x
  slider.y = sliderY
  slider.w = SLIDER_W
  slider.h = SLIDER_H
end

local function update_slider_from_mouse(slider)
  local normalized = clamp((gfx.mouse_x - slider.x) / slider.w, 0.0, 1.0)
  local rawValue = slider.min + ((slider.max - slider.min) * normalized)
  local steppedValue = math.floor((rawValue / slider.step) + 0.5) * slider.step
  state[slider.key] = clamp(steppedValue, slider.min, slider.max)
end

local function draw_button(button, label, pressed)
  if pressed then
    gfx.set(0.24, 0.58, 0.24, 1.0)
  else
    gfx.set(0.18, 0.45, 0.18, 1.0)
  end
  gfx.rect(button.x, button.y, button.w, button.h, true)

  gfx.set(1.0, 1.0, 1.0, 1.0)
  local textW, textH = gfx.measurestr(label)
  gfx.x = button.x + ((button.w - textW) * 0.5)
  gfx.y = button.y + ((button.h - textH) * 0.5)
  gfx.drawstr(label)
end

local function handle_mouse()
  local mouseDown = (gfx.mouse_cap % 2) == 1 -- MOD
  local justPressed = mouseDown and not state.prevMouseDown

  if justPressed then
    for _, slider in ipairs(sliders) do
      if slider.x and point_in_rect(gfx.mouse_x, gfx.mouse_y, slider.x, slider.y, slider.w, slider.h) then -- MOD
        state.activeSlider = slider
        update_slider_from_mouse(slider)
        break
      end
    end

    if point_in_rect(
      gfx.mouse_x,
      gfx.mouse_y,
      generateButton.x,
      generateButton.y,
      generateButton.w,
      generateButton.h
    ) then
      generate_variations()
    end
  elseif mouseDown and state.activeSlider then
    update_slider_from_mouse(state.activeSlider)
  elseif not mouseDown then
    state.activeSlider = nil
  end

  state.prevMouseDown = mouseDown
end

local function draw_status()
  gfx.set(0.85, 0.85, 0.85, 1.0)
  gfx.x = PADDING + BUTTON_W + 16
  gfx.y = generateButton.y + 7
  gfx.drawstr(state.statusText)
end

local function draw()
  gfx.set(0.10, 0.10, 0.10, 1.0)
  gfx.rect(0, 0, WINDOW_W, WINDOW_H, true)

  gfx.set(1.0, 1.0, 1.0, 1.0)
  draw_label("Selected Item Variations", PADDING, 10)

  local startY = 42
  for index, slider in ipairs(sliders) do
    draw_slider(slider, PADDING, startY + ((index - 1) * ROW_H))
  end

  local buttonPressed = point_in_rect(
    gfx.mouse_x,
    gfx.mouse_y,
    generateButton.x,
    generateButton.y,
    generateButton.w,
    generateButton.h
  ) and ((gfx.mouse_cap % 2) == 1) -- MOD

  draw_button(generateButton, "Generate", buttonPressed)
  draw_status()
end

local function main()
  local char = gfx.getchar()
  if char < 0 or char == 27 then
    return
  end

  draw()
  handle_mouse()
  gfx.update()
  reaper.defer(main)
end

gfx.init("Selected Item Variations", WINDOW_W, WINDOW_H)
main()
