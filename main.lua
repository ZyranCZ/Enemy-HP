-- Enemy HP Readout for Gen1Recomp
-- v2.0.0 (stable Gen 1 + Gen 2 / Gold release)
--
-- Vanilla path:
--   Keep the 1.0.1 behavior: move the enemy HUD underline down one tile and
--   render the enemy's animated shownHP directly into the opened row.
--
-- UI-overhaul compatibility path:
--   Gen1 Modern UI and Gen 3 Inspired UI can suppress/replace the native HUD.
--   In those frames the native foe-level Font.draw anchor never fires.
--   A render.hud fallback therefore draws the same readout in screen space,
--   after the final game frame and other HUD presenters have been composed.
--   This is deliberately automatic and does not patch either foreign mod.

local EXACT, PERCENT = "exact", "percent"
local AUTO, GEN3, MODERN, NATIVE = "auto", "gen3", "modern", "native"
local KEEP_OG_UI, HIDE_OG_UI = "keep_og_ui", "hide_og_ui"

local FORMAT_CHOICES = {
  { "NUMBERS", EXACT },
  { "PERCENT", PERCENT },
}

local COMPAT_CHOICES = {
  { "ORIGINAL / VANILLA UI", NATIVE },
  { "GEN 3 UI", GEN3 },
  { "GEN 1 MODERN UI", MODERN },
  { "AUTO DETECT", AUTO },
}

local BATTLE_UI_CHOICES = {
  { "KEEP OG UI", KEEP_OG_UI },
  { "HIDE OG UI", HIDE_OG_UI },
}

local ANCHOR_X, ANCHOR_Y = 40, 8
local RULE_Y, RULE_DROP = 24, 8
local RULE_CORNER, RULE_STROKE = 0x74, 0x73
local OPENED_Y, OPENED_LAST_COL = 24, 9
local BELOW_X, BELOW_Y = 8, 32

-- GameVersion is a process-global source of truth shared by both engines.
-- We must choose the presentation backend before any Gen 1-only monkey patch
-- is installed: on Gold, src.battle.BattleState / HudTiles / global Font.draw
-- are intentionally never touched.
local GameVersion = require("src.core.GameVersion")

local function formatReadout(hp, maxHp, style)
  if not maxHp or maxHp <= 0 then return nil end
  hp = math.max(0, math.min(hp or 0, maxHp))
  if style == EXACT then return ("%d/%d"):format(hp, maxHp) end
  local pct = hp <= 0 and 0 or math.max(1, math.floor(hp * 100 / maxHp))
  return ("%d%%"):format(pct)
end

-- Kept generation-neutral so the legacy diagnostics export can retain its
-- exact Gen 1 meaning even while the Gold backend is active.
local function legacyEnemyHudExpected(battle)
  if not battle or battle.blankForAskName then return false end
  local enemy = battle.enemy
  if not (enemy and enemy.mon) then return false end
  if battle.showEnemyTrainer or battle.enemySendingOut or battle.introBalls then
    return false
  end
  if enemy.fainted then return false end
  if (battle.introSlide or 0) ~= 0 then return false end
  if type(battle.growInScale) == "function" then
    local ok, scale = pcall(battle.growInScale, battle, enemy)
    if ok and scale then return false end
  end
  return true
