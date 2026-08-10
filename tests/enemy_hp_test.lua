-- Drives the readout and the rule shift with a stubbed font and a stand-in
-- BattleState, so it runs with no graphics context.
-- Run from the game root:  lua tests/enemy_hp_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local modPath = os.getenv("ENEMY_HP_MAIN") or "mods/enemy_hp/main.lua"

local drawn, tiles, registered = {}, {}, {}

-- A stand-in BattleState whose drawHUDs closes over a file-scope `hudTile`
-- exactly as the real one does, so the upvalue swap is exercised for real.
local function makeBattleState()
  local hudTile = function(code, x, y, tint)
    tiles[#tiles + 1] = { code = code, x = x, y = y }
  end
  local BattleState = {}
  function BattleState.drawHUDs()
    -- the foe's rule, as BattleState draws it
    hudTile(0x74, 8, 24)
    for i = 2, 9 do hudTile(0x76, i * 8, 24) end
    hudTile(0x78, 80, 24)
    -- things on other rows, which must not move
    hudTile(0x73, 8, 16)
    hudTile(0x6E, 32, 8)
    hudTile(0x74, 8, 88)      -- the player's rule
  end
  return BattleState
end

local BattleState = makeBattleState()

-- DramaticShapeVoxelMod replaces BattleState.drawHUDs and keeps the original
-- in a local of its own, so the hudTile binding sits one closure deeper than
-- the module's function.  Reproduce that here.
local innerHUDs = BattleState.drawHUDs
BattleState.drawHUDs = function(...) return innerHUDs(...) end

package.loaded["src.battle.BattleState"] = BattleState

local fakeFont = { draw = function(text, x, y)
  drawn[#drawn + 1] = { text = text, x = x, y = y }
end }

local options = { enabled = true, format = "exact" }
local listeners = {}

local mod = {
  content = { font = { register = function(_, id, value)
    registered[id] = value
  end } },
  assets = { path = function(_, p) return p end },
  options = { define = function() end, get = function(_, k) return options[k] end },
  events = { on = function(_, name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
  end },
  hooks = { wrap = function() end },
  ui = { Font = fakeFont },
  exports = {},
  log = { info = function() end, warn = function() end },
}

assert(loadfile(modPath), "cannot load " .. modPath)()(mod)

local function emit(name, payload)
  for _, fn in ipairs(listeners[name] or {}) do fn(payload) end
end

local function setOption(key, value)
  options[key] = value
  emit("mod.options_changed", { mod = "enemy_hp", key = key, value = value })
end

local function battle(hp, max)
  return { enemy = { mon = { stats = { hp = max } }, shownHP = hp } }
end

local function drawRow(levelText)
  drawn = {}
  fakeFont.draw(levelText or "23", 40, 8)
  return drawn
end

local failures = 0
local function check(label, got, want)
  local ok = got == want
  if not ok then failures = failures + 1 end
  print(("%-56s %s  (got %s, want %s)")
    :format(label, ok and "PASS" or "FAIL", tostring(got), tostring(want)))
end

-- the swap reaches the binding even though a foreign wrapper hides it
check("the rule was moved through a foreign wrapper",
      mod.exports.ruleMoved(), true)

-- run the engine's HUD pass and see where the tiles landed
tiles = {}
BattleState.drawHUDs()

local byRow = {}
for _, t in ipairs(tiles) do byRow[t.y] = (byRow[t.y] or 0) + 1 end
check("row 3 is emptied of rule tiles", byRow[24], 1)
check("the rule is now on row 4", byRow[32], 10)
check("the bar row is untouched", byRow[16], 1)
check("the level row is untouched", byRow[8], 1)
check("the player's rule is untouched", byRow[88], 1)

-- the L still meets the bar: the vertical stroke is carried down a tile
local bridge
for _, t in ipairs(tiles) do
  if t.y == 24 and t.code == 0x73 then bridge = t end
end
check("the vertical stroke is extended to row 3", bridge and bridge.x, 8)

-- and the figure goes in the opened row, under the bar
emit("battle.started", { battle = battle(24, 57) })
local out = drawRow("23")
check("the level is left exactly where it was", out[1].x, 40)
check("numbers read hp/max", out[2].text, "24/57")
check("numbers sit in the opened row (y)", out[2].y, 24)
-- right-aligned to the bar's last column, 9: "24/57" is 5 wide, so column 5
check("numbers end where the bar ends", out[2].x, 40)

emit("battle.started", { battle = battle(352, 705) })
check("the widest figure fits", drawRow("23")[2].text, "352/705")
-- seven characters reach back to column 3, clear of the L's stroke at 1
check("the widest figure starts at column 3", drawRow("23")[2].x, 24)
check("and ends with the bar at column 9",
      drawRow("23")[2].x + #drawRow("23")[2].text * 8, 80)

setOption("format", "percent")
emit("battle.started", { battle = battle(24, 57) })
check("percent rounds down", drawRow("23")[2].text, "42%")
emit("battle.started", { battle = battle(57, 57) })
check("percent at full health is 100", drawRow("23")[2].text, "100%")
emit("battle.started", { battle = battle(1, 400) })
check("one hp left never reads 0%", drawRow("23")[2].text, "1%")
emit("battle.started", { battle = battle(0, 57) })
check("fainted reads 0%", drawRow("23")[2].text, "0%")
setOption("format", "exact")

-- the missing "%" glyph is supplied rather than printing a blank block
check("a percent glyph page is registered",
      registered["enemy_hp_percent"] ~= nil, true)
check("and mapped to the % character",
      registered["charmap:enemy_hp_percent"].seq, "%")

-- shownHP is the bar's drained value, not the raw current HP
local draining = battle(40, 57)
draining.enemy.mon.hp = 12
emit("battle.started", { battle = draining })
check("follows the bar, not the raw hp", drawRow("23")[2].text, "40/57")

-- visibility is inherited from the level draw
emit("battle.started", { battle = battle(24, 57) })
drawn = {}
fakeFont.draw("RED", 88, 56)
check("no readout without the level anchor", #drawn, 1)

emit("battle.ended", {})
check("nothing after the battle ends", #drawRow("23"), 1)

-- guards
emit("battle.started", { battle = { enemy = {} } })
check("no stats, no readout", #drawRow("23"), 1)
emit("battle.started", { battle = battle(0, 0) })
check("zero max hp is not divided by", #drawRow("23"), 1)

emit("battle.started", { battle = battle(24, 57) })
setOption("enabled", false)
check("disabled mod draws only the level", #drawRow("23"), 1)
setOption("enabled", true)
check("re-enabling restores the readout", #drawRow("23"), 2)
check("no recursion through the wrapper", #drawRow("23"), 2)

-- everything else in the game is untouched
drawn = {}
fakeFont.draw("FIGHT", 80, 112)
fakeFont.draw("23", 120, 64)
check("unrelated draws pass through", #drawn, 2)
check("the player's level is not moved", drawn[2].x, 120)

-- If the swap cannot be made, nothing is moved and the figure falls back
-- to row 4 under the untouched rule.
do
  package.loaded["src.battle.BattleState"] = { drawHUDs = function() end }
  local drawn2 = {}
  local font2 = { draw = function(t, x, y)
    drawn2[#drawn2 + 1] = { text = t, x = x, y = y }
  end }
  local listeners2 = {}
  local mod2 = {
    content = { font = { register = function() end } },
    assets = { path = function(_, p) return p end },
    options = { define = function() end,
                get = function(_, k) return options[k] end },
    events = { on = function(_, n, f)
      listeners2[n] = listeners2[n] or {}; table.insert(listeners2[n], f)
    end },
    hooks = { wrap = function() end },
    ui = { Font = font2 },
    exports = {},
    log = { info = function() end, warn = function() end },
  }
  assert(loadfile(modPath))()(mod2)
  check("no rule to move means no shift claimed", mod2.exports.ruleMoved(), false)
  for _, fn in ipairs(listeners2["battle.started"] or {}) do
    fn({ battle = battle(24, 57) })
  end
  drawn2 = {}
  font2.draw("23", 40, 8)
  check("the figure falls back under the rule (x)", drawn2[2].x, 8)
  check("the figure falls back under the rule (y)", drawn2[2].y, 32)
end

print(failures == 0 and "\nall checks passed"
                    or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
