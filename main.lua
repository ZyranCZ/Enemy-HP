-- Enemy HP Readout for Gen1Recomp
--
-- Gen 1 shows the foe's HP as a bar and nothing else.  This opens a line
-- inside the foe's HUD, directly under its bar, and puts the figure there.
--
-- MAKING THE ROOM
--
-- The foe's HUD ends in an L-shaped white rule on row 3: a corner at
-- column 1 and a horizontal run out to column 10, hanging off the vertical
-- stroke that starts on the bar's row.  Row 4 below it is empty -- the
-- player's back sprite only starts at hlcoord 1,5.
--
-- So the rule moves down one row.  That frees row 3 entirely: a full line
-- immediately under the bar, inside the frame rather than dangling below
-- it, and wide enough for "352/705" with room to spare.  The vertical
-- stroke is extended by one tile so the L still meets the bar.
--
-- REACHING THE RULE
--
-- The tiles are drawn through `hudTile`, which BattleState binds as a
-- file-scope local (`local hudTile = HudTiles.tile`).  Patching the
-- HudTiles module does NOT reach it, and worse, it half-works: WideBattle
-- calls the module directly with the same coordinates, so a module patch
-- lands on one path and not the other and the tile ends up drawn twice.
-- That is what put a ghost <LV> under the level digits in an earlier
-- version of this mod.
--
-- Mods are loaded with no sandbox, so the debug library is available and
-- the binding itself can be replaced: debug.setupvalue on drawHUDs swaps
-- the exact upvalue the engine calls.  File-scope locals are shared by
-- every closure in the chunk, so one swap covers all of them, and there is
-- no second path and no load-order race.
--
-- If the swap fails for any reason the mod does not move anything.  The
-- figure then goes on row 4, under the untouched rule -- less tidy, but it
-- cannot break the HUD.
--
-- DRAWING THE FIGURE
--
-- Not through battle.overlay: that runs after drawZonePass has recoloured
-- the HUD and blitted it, so anything drawn there skips the palette
-- pipeline and looks foreign beside the HUD -- and under a render pipeline
-- like the voxel one it lands over the 3D scene entirely.
--
-- Instead the mod wraps Font.draw and hangs off the foe's level draw,
-- uniquely at (40, 8).  That puts the figure on the same canvas in the
-- same pass, coloured and faded by the engine's own code, riding the HUD
-- shake with everything else.  It also inherits the HUD's visibility: the
-- block is gated on the intro slide, the trainer pic, the send-out, the
-- grow-in and the faint, so if the level is not drawn, neither is this.

local EXACT, PERCENT = "exact", "percent"

local FORMAT_CHOICES = {
  { "NUMBERS", EXACT },
  { "PERCENT", PERCENT },
}

local ANCHOR_X, ANCHOR_Y = 40, 8   -- the foe's level slot

local RULE_Y = 24                  -- row 3, where the rule sits in vanilla
local RULE_DROP = 8                -- one row down
local RULE_CORNER = 0x74           -- the L's corner tile
local RULE_STROKE = 0x73           -- the vertical stroke above it

-- The opened row could run out to column 11 -- the foe's pic occupies a 7x7
-- tile buffer at hlcoord 12,0, so columns 12 upward are sprite on rows 0 to
-- 6, row 3 included.  It ends at column 9 instead, which is where the HP
-- bar itself ends (label tile at column 2, its cap at 3, six segments out
-- to 9), so the figure and the bar above it finish on the same edge.
--
-- Right-aligned rather than pinned on the left, because the figure loses
-- digits from the left as HP drops ("113/166" -> "99/166") and a fixed left
-- edge would drag the slash and the maximum around with it.  Seven
-- characters, the widest Gen 1 can produce, reach back to column 3 -- still
-- clear of the L's vertical stroke at column 1.
local OPENED_Y = 24
local OPENED_LAST_COL = 9
-- fallback when the rule could not be moved: row 4, under it
local BELOW_X, BELOW_Y = 8, 32