end

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
    { key = "compat_fix", label = "MOD COMPATIBILITY FIX", type = "choice",
      default = NATIVE, choices = COMPAT_CHOICES },
    { key = "experimental_battle_ui", label = "EXPERIMENTAL BATTLE UI",
      type = "choice", default = KEEP_OG_UI, choices = BATTLE_UI_CHOICES },
  })

  local enabled, format, compatMode, hideOriginalBattleUI

  local function readOptions()
    enabled = mod.options:get("enabled") and true or false
    format = mod.options:get("format") == PERCENT and PERCENT or EXACT
    local c = mod.options:get("compat_fix")
    if c == GEN3 or c == MODERN or c == NATIVE or c == AUTO then
      compatMode = c
    else
      compatMode = NATIVE
    end
    hideOriginalBattleUI =
      mod.options:get("experimental_battle_ui") == HIDE_OG_UI
  end

  readOptions()
  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod == "enemy_hp" then readOptions() end
  end)

  local generation = GameVersion.generation()
  if generation == 2 then
    --------------------------------------------------------------------------
    -- GOLD / GEN 2 PRESENTATION BACKEND
    --
    -- Gold's battle model resolves a whole turn ahead of its presentation
    -- queue.  The HUD therefore owns shownMon/shownHp, and those are the only
    -- values safe to present without spoiling damage/healing before the bar
    -- visibly gets there.  This backend is deliberately read-only.
    --------------------------------------------------------------------------
    local goldOverlayInstalled = false
    local goldNativeInstalled = false
    local goldLastVisible = false
    local goldLastHp, goldLastMaxHp = nil, nil
    local goldReadoutSource = nil
    local goldLastDrawError = nil
    -- Once Gold has legitimately revealed the foe HUD for this battle screen,
    -- keep the numeric readout alive until the battle actually ends.  Vanilla
    -- transiently hides its HUD during move effects, faint/catch cleanup and
    -- replacement choreography; those are presentation states, not moments
    -- where the foe's displayed HP ceases to exist.
    local goldEnemyHudLatched = false
    local goldLatchedScreen = nil
    local GOLD_OVERLAY_PRIORITY = 200

    local function legacyShownHP(battler)
      local shown = battler and battler.shownHP
      if shown == nil then shown = battler and battler.mon and battler.mon.hp end
      return shown or 0
    end

    -- Preserve the existing public readout(battle) export for consumers that
    -- pass the historical Gen 1 battle shape, even on a Gold boot.
    local function legacyReadout(battle)
      if not enabled or not battle then return nil end
      local enemy = battle.enemy
      local stats = enemy and enemy.mon and enemy.mon.stats
      local maxHp = stats and stats.hp
      return formatReadout(legacyShownHP(enemy), maxHp, format)
    end

    local function goldFallbackReason()
      if hideOriginalBattleUI then
        return "HIDE OG UI is Gen1-only until a Gold replacement UI is verified; native Gold HUD kept"
      end
      if compatMode ~= NATIVE then
        return "requested " .. tostring(compatMode) .. " compatibility is not verified on Gold; native Gold HUD used"
      end
      return nil
    end

    local function displayedEnemy(screen)
      if not screen then return nil, "none" end
      if type(screen.activeMon) == "function" then
        local ok, mon = pcall(screen.activeMon, screen, "enemy")
        if ok and mon ~= nil then return mon, "activeMon(enemy)" end
      end
      local shown = screen.shownMon and screen.shownMon.enemy
      if shown ~= nil then return shown, "shownMon.enemy" end
      local live = screen.battle and screen.battle.enemy
      if live ~= nil then return live, "battle.enemy fallback" end
      return nil, "none"
    end

    local function goldVisible(screen)
      if not enabled or not screen then return false end

      -- A new BattleState instance is a new presentation lifecycle.  Do NOT
      -- use battle.ended / battle.over / mon.hp here: Gold resolves battle
      -- logic ahead of its presentation queue, so a lethal hit can already be
      -- logically finished while shownHp is still draining on screen.
      if goldLatchedScreen ~= screen then
        goldLatchedScreen = screen
        goldEnemyHudLatched = false
      end

      -- Mirror the native enemy HP BAR's own draw gate from Gold
      -- BattleState:drawHud(), not the logical battle outcome.  This guarantees
      -- that a lethal hit remains visible at its chased shownHp value all the
      -- way to 0, and that 0/max (or 0%) remains on screen for as long as the
      -- native enemy HP bar itself is still being drawn.
      if screen.showEnemyHud ~= true then return false end
      if type(screen.hudCleared) == "function" then
        local ok, cleared = pcall(screen.hudCleared, screen, "enemy")
        if ok and cleared then return false end
      end

      goldEnemyHudLatched = true
      return true
    end

    local function goldView(screen)
      local view = {
        mon = nil, hp = nil, maxHp = nil, visible = false,
        source = nil, generation = 2,
      }
      if not goldVisible(screen) then return view end

      local mon, monSource = displayedEnemy(screen)
      if not mon then return view end
      local maxHp = mon.maxHp or (mon.stats and mon.stats.hp)
      if not maxHp or maxHp <= 0 then return view end

      local hp, hpSource
      if screen.shownHp and screen.shownHp.enemy ~= nil then
        hp = screen.shownHp.enemy
        hpSource = "shownHp.enemy"
      elseif type(screen.hudHp) == "function" then
        local ok, shown = pcall(screen.hudHp, screen, mon, "enemy")
        if ok and shown ~= nil then
          hp = shown
          hpSource = "hudHp(enemy) fallback"
        end
      end
      if hp == nil then
        hp = mon.hp or 0
        hpSource = "displayedMon.hp defensive fallback"
      end

      view.mon = mon
      view.hp = math.max(0, math.min(hp, maxHp))
      view.maxHp = maxHp
      view.visible = true
      view.source = hpSource .. " + " .. monSource
      return view
    end

    local function readoutForScreen(screen)
      local view = goldView(screen)
      if not view.visible then return nil, view end
      return formatReadout(view.hp, view.maxHp, format), view
    end

    local function drawGoldNativeRow(screen, figure)
      local G = love and love.graphics
      if not (G and G.setColor and G.rectangle and type(Font.draw) == "function") then
        return false, "Gold graphics primitives unavailable"
      end

      local pushed = false
      if type(G.push) == "function" and type(G.pop) == "function" then
        local ok = pcall(G.push, "all")
        if not ok then ok = pcall(G.push) end
        pushed = ok and true or false
      end

      local ok, err = pcall(function()
        -- Native enemy frame: side is at row 2, bottom rule at row 3.  Keep the
        -- existing row-2 side, erase only the old bottom row, then redraw the
        -- same frame shifted one tile so its side continues through our new
        -- numeric row and its bottom rule lands at row 4.
        G.setColor(1, 1, 1, 1)
        G.rectangle("fill", 8, 24, 88, 8)

        local shifted = false
        local hud = screen and screen.hud
        if hud and type(hud.available) == "function"
            and type(hud.drawEnemyFrame) == "function"
            and type(G.translate) == "function" then
          local available = false
          local okAvail, value = pcall(hud.available, hud)
          if okAvail then available = value and true or false end
          if available then
            G.translate(0, 8)
            hud:drawEnemyFrame()
            G.translate(0, -8)
            shifted = true
          end
        end
        if not shifted and screen and type(screen.drawFrame) == "function" then
          screen:drawFrame(1, 4, 10, false)
          shifted = true
        end
        if not shifted then
          -- Last-resort shape is the exact fallback geometry Gold itself uses.
          G.setColor(0, 0, 0, 1)
          G.rectangle("fill", 8, 32, 80, 2)
          G.rectangle("fill", 8, 24, 2, 10)
        end

        local width
        if type(Font.width) == "function" then
          local okWidth, measured = pcall(Font.width, figure)
          if okWidth and type(measured) == "number" then width = measured end
        end
        width = width or (#figure * 8)
        G.setColor(0, 0, 0, 1)
        Font.draw(figure, 88 - width - 8, 24)
      end)

      if pushed then pcall(G.pop) end
      if not ok then return false, tostring(err) end
      return true
    end

    if mod.hooks and type(mod.hooks.wrap) == "function" then
      local ok, err = pcall(function()
        mod.hooks:wrap("battle.overlay", function(next, screen, ...)
          local result = next(screen, ...)
          local figure, view = readoutForScreen(screen)
          goldLastVisible = view.visible and true or false
          goldLastHp = view.hp
          goldLastMaxHp = view.maxHp
          goldReadoutSource = view.source
          if figure then
            local drawn, drawErr = drawGoldNativeRow(screen, figure)
            goldNativeInstalled = drawn or goldNativeInstalled
            goldLastDrawError = drawErr
          end
          return result
        end, GOLD_OVERLAY_PRIORITY)
      end)
      goldOverlayInstalled = ok
      if not ok then
        goldLastDrawError = tostring(err)
        if mod.log and mod.log.warn then
          mod.log:warn("Enemy HP: Gold battle.overlay could not be installed: " .. tostring(err))
        end
      end
    end

    local function clearGoldDiagnostics()
      goldLastVisible = false
      goldLastHp, goldLastMaxHp = nil, nil
      goldReadoutSource = nil
      goldLastDrawError = nil
    end

    local function beginGoldBattle()
      clearGoldDiagnostics()
      goldEnemyHudLatched = false
      goldLatchedScreen = nil
    end

    local function noteGoldBattleEnded()
      -- battle.ended is a LOGIC boundary on Gold, not the visual lifetime of
      -- its BattleState.  In particular a lethal attack can reach this event
      -- before shownHp has chased to zero.  Never suppress the overlay here.
      clearGoldDiagnostics()
    end

    mod.events:on("battle.started", beginGoldBattle)
    mod.events:on("battle.ended", noteGoldBattleEnded)

    mod.exports.readout = legacyReadout
    mod.exports.readoutForScreen = readoutForScreen
    mod.exports.ruleMoved = function() return false end
    mod.exports.compat = {
      version = 5,
      -- Legacy Gen 1 diagnostics remain present with safe Gold semantics.
      gen3Integration = "Gen1-only on Gold",
      gen3DirectInstalled = function() return false end,
      gen3DirectReason = function() return goldFallbackReason() or "Gen3 private integration is Gen1-only" end,
      gen3HideBridgeInstalled = function() return false end,
      gen3HideBridgeReason = function() return "Gen1-only on Gold" end,
      hideOriginalBattleUI = function() return hideOriginalBattleUI end,
      hardHideInstalled = function() return false end,
      hardHideDramalessInstalled = function() return false end,
      hardHideReason = function() return "Gen1 hard-hide stack is intentionally not installed on Gold" end,
      finalNativeSuppressor = function() return false end,
      finalDramalessSuppressor = function() return false end,
      v12NativeKillSwitch = function() return false end,
      v12DramalessKillSwitch = function() return false end,
      primitiveHudKill = function() return false end,
      hpBarPrimitiveKill = function() return false end,
      hpBarIdentityPatchCount = function() return 0 end,
      patchCapturedHPBarReferences = function() return false end,
      compatibilityMode = function() return compatMode end,
      renderHookPriority = 12000,
      overlayInstalled = function() return false end,
      nativeAnchorSeen = function() return false end,
      enemyHudExpected = legacyEnemyHudExpected,
      -- v5 generation-aware diagnostics.
      generation = 2,
      backend = "gold",
      goldNativeInstalled = function() return goldNativeInstalled end,
      goldOverlayInstalled = function() return goldOverlayInstalled end,
      goldOverlayPriority = GOLD_OVERLAY_PRIORITY,
      goldReadoutSource = function() return goldReadoutSource end,
      goldLastVisible = function() return goldLastVisible end,
      goldLastHp = function() return goldLastHp end,
      goldLastMaxHp = function() return goldLastMaxHp end,
      goldEnemyHudLatched = function() return goldEnemyHudLatched end,
      goldReplacementUi = function() return nil end,
      goldFallbackReason = goldFallbackReason,
      goldLastDrawError = function() return goldLastDrawError end,
    }
    return
  end

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

  local ruleMoved = false
  do
    local BattleState = require("src.battle.BattleState")
    local vanillaTile

    local function shifted(code, x, y, tint)
      -- Primitive-level native HUD kill. This function is installed directly
      -- into the hudTile upvalue used by the original/captured battle HUD
      -- renderer, including Dramaless' private innerHUDs copy.
      if hideOriginalBattleUI and compatMode ~= NATIVE then
        return
      end

      if y ~= RULE_Y then return vanillaTile(code, x, y, tint) end
      if code == RULE_CORNER then
        vanillaTile(RULE_STROKE, x, y, tint)
      end
      return vanillaTile(code, x, y + RULE_DROP, tint)
    end

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
      mod.log:warn("could not reach the HUD rule; drawing the native readout below it")
    end
  end

  local current
  local battleFrames = 0
  local anchorSeenThisFrame = false
  local anchorEverSeen = false

  mod.events:on("battle.started", function(payload)
    current = payload and payload.battle
    battleFrames = 0
    anchorSeenThisFrame = false
    anchorEverSeen = false
  end)

  mod.events:on("battle.ended", function()
    current = nil
    battleFrames = 0
    anchorSeenThisFrame = false
    anchorEverSeen = false
  end)


  -- V14: dedicated native HP-bar renderer kill -----------------------------
  --
  -- Gen1Recomp's battle HP bars are NOT drawn through BattleState's local
  -- hudTile helper. HudTiles.drawHPBar() directly calls HudTiles.tile() for
  -- "HP", the bracket, all fill segments, and the end cap. This is why V13
  -- removed every other native HUD glyph but left two naked HP bars behind.
  --
  -- Gate the dedicated primitive itself. Gen3 UI uses its own drawStyledHP /
  -- love.graphics path, so its yellow panels and green bars are unaffected.
  local HudTiles = require("src.render.HudTiles")
  HudTiles.__enemyHpV14State = HudTiles.__enemyHpV14State or {}
  HudTiles.__enemyHpV14State.requested = function()
    return current ~= nil
      and hideOriginalBattleUI
      and compatMode ~= NATIVE
  end

  if type(HudTiles.drawHPBar) == "function"
      and HudTiles.drawHPBar ~= HudTiles.__enemyHpV14DrawHPBar then
    local previousDrawHPBar = HudTiles.drawHPBar
    HudTiles.__enemyHpV14OriginalDrawHPBar =
      HudTiles.__enemyHpV14OriginalDrawHPBar or previousDrawHPBar
    local state = HudTiles.__enemyHpV14State
    local function drawHPBarGate(...)
      local requested = state.requested
      if requested and requested() then
        return
      end
      return previousDrawHPBar(...)
    end
    HudTiles.__enemyHpV14DrawHPBar = drawHPBarGate
    HudTiles.drawHPBar = drawHPBarGate
  end


  -- V15: patch captured drawHPBar references by FUNCTION IDENTITY ----------
  --
  -- V14 replaced HudTiles.drawHPBar on the module table. That does not affect
  -- a caller that cached `local drawHPBar = HudTiles.drawHPBar` earlier.
  --
  -- V15 walks the BattleState function graph and replaces every upvalue whose
  -- VALUE is the original drawHPBar function object. This also reaches nested
  -- functions captured by Dramaless' innerHUDs path. The replacement remains
  -- battle/hide gated, so Party/Summary HP bars outside battle are untouched.
  local hpBarIdentityPatchCount = 0
  local hpBarIdentityPatchedFns = setmetatable({}, { __mode = "k" })

  local originalDrawHPBarIdentity =
    HudTiles.__enemyHpV14OriginalDrawHPBar or nil

  -- V14 did not persist the original identity; recover it from its wrapper
  -- upvalues if necessary.
  if not originalDrawHPBarIdentity
      and type(HudTiles.__enemyHpV14DrawHPBar) == "function"
      and debug and debug.getupvalue then
    local i = 1
    while true do
      local name, value = debug.getupvalue(HudTiles.__enemyHpV14DrawHPBar, i)
      if not name then break end
      if name == "previousDrawHPBar" and type(value) == "function" then
        originalDrawHPBarIdentity = value
        break
      end
      i = i + 1
    end
  end

  if originalDrawHPBarIdentity then
    HudTiles.__enemyHpV14OriginalDrawHPBar = originalDrawHPBarIdentity
  end

  local function hpBarIdentityGate(...)
    if current and hideOriginalBattleUI and compatMode ~= NATIVE then
      return
    end
    if originalDrawHPBarIdentity then
      return originalDrawHPBarIdentity(...)
    end
  end

  local function patchFunctionGraph(fn, seen, depth)
    if type(fn) ~= "function" or depth > 12 then return end
    if hpBarIdentityPatchedFns[fn] then return end
    hpBarIdentityPatchedFns[fn] = true
    seen = seen or {}

    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if not name then break end

      if originalDrawHPBarIdentity and value == originalDrawHPBarIdentity then
        debug.setupvalue(fn, i, hpBarIdentityGate)
        hpBarIdentityPatchCount = hpBarIdentityPatchCount + 1
      elseif type(value) == "function" and not seen[value] then
        seen[value] = true
        patchFunctionGraph(value, seen, depth + 1)
      end

      i = i + 1
    end
  end

  local function patchCapturedHPBarReferences()
    if not (debug and debug.getupvalue and debug.setupvalue)
        or not originalDrawHPBarIdentity then
      return false
    end

    local okBattle, BattleState = pcall(require, "src.battle.BattleState")
    if okBattle and type(BattleState) == "table" then
      hpBarIdentityPatchedFns = setmetatable({}, { __mode = "k" })
      for _, value in pairs(BattleState) do
        if type(value) == "function" then
          patchFunctionGraph(value, {}, 0)
        end
      end
    end

    -- Explicitly traverse Dramaless' currently captured innerHUDs too.
    local dramaHandle =
      type(mod.find) == "function" and mod.find("DRAMALESS_SHAPE") or nil
    local dramaLib =
      dramaHandle and dramaHandle.exports and dramaHandle.exports.lib
    if dramaLib and type(dramaLib.require) == "function" then
      local okDrama, O = pcall(dramaLib.require, "OverworldBattle")
      if okDrama and type(O) == "table" and type(O.hudTexture) == "function" then
        local function walkForInner(fn, seen, depth)
          if type(fn) ~= "function" or depth > 12 or seen[fn] then return end
          seen[fn] = true
          local i = 1
          while true do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == "innerHUDs" and type(value) == "function" then
              patchFunctionGraph(value, {}, 0)
            elseif type(value) == "function" then
              walkForInner(value, seen, depth + 1)
            end
            i = i + 1
          end
        end
        walkForInner(O.hudTexture, {}, 0)
      end
    end

    return hpBarIdentityPatchCount > 0
  end

  patchCapturedHPBarReferences()

  mod.events:on("battle.started", function()
    patchCapturedHPBarReferences()
  end, -300000)

  local function shownHP(battler)
    local shown = battler and battler.shownHP
    if shown == nil then shown = battler and battler.mon and battler.mon.hp end
    return shown or 0
  end

  local function readout(battle)
    if not enabled or not battle then return nil end
    local enemy = battle.enemy
    local stats = enemy and enemy.mon and enemy.mon.stats
    local maxHp = stats and stats.hp
    return formatReadout(shownHP(enemy), maxHp, format)
  end

  -- Exact v1.0.2 visibility semantics, shared with the legacy diagnostics key
  -- exposed on the Gold backend.
  local enemyHudExpected = legacyEnemyHudExpected

  local function foreignUiPresent()
    if type(mod.find) ~= "function" or compatMode == NATIVE then
      return false, nil
    end

    local function has(id)
      local ok, found = pcall(mod.find, id)
      if not ok then
        ok, found = pcall(mod.find, mod, id)
      end
      return ok and found or nil
    end

    local modern = has("gen1_modern_ui")
    local gen3 = has("gen3_battle_ui")
    if compatMode == GEN3 then
      return gen3 and true or false, gen3 and "gen3" or nil
    elseif compatMode == MODERN then
      return modern and true or false, modern and "modern" or nil
    end
    if gen3 then return true, "gen3" end
    if modern then return true, "modern" end
    return false, nil
  end



  -- Enemy HP hard original-battle-UI suppression ---------------------------
  --
  -- This does NOT rely on Gen3 UI's hideNativeBattleUI option. The user's
  -- setup includes a 3D battle presenter that can capture the legacy HUD
  -- before Gen3's final screen-space pass. We therefore suppress the native
  -- HUD at its source and also suppress Dramaless Shape's cached HUD copy.
  local hardHideInstalled = false
  local hardHideDramalessInstalled = false
  local hardHideReason = "not attempted"

  local function hideRequested()
    return hideOriginalBattleUI
      and (compatMode == GEN3 or compatMode == AUTO)
  end

  local function runInvisible(fn, self, ...)
    local g = love and love.graphics
    if not (g and g.push and g.setScissor and g.pop) then
      return fn(self, ...)
    end
    g.push("all")
    g.setScissor(0, 0, 0, 0)
    local packed = { pcall(fn, self, ...) }
    g.pop()
    if not packed[1] then error(packed[2], 0) end
    table.remove(packed, 1)
    return unpack(packed)
  end

  local function installHardHide()
    local okBattle, BattleState = pcall(require, "src.battle.BattleState")
    if not okBattle or type(BattleState) ~= "table" then
      hardHideReason = "BattleState unavailable"
      return false
    end

    if not BattleState.__enemyHpHardHidePatched then
      BattleState.__enemyHpHardHidePatched = true

      local previousHUDs = BattleState.drawHUDs
      if type(previousHUDs) == "function" then
        BattleState.drawHUDs = function(self, slide, ...)
          if hideRequested() then
            -- Run all lifecycle/mod behavior but permit zero legacy pixels.
            return runInvisible(previousHUDs, self, slide, ...)
          end
          return previousHUDs(self, slide, ...)
        end
      end

      local previousTextArea = BattleState.drawTextArea
      if type(previousTextArea) == "function" then
        BattleState.drawTextArea = function(self, ...)
          if hideRequested() then
            return runInvisible(previousTextArea, self, ...)
          end
          return previousTextArea(self, ...)
        end
      end
    end

    hardHideInstalled = true
    hardHideReason = "BattleState + Dramaless silent-success snap suppression active"

    -- Dramaless Shape captures the pre-wrapper BattleState.drawHUDs into
    -- private innerHUDs, then every update frame runs:
    -- innerHUDs -> hudTexture -> snapHUDs -> shot.canvas.
    -- Therefore wrapping the current BattleState.drawHUDs cannot remove the
    -- white legacy HUD already captured by Dramaless.
    local function patchDramalessNow()
      local dramaHandle =
        type(mod.find) == "function" and mod.find("DRAMALESS_SHAPE") or nil
      local dramaLib =
        dramaHandle and dramaHandle.exports and dramaHandle.exports.lib
      if not (dramaLib and type(dramaLib.require) == "function") then
        hardHideDramalessInstalled = false
        return false
      end

      local okDrama, OverworldBattle =
        pcall(dramaLib.require, "OverworldBattle")
      if not okDrama or type(OverworldBattle) ~= "table" then
        hardHideDramalessInstalled = false
        return false
      end

      if type(OverworldBattle.hudTexture) == "function"
          and OverworldBattle.hudTexture ~= OverworldBattle.__enemyHpHudTextureWrapper then
        local previousHudTexture = OverworldBattle.hudTexture
        local function wrappedHudTexture(battle, slide)
          if hideRequested() then return nil end
          return previousHudTexture(battle, slide)
        end
        OverworldBattle.__enemyHpHudTextureWrapper = wrappedHudTexture
        OverworldBattle.hudTexture = wrappedHudTexture
      end

      if type(OverworldBattle.snapHUDs) == "function"
          and OverworldBattle.snapHUDs ~= OverworldBattle.__enemyHpSnapWrapper then
        local previousSnapHUDs = OverworldBattle.snapHUDs
        local function wrappedSnapHUDs(battle, shot)
          if hideRequested() then
            -- IMPORTANT: Dramaless stores this return value in session.snapped.
            -- false means "snap failed" and makes its BattleState:drawHUDs
            -- wrapper deliberately draw the old HUD in-frame as a fallback.
            -- We have intentionally handled the HUD by hiding it, so report
            -- success without drawing anything.
            return true
          end
          return previousSnapHUDs(battle, shot)
        end
        OverworldBattle.__enemyHpSnapWrapper = wrappedSnapHUDs
        OverworldBattle.snapHUDs = wrappedSnapHUDs
      end

      if type(OverworldBattle.drawHudPanels) == "function"
          and OverworldBattle.drawHudPanels ~= OverworldBattle.__enemyHpPanelsWrapper then
        local previousDrawHudPanels = OverworldBattle.drawHudPanels
        local function wrappedDrawHudPanels(battle, ...)
          if hideRequested() then return end
          return previousDrawHudPanels(battle, ...)
        end
        OverworldBattle.__enemyHpPanelsWrapper = wrappedDrawHudPanels
        OverworldBattle.drawHudPanels = wrappedDrawHudPanels
      end

      hardHideDramalessInstalled =
        OverworldBattle.hudTexture == OverworldBattle.__enemyHpHudTextureWrapper
        and OverworldBattle.snapHUDs == OverworldBattle.__enemyHpSnapWrapper
        and OverworldBattle.drawHudPanels == OverworldBattle.__enemyHpPanelsWrapper

      return hardHideDramalessInstalled
    end

    patchDramalessNow()

    mod.events:on("battle.started", function()
      patchDramalessNow()
    end, 100000)

    if type(mod.hooks.wrap) == "function" then
      pcall(function()
        mod.hooks:wrap("render.hud", function(next, game, viewport)
          patchDramalessNow()
          return next(game, viewport)
        end, 25000)
      end)
    end

    if mod.log and mod.log.info then
      mod.log:info("Enemy HP: hard original UI suppression + Dramaless compositor block installed")
    end
    return true
  end

  installHardHide()


  -- V11: hot-reload-safe final original-UI suppression ---------------------
  --
  -- Earlier test wrappers captured local option state. If a mod ZIP was hot
  -- reloaded, a surviving wrapper could keep the OLD closure and ignore the
  -- new menu value. V11 stores only a live predicate on the engine/module
  -- objects themselves; surviving wrappers therefore read the newest state.
  local function installFinalNativeSuppressor()
    local okBattle, BattleState = pcall(require, "src.battle.BattleState")
    if not okBattle or type(BattleState) ~= "table" then return false end

    BattleState.__enemyHpV11HideState = BattleState.__enemyHpV11HideState or {}
    BattleState.__enemyHpV11HideState.requested = hideRequested

    local state = BattleState.__enemyHpV11HideState

    if type(BattleState.drawHUDs) == "function"
        and BattleState.drawHUDs ~= BattleState.__enemyHpV11HudWrapper then
      local previous = BattleState.drawHUDs
      local function wrapper(self, ...)
        local requested = state.requested
        if requested and requested() then
          -- Hard stop at the OUTERMOST currently-active HUD method.
          -- Gen3 has its own screen-space panels, so native drawHUDs must not
          -- run at all while this compatibility mode is selected.
          return
        end
        return previous(self, ...)
      end
      BattleState.__enemyHpV11HudWrapper = wrapper
      BattleState.drawHUDs = wrapper
    end

    if type(BattleState.drawTextArea) == "function"
        and BattleState.drawTextArea ~= BattleState.__enemyHpV11TextWrapper then
      local previous = BattleState.drawTextArea
      local function wrapper(self, ...)
        local requested = state.requested
        if requested and requested() then return end
        return previous(self, ...)
      end
      BattleState.__enemyHpV11TextWrapper = wrapper
      BattleState.drawTextArea = wrapper
    end

    return true
  end

  local function installFinalDramalessSuppressor()
    local dramaHandle =
      type(mod.find) == "function" and mod.find("DRAMALESS_SHAPE") or nil
    local dramaLib =
      dramaHandle and dramaHandle.exports and dramaHandle.exports.lib
    if not (dramaLib and type(dramaLib.require) == "function") then return false end

    local ok, O = pcall(dramaLib.require, "OverworldBattle")
    if not ok or type(O) ~= "table" then return false end

    O.__enemyHpV11HideState = O.__enemyHpV11HideState or {}
    O.__enemyHpV11HideState.requested = hideRequested
    local state = O.__enemyHpV11HideState

    -- New marker names on purpose: even if test.9/10 wrappers survived a hot
    -- reload, V11 wraps the CURRENT functions from outside and wins first.
    if type(O.hudTexture) == "function"
        and O.hudTexture ~= O.__enemyHpV11HudTextureWrapper then
      local previous = O.hudTexture
      local function wrapper(...)
        local requested = state.requested
        if requested and requested() then return nil end
        return previous(...)
      end
      O.__enemyHpV11HudTextureWrapper = wrapper
      O.hudTexture = wrapper
    end

    if type(O.snapHUDs) == "function"
        and O.snapHUDs ~= O.__enemyHpV11SnapWrapper then
      local previous = O.snapHUDs
      local function wrapper(...)
        local requested = state.requested
        if requested and requested() then
          -- "Handled successfully": Dramaless' snapped() stays true and its
          -- own in-frame native-HUD fallback is suppressed.
          return true
        end
        return previous(...)
      end
      O.__enemyHpV11SnapWrapper = wrapper
      O.snapHUDs = wrapper
    end

    if type(O.drawHudPanels) == "function"
        and O.drawHudPanels ~= O.__enemyHpV11PanelsWrapper then
      local previous = O.drawHudPanels
      local function wrapper(...)
        local requested = state.requested
        if requested and requested() then return end
        return previous(...)
      end
      O.__enemyHpV11PanelsWrapper = wrapper
      O.drawHudPanels = wrapper
    end

    return
      O.hudTexture == O.__enemyHpV11HudTextureWrapper
      and O.snapHUDs == O.__enemyHpV11SnapWrapper
      and O.drawHudPanels == O.__enemyHpV11PanelsWrapper
  end

  local function refreshFinalSuppressors()
    installFinalNativeSuppressor()
    if installFinalDramalessSuppressor() then
      hardHideDramalessInstalled = true
    end
  end

  refreshFinalSuppressors()

  -- Re-run after everyone has received battle.started. Priority -100000 makes
  -- this listener the last one in the normal descending-priority event chain.
  mod.events:on("battle.started", function()
    refreshFinalSuppressors()
  end, -100000)

  -- And once more immediately before HUD composition. If another mod replaced
  -- a method during the battle, this re-wraps that current method.
  if type(mod.hooks.wrap) == "function" then
    pcall(function()
      mod.hooks:wrap("render.hud", function(next, game, viewport)
        refreshFinalSuppressors()
        return next(game, viewport)
      end, 30000)
    end)
  end


  -- V12: definitive complete native battle UI kill switch -----------------
  --
  -- HIDE ORIGINAL BATTLE UI means exactly that: no Gen1 battle chrome at all.
  -- This includes:
  --   * enemy status HUD
  --   * player status HUD
  --   * battle text boxes
  --   * FIGHT / PKMN / ITEM / RUN command box
  --   * move selection / TYPE / PP boxes
  --
  -- Gen3/Modern UI are separate render.hud presenters and remain untouched.

  local function v12HideRequested()
    return hideOriginalBattleUI
      and (compatMode == GEN3 or compatMode == MODERN or compatMode == AUTO)
  end

  local function installV12NativeKillSwitch()
    local okBattle, BattleState = pcall(require, "src.battle.BattleState")
    if not okBattle or type(BattleState) ~= "table" then return false end

    BattleState.__enemyHpV12State = BattleState.__enemyHpV12State or {}
    BattleState.__enemyHpV12State.requested = v12HideRequested
    local state = BattleState.__enemyHpV12State

    -- Status bars / HP HUDs.
    if type(BattleState.drawHUDs) == "function"
        and BattleState.drawHUDs ~= BattleState.__enemyHpV12DrawHUDs then
      local previous = BattleState.drawHUDs
      local function wrapper(self, ...)
        local requested = state.requested
        if requested and requested() then return end
        return previous(self, ...)
      end
      BattleState.__enemyHpV12DrawHUDs = wrapper
      BattleState.drawHUDs = wrapper
    end

    -- Text box, command box, move-selection boxes, TYPE/PP etc.
    if type(BattleState.drawTextArea) == "function"
        and BattleState.drawTextArea ~= BattleState.__enemyHpV12DrawTextArea then
      local previous = BattleState.drawTextArea
      local function wrapper(self, ...)
        local requested = state.requested
        if requested and requested() then return end
        return previous(self, ...)
      end
      BattleState.__enemyHpV12DrawTextArea = wrapper
      BattleState.drawTextArea = wrapper
    end

    return true
  end

  local function installV12DramalessKillSwitch()
    local dramaHandle =
      type(mod.find) == "function" and mod.find("DRAMALESS_SHAPE") or nil
    local dramaLib =
      dramaHandle and dramaHandle.exports and dramaHandle.exports.lib
    if not (dramaLib and type(dramaLib.require) == "function") then return false end

    local ok, O = pcall(dramaLib.require, "OverworldBattle")
    if not ok or type(O) ~= "table" then return false end

    O.__enemyHpV12State = O.__enemyHpV12State or {}
    O.__enemyHpV12State.requested = v12HideRequested
    local state = O.__enemyHpV12State

    -- Critical Dramaless seam: hudTexture() owns a private `innerHUDs`
    -- captured BEFORE later BattleState wrappers. Replace that upvalue with
    -- a live gate so Dramaless can never resurrect the two old status bars.
    if type(O.hudTexture) == "function"
        and debug and debug.getupvalue and debug.setupvalue then
      local i = 1
      while true do
        local name, value = debug.getupvalue(O.hudTexture, i)
        if not name then break end
        if name == "innerHUDs" and type(value) == "function" then
          -- Preserve the real captured renderer once, even across hot reload.
          if not O.__enemyHpV12OriginalInnerHUDs then
            O.__enemyHpV12OriginalInnerHUDs = value
          end
          local original = O.__enemyHpV12OriginalInnerHUDs
          local function gatedInnerHUDs(...)
            local requested = state.requested
            if requested and requested() then return end
            return original(...)
          end
          debug.setupvalue(O.hudTexture, i, gatedInnerHUDs)
          O.__enemyHpV12InnerHUDGate = gatedInnerHUDs
          break
        end
        i = i + 1
      end
    end

    -- The captured HUD texture must still count as "successfully handled"
    -- while hidden, otherwise Dramaless deliberately falls back to drawing
    -- the native HUD directly in the GB frame.
    if type(O.snapHUDs) == "function"
        and O.snapHUDs ~= O.__enemyHpV12SnapHUDs then
      local previous = O.snapHUDs
      local function wrapper(...)
        local requested = state.requested
        if requested and requested() then return true end
        return previous(...)
      end
      O.__enemyHpV12SnapHUDs = wrapper
      O.snapHUDs = wrapper
    end

    -- Frosted/glass native HUD plates also belong to the old HUD.
    if type(O.drawHudPanels) == "function"
        and O.drawHudPanels ~= O.__enemyHpV12DrawHudPanels then
      local previous = O.drawHudPanels
      local function wrapper(...)
        local requested = state.requested
        if requested and requested() then return end
        return previous(...)
      end
      O.__enemyHpV12DrawHudPanels = wrapper
      O.drawHudPanels = wrapper
    end

    return true
  end

  local function refreshV12KillSwitch()
    installV12NativeKillSwitch()
    installV12DramalessKillSwitch()
  end

  refreshV12KillSwitch()

  -- Reassert after battle setup and before final HUD composition so this wins
  -- over load order, hot reload and mods that replace BattleState methods.
  mod.events:on("battle.started", function()
    refreshV12KillSwitch()
  end, -200000)

  if type(mod.hooks.wrap) == "function" then
    pcall(function()
      mod.hooks:wrap("render.hud", function(next, game, viewport)
        refreshV12KillSwitch()
        return next(game, viewport)
      end, 35000)
    end)
  end

  -- Gen 3 Inspired UI direct panel integration ----------------------------
  local gen3DirectInstalled = false
  local gen3DirectReason = "not attempted"
  local gen3HideBridgeInstalled = false
  local gen3HideBridgeReason = "not attempted"

  local function directUpvalue(fn, wanted)
    if not (debug and debug.getupvalue) or type(fn) ~= "function" then return nil end
    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if not name then return nil end
      if name == wanted then return fn, i, value end
      i = i + 1
    end
  end

  local function gen3Figure(battle)
    if not enabled or not battle then return nil end
    local enemy = battle.enemy
    local max = enemy and enemy.mon and enemy.mon.stats and enemy.mon.stats.hp
    if not max or max <= 0 then return nil end
    local hp = math.max(0, math.min(shownHP(enemy), max))
    if format == PERCENT then
      local pct = hp <= 0 and 0 or math.max(1, math.floor(hp * 100 / max))
      return ("%d%%"):format(pct)
    end
    return ("%d / %d"):format(hp, max)
  end

  local function installGen3Direct()
    if not (debug and debug.getupvalue and debug.setupvalue) then
      gen3DirectReason = "debug upvalue API unavailable"
      return false
    end

    local handle = type(mod.find) == "function" and mod.find("gen3_battle_ui") or nil
    if not handle then
      gen3DirectReason = "gen3_battle_ui not active"
      return false
    end

    local version = tostring(handle.version or "")
    if version ~= "" and version ~= "1.3" then
      gen3DirectReason = "unsupported Gen3 UI version " .. version
      return false
    end

    local okRuntime, Runtime = pcall(require, "src.mods.Runtime")
    if not okRuntime or not Runtime or not Runtime.hooks then
      gen3DirectReason = "Gen1Recomp Runtime hook bus unavailable"
      return false
    end

    local chain = Runtime.hooks.chains and Runtime.hooks.chains["render.hud"]
    if type(chain) ~= "table" then
      gen3DirectReason = "render.hud chain unavailable"
      return false
    end

    local gen3Callback
    for _, entry in ipairs(chain) do
      if entry.owner == "gen3_battle_ui"
          and entry.priority == 10000
          and type(entry.callback) == "function" then
        gen3Callback = entry.callback
        break
      end
    end
    if not gen3Callback then
      gen3DirectReason = "Gen3 render.hud callback not found"
      return false
    end

    local _, _, renderHudHook = directUpvalue(gen3Callback, "renderHudHook")
    if type(renderHudHook) ~= "function" then
      gen3DirectReason = "Gen3 renderHudHook upvalue not found"
      return false
    end

    -- Enemy HP no longer drives Gen3's own hideNativeBattleUI option.
    -- The independent hard-hide layer above owns original-HUD suppression.
    gen3HideBridgeInstalled = false
    gen3HideBridgeReason = "unused: independent Enemy HP hard suppression"

    local owner, index, originalEnemyHUD = directUpvalue(renderHudHook, "drawEnemyHUD")
    if not owner or type(originalEnemyHUD) ~= "function" then
      gen3DirectReason = "Gen3 drawEnemyHUD upvalue not found"
      return false
    end

    -- Reuse Gen3's own private primitives so the replacement remains
    -- visually identical to its native enemy panel. We intentionally replace
    -- drawEnemyHUD as a whole here because simply drawing after the original
    -- cannot extend the beige plate itself.
    local _, _, gen3PrintText = directUpvalue(originalEnemyHUD, "printText")
    local _, _, gen3EnemyVisible = directUpvalue(originalEnemyHUD, "enemyVisible")
    local _, _, gen3DrawPlate = directUpvalue(originalEnemyHUD, "drawPlate")
    local _, _, gen3DisplayName = directUpvalue(originalEnemyHUD, "displayName")
    local _, _, gen3DrawStyledHP = directUpvalue(originalEnemyHUD, "drawStyledHP")
    local _, _, gen3StatusText = directUpvalue(originalEnemyHUD, "statusText")
    local _, _, gen3StatusColor = directUpvalue(originalEnemyHUD, "statusColor")

    if type(gen3PrintText) ~= "function"
        or type(gen3EnemyVisible) ~= "function"
        or type(gen3DrawPlate) ~= "function"
        or type(gen3DisplayName) ~= "function"
        or type(gen3DrawStyledHP) ~= "function"
        or type(gen3StatusText) ~= "function"
        or type(gen3StatusColor) ~= "function" then
      gen3DirectReason = "Gen3 v1.3 enemy HUD primitives not found"
      return false
    end

    local textColor = {0.11, 0.12, 0.11, 1}

    local function enemyHUDWithNumbers(battle, s)
      if not gen3EnemyVisible(battle) then return end

      local margin = 7*s
      -- Gen3 v1.3 native enemy plate is 112*s x 31*s.
      -- Enemy HP adds exactly one extra 7*s row underneath the numeric HP
      -- line, producing breathing room before the lower border.
      local w, h = 112*s, 38*s
      local x, y = margin, margin
      local b = battle.enemy

      gen3DrawPlate(x, y, w, h, s)

      gen3PrintText(gen3DisplayName(b), x+7*s, y+2.0*s, 6.4*s, textColor)
      gen3PrintText("Lv."..tostring((b.mon and b.mon.level) or "?"),
                    x+64*s, y+2.2*s, 5.5*s, textColor, "right", 39*s)

      gen3DrawStyledHP(x+7*s, y+14.5*s, 97*s, 7*s, b)

      local status = gen3StatusText(battle, b)
      if status then
        local r,g,bb,aa = gen3StatusColor(status)
        gen3PrintText(status, x+8*s, y+22.0*s, 3.8*s, {r,g,bb,aa})
      end

      if enabled and (compatMode == GEN3 or compatMode == AUTO) then
        local figure = gen3Figure(battle)
        if figure then
          gen3PrintText(figure,
                        x+51*s, y+21.8*s, 4.4*s,
                        textColor, "right", 53*s)
        end
      end
    end

    debug.setupvalue(owner, index, enemyHUDWithNumbers)
    gen3DirectInstalled = true
    gen3DirectReason = "Gen3 v1.3 enemy plate extended by one row"
    if mod.log and mod.log.info then
      mod.log:info("Enemy HP: Gen3 v1.3 enemy panel extended with numeric HP row")
    end
    return true
  end

  installGen3Direct()

  local drawing = false
  local vanillaDraw = Font.draw

  Font.draw = function(text, x, y)
    -- Do not let any original Gen1 battle glyph reach the frame while the
    -- complete hide switch is active. Gen3 uses its own screen-space
    -- printText/love.graphics renderer and is unaffected by this.
    if current and hideOriginalBattleUI and compatMode ~= NATIVE then
      return
    end

    local result = vanillaDraw(text, x, y)

    if drawing or x ~= ANCHOR_X or y ~= ANCHOR_Y or not current then
      return result
    end

    -- The foe level/status anchor is the strongest possible proof that the
    -- source/native HUD survived this frame. AUTO/MODERN use this to avoid duplicates.
    anchorSeenThisFrame = true
    anchorEverSeen = true

    if compatMode == GEN3 and gen3DirectInstalled then
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

  -- Gen 3 UI integration -------------------------------------------------
  --
  -- Do not hard-code HighDrexler's panel coordinates. During Gen 3 UI's own
  -- render.hud pass we temporarily observe text draws. Its player panel already
  -- prints the exact current/max HP row we want. By pairing that row with the
  -- nearest "HP" label, and then applying the same relative geometry to the
  -- *other* HP label (the enemy panel), Enemy HP inherits Gen 3 UI's current
  -- font, color, spacing, scaling and responsive placement automatically.
  --
  -- Nothing in the foreign mod is mutated and no private function is called.
  local function hpPairText(battler)
    local mon = battler and battler.mon
    local max = mon and mon.stats and mon.stats.hp
    if not max or max <= 0 then return nil end
    return shownHP(battler), max
  end

  local function compactText(value)
    return tostring(value or ""):gsub("%s+", "")
  end

  local function captureGen3Hud(next, game, viewport)
    local g = love and love.graphics
    if not (g and g.print and current and current.player and current.enemy) then
      return next(game, viewport), false
    end

    local php, pmax = hpPairText(current.player)
    if not php then return next(game, viewport), false end
    local playerCompact = tostring(php) .. "/" .. tostring(pmax)

    local hpLabels, playerNumber = {}, nil
    local originalPrint, originalPrintf = g.print, g.printf

    local function snapshot(kind, text, x, y, ...)
      local str = tostring(text or "")
      local font = g.getFont and g.getFont() or nil
      local r, gg, b, a
      if g.getColor then r, gg, b, a = g.getColor() end
      local rec = {
        kind = kind, raw = str, x = x or 0, y = y or 0,
        extra = { ... }, font = font, color = r and {r, gg, b, a} or nil,
      }
      if str:upper():gsub("%s+", "") == "HP" then
        hpLabels[#hpLabels + 1] = rec
      elseif compactText(str) == playerCompact then
        playerNumber = rec
      end
    end

    g.print = function(text, x, y, ...)
      snapshot("print", text, x, y, ...)
      return originalPrint(text, x, y, ...)
    end
    if originalPrintf then
      g.printf = function(text, x, y, ...)
        snapshot("printf", text, x, y, ...)
        return originalPrintf(text, x, y, ...)
      end
    end

    local ok, result = pcall(next, game, viewport)
    g.print = originalPrint
    if originalPrintf then g.printf = originalPrintf end
    if not ok then error(result) end

    if not playerNumber or #hpLabels < 2 then return result, false end

    -- The player's HP label is the one closest to its own numeric row, with a
    -- preference for labels above that row. The remaining farthest label is the
    -- enemy panel's HP label.
    local playerLabel, playerDist
    for _, label in ipairs(hpLabels) do
      local dx = playerNumber.x - label.x
      local dy = playerNumber.y - label.y
      local penalty = dy < 0 and 100000 or 0
      local dist = dx * dx + dy * dy + penalty
      if not playerDist or dist < playerDist then
        playerLabel, playerDist = label, dist
      end
    end
    if not playerLabel then return result, false end

    local enemyLabel, enemyDist
    for _, label in ipairs(hpLabels) do
      if label ~= playerLabel then
        local dx = label.x - playerLabel.x
        local dy = label.y - playerLabel.y
        local dist = dx * dx + dy * dy
        if not enemyDist or dist > enemyDist then
          enemyLabel, enemyDist = label, dist
        end
      end
    end
    if not enemyLabel then return result, false end

    local figure = readout(current)
    if not figure then return result, false end

    -- Exact-number mode intentionally copies Gen 3 UI's own spaces around '/'.
    if format == EXACT then
      local left, right = playerNumber.raw:match("^(%s*%d+%s*)/(%s*%d+%s*)$")
      if left and right then
        local before = left:match("%d+(%s*)$") or ""
        local after = right:match("^(%s*)") or ""
        local ehp, emax = hpPairText(current.enemy)
        figure = tostring(ehp) .. before .. "/" .. after .. tostring(emax)
      end
    end

    local font = playerNumber.font
    local dx = playerNumber.x - playerLabel.x
    local dy = playerNumber.y - playerLabel.y
    local drawX = enemyLabel.x + dx
    local drawY = enemyLabel.y + dy

    -- If Gen 3 used plain print, preserve the player's numeric row's right edge
    -- relative to its HP label. This makes 9 / 32, 32 / 32 and 352 / 705 line
    -- up the same way instead of walking left/right as digit count changes.
    if playerNumber.kind == "print" and font and font.getWidth then
      local playerRightOffset = dx + font:getWidth(playerNumber.raw)
      drawX = enemyLabel.x + playerRightOffset - font:getWidth(figure)
    end

    local oldFont = g.getFont and g.getFont() or nil
    local oldColor = g.getColor and { g.getColor() } or nil
    if font and g.setFont then g.setFont(font) end
    if playerNumber.color and g.setColor then
      g.setColor(playerNumber.color[1], playerNumber.color[2],
                 playerNumber.color[3], playerNumber.color[4])
    end

    if playerNumber.kind == "printf" and originalPrintf then
      originalPrintf(figure, drawX, drawY, table.unpack(playerNumber.extra))
    else
      originalPrint(figure, drawX, drawY, table.unpack(playerNumber.extra))
    end

    if oldColor and g.setColor then g.setColor(table.unpack(oldColor)) end
    if oldFont and g.setFont then g.setFont(oldFont) end
    return result, true
  end

  -- Generic compatibility fallback retained for Modern UI and as a last-resort
  -- safety net if a future Gen 3 UI version changes its text rendering contract.
  local function drawOverlay(figure, viewport, flavor)
    local loveg = love and love.graphics
    if not (loveg and loveg.print and loveg.rectangle) then return false end

    local oldFont = loveg.getFont and loveg.getFont() or nil
    local oldR, oldG, oldB, oldA
    if loveg.getColor then oldR, oldG, oldB, oldA = loveg.getColor() end

    local scale = (viewport and viewport.scale) or 1
    local gx = (viewport and viewport.gameX) or 0
    local gy = (viewport and viewport.gameY) or 0
    local gw = (viewport and viewport.gameWidth) or 160 * scale
    local gh = (viewport and viewport.gameHeight) or 144 * scale
    local x = gx + math.max(8, gw * 0.055)
    local y = gy + math.max(8, gh * (flavor == "modern" and 0.13 or 0.18))

    local label = "HP " .. figure
    local font = oldFont
    local tw = font and font.getWidth and font:getWidth(label) or (#label * 8)
    local th = font and font.getHeight and font:getHeight() or 12
    local padX, padY = 6, 3
    loveg.setColor(0, 0, 0, 0.72)
    loveg.rectangle("fill", x - padX, y - padY, tw + padX * 2, th + padY * 2, 3, 3)
    loveg.setColor(1, 1, 1, 1)
    loveg.print(label, x, y)

    if oldR then loveg.setColor(oldR, oldG, oldB, oldA) end
    if oldFont and loveg.setFont then loveg.setFont(oldFont) end
    return true
  end

  local overlayInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    local ok = pcall(function()
      -- IMPORTANT: Gen 3 Inspired UI v1.3 registers its battle render.hud hook
      -- at priority 10000 (and its Dex HUD at 11000). Hook chains execute higher
      -- priorities first. We therefore sit at 12000 so next() contains Gen3's
      -- actual screen-space HUD draw. A lower priority can only see native draws
      -- underneath Gen3 and can never inject into the panel Gen3 paints after next().
      mod.hooks:wrap("render.hud", function(next, game, viewport)
        battleFrames = current and (battleFrames + 1) or 0
        local foreign, flavor = foreignUiPresent()

        -- Gen3 v1.3 is integrated inside its own drawEnemyHUD function.
        local result = next(game, viewport)
        local gen3Integrated = gen3DirectInstalled and flavor == "gen3"

        if current and enabled and compatMode ~= NATIVE and enemyHudExpected(current) then
          -- AUTO overlays only when native HUD vanished. For Gen 3, successful
          -- in-panel integration wins and suppresses the old floating badge.
          local shouldOverlay =
            (flavor == "modern")
            and (compatMode == MODERN or compatMode == AUTO)
            and foreign
            and not anchorSeenThisFrame
          if flavor == "gen3" then shouldOverlay = false end

          if shouldOverlay then
            local figure = readout(current)
            if figure then drawOverlay(figure, viewport, flavor) end
          end
        end

        anchorSeenThisFrame = false
        return result
      end, 12000)
    end)
    overlayInstalled = ok
    if not ok then
      mod.log:warn("render.hud compatibility fallback could not be installed")
    end
  end

  mod.exports.readout = readout
  mod.exports.ruleMoved = function() return ruleMoved end
  mod.exports.compat = {
    version = 5,
    gen3Integration = "direct-drawEnemyHUD-replacement-extended-plate",
    gen3DirectInstalled = function() return gen3DirectInstalled end,
    gen3DirectReason = function() return gen3DirectReason end,
    gen3HideBridgeInstalled = function() return gen3HideBridgeInstalled end,
    gen3HideBridgeReason = function() return gen3HideBridgeReason end,
    hideOriginalBattleUI = function() return hideOriginalBattleUI end,
    hardHideInstalled = function() return hardHideInstalled end,
    hardHideDramalessInstalled = function() return hardHideDramalessInstalled end,
    hardHideReason = function() return hardHideReason end,
    finalNativeSuppressor = installFinalNativeSuppressor,
    finalDramalessSuppressor = installFinalDramalessSuppressor,
    v12NativeKillSwitch = installV12NativeKillSwitch,
    v12DramalessKillSwitch = installV12DramalessKillSwitch,
    primitiveHudKill = function()
      return hideOriginalBattleUI and compatMode ~= NATIVE
    end,
    hpBarPrimitiveKill = function()
      return current ~= nil and hideOriginalBattleUI and compatMode ~= NATIVE
    end,
    hpBarIdentityPatchCount = function() return hpBarIdentityPatchCount end,
    patchCapturedHPBarReferences = patchCapturedHPBarReferences,
    compatibilityMode = function() return compatMode end,
    renderHookPriority = 12000,
    overlayInstalled = function() return overlayInstalled end,
    nativeAnchorSeen = function() return anchorEverSeen end,
    enemyHudExpected = enemyHudExpected,
    generation = 1,
    backend = "gen1",
    goldNativeInstalled = function() return false end,
    goldOverlayInstalled = function() return false end,
    goldOverlayPriority = 200,
    goldReadoutSource = function() return nil end,
    goldLastVisible = function() return false end,
    goldLastHp = function() return nil end,
    goldLastMaxHp = function() return nil end,
    goldReplacementUi = function() return nil end,
    goldFallbackReason = function() return nil end,
    goldLastDrawError = function() return nil end,
  }
end
