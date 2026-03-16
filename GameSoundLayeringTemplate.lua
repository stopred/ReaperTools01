-- Game Sound Layering Template v1.0
-- Reaper ReaScript (Lua)
-- Automates game-audio layering track setup for REAPER projects.
--
-- Usage:
-- 1. Actions -> Load ReaScript and load this file.
-- 2. Run the script from the Action List.
-- 3. Enter a template key such as Weapon_Melee or Footstep.
-- 4. Enter one or more asset names separated by commas.
-- 5. Choose insert mode and confirm to build the track structure.
--
-- Requirements: REAPER v7.0+
-- Recommended: SWS Extension for visible track notes
-- Related workflow: GameSoundVariationGenerator.lua,
--                   GameSoundTailProcessor.lua,
--                   GameSoundLoudnessNormalizer.lua,
--                   GameSoundBatchRenderer.lua

local SCRIPT_TITLE = "Game Sound Layering Template v1.0"
local EXT_SECTION = "GameSoundLayerTemplates"
local REAPER_COLOR_FLAG = 0x1000000

local DEFAULTS = {
  template_key = "Weapon_Melee",
  asset_names = "Sword_Swing",
  insert_mode = "end",
  include_fx = true,
  apply_colors = true,
  write_notes = true,
  include_buses = false,
  create_markers = false,
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

local function db_to_linear(db_value)
  return 10 ^ ((tonumber(db_value) or 0.0) / 20.0)
end

local function log10(value)
  return math.log(value) / math.log(10)
end

local function linear_to_db(linear_value)
  local safe = math.max(math.abs(tonumber(linear_value) or 0.0), 1e-12)
  return 20.0 * log10(safe)
end

local function round_to(value, decimals)
  local power = 10 ^ (decimals or 0)
  if value >= 0 then
    return math.floor(value * power + 0.5) / power
  end
  return math.ceil(value * power - 0.5) / power
end

local function bool_to_string(value)
  return value and "y" or "n"
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

local function normalize_token(value)
  local lowered = trim_string(value):lower()
  return lowered:gsub("[^%w]", "")
end

local function sanitize_asset_name(value)
  local sanitized = trim_string(value)
  sanitized = sanitized:gsub("[%c]", "")
  sanitized = sanitized:gsub("[\\/:*?\"<>|]", "")
  sanitized = sanitized:gsub("%s+", "_")
  sanitized = sanitized:gsub("_+", "_")
  sanitized = sanitized:gsub("^_+", "")
  sanitized = sanitized:gsub("_+$", "")
  return sanitized
end

local function copy_table(source)
  if type(source) ~= "table" then
    return source
  end

  local copy = {}
  for key, value in pairs(source) do
    copy[key] = copy_table(value)
  end
  return copy
end

local function color(r, g, b)
  return { r = r, g = g, b = b }
end

local function fx(plugin, params, enabled)
  return { plugin = plugin, params = params or {}, enabled = enabled }
end

local function layer(definition)
  local item = copy_table(definition or {})
  item.volume_db = tonumber(item.volume_db) or 0.0
  item.pan = tonumber(item.pan) or 0.0
  item.fx_chain = item.fx_chain or {}
  return item
end

local BUILTIN_TEMPLATES = {
  Weapon_Melee = {
    name = "Weapon_Melee",
    description = "Melee weapon impact layering template.",
    category_prefix = "SFX_Weapon",
    folder = { name = "SFX_Weapon_[AssetName]", color = color(200, 60, 60) },
    layers = {
      layer({
        name = "Attack",
        color = color(255, 100, 100),
        sends = {
          { bus = "Reverb_Bus", volume_db = -18.0, mode = "postfader" },
        },
        fx_chain = {
          fx("ReaEQ", {
            { idx = 0, val = 1.0 },
            { idx = 1, val = 0.15 },
            { idx = 2, val = 0.70 },
            { idx = 3, val = 1.0 },
          }),
          fx("ReaComp", {
            { idx = 0, val = 0.50 },
            { idx = 1, val = 0.30 },
            { idx = 3, val = 0.001 },
            { idx = 4, val = 0.05 },
          }),
        },
        note = table.concat({
          "Sharp initial impact.",
          "- Focus on transient definition.",
          "- Keep the core hit short and controlled.",
          "- Good sources: metal clanks, snaps, whip-like attacks.",
        }, "\n"),
      }),
      layer({
        name = "Body",
        color = color(180, 80, 80),
        volume_db = -2.0,
        sends = {
          { bus = "Reverb_Bus", volume_db = -14.0, mode = "postfader" },
        },
        fx_chain = {
          fx("ReaEQ", {
            { idx = 0, val = 0.0 },
            { idx = 1, val = 0.30 },
            { idx = 2, val = 0.50 },
            { idx = 4, val = 1.0 },
          }),
        },
        note = "Main weight and tonal center.\n- Build the physical mass here.\n- Favor dense mids over piercing highs.",
      }),
      layer({
        name = "Tail",
        color = color(150, 90, 90),
        volume_db = -6.0,
        sends = {
          { bus = "Reverb_Bus", volume_db = -8.0, mode = "postfader" },
        },
        fx_chain = { fx("ReaVerbate", {}) },
        note = "Residual decay and space.\n- Match the environment size.\n- Keep enough separation from the main impact.",
      }),
      layer({
        name = "Sweetener",
        color = color(120, 100, 100),
        volume_db = -8.0,
        sends = {
          { bus = "Reverb_Bus", volume_db = -12.0, mode = "postfader" },
        },
        note = "Stylized detail layer.\n- Add texture, magic, sparks, or genre flavor.\n- Use sparingly so it supports the hit instead of masking it.",
      }),
    },
    buses = {
      {
        name = "Reverb_Bus",
        color = color(100, 110, 180),
        fx_chain = {
          fx("ReaVerbate", {}),
        },
      },
    },
  },
  Footstep = {
    name = "Footstep",
    description = "Footstep layering template by surface and gear detail.",
    category_prefix = "SFX_Footstep",
    folder = { name = "SFX_Footstep_[AssetName]", color = color(120, 180, 80) },
    layers = {
      layer({
        name = "Step",
        color = color(160, 220, 120),
        fx_chain = {
          fx("ReaEQ", {
            { idx = 0, val = 1.0 },
            { idx = 1, val = 0.08 },
            { idx = 2, val = 0.60 },
            { idx = 3, val = 1.0 },
          }),
        },
        note = "Main foot plant.\n- Start with the most readable surface contact.\n- This should carry the identity before extra detail is added.",
      }),
      layer({
        name = "Scuff",
        color = color(145, 205, 110),
        volume_db = -4.0,
        fx_chain = {
          fx("ReaComp", {
            { idx = 0, val = 0.45 },
            { idx = 1, val = 0.20 },
            { idx = 3, val = 0.003 },
            { idx = 4, val = 0.06 },
          }),
        },
        note = "Friction and shoe drag detail.\n- Helps sell movement direction and body weight.",
      }),
      layer({
        name = "Material",
        color = color(125, 185, 95),
        volume_db = -2.0,
        note = "Surface-specific detail such as gravel, grass, wood, snow, or mud.",
      }),
      layer({
        name = "Foley",
        color = color(105, 165, 80),
        volume_db = -6.0,
        note = "Cloth, armor, pouch, or gear movement. Optional support layer.",
      }),
    },
  },
  UI_General = {
    name = "UI_General",
    description = "General UI sound layering template.",
    category_prefix = "UI",
    folder = { name = "UI_[AssetName]", color = color(60, 160, 220) },
    layers = {
      layer({
        name = "Tone",
        color = color(110, 200, 245),
        fx_chain = {
          fx("ReaEQ", {
            { idx = 1, val = 0.60 },
            { idx = 2, val = 0.40 },
            { idx = 4, val = 0.60 },
          }),
        },
        note = "Main tonal identity.\n- Keep pitch relationships clean and intentional.\n- Useful for melodic or branded UI sounds.",
      }),
      layer({
        name = "Click",
        color = color(90, 185, 235),
        fx_chain = {
          fx("ReaComp", {
            { idx = 0, val = 0.55 },
            { idx = 1, val = 0.25 },
            { idx = 3, val = 0.001 },
            { idx = 4, val = 0.04 },
          }),
        },
        note = "Click or tap transient.\n- Keep this crisp so the interaction reads instantly.",
      }),
      layer({
        name = "Texture",
        color = color(70, 165, 210),
        volume_db = -5.0,
        note = "Additional motion, glitch, noise, or swipe texture.",
      }),
    },
  },
  Ambience = {
    name = "Ambience",
    description = "Environmental ambience layering template.",
    category_prefix = "AMB",
    folder = { name = "AMB_[AssetName]", color = color(80, 140, 80) },
    layers = {
      layer({
        name = "Base",
        color = color(110, 170, 110),
        sends = {
          { bus = "Space_Bus", volume_db = -12.0, mode = "postfader" },
        },
        fx_chain = {
          fx("ReaEQ", {
            { idx = 0, val = 1.0 },
            { idx = 1, val = 0.03 },
            { idx = 2, val = 0.60 },
            { idx = 3, val = 1.0 },
          }),
        },
        note = "Core ambience bed such as wind, water, room tone, or broad environment wash.",
      }),
      layer({
        name = "Detail",
        color = color(95, 155, 95),
        volume_db = -3.0,
        sends = {
          { bus = "Space_Bus", volume_db = -18.0, mode = "postfader" },
        },
        note = "Fine detail such as birds, insects, drips, or distant texture.",
      }),
      layer({
        name = "Accent",
        color = color(85, 145, 85),
        volume_db = -6.0,
        sends = {
          { bus = "Space_Bus", volume_db = -10.0, mode = "postfader" },
        },
        fx_chain = { fx("ReaVerbate", {}) },
        note = "Intermittent accents like leaves, drops, creaks, or gusts.",
      }),
      layer({
        name = "LFE",
        color = color(70, 125, 70),
        volume_db = -9.0,
        note = "Optional low-frequency rumble or environmental weight.",
      }),
    },
    buses = {
      { name = "Space_Bus", color = color(90, 120, 165), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
  Explosion = {
    name = "Explosion",
    description = "Explosion and large impact layering template.",
    category_prefix = "SFX_Explosion",
    folder = { name = "SFX_Explosion_[AssetName]", color = color(255, 140, 0) },
    layers = {
      layer({
        name = "Transient",
        color = color(255, 185, 90),
        sends = {
          { bus = "Impact_Bus", volume_db = -18.0, mode = "postfader" },
        },
        fx_chain = {
          fx("ReaEQ", {
            { idx = 0, val = 1.0 },
            { idx = 1, val = 0.12 },
            { idx = 2, val = 0.70 },
            { idx = 3, val = 1.0 },
          }),
          fx("ReaComp", {
            { idx = 0, val = 0.48 },
            { idx = 1, val = 0.28 },
            { idx = 3, val = 0.001 },
            { idx = 4, val = 0.05 },
          }),
        },
        note = "Initial crack and transient spike.\n- Preserve sharpness before the low-end bloom arrives.",
      }),
      layer({ name = "LowEnd", color = color(235, 150, 70), volume_db = -2.0, sends = { { bus = "Impact_Bus", volume_db = -18.0, mode = "postfader" } }, note = "Sub and low-frequency impact weight." }),
      layer({ name = "Body", color = color(215, 125, 50), volume_db = -1.0, sends = { { bus = "Impact_Bus", volume_db = -14.0, mode = "postfader" } }, note = "Midrange blast body, crunch, and density." }),
      layer({ name = "Debris", color = color(190, 110, 45), volume_db = -5.0, note = "Shrapnel, rocks, dirt, and fallout material." }),
      layer({
        name = "Tail",
        color = color(165, 95, 40),
        volume_db = -7.0,
        sends = {
          { bus = "Impact_Bus", volume_db = -8.0, mode = "postfader" },
        },
        fx_chain = { fx("ReaVerbate", {}) },
        note = "Long decay, roll-off, and reflections.",
      }),
      layer({ name = "Sweetener", color = color(140, 85, 40), volume_db = -9.0, note = "Stylized energy, chemical sizzle, or sci-fi detail." }),
    },
    buses = {
      { name = "Impact_Bus", color = color(100, 110, 175), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
  Weapon_Ranged = {
    name = "Weapon_Ranged",
    description = "Ranged weapon fire layering template.",
    category_prefix = "SFX_Weapon",
    folder = { name = "SFX_Weapon_[AssetName]", color = color(200, 80, 40) },
    layers = {
      layer({ name = "Mech", color = color(235, 135, 95), sends = { { bus = "Tail_Bus", volume_db = -18.0, mode = "postfader" } }, note = "Mechanical movement such as trigger, bolt, or reload detail." }),
      layer({ name = "Fire", color = color(255, 115, 70), sends = { { bus = "Tail_Bus", volume_db = -16.0, mode = "postfader" } }, note = "Primary firing impact. This is the core shot signature." }),
      layer({ name = "Punch", color = color(180, 90, 55), volume_db = -3.0, note = "Low-frequency punch or sub reinforcement." }),
      layer({ name = "Tail", color = color(150, 90, 70), volume_db = -6.0, sends = { { bus = "Tail_Bus", volume_db = -8.0, mode = "postfader" } }, note = "Reflection and environment tail." }),
      layer({ name = "Sweetener", color = color(135, 95, 85), volume_db = -8.0, sends = { { bus = "Tail_Bus", volume_db = -12.0, mode = "postfader" } }, note = "Stylized extra layer such as electricity, magic, or plasma." }),
      layer({ name = "Shell", color = color(120, 95, 75), volume_db = -10.0, note = "Shell, debris, or byproduct element. Optional." }),
    },
    buses = {
      { name = "Tail_Bus", color = color(95, 105, 175), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
  Weapon_Magic = {
    name = "Weapon_Magic",
    description = "Magic or ability attack layering template.",
    category_prefix = "SFX_Weapon",
    folder = { name = "SFX_Weapon_[AssetName]", color = color(120, 60, 200) },
    layers = {
      layer({ name = "Charge", color = color(165, 110, 240), sends = { { bus = "MagicSpace_Bus", volume_db = -16.0, mode = "postfader" } }, note = "Charge-up or anticipation layer." }),
      layer({ name = "Cast", color = color(145, 95, 230), sends = { { bus = "MagicSpace_Bus", volume_db = -14.0, mode = "postfader" } }, note = "Casting impact or release moment." }),
      layer({ name = "Element", color = color(125, 80, 220), sends = { { bus = "MagicSpace_Bus", volume_db = -12.0, mode = "postfader" } }, note = "Element identity such as fire, ice, lightning, poison, or arcane." }),
      layer({ name = "Whoosh", color = color(110, 75, 205), volume_db = -3.0, note = "Projectile travel or motion pass-by." }),
      layer({ name = "Impact", color = color(95, 70, 190), sends = { { bus = "MagicSpace_Bus", volume_db = -14.0, mode = "postfader" } }, note = "Target hit or arrival impact." }),
      layer({ name = "Tail", color = color(85, 65, 175), volume_db = -6.0, sends = { { bus = "MagicSpace_Bus", volume_db = -8.0, mode = "postfader" } }, note = "Decay, shimmer, or dissipation layer." }),
    },
    buses = {
      { name = "MagicSpace_Bus", color = color(110, 95, 185), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
  Creature = {
    name = "Creature",
    description = "Creature and monster voice layering template.",
    category_prefix = "SFX_Creature",
    folder = { name = "SFX_Creature_[AssetName]", color = color(160, 60, 160) },
    layers = {
      layer({ name = "Vocal", color = color(210, 110, 210), sends = { { bus = "CreatureSpace_Bus", volume_db = -14.0, mode = "postfader" } }, note = "Primary voice layer such as growl, scream, or bark." }),
      layer({ name = "Breath", color = color(190, 95, 190), volume_db = -4.0, sends = { { bus = "CreatureSpace_Bus", volume_db = -18.0, mode = "postfader" } }, note = "Breath, air, or pressure detail." }),
      layer({ name = "Texture", color = color(175, 85, 175), volume_db = -5.0, sends = { { bus = "CreatureSpace_Bus", volume_db = -16.0, mode = "postfader" } }, note = "Organic texture such as slime, scales, or wetness." }),
      layer({ name = "Movement", color = color(160, 75, 160), volume_db = -6.0, note = "Body movement such as wings, claws, or cloth." }),
      layer({ name = "Processed", color = color(145, 70, 145), volume_db = -6.0, note = "Pitch-shifted or heavily processed support layer." }),
    },
    buses = {
      { name = "CreatureSpace_Bus", color = color(105, 100, 180), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
  Vehicle = {
    name = "Vehicle",
    description = "Vehicle and ride layering template.",
    category_prefix = "SFX_Vehicle",
    folder = { name = "SFX_Vehicle_[AssetName]", color = color(100, 100, 100) },
    layers = {
      layer({ name = "Engine", color = color(150, 150, 150), note = "Core engine loop or power source layer." }),
      layer({ name = "Exhaust", color = color(135, 135, 135), volume_db = -3.0, note = "Exhaust or rear emission layer." }),
      layer({ name = "Mechanical", color = color(125, 125, 125), volume_db = -4.0, note = "Gear, chain, belt, and machine detail." }),
      layer({ name = "Wind", color = color(115, 115, 115), volume_db = -6.0, note = "Air movement and speed layer." }),
      layer({ name = "Surface", color = color(105, 105, 105), volume_db = -5.0, note = "Tire, tread, or contact with ground." }),
      layer({ name = "Interior", color = color(95, 95, 95), volume_db = -8.0, note = "Cabin or interior resonance. Optional." }),
    },
  },
  Music_Stinger = {
    name = "Music_Stinger",
    description = "Short music stinger or jingle layering template.",
    category_prefix = "MUS_Jingle",
    folder = { name = "MUS_[AssetName]", color = color(220, 180, 60) },
    layers = {
      layer({ name = "Melody", color = color(245, 210, 110), note = "Main melodic hook." }),
      layer({ name = "Harmony", color = color(235, 195, 95), volume_db = -3.0, note = "Harmony or chord support." }),
      layer({ name = "Rhythm", color = color(220, 180, 75), volume_db = -2.0, note = "Percussive or rhythmic layer." }),
      layer({ name = "Bass", color = color(200, 160, 65), volume_db = -4.0, note = "Low-end support and grounding." }),
      layer({ name = "FX", color = color(180, 145, 60), volume_db = -5.0, sends = { { bus = "MusicFX_Bus", volume_db = -10.0, mode = "postfader" } }, note = "Impacts, risers, reverses, and transition detail." }),
    },
    buses = {
      { name = "MusicFX_Bus", color = color(95, 110, 175), fx_chain = { fx("ReaVerbate", {}) } },
    },
  },
}
local TEMPLATE_ORDER = {
  "Weapon_Melee",
  "Weapon_Ranged",
  "Weapon_Magic",
  "Footstep",
  "UI_General",
  "Ambience",
  "Explosion",
  "Creature",
  "Vehicle",
  "Music_Stinger",
}
local TEMPLATE_ALIASES = {
  footstep = "Footstep",
  ui = "UI_General",
  ambience = "Ambience",
  ambient = "Ambience",
  amb = "Ambience",
  explosion = "Explosion",
  melee = "Weapon_Melee",
  ranged = "Weapon_Ranged",
  magic = "Weapon_Magic",
  creature = "Creature",
  vehicle = "Vehicle",
  stinger = "Music_Stinger",
  jingle = "Music_Stinger",
}

local function set_track_name(track, name)
  if track then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(name or ""), true)
  end
end

local function apply_track_color(track, track_color)
  if not track or not track_color then
    return
  end

  local native = reaper.ColorToNative(track_color.r or 0, track_color.g or 0, track_color.b or 0)
  reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", native + REAPER_COLOR_FLAG)
end

local function set_track_volume(track, volume_db)
  if track and volume_db ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", db_to_linear(volume_db))
  end
end

local function set_track_pan(track, pan)
  if track and pan ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", tonumber(pan) or 0.0)
  end
end

local function set_track_note(track, note_text)
  local note = trim_string(note_text)
  if not track or note == "" then
    return false
  end

  reaper.GetSetMediaTrackInfo_String(track, "P_EXT:GameSoundLayerNote", note, true)
  if reaper.APIExists and reaper.APIExists("NF_SetSWSTrackNotes") then
    reaper.NF_SetSWSTrackNotes(track, note)
    return true
  end
  return false
end

local function build_template_lookup(templates, order, aliases)
  local template_map = templates or BUILTIN_TEMPLATES
  local template_order = order or TEMPLATE_ORDER
  local lookup = copy_table(aliases or TEMPLATE_ALIASES)

  for _, key in ipairs(template_order) do
    local template = template_map[key]
    if template then
      lookup[normalize_token(key)] = key
      lookup[normalize_token(template.name)] = key
    end
  end

  return lookup
end

local function build_template_preview(template)
  local layer_names = {}
  for index, item in ipairs(template.layers or {}) do
    layer_names[index] = item.name
  end
  return table.concat(layer_names, " / ")
end

local function build_template_catalog(templates, order)
  local template_map = templates or BUILTIN_TEMPLATES
  local template_order = order or TEMPLATE_ORDER
  local lines = { "Available template keys:", "" }
  for _, key in ipairs(template_order) do
    local template = template_map[key]
    if type(key) == "string" and key:match("^custom::") then
      lines[#lines + 1] = key .. "  (" .. tostring(template.name or "Custom") .. ")"
    else
      lines[#lines + 1] = key
    end
    lines[#lines + 1] = "  " .. template.description
    lines[#lines + 1] = "  Layers: " .. build_template_preview(template)
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Tip: input is case-insensitive. Example: weapon_melee"
  return table.concat(lines, "\n")
end

local function resolve_template_key(value, template_lookup)
  local trimmed = trim_string(value)
  if trimmed == "" then
    return nil
  end
  if BUILTIN_TEMPLATES[trimmed] then
    return trimmed
  end
  return template_lookup[normalize_token(trimmed)]
end

local function parse_insert_mode(value)
  local lowered = trim_string(value):lower()
  if lowered == "" or lowered == "end" or lowered == "e" then
    return "end"
  end
  if lowered == "cursor" or lowered == "c" or lowered == "selected" or lowered == "selection" or lowered == "track" then
    return "cursor"
  end
  return nil
end

local function get_ext_state(key, default_value)
  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == nil or value == "" then
    return default_value
  end
  return value
end

local function load_settings()
  return {
    template_key = get_ext_state("template_key", DEFAULTS.template_key),
    asset_names = get_ext_state("asset_names", DEFAULTS.asset_names),
    insert_mode = parse_insert_mode(get_ext_state("insert_mode", DEFAULTS.insert_mode)) or DEFAULTS.insert_mode,
    include_fx = parse_boolean(get_ext_state("include_fx", bool_to_string(DEFAULTS.include_fx)), DEFAULTS.include_fx),
    apply_colors = parse_boolean(get_ext_state("apply_colors", bool_to_string(DEFAULTS.apply_colors)), DEFAULTS.apply_colors),
    write_notes = parse_boolean(get_ext_state("write_notes", bool_to_string(DEFAULTS.write_notes)), DEFAULTS.write_notes),
    include_buses = parse_boolean(get_ext_state("include_buses", bool_to_string(DEFAULTS.include_buses)), DEFAULTS.include_buses),
    create_markers = parse_boolean(get_ext_state("create_markers", bool_to_string(DEFAULTS.create_markers)), DEFAULTS.create_markers),
  }
end

local function save_settings(settings)
  reaper.SetExtState(EXT_SECTION, "template_key", tostring(settings.template_key or DEFAULTS.template_key), true)
  reaper.SetExtState(EXT_SECTION, "asset_names", tostring(settings.asset_names or DEFAULTS.asset_names), true)
  reaper.SetExtState(EXT_SECTION, "insert_mode", tostring(settings.insert_mode or DEFAULTS.insert_mode), true)
  reaper.SetExtState(EXT_SECTION, "include_fx", bool_to_string(settings.include_fx), true)
  reaper.SetExtState(EXT_SECTION, "apply_colors", bool_to_string(settings.apply_colors), true)
  reaper.SetExtState(EXT_SECTION, "write_notes", bool_to_string(settings.write_notes), true)
  reaper.SetExtState(EXT_SECTION, "include_buses", bool_to_string(settings.include_buses), true)
  reaper.SetExtState(EXT_SECTION, "create_markers", bool_to_string(settings.create_markers), true)
end

local function is_array_table(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  return count == max_index
end

local function serialize_value(value)
  local value_type = type(value)
  if value_type == "table" then
    local parts = {}
    if is_array_table(value) then
      for index = 1, #value do
        parts[#parts + 1] = serialize_value(value[index])
      end
    else
      for key, item in pairs(value) do
        parts[#parts + 1] = "[" .. serialize_value(key) .. "]=" .. serialize_value(item)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end
  return "nil"
end

local function deserialize_value(serialized)
  local text = tostring(serialized or "")
  local prefix = text:match("^%s*return%s") and "" or "return "
  local chunk, err = load(prefix .. text, SCRIPT_TITLE .. "_Deserialize", "t", {})
  if not chunk then
    return nil, err
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end
  return result
end

local function sort_case_insensitive(values, accessor)
  table.sort(values, function(left, right)
    local lhs = accessor and accessor(left) or left
    local rhs = accessor and accessor(right) or right
    lhs = tostring(lhs or ""):lower()
    rhs = tostring(rhs or ""):lower()
    if lhs == rhs then
      return tostring(accessor and accessor(left) or left) < tostring(accessor and accessor(right) or right)
    end
    return lhs < rhs
  end)
end

local function make_custom_storage_id(name)
  local base = normalize_token(name)
  if base == "" then
    base = "customtemplate"
  end
  return base
end

local function load_custom_index()
  local raw = reaper.GetExtState(EXT_SECTION, "custom_index")
  if raw == nil or raw == "" then
    return {}
  end

  local value = deserialize_value(raw)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function save_custom_index(index)
  reaper.SetExtState(EXT_SECTION, "custom_index", serialize_value(index or {}), true)
end

local function save_custom_template(template, preferred_id)
  local index = load_custom_index()
  local base_id = preferred_id or make_custom_storage_id(template.name)
  local final_id = base_id
  local suffix = 2

  while index[final_id] and final_id ~= preferred_id do
    final_id = base_id .. "_" .. tostring(suffix)
    suffix = suffix + 1
  end

  local stored = copy_table(template)
  stored.is_custom = true
  stored.custom_id = final_id

  reaper.SetExtState(EXT_SECTION, "custom_data_" .. final_id, serialize_value(stored), true)
  index[final_id] = { name = stored.name }
  save_custom_index(index)
  return final_id
end

local function load_custom_templates()
  local index = load_custom_index()
  local templates = {}

  for custom_id in pairs(index) do
    local raw = reaper.GetExtState(EXT_SECTION, "custom_data_" .. custom_id)
    if raw ~= nil and raw ~= "" then
      local template = deserialize_value(raw)
      if type(template) == "table" then
        template.is_custom = true
        template.custom_id = custom_id
        templates[custom_id] = template
      end
    end
  end

  return templates
end

local function delete_custom_template(custom_id)
  local index = load_custom_index()
  index[custom_id] = nil
  save_custom_index(index)
  reaper.DeleteExtState(EXT_SECTION, "custom_data_" .. tostring(custom_id or ""), true)
end

local function build_runtime_templates()
  local templates = {}
  local order = {}
  local custom_templates = load_custom_templates()
  local custom_ids = {}

  for _, key in ipairs(TEMPLATE_ORDER) do
    templates[key] = BUILTIN_TEMPLATES[key]
    order[#order + 1] = key
  end

  for custom_id in pairs(custom_templates) do
    custom_ids[#custom_ids + 1] = custom_id
  end
  sort_case_insensitive(custom_ids, function(custom_id)
    return custom_templates[custom_id] and custom_templates[custom_id].name or custom_id
  end)

  for _, custom_id in ipairs(custom_ids) do
    local runtime_key = "custom::" .. custom_id
    templates[runtime_key] = custom_templates[custom_id]
    order[#order + 1] = runtime_key
  end

  return templates, order, custom_templates
end

local function parse_asset_names(raw_value)
  local names = {}
  local seen = {}
  for token in tostring(raw_value or ""):gmatch("[^,\r\n;]+") do
    local sanitized = sanitize_asset_name(token)
    if sanitized ~= "" and not seen[sanitized] then
      seen[sanitized] = true
      names[#names + 1] = sanitized
    end
  end
  return names
end

local function get_track_name(track)
  local _, name = reaper.GetTrackName(track, "")
  return trim_string(name)
end

local function get_track_color_definition(track)
  local native = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR") or 0)
  local base_color = native % REAPER_COLOR_FLAG
  if base_color == 0 then
    return nil
  end

  local r, g, b = reaper.ColorFromNative(base_color)
  return { r = r, g = g, b = b }
end

local function capture_fx_chain(track)
  local chain = {}
  local fx_count = reaper.TrackFX_GetCount(track)

  for fx_index = 0, fx_count - 1 do
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    local params = {}
    local param_count = reaper.TrackFX_GetNumParams(track, fx_index)

    for param_index = 0, param_count - 1 do
      params[#params + 1] = {
        idx = param_index,
        val = round_to(reaper.TrackFX_GetParamNormalized(track, fx_index, param_index), 6),
      }
    end

    chain[#chain + 1] = {
      plugin = trim_string(fx_name),
      params = params,
      enabled = reaper.TrackFX_GetEnabled(track, fx_index),
    }
  end

  return chain
end

local function capture_layer_sends(track, bus_lookup)
  local sends = {}
  local send_count = reaper.GetTrackNumSends(track, 0)

  for send_index = 0, send_count - 1 do
    local dest_track = reaper.GetTrackSendInfo_Value(track, 0, send_index, "P_DESTTRACK")
    for bus_name, bus_track in pairs(bus_lookup) do
      if dest_track == bus_track then
        sends[#sends + 1] = {
          bus = bus_name,
          volume_db = round_to(linear_to_db(reaper.GetTrackSendInfo_Value(track, 0, send_index, "D_VOL") or 1.0), 3),
          pan = round_to(reaper.GetTrackSendInfo_Value(track, 0, send_index, "D_PAN") or 0.0, 3),
          mode = ({ [0] = "postfader", [1] = "prefx", [3] = "postfx" })[math.floor(reaper.GetTrackSendInfo_Value(track, 0, send_index, "I_SENDMODE") or 0)] or "postfader",
          mute = reaper.GetTrackSendInfo_Value(track, 0, send_index, "B_MUTE") > 0.5,
        }
      end
    end
  end

  return sends
end

local function capture_template_from_selection()
  local selected_count = reaper.CountSelectedTracks(0)
  if selected_count < 2 then
    return nil, "Select a folder track and at least one layer track to capture."
  end

  local folder_track = reaper.GetSelectedTrack(0, 0)
  local default_name = sanitize_asset_name(get_track_name(folder_track))
  if default_name == "" then
    default_name = "My_Template"
  end

  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Capture Custom Template",
    4,
    "Template Name,Description,Category Prefix,Folder Pattern (use [AssetName])",
    table.concat({
      default_name,
      "Custom template captured from selected tracks",
      "Custom",
      "Custom_[AssetName]",
    }, ",")
  )

  if not ok then
    return nil, "User cancelled."
  end

  local parts = split_delimited(csv, ",", 4)
  local template_name = trim_string(parts[1])
  local description = trim_string(parts[2])
  local category_prefix = trim_string(parts[3])
  local folder_pattern = trim_string(parts[4])

  if template_name == "" then
    return nil, "Template name is required."
  end
  if folder_pattern == "" or not folder_pattern:find("%[AssetName%]") then
    return nil, "Folder pattern must contain [AssetName]."
  end
  if category_prefix == "" then
    category_prefix = "Custom"
  end
  if description == "" then
    description = "Custom template captured from selected tracks"
  end

  local template = {
    name = template_name,
    description = description,
    category_prefix = category_prefix,
    folder = {
      name = folder_pattern,
      color = get_track_color_definition(folder_track) or color(120, 120, 120),
    },
    layers = {},
    is_custom = true,
  }

  local selected_tracks = {}
  for index = 0, selected_count - 1 do
    selected_tracks[#selected_tracks + 1] = reaper.GetSelectedTrack(0, index)
  end

  local layer_tracks = {}
  local bus_tracks = {}
  local open_depth = 1
  for index = 2, #selected_tracks do
    local track = selected_tracks[index]
    if open_depth > 0 then
      layer_tracks[#layer_tracks + 1] = track
      local folder_delta = math.floor((reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") or 0) + 0.5)
      open_depth = open_depth + folder_delta
    else
      bus_tracks[#bus_tracks + 1] = track
    end
  end

  local bus_lookup = {}
  if #bus_tracks > 0 then
    template.buses = {}
    for _, bus_track in ipairs(bus_tracks) do
      local bus_name = get_track_name(bus_track)
      bus_lookup[bus_name] = bus_track
      template.buses[#template.buses + 1] = {
        name = bus_name,
        color = get_track_color_definition(bus_track),
        fx_chain = capture_fx_chain(bus_track),
      }
    end
  end

  for _, track in ipairs(layer_tracks) do
    local _, existing_note = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:GameSoundLayerNote", "", false)
    template.layers[#template.layers + 1] = layer({
      name = get_track_name(track),
      color = get_track_color_definition(track),
      volume_db = round_to(linear_to_db(reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0), 3),
      pan = round_to(reaper.GetMediaTrackInfo_Value(track, "D_PAN") or 0.0, 3),
      fx_chain = capture_fx_chain(track),
      sends = capture_layer_sends(track, bus_lookup),
      note = trim_string(existing_note),
    })
  end

  if #template.layers == 0 then
    return nil, "No child layers were captured."
  end

  return template
end

local function parse_csv_asset_text(text)
  local names = {}
  local seen = {}

  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local first_cell = trim_string((line:match("^%s*([^,\t;]+)") or ""))
    local lowered = normalize_token(first_cell)
    if first_cell ~= "" and lowered ~= "assetname" and lowered ~= "asset" and lowered ~= "name" and lowered ~= "id" then
      local sanitized = sanitize_asset_name(first_cell)
      if sanitized ~= "" and not seen[sanitized] then
        seen[sanitized] = true
        names[#names + 1] = sanitized
      end
    end
  end

  return names
end

local function read_text_file(path)
  local handle, err = io.open(path, "rb")
  if not handle then
    return nil, err
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_text_file(path, content)
  local handle, err = io.open(path, "wb")
  if not handle then
    return false, err
  end
  handle:write(content or "")
  handle:close()
  return true
end

local function export_templates_to_file(path, templates)
  local payload = {
    version = 1,
    templates = templates,
  }
  return write_text_file(path, "return " .. serialize_value(payload))
end

local function import_templates_from_file(path)
  local content, err = read_text_file(path)
  if not content then
    return nil, err
  end

  content = content:gsub("^\239\187\191", "")
  local payload, load_err = deserialize_value(content)
  if type(payload) ~= "table" then
    return nil, load_err or "Invalid template file."
  end

  local templates = payload.templates or payload
  if type(templates) ~= "table" then
    return nil, "Template file does not contain a template list."
  end
  if templates.name then
    templates = { templates }
  end

  local imported_ids = {}
  for _, template in ipairs(templates) do
    if type(template) == "table" and trim_string(template.name) ~= "" then
      imported_ids[#imported_ids + 1] = save_custom_template(template)
    end
  end

  if #imported_ids == 0 then
    return nil, "No valid templates were found in the file."
  end

  return imported_ids
end

local function resolve_send_mode(mode_name)
  local lowered = trim_string(mode_name):lower()
  if lowered == "prefx" or lowered == "pre" then
    return 1
  end
  if lowered == "postfx" then
    return 3
  end
  return 0
end

local function build_bus_track_name(bus_definition, asset_name)
  local template_name = trim_string(bus_definition.name or "Bus")
  if template_name:find("%[AssetName%]") then
    return template_name:gsub("%[AssetName%]", asset_name)
  end
  return template_name .. "_" .. asset_name
end

local function apply_track_send(source_track, send_definition, bus_track, stats)
  local send_index = reaper.CreateTrackSend(source_track, bus_track)
  if send_index < 0 then
    return false
  end

  if send_definition.volume_db ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_VOL", db_to_linear(send_definition.volume_db))
  end
  if send_definition.pan ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_PAN", tonumber(send_definition.pan) or 0.0)
  end
  if send_definition.mute ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "B_MUTE", send_definition.mute and 1 or 0)
  end

  reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "I_SENDMODE", resolve_send_mode(send_definition.mode))
  stats.created_sends = stats.created_sends + 1
  return true
end

local function create_guide_markers(asset_name, start_position, stats)
  local markers = {
    { offset = 0.0, name = asset_name .. " - Start: layer your sounds here" },
    { offset = 5.0, name = asset_name .. " - Check: solo each layer" },
    { offset = 10.0, name = asset_name .. " - Mix: balance and print" },
  }

  for _, marker in ipairs(markers) do
    reaper.AddProjectMarker2(0, false, start_position + marker.offset, 0.0, marker.name, -1, 0)
    stats.created_markers = stats.created_markers + 1
  end
end

local function prompt_for_settings(current, template_lookup, templates, order)
  local defaults = {
    current.template_key or DEFAULTS.template_key,
    current.asset_names or DEFAULTS.asset_names,
    current.insert_mode or DEFAULTS.insert_mode,
    bool_to_string(current.include_buses),
    bool_to_string(current.create_markers),
  }

  while true do
    local ok, csv = reaper.GetUserInputs(
      SCRIPT_TITLE,
      5,
      table.concat({
        "extrawidth=420",
        "separator=|",
        "Template Key (? = list)",
        "Asset Name(s) (comma separated)",
        "Insert Position (end/cursor=selected track)",
        "Include Bus Tracks (y/n)",
        "Create Guide Markers (y/n)",
      }, ","),
      table.concat(defaults, "|")
    )

    if not ok then
      return nil, "User cancelled."
    end

    local parts = split_delimited(csv, "|", 5)
    defaults = parts

    local template_input = trim_string(parts[1])
    if template_input == "?" or template_input:lower() == "list" then
      reaper.ShowMessageBox(build_template_catalog(templates, order), SCRIPT_TITLE, 0)
    else
      local resolved_template_key = resolve_template_key(template_input, template_lookup)
      if not resolved_template_key then
        reaper.ShowMessageBox("Unknown template key.\n\n" .. build_template_catalog(templates, order), SCRIPT_TITLE, 0)
      else
        local asset_names = parse_asset_names(parts[2])
        if #asset_names == 0 then
          reaper.ShowMessageBox(
            "Please enter at least one valid asset name.\n\nInvalid file-name characters will be removed automatically.",
            SCRIPT_TITLE,
            0
          )
        else
          local insert_mode = parse_insert_mode(parts[3])
          if not insert_mode then
            reaper.ShowMessageBox(
              "Insert position must be 'end' or 'cursor'.\n\n'cursor' inserts after the last selected track.",
              SCRIPT_TITLE,
              0
            )
          else
            local include_buses = parse_boolean(parts[4], nil)
            local create_markers = parse_boolean(parts[5], nil)
            if include_buses == nil or create_markers == nil then
              reaper.ShowMessageBox(
                "Bus and marker options must be y/n values.",
                SCRIPT_TITLE,
                0
              )
            else
              return {
                template_key = resolved_template_key,
                template = templates[resolved_template_key],
                asset_names = asset_names,
                asset_names_raw = parts[2],
                insert_mode = insert_mode,
                include_fx = current.include_fx,
                apply_colors = current.apply_colors,
                write_notes = current.write_notes,
                include_buses = include_buses,
                create_markers = create_markers,
              }
            end
          end
        end
      end
    end
  end
end

local function resolve_insert_index(insert_mode)
  local track_count = reaper.CountTracks(0)
  if insert_mode ~= "cursor" then
    return track_count, false
  end

  local selected_count = reaper.CountSelectedTracks(0)
  if selected_count == 0 then
    return track_count, true
  end

  local last_track_number = 0
  for index = 0, selected_count - 1 do
    local track = reaper.GetSelectedTrack(0, index)
    local track_number = math.floor((reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0) + 0.5)
    if track_number > last_track_number then
      last_track_number = track_number
    end
  end

  return last_track_number, false
end

local function insert_fx(track, fx_definition, stats)
  local fx_index = reaper.TrackFX_AddByName(track, fx_definition.plugin, false, -1)
  if fx_index < 0 then
    stats.fx_warnings = stats.fx_warnings + 1
    stats.fx_missing[#stats.fx_missing + 1] = fx_definition.plugin
    log_line(string.format("[Layer Template] Warning: FX '%s' was not found and was skipped.", fx_definition.plugin))
    return false
  end

  for _, param in ipairs(fx_definition.params or {}) do
    reaper.TrackFX_SetParamNormalized(track, fx_index, param.idx, param.val)
  end

  if fx_definition.enabled == false then
    reaper.TrackFX_SetEnabled(track, fx_index, false)
  end
  return true
end

local function apply_layer_settings(track, layer_definition, options, stats)
  set_track_name(track, layer_definition.name)
  if options.apply_colors then
    apply_track_color(track, layer_definition.color)
  end
  set_track_volume(track, layer_definition.volume_db)
  set_track_pan(track, layer_definition.pan)

  if options.include_fx then
    for _, fx_definition in ipairs(layer_definition.fx_chain or {}) do
      insert_fx(track, fx_definition, stats)
    end
  end

  if options.write_notes and layer_definition.note then
    local note_visible = set_track_note(track, layer_definition.note)
    stats.note_count = stats.note_count + 1
    if note_visible then
      stats.sws_notes_written = stats.sws_notes_written + 1
    end
  end
end

local function create_single_template(template, asset_name, insert_index, options, stats)
  local folder_track_name = template.folder.name:gsub("%[AssetName%]", asset_name)
  local created_layer_tracks = {}
  local created_bus_tracks = {}
  reaper.InsertTrackAtIndex(insert_index, true)
  local folder_track = reaper.GetTrack(0, insert_index)
  set_track_name(folder_track, folder_track_name)
  reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)

  if options.apply_colors then
    apply_track_color(folder_track, template.folder.color)
  end

  if options.write_notes then
    local folder_note = table.concat({
      "Template: " .. template.name,
      "Description: " .. template.description,
      "Asset: " .. asset_name,
      "Layers: " .. build_template_preview(template),
    }, "\n")
    local note_visible = set_track_note(folder_track, folder_note)
    stats.note_count = stats.note_count + 1
    if note_visible then
      stats.sws_notes_written = stats.sws_notes_written + 1
    end
  end

  stats.created_templates = stats.created_templates + 1
  stats.created_tracks = stats.created_tracks + 1
  stats.created_assets[#stats.created_assets + 1] = folder_track_name

  for layer_index, layer_definition in ipairs(template.layers or {}) do
    local track_index = insert_index + layer_index
    reaper.InsertTrackAtIndex(track_index, true)
    local layer_track = reaper.GetTrack(0, track_index)
    apply_layer_settings(layer_track, layer_definition, options, stats)
    created_layer_tracks[layer_index] = {
      track = layer_track,
      definition = layer_definition,
    }

    if layer_index == #template.layers then
      reaper.SetMediaTrackInfo_Value(layer_track, "I_FOLDERDEPTH", -1)
    else
      reaper.SetMediaTrackInfo_Value(layer_track, "I_FOLDERDEPTH", 0)
    end
    stats.created_tracks = stats.created_tracks + 1
  end

  local next_insert_index = insert_index + #template.layers + 1

  if options.include_buses and template.buses then
    for bus_index, bus_definition in ipairs(template.buses) do
      local track_index = insert_index + #template.layers + bus_index
      reaper.InsertTrackAtIndex(track_index, true)
      local bus_track = reaper.GetTrack(0, track_index)
      set_track_name(bus_track, build_bus_track_name(bus_definition, asset_name))

      if options.apply_colors then
        apply_track_color(bus_track, bus_definition.color)
      end
      if options.include_fx then
        for _, fx_definition in ipairs(bus_definition.fx_chain or {}) do
          insert_fx(bus_track, fx_definition, stats)
        end
      end
      if options.write_notes and bus_definition.note then
        local note_visible = set_track_note(bus_track, bus_definition.note)
        stats.note_count = stats.note_count + 1
        if note_visible then
          stats.sws_notes_written = stats.sws_notes_written + 1
        end
      end

      created_bus_tracks[bus_definition.name] = bus_track
      stats.created_tracks = stats.created_tracks + 1
      stats.created_buses = stats.created_buses + 1
    end

    for _, layer_data in ipairs(created_layer_tracks) do
      for _, send_definition in ipairs(layer_data.definition.sends or {}) do
        local bus_track = created_bus_tracks[send_definition.bus]
        if bus_track then
          apply_track_send(layer_data.track, send_definition, bus_track, stats)
        end
      end
    end

    next_insert_index = insert_index + #template.layers + #template.buses + 1
  end

  return next_insert_index
end

local function create_templates(settings)
  local stats = {
    created_templates = 0,
    created_tracks = 0,
    created_buses = 0,
    created_sends = 0,
    created_markers = 0,
    created_assets = {},
    fx_warnings = 0,
    fx_missing = {},
    note_count = 0,
    sws_notes_written = 0,
    cursor_fallback_to_end = false,
  }

  local insert_index, cursor_fallback = resolve_insert_index(settings.insert_mode)
  stats.cursor_fallback_to_end = cursor_fallback
  local marker_start = reaper.GetCursorPosition()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, err = pcall(function()
    for asset_index, asset_name in ipairs(settings.asset_names) do
      insert_index = create_single_template(settings.template, asset_name, insert_index, settings, stats)
      if settings.create_markers then
        create_guide_markers(asset_name, marker_start + ((asset_index - 1) * 15.0), stats)
      end
    end
  end)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if ok then
    reaper.Undo_EndBlock("Create Game Sound Layering Template: " .. settings.template.name, -1)
    return true, stats
  end

  reaper.Undo_EndBlock("Create Game Sound Layering Template (failed)", -1)
  return false, err
end

local function print_summary(settings, stats)
  log_line("")
  log_line("===========================================")
  log_line(SCRIPT_TITLE)
  log_line("===========================================")
  log_line(string.format("Template:       %s", settings.template.name))
  log_line(string.format("Assets:         %s", table.concat(settings.asset_names, ", ")))
  log_line(string.format("Insert Mode:    %s", settings.insert_mode))
  log_line(string.format("Created Sets:   %d", stats.created_templates))
  log_line(string.format("Created Tracks: %d", stats.created_tracks))
  log_line(string.format("Created Buses:  %d", stats.created_buses))
  log_line(string.format("Created Sends:  %d", stats.created_sends))
  log_line(string.format("Guide Markers:  %d", stats.created_markers))
  log_line(string.format("Notes Stored:   %d", stats.note_count))

  if stats.cursor_fallback_to_end then
    log_line("Insert Note:    No selected track was found, so tracks were appended at project end.")
  end
  if stats.note_count > 0 and stats.sws_notes_written < stats.note_count then
    log_line("Track Notes:    SWS track notes API not available; notes were stored in P_EXT only.")
  end

  if stats.fx_warnings > 0 then
    local unique_missing = {}
    local seen = {}
    for _, fx_name in ipairs(stats.fx_missing) do
      if not seen[fx_name] then
        seen[fx_name] = true
        unique_missing[#unique_missing + 1] = fx_name
      end
    end
    log_line(string.format("FX Warnings:    %d missing plugin insertions", stats.fx_warnings))
    log_line("Missing FX:     " .. table.concat(unique_missing, ", "))
  else
    log_line("FX Warnings:    none")
  end

  log_line("Created Folders:")
  for _, folder_name in ipairs(stats.created_assets) do
    log_line("  - " .. folder_name)
  end
  log_line("===========================================")
end

local function is_custom_runtime_key(template_key)
  return type(template_key) == "string" and template_key:match("^custom::") ~= nil
end

local function get_custom_id_from_runtime_key(template_key)
  return is_custom_runtime_key(template_key) and template_key:sub(9) or nil
end

local function save_ui_settings(ui)
  save_settings({
    template_key = ui.selected_template_key,
    asset_names = ui.asset_names_text,
    insert_mode = ui.insert_mode,
    include_fx = ui.include_fx,
    apply_colors = ui.apply_colors,
    write_notes = ui.write_notes,
    include_buses = ui.include_buses,
    create_markers = ui.create_markers,
  })
end

local function refresh_gui_templates(ui, preferred_key)
  local templates, order, custom_templates = build_runtime_templates()
  ui.templates = templates
  ui.template_order = order
  ui.custom_templates = custom_templates
  ui.template_lookup = build_template_lookup(templates, order, TEMPLATE_ALIASES)

  if preferred_key and templates[preferred_key] then
    ui.selected_template_key = preferred_key
  elseif ui.selected_template_key and templates[ui.selected_template_key] then
    ui.selected_template_key = ui.selected_template_key
  else
    ui.selected_template_key = order[1]
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

local function shorten_text(value, max_length)
  local text = tostring(value or "")
  if #text <= max_length then
    return text
  end
  if max_length <= 3 then
    return text:sub(1, max_length)
  end
  return text:sub(1, max_length - 3) .. "..."
end

local function draw_button(ui, id, label, rect_x, rect_y, rect_w, rect_h, enabled)
  local is_enabled = enabled ~= false
  local hovered = is_enabled and point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)

  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end

  local clicked = is_enabled and hovered and ui.mouse_released and ui.active_mouse_id == id
  local fill = is_enabled and (hovered and 66 or 52) or 34
  local border = is_enabled and (hovered and 115 or 86) or 55

  draw_rect(rect_x, rect_y, rect_w, rect_h, true, fill, fill, fill, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, border, border, border, 255)
  draw_text(label, rect_x + 10, rect_y + 8, is_enabled and 240 or 120, is_enabled and 240 or 120, is_enabled and 240 or 120, 255, 1, "Segoe UI", 15)

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
  draw_text(label, rect_x + box_size + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 15)

  return changed and not value or value
end

local function draw_radio(ui, id, label, rect_x, rect_y, value, target_value)
  local radius = 18
  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, radius + 8 + 220, radius)
  if hovered and ui.mouse_pressed then
    ui.active_mouse_id = id
    ui.focus_field = nil
  end
  local changed = hovered and ui.mouse_released and ui.active_mouse_id == id

  draw_rect(rect_x, rect_y, radius, radius, true, 35, 35, 35, 255)
  draw_rect(rect_x, rect_y, radius, radius, false, 100, 100, 100, 255)
  if value == target_value then
    draw_rect(rect_x + 5, rect_y + 5, radius - 10, radius - 10, true, 100, 175, 220, 255)
  end
  draw_text(label, rect_x + radius + 8, rect_y - 1, 225, 225, 225, 255, 1, "Segoe UI", 15)

  if changed then
    return target_value
  end
  return value
end

local function draw_text_input(ui, id, label, rect_x, rect_y, rect_w, rect_h, value)
  draw_text(label, rect_x, rect_y - 22, 215, 215, 215, 255, 1, "Segoe UI", 14)

  local hovered = point_in_rect(ui.mouse_x, ui.mouse_y, rect_x, rect_y, rect_w, rect_h)
  if hovered and ui.mouse_pressed then
    ui.focus_field = id
    ui.active_mouse_id = nil
  elseif ui.mouse_pressed and not hovered and ui.focus_field == id then
    ui.focus_field = nil
  end

  local is_focused = ui.focus_field == id
  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 26, 26, 26, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, is_focused and 110 or 78, is_focused and 145 or 78, is_focused and 210 or 78, 255)

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

  local draw_value = shorten_text(text_value, math.max(8, math.floor(rect_w / 8)))
  draw_text(draw_value, rect_x + 8, rect_y + 7, 240, 240, 240, 255, 1, "Consolas", 15)
  return text_value
end

local function build_fx_summary(layer_definition)
  local names = {}
  for _, fx_definition in ipairs(layer_definition.fx_chain or {}) do
    local plugin_name = trim_string(fx_definition.plugin)
    if plugin_name ~= "" then
      names[#names + 1] = plugin_name
    end
  end
  if #names == 0 then
    return "No FX"
  end
  return table.concat(names, ", ")
end

local function draw_template_preview(template, rect_x, rect_y, rect_w, rect_h)
  draw_rect(rect_x, rect_y, rect_w, rect_h, true, 20, 20, 20, 255)
  draw_rect(rect_x, rect_y, rect_w, rect_h, false, 60, 60, 60, 255)

  local line_y = rect_y + 12
  draw_text("Preview", rect_x + 12, line_y, 240, 240, 240, 255, 1, "Segoe UI Semibold", 16)
  line_y = line_y + 30

  draw_text("Name: " .. tostring(template.name or ""), rect_x + 12, line_y, 220, 220, 220, 255, 1, "Segoe UI", 14)
  line_y = line_y + 22
  draw_text("Description: " .. shorten_text(template.description or "", 90), rect_x + 12, line_y, 190, 190, 190, 255, 1, "Segoe UI", 14)
  line_y = line_y + 22
  draw_text("Folder: " .. tostring(template.folder and template.folder.name or ""), rect_x + 12, line_y, 190, 205, 220, 255, 1, "Consolas", 14)
  line_y = line_y + 30

  for _, layer_definition in ipairs(template.layers or {}) do
    local header = string.format("%s  (%+.1f dB)", layer_definition.name or "Layer", tonumber(layer_definition.volume_db) or 0.0)
    draw_text(header, rect_x + 16, line_y, 235, 235, 235, 255, 1, "Segoe UI Semibold", 14)
    line_y = line_y + 18
    draw_text("FX: " .. shorten_text(build_fx_summary(layer_definition), 72), rect_x + 28, line_y, 165, 190, 205, 255, 1, "Consolas", 13)
    line_y = line_y + 18
    if layer_definition.sends and #layer_definition.sends > 0 then
      draw_text("Sends: " .. shorten_text(layer_definition.sends[1].bus or "", 72), rect_x + 28, line_y, 175, 185, 150, 255, 1, "Consolas", 13)
      line_y = line_y + 18
    end
    if trim_string(layer_definition.note or "") ~= "" then
      draw_text(shorten_text(layer_definition.note, 82), rect_x + 28, line_y, 170, 170, 170, 255, 1, "Segoe UI", 13)
      line_y = line_y + 18
    end
    line_y = line_y + 8
    if line_y > rect_y + rect_h - 30 then
      draw_text("...", rect_x + 28, rect_y + rect_h - 26, 190, 190, 190, 255, 1, "Segoe UI", 14)
      break
    end
  end

  if template.buses and #template.buses > 0 and line_y <= rect_y + rect_h - 40 then
    line_y = line_y + 4
    draw_text("Buses", rect_x + 12, line_y, 220, 220, 220, 255, 1, "Segoe UI Semibold", 15)
    line_y = line_y + 22
    for _, bus_definition in ipairs(template.buses) do
      draw_text("- " .. shorten_text(build_bus_track_name(bus_definition, "Asset"), 60), rect_x + 24, line_y, 180, 200, 220, 255, 1, "Segoe UI", 13)
      line_y = line_y + 18
      if line_y > rect_y + rect_h - 22 then
        break
      end
    end
  end
end

local function perform_load_assets_from_csv(ui)
  local ok, file_path = reaper.GetUserFileNameForRead("", "Import Asset Names From CSV", "csv")
  if not ok or trim_string(file_path) == "" then
    return
  end

  local content, err = read_text_file(file_path)
  if not content then
    reaper.ShowMessageBox("Failed to read CSV file:\n\n" .. tostring(err), SCRIPT_TITLE, 0)
    set_status(ui, "CSV import failed.")
    return
  end

  local asset_names = parse_csv_asset_text(content)
  if #asset_names == 0 then
    reaper.ShowMessageBox("No asset names were found in the selected CSV file.", SCRIPT_TITLE, 0)
    set_status(ui, "CSV import found no usable asset names.")
    return
  end

  ui.asset_names_text = table.concat(asset_names, ", ")
  save_ui_settings(ui)
  set_status(ui, string.format("Loaded %d asset name(s) from CSV.", #asset_names))
end

local function perform_export_selected_custom(ui)
  local custom_id = get_custom_id_from_runtime_key(ui.selected_template_key)
  local template = ui.templates[ui.selected_template_key]
  if not custom_id or not template then
    set_status(ui, "Select a custom template to export.")
    return
  end

  local project_path = reaper.GetProjectPath("")
  local default_path = project_path .. "/" .. sanitize_asset_name(template.name) .. ".gsltemplate"
  local ok, csv = reaper.GetUserInputs(
    SCRIPT_TITLE .. " - Export Custom Template",
    1,
    "separator=|,Output File Path",
    default_path
  )
  if not ok then
    return
  end

  local output_path = trim_string(csv)
  if output_path == "" then
    set_status(ui, "Export cancelled: no output path provided.")
    return
  end

  local write_ok, err = export_templates_to_file(output_path, { template })
  if not write_ok then
    reaper.ShowMessageBox("Failed to export template:\n\n" .. tostring(err), SCRIPT_TITLE, 0)
    set_status(ui, "Export failed.")
    return
  end

  set_status(ui, "Exported custom template to " .. output_path)
end

local function perform_import_templates_from_ui(ui)
  local ok, file_path = reaper.GetUserFileNameForRead("", "Import Custom Template File", "gsltemplate")
  if not ok or trim_string(file_path) == "" then
    return
  end

  local imported_ids, err = import_templates_from_file(file_path)
  if not imported_ids then
    reaper.ShowMessageBox("Failed to import template file:\n\n" .. tostring(err), SCRIPT_TITLE, 0)
    set_status(ui, "Template import failed.")
    return
  end

  refresh_gui_templates(ui, "custom::" .. imported_ids[#imported_ids])
  save_ui_settings(ui)
  set_status(ui, string.format("Imported %d custom template(s).", #imported_ids))
end

local function perform_create_from_ui(ui)
  local template = ui.templates[ui.selected_template_key]
  if not template then
    set_status(ui, "Select a template first.")
    return
  end

  local asset_names = parse_asset_names(ui.asset_names_text)
  if #asset_names == 0 then
    set_status(ui, "Enter at least one asset name.")
    return
  end

  local settings = {
    template_key = ui.selected_template_key,
    template = template,
    asset_names = asset_names,
    asset_names_raw = ui.asset_names_text,
    insert_mode = ui.insert_mode,
    include_fx = ui.include_fx,
    apply_colors = ui.apply_colors,
    write_notes = ui.write_notes,
    include_buses = ui.include_buses,
    create_markers = ui.create_markers,
  }

  save_ui_settings(ui)

  local ok, result = create_templates(settings)
  if not ok then
    reaper.ShowMessageBox("Template creation failed:\n\n" .. tostring(result), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Layer Template] ERROR: " .. tostring(result))
    set_status(ui, "Create failed. See error dialog.")
    return
  end

  print_summary(settings, result)
  set_status(ui, string.format("Created %d set(s), %d track(s).", result.created_templates, result.created_tracks))
end

local function perform_capture_from_ui(ui)
  local template, err = capture_template_from_selection()
  if not template then
    if err and err ~= "User cancelled." then
      reaper.ShowMessageBox(err, SCRIPT_TITLE, 0)
      set_status(ui, err)
    end
    return
  end

  local custom_id = save_custom_template(template)
  refresh_gui_templates(ui, "custom::" .. custom_id)
  save_ui_settings(ui)
  set_status(ui, "Captured custom template: " .. template.name)
end

local function perform_delete_selected_custom(ui)
  local custom_id = get_custom_id_from_runtime_key(ui.selected_template_key)
  local template = ui.templates[ui.selected_template_key]
  if not custom_id or not template then
    set_status(ui, "Select a custom template to delete.")
    return
  end

  local confirm = reaper.ShowMessageBox(
    "Delete custom template '" .. tostring(template.name or custom_id) .. "'?",
    SCRIPT_TITLE,
    4
  )
  if confirm ~= 6 then
    return
  end

  delete_custom_template(custom_id)
  refresh_gui_templates(ui, TEMPLATE_ORDER[1])
  save_ui_settings(ui)
  set_status(ui, "Deleted custom template.")
end

local function show_template_menu(ui, rect_x, rect_y)
  local items = {}
  local mapping = {}
  for _, key in ipairs(ui.template_order) do
    local template = ui.templates[key]
    local label = template and template.name or key
    if is_custom_runtime_key(key) then
      label = "Custom: " .. label
    end
    if key == ui.selected_template_key then
      label = "!" .. label
    end
    items[#items + 1] = label
    mapping[#mapping + 1] = key
  end

  gfx.x = rect_x
  gfx.y = rect_y
  local selection = gfx.showmenu(table.concat(items, "|"))
  if selection > 0 and mapping[selection] then
    ui.selected_template_key = mapping[selection]
    save_ui_settings(ui)
    set_status(ui, "Selected template: " .. tostring(ui.templates[ui.selected_template_key].name))
  end
end

local function run_prompt_flow(current_settings)
  local templates, order = build_runtime_templates()
  local template_lookup = build_template_lookup(templates, order, TEMPLATE_ALIASES)
  local settings, prompt_err = prompt_for_settings(current_settings, template_lookup, templates, order)
  if not settings then
    if prompt_err ~= "User cancelled." then
      reaper.ShowMessageBox(prompt_err or "Invalid settings.", SCRIPT_TITLE, 0)
    end
    return
  end

  save_settings({
    template_key = settings.template_key,
    asset_names = settings.asset_names_raw,
    insert_mode = settings.insert_mode,
    include_fx = settings.include_fx,
    apply_colors = settings.apply_colors,
    write_notes = settings.write_notes,
    include_buses = settings.include_buses,
    create_markers = settings.create_markers,
  })

  local ok, result = create_templates(settings)
  if not ok then
    reaper.ShowMessageBox("Template creation failed:\n\n" .. tostring(result), SCRIPT_TITLE, 0)
    log_line("")
    log_line("[Layer Template] ERROR: " .. tostring(result))
    return
  end

  print_summary(settings, result)
end

local function run_gfx_ui(current_settings)
  if not gfx or not gfx.init then
    return false
  end

  local ui = {
    width = 980,
    height = 860,
    selected_template_key = current_settings.template_key,
    asset_names_text = current_settings.asset_names or DEFAULTS.asset_names,
    insert_mode = current_settings.insert_mode or DEFAULTS.insert_mode,
    include_fx = current_settings.include_fx,
    apply_colors = current_settings.apply_colors,
    write_notes = current_settings.write_notes,
    include_buses = current_settings.include_buses,
    create_markers = current_settings.create_markers,
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
  }

  refresh_gui_templates(ui, current_settings.template_key)

  gfx.init(SCRIPT_TITLE, ui.width, ui.height, 0)
  if (gfx.w or 0) <= 0 then
    return false
  end

  local function loop()
    local key = gfx.getchar()
    if key < 0 then
      save_ui_settings(ui)
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
    draw_text("Phase 3: buses, sends, guide markers, CSV import, custom export/import", 24, 48, 150, 170, 185, 255, 1, "Segoe UI", 13)

    draw_rect(20, 82, 420, 750, true, 24, 24, 24, 255)
    draw_rect(20, 82, 420, 750, false, 58, 58, 58, 255)
    draw_rect(460, 82, 500, 750, true, 24, 24, 24, 255)
    draw_rect(460, 82, 500, 750, false, 58, 58, 58, 255)

    draw_text("Template", 40, 102, 235, 235, 235, 255, 1, "Segoe UI Semibold", 16)
    local selected_template = ui.templates[ui.selected_template_key]
    local template_label = selected_template and selected_template.name or "Select template"
    if draw_button(ui, "template_menu", template_label, 40, 132, 280, 34, true) then
      show_template_menu(ui, 40, 166)
    end
    draw_text(selected_template and selected_template.description or "", 40, 176, 170, 170, 170, 255, 1, "Segoe UI", 13)

    ui.asset_names_text = draw_text_input(ui, "asset_names", "Asset Name(s) - comma separated", 40, 230, 360, 34, ui.asset_names_text)
    if draw_button(ui, "load_csv", "Load Asset Names From CSV", 40, 276, 220, 32, true) then
      perform_load_assets_from_csv(ui)
    end

    draw_text("Insert Position", 40, 332, 235, 235, 235, 255, 1, "Segoe UI Semibold", 15)
    ui.insert_mode = draw_radio(ui, "insert_end", "End of project", 40, 360, ui.insert_mode, "end")
    ui.insert_mode = draw_radio(ui, "insert_cursor", "After selected track", 210, 360, ui.insert_mode, "cursor")

    draw_text("Options", 40, 410, 235, 235, 235, 255, 1, "Segoe UI Semibold", 15)
    ui.include_fx = draw_checkbox(ui, "include_fx", "Include FX chains", 40, 440, ui.include_fx)
    ui.apply_colors = draw_checkbox(ui, "apply_colors", "Apply track colors", 40, 470, ui.apply_colors)
    ui.write_notes = draw_checkbox(ui, "write_notes", "Store track notes", 40, 500, ui.write_notes)
    ui.include_buses = draw_checkbox(ui, "include_buses", "Include bus tracks and sends", 40, 530, ui.include_buses)
    ui.create_markers = draw_checkbox(ui, "create_markers", "Create guide markers", 40, 560, ui.create_markers)

    draw_text("Custom Templates", 40, 614, 235, 235, 235, 255, 1, "Segoe UI Semibold", 15)
    if draw_button(ui, "capture_custom", "Capture Selection", 40, 644, 170, 34, true) then
      perform_capture_from_ui(ui)
    end
    if draw_button(ui, "delete_custom", "Delete Selected Custom", 220, 644, 180, 34, is_custom_runtime_key(ui.selected_template_key)) then
      perform_delete_selected_custom(ui)
    end
    if draw_button(ui, "export_custom", "Export Selected", 40, 688, 170, 32, is_custom_runtime_key(ui.selected_template_key)) then
      perform_export_selected_custom(ui)
    end
    if draw_button(ui, "import_custom", "Import Template File", 220, 688, 180, 32, true) then
      perform_import_templates_from_ui(ui)
    end
    if draw_button(ui, "refresh_custom", "Refresh List", 40, 730, 120, 32, true) then
      refresh_gui_templates(ui)
      set_status(ui, "Template list refreshed.")
    end

    if draw_button(ui, "create", "Create Template", 40, 780, 190, 36, true) then
      perform_create_from_ui(ui)
    end
    if draw_button(ui, "close", "Close", 250, 780, 100, 36, true) then
      save_ui_settings(ui)
      gfx.quit()
      return
    end

    if selected_template then
      draw_template_preview(selected_template, 480, 102, 460, 650)
      draw_text(
        is_custom_runtime_key(ui.selected_template_key) and "Type: Custom template" or "Type: Built-in template",
        480,
        772,
        180,
        200,
        180,
        255,
        1,
        "Segoe UI",
        14
      )
    end

    draw_rect(20, 838, 940, 1, true, 48, 48, 48, 255)
    draw_text(shorten_text(ui.status_message, 120), 24, 846, 170, 205, 220, 255, 1, "Segoe UI", 13)

    if key == 27 and not ui.consume_escape and ui.focus_field == nil then
      save_ui_settings(ui)
      gfx.quit()
      return
    end

    if ui.mouse_released then
      ui.active_mouse_id = nil
    end
    ui.prev_mouse_down = ui.mouse_down

    gfx.update()
    reaper.defer(loop)
  end

  loop()
  return true
end

local function main()
  local current_settings = load_settings()
  local ok = run_gfx_ui(current_settings)
  if not ok then
    run_prompt_flow(current_settings)
  end
end

main()