return function(mod)
  local Font = mod.ui.Font

  mod.content.font:register("enemy_hp_percent", {
    image = mod.assets:path("assets/percent.png"),
    base = 0x140, glyphsPerRow = 1,
  })
  mod.content.font:register("charmap:enemy_hp_percent", {
    seq = "%", code = 0x140,
  })

  mod.options:define({
    { key = "enabled", label = "ENEMY HP", type = "toggle", default = true },
    { key = "format", label = "ENEMY HP AS", type = "choice",
      default = EXACT, choices = FORMAT_CHOICES },
  })

  local enabled, format

  local function readOptions()
    enabled = mod.options:get("enabled") and true or false
    format = mod.options:get("format") == PERCENT and PERCENT or EXACT
  end

  readOptions()
  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod == "enemy_hp" then readOptions() end
  end)

  -- Find the closure that owns a named upvalue, walking through function
  -- upvalues as well.  Another mod may have replaced BattleState.drawHUDs
  -- with a wrapper that keeps the original in one of its own upvalues --
  -- DramaticShapeVoxelMod does exactly this -- so the binding we want can
  -- sit a few closures deep rather than on the table's function itself.
  local function findUpvalue(fn, name, seen, depth)
    if type(fn) ~= "function" or depth > 4 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local nested = {}
    local i = 1
    while true do
      local found, value = debug.getupvalue(fn, i)
      if not found then break end
      if found == name then return fn, i, value end
      if type(value) == "function" then nested[#nested + 1] = value end
      i = i + 1
    end

    for _, child in ipairs(nested) do
      local owner, index, value = findUpvalue(child, name, seen, depth + 1)
      if owner then return owner, index, value end
    end
    return nil
  end

  -- Drop the foe's rule one row.  Only the foe's is on row 3 -- its party
  -- balls are on row 2 and the player's whole HUD is on rows 7-11 -- so a
  -- plain row test is enough and no side has to be identified.
  local ruleMoved = false
  do
    local BattleState = require("src.battle.BattleState")
    local vanillaTile
    local function shifted(code, x, y, tint)
      if y ~= RULE_Y then return vanillaTile(code, x, y, tint) end
      if code == RULE_CORNER then
        -- the L hangs off a vertical stroke that stopped at the bar's row;
        -- carry it down one tile so the corner still meets it
        vanillaTile(RULE_STROKE, x, y, tint)
      end
      return vanillaTile(code, x, y + RULE_DROP, tint)
    end

    -- Search every function the module exposes, not just drawHUDs: if a mod
    -- replaced that one, the original is reachable through its wrapper's
    -- upvalues.  The binding is read rather than assumed to be
    -- HudTiles.tile, so a mod that already wrapped the tile stays in the
    -- chain.
    if debug and debug.getupvalue and debug.setupvalue then
      local seen = {}
      for _, value in pairs(BattleState) do
        local owner, index, found = findUpvalue(value, "hudTile", seen, 0)
        if owner then
          vanillaTile = found
          debug.setupvalue(owner, index, shifted)
          ruleMoved = true
          break
        end
      end
    end

    if not ruleMoved then
      mod.log:warn("could not reach the HUD rule; " ..
                   "drawing the readout below it instead")
    end
  end

  -- Font.draw has no idea which battle is on screen, so the current one is
  -- kept here.  battle.started / battle.ended bracket every battle.
  local current
  mod.events:on("battle.started", function(payload)
    current = payload and payload.battle
  end)
  mod.events:on("battle.ended", function() current = nil end)

  -- The HP the bar is currently showing, which lags mon.hp through the
  -- drain animation.  Reading mon.hp would snap the number to its final
  -- value while the bar was still sliding.
  local function shownHP(battler)
    local shown = battler.shownHP
    if shown == nil then shown = battler.mon and battler.mon.hp end
    return shown or 0
  end

  local function readout(battle)
    if not enabled or not battle then return nil end

    local enemy = battle.enemy
    local stats = enemy and enemy.mon and enemy.mon.stats
    local max = stats and stats.hp
    if not max or max <= 0 then return nil end

    local hp = math.max(0, math.min(shownHP(enemy), max))

    if format == EXACT then return ("%d/%d"):format(hp, max) end

    -- a foe still standing must never read 0%, and one at full HP must
    -- read 100 rather than 99 from a floor
    local pct = hp <= 0 and 0 or math.max(1, math.floor(hp * 100 / max))
    return ("%d%%"):format(pct)
  end

  -- our own draw goes back through the wrapped function; do not re-enter
  local drawing = false

  local vanillaDraw = Font.draw
  Font.draw = function(text, x, y)
    local result = vanillaDraw(text, x, y)
    if drawing or x ~= ANCHOR_X or y ~= ANCHOR_Y or not current then
      return result
    end

    local figure = readout(current)
    if figure then
      drawing = true
      if ruleMoved then
        vanillaDraw(figure, (OPENED_LAST_COL + 1 - #figure) * 8, OPENED_Y)
      else
        vanillaDraw(figure, BELOW_X, BELOW_Y)
      end
      drawing = false
    end
    return result
  end

  mod.exports.readout = readout
  mod.exports.ruleMoved = function() return ruleMoved end
end
