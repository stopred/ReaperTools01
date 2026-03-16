# GameAudioWorkflow

Phase 3 implementation for a REAPER game-audio workflow built with ReaScript Lua.

Included scripts:

- `GameAudioWorkflow_FOLDER_ITEMS.lua`
  Background folder-item updater. Keeps folder-track proxy items in sync with child-item columns.
- `GameAudioWorkflow_FOLDER_ITEMS_Settings.lua`
  Folder-item, numbering, marker, and selection settings window.
- `GameAudioWorkflow_FOLDER_ITEMS_Update.lua`
  One-shot update for all folder tracks.
- `GameAudioWorkflow_FOLDER_ITEMS_AddNew.lua`
  One-shot update for selected folder contexts.
- `GameAudioWorkflow_Rename.lua`
  Batch rename window. Uses ReaImGui when available and falls back to `GetUserInputs`.
- `GameAudioWorkflow_Render_SMART.lua`
  Folder-item driven WAV render using current REAPER render engine with preset/copy/sausage/variant support in the ImGui UI.
- `GameAudioWorkflow_Reposition.lua`
  Reposition selected items or folder-item groups with a uniform gap.
- `GameAudioWorkflow_Reposition_Preset1.lua`
- `GameAudioWorkflow_Reposition_Preset2.lua`
- `GameAudioWorkflow_Reposition_Preset3.lua`
  Hotkey-friendly reposition preset launchers.
- `GameAudioWorkflow_Trim_SMART.lua`
  Trim folder items to their children or regular items using snap/source limits.
- `GameAudioWorkflow_Fade_SMART.lua`
  Apply linked fades to selected items or folder-item groups.
- `GameAudioWorkflow_Shuffle.lua`
  Shuffle the start positions of selected item groups.
- `GameAudioWorkflow_Join.lua`
  Join selected folder items per folder track into one new folder item.
- `GameAudioWorkflow_Remove.lua`
  Delete selected folder items with children, or regular items/tracks.
- `GameAudioWorkflow_TAKES.lua`
  Background take-marker helper for long source files.
- `GameAudioWorkflow_TAKES_Next.lua`
  Smart next take or next take-marker offset.
- `GameAudioWorkflow_TAKES_Previous.lua`
  Smart previous take or previous take-marker offset.
- `GameAudioWorkflow_TAKES_Duplicate_Next.lua`
  Duplicate selection to the right and advance the duplicate to the next take.
- `GameAudioWorkflow_TAKES_Random.lua`
  Random take / random take-marker selection without immediate repeat.
- `GameAudioWorkflow_TAKES_Settings.lua`
  TAKES settings window.
- `GameAudioWorkflow_TAKES_Reverse.lua`
  Reverse selected takes while rebuilding take-marker positions.
- `GameAudioWorkflow_TAKES_Find.lua`
  Search takes by name.
- `GameAudioWorkflow_Mousewheel_Pitch.lua`
  Mousewheel-based pitch shift for selected items or selected folder-item children.
- `GameAudioWorkflow_Mousewheel_Volume.lua`
  Mousewheel-based volume shift for selected items or selected folder-item children.
- `GameAudioWorkflow_SUBPROJECT.lua`
  Basic track-oriented subproject creation helper. Falls back to marker fixing when nothing is selected.
- `GameAudioWorkflow_SUBPROJECT_Settings.lua`
  Subproject settings window.
- `GameAudioWorkflow_SUBPROJECT_FixMarkers.lua`
  Rebuild `=START` / `=END` markers in the current subproject.
- `GameAudioWorkflow_SUBPROJECT_Render.lua`
  Trigger save/rerender for the current subproject or for selected subproject items from the main project.
- `GameAudioWorkflow_SHARED.lua`
  Shared library for settings, folder detection, naming, rendering, and take utilities.

Usage flow:

1. Put layered design items inside a folder track.
2. Run `GameAudioWorkflow_FOLDER_ITEMS.lua` once to start the background updater.
3. Select generated folder items to auto-select matching child items.
4. Run `GameAudioWorkflow_Rename.lua` to batch-name assets.
5. Run `GameAudioWorkflow_Render_SMART.lua` to render selected folder items, or all folder items if none are selected.
6. Use the Phase 2 utility scripts for layout edits, take management, and subproject prep.

Notes:

- Folder items are tagged internally with `P_EXT:GAW_ROLE=folder_item`.
- Marker/region sync is stored in project ext state and recreated from folder items.
- Render SMART currently forces WAV sink type by setting `RENDER_FORMAT` to `evaw` and uses REAPER's most recent render action.
- TAKES auto-marker generation currently uses an equal-segment heuristic based on item length vs source length.
- Rename now supports Match/Replace and optional UCS category prefixing.
- FOLDER_ITEMS can optionally include automation-item ranges and experimental wider auto-grouping during column clustering.
- SUBPROJECT creation currently targets selected tracks or tracks implied by selected folder items/items and uses REAPER's native "Move tracks to subproject" action.
- SUBPROJECT rerender currently uses save-based proxy refresh and opens source subprojects via `Main_openProject`, so it should be validated on your REAPER install before relying on it in production.
