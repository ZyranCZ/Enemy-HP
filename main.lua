-- Enemy HP Readout for Gen1Recomp
-- v2.3.2 - public Mod API migration for Gen1Recomp v0.1.86
--
-- The native row is drawn through battle.overlay, a shared Gen 1 / Gold
-- draw seam. Replacement-UI modes are drawn after their render.hud pass.
-- The original UI hide option uses the engine's public visibility hooks.

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

local function clamp(value, low, high)
  value = tonumber(value) or low
  if value < low then return low end
  if value > high then return high end
  return value
end

local function formatReadout(hp, maxHp, style, spaced)
  maxHp = tonumber(maxHp)
  if not maxHp or maxHp <= 0 then return nil end
  hp = clamp(hp, 0, maxHp)
  if style == PERCENT then
    local pct = hp <= 0 and 0 or math.max(1, math.floor(hp * 100 / maxHp))
    return ("%d%%"):format(pct)
  end
  if spaced then return ("%d / %d"):format(hp, maxHp) end
  return ("%d/%d"):format(hp, maxHp)
end

return function(mod)
  local Font = mod.ui.Font

  mod.content.font:register("enemy_hp_percent", {
    image = mod.assets:path("assets/percent.png"),
    base = 0x140,
    glyphsPerRow = 1,
  })
  mod.content.font:register("charmap:enemy_hp_percent", {
    seq = "%",
    code = 0x140,
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
    enabled = mod.options:get("enabled") ~= false
    format = mod.options:get("format") == PERCENT and PERCENT or EXACT
    local choice = mod.options:get("compat_fix")
    if choice == AUTO or choice == GEN3 or choice == MODERN or choice == NATIVE then
      compatMode = choice
    else
      compatMode = NATIVE
    end
    hideOriginalBattleUI =
      mod.options:get("experimental_battle_ui") == HIDE_OG_UI
  end

  readOptions()
  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod == mod.id then readOptions() end
  end)

  -- Optional dependencies load first. A handle exists only when the other
  -- mod is present, active for this game, and loaded successfully.
  local gen3Handle = mod.find("gen3_battle_ui")
  local modernHandle = mod.find("gen1_modern_ui")

  local function resolvedCompatibilityMode()
    if compatMode == AUTO then
      if gen3Handle then return GEN3 end
      if modernHandle then return MODERN end
      return NATIVE
    end
    if compatMode == GEN3 and not gen3Handle then return NATIVE end
    if compatMode == MODERN and not modernHandle then return NATIVE end
    return compatMode
  end

  local function isGen1Battle(state)
    return type(state) == "table"
      and type(state.enemy) == "table"
      and type(state.player) == "table"
      and type(state.enemy.mon) == "table"
      and state.shownHp == nil
  end

  local function isGoldBattle(state)
    return type(state) == "table"
      and type(state.battle) == "table"
      and (type(state.shownHp) == "table"
        or type(state.shownMon) == "table"
        or state.showEnemyHud ~= nil)
  end

  local function isBattleScreen(state)
    return isGen1Battle(state) or isGoldBattle(state)
  end

  local function callBooleanMethod(owner, name, ...)
    local fn = owner and owner[name]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, owner, ...)
    if ok then return value and true or false end
    return nil
  end

  local function gen1View(state)
    if not isGen1Battle(state) then return nil end
    local enemy = state.enemy
    local mon = enemy.mon
    local maxHp = mon and mon.stats and mon.stats.hp
    if not maxHp or maxHp <= 0 then return nil end
    local hp = enemy.shownHP
    local source = "enemy.shownHP"
    if hp == nil then
      hp = mon.hp or 0
      source = "enemy.mon.hp"
    end

    local growing = callBooleanMethod(state, "growInScale", enemy)
    local baseVisible = not state.blankForAskName
      and not state.showEnemyTrainer
      and not state.enemySendingOut
      and not state.introBalls
      and (tonumber(state.introSlide) or 0) == 0
      and not growing

    return {
      generation = 1,
      state = state,
      hp = clamp(hp, 0, maxHp),
      maxHp = maxHp,
      source = source,
      nativeVisible = baseVisible and not enemy.fainted,
      replacementBaseVisible = baseVisible,
      logicalFainted = enemy.fainted == true or (tonumber(mon.hp) or 0) <= 0,
    }
  end

  local function goldDisplayedEnemy(state)
    local shown = state.shownMon and state.shownMon.enemy
    if shown ~= nil then return shown, "shownMon.enemy" end
    local live = state.battle and state.battle.enemy
    if live ~= nil then return live, "battle.enemy" end
    return nil, "none"
  end

  local function goldView(state)
    if not isGoldBattle(state) then return nil end
    local mon, monSource = goldDisplayedEnemy(state)
    if not mon then return nil end
    local maxHp = mon.maxHp or (mon.stats and mon.stats.hp)
    if not maxHp or maxHp <= 0 then return nil end

    local hp = state.shownHp and state.shownHp.enemy
    local hpSource = "shownHp.enemy"
    if hp == nil and type(state.hudHp) == "function" then
      local ok, shown = pcall(state.hudHp, state, mon, "enemy")
      if ok then hp = shown end
      if hp ~= nil then hpSource = "hudHp(enemy)" end
    end
    if hp == nil then
      hp = mon.hp or 0
      hpSource = "displayed enemy hp"
    end

    local cleared = callBooleanMethod(state, "hudCleared", "enemy")
    local nativeVisible = state.showEnemyHud == true
      and state.showEnemyTrainer ~= true
      and cleared ~= true
    local replacementVisible = state.showEnemyHud == true
      and state.showEnemyTrainer ~= true
      and state.phase ~= "moves"
      and state.phase ~= "choose-forget"

    return {
      generation = 2,
      state = state,
      hp = clamp(hp, 0, maxHp),
      maxHp = maxHp,
      source = hpSource .. " + " .. monSource,
      nativeVisible = nativeVisible,
      replacementBaseVisible = replacementVisible,
      logicalFainted = (tonumber(mon.hp) or 0) <= 0,
    }
  end

  local function viewFor(state)
    return gen1View(state) or goldView(state)
  end

  -- Replacement UIs should keep their enemy plate through the visible lethal
  -- drain, including one complete 0 HP frame. Native UI follows the cart and
  -- clears its own plate as soon as the faint is committed.
  local lethalState, lethalZeroFrames
  local function replacementVisible(view)
    if not (view and view.replacementBaseVisible) then
      if view and lethalState == view.state then
        lethalState, lethalZeroFrames = nil, 0
      end
      return false
    end
    if not view.logicalFainted then
      lethalState, lethalZeroFrames = nil, 0
      return true
    end
    if view.hp > 0 then
      lethalState, lethalZeroFrames = view.state, 1
      return true
    end
    if lethalState == view.state and (lethalZeroFrames or 0) > 0 then
      lethalZeroFrames = lethalZeroFrames - 1
      return true
    end
    return false
  end

  local function readout(state, spaced)
    if not enabled then return nil end
    local view = viewFor(state)
    if not view then return nil end
    return formatReadout(view.hp, view.maxHp, format, spaced), view
  end

  local function withGraphics(draw)
    local G = love and love.graphics
    if not G then return false, "graphics unavailable" end
    local pushed = false
    if type(G.push) == "function" and type(G.pop) == "function" then
      local ok = pcall(G.push, "all")
      if not ok then ok = pcall(G.push) end
      pushed = ok and true or false
    end
    local oldColor = type(G.getColor) == "function" and { G.getColor() } or nil
    local oldFont = type(G.getFont) == "function" and G.getFont() or nil
    local ok, err = pcall(draw, G)
    if pushed then
      pcall(G.pop)
    else
      if oldColor and type(G.setColor) == "function" then
        pcall(G.setColor, unpack(oldColor))
      end
      if oldFont and type(G.setFont) == "function" then
        pcall(G.setFont, oldFont)
      end
    end
    if not ok then return false, tostring(err) end
    return true
  end

  local function tileTextWidth(text)
    if type(Font.width) == "function" then
      local ok, width = pcall(Font.width, text)
      if ok and type(width) == "number" then return width end
    end
    return #tostring(text or "") * 8
  end

  local function drawNativeRow(figure, generation)
    return withGraphics(function(G)
      assert(type(G.setColor) == "function" and type(G.rectangle) == "function",
        "graphics primitives unavailable")
      -- Clear the original rule row before moving the number down one tile.
      G.setColor(1, 1, 1, 1)
      G.rectangle("fill", 8, 24, 88, 16)
      G.setColor(0, 0, 0, 1)

      if generation == 2 then
        -- Gold's $73/$77/$76/$6f player-frame tiles are not the same art as
        -- Gen 1's frame: the side is four pixels wide and the bottom rule is
        -- on scanline 6.  Draw their exact horizontal mirror.  The first
        -- rectangle continues the original enemy $6d side at x=9..12, so the
        -- upper tile beside HP and this moved lower tile form one clean stem.
        G.rectangle("fill", 9, 24, 4, 11)
        G.rectangle("fill", 9, 35, 7, 2)
        G.rectangle("fill", 10, 37, 6, 1)
        G.rectangle("fill", 80, 35, 2, 1)
        G.rectangle("fill", 80, 36, 4, 1)
        G.rectangle("fill", 80, 37, 6, 1)
        G.rectangle("fill", 11, 38, 77, 1)
      else
        -- Gen 1: reproduce the player's native frame pixel-for-pixel with its
        -- horizontal direction mirrored: a two-pixel stem, two-scanline rule
        -- and the same four-step half-arrow at the far end.
        G.rectangle("fill", 11, 24, 2, 11)
        G.rectangle("fill", 80, 33, 2, 1)
        G.rectangle("fill", 80, 34, 4, 1)
        G.rectangle("fill", 11, 35, 75, 1)
        G.rectangle("fill", 12, 36, 76, 1)
      end
      Font.draw(figure, math.max(8, 80 - tileTextWidth(figure)), 24)
    end)
  end

  local screenFonts = {}
  local function screenFont(size, G)
    local px = math.max(6, math.floor((tonumber(size) or 8) + 0.5))
    if screenFonts[px] then return screenFonts[px] end
    if type(G.newFont) == "function" and Font.PLAINPIXEL then
      local ok, font = pcall(G.newFont, Font.PLAINPIXEL, px, "normal")
      if ok and font then
        if type(font.setFilter) == "function" then
          pcall(font.setFilter, font, "linear", "linear")
        end
        screenFonts[px] = font
        return font
      end
    end
    return type(G.getFont) == "function" and G.getFont() or nil
  end

  local function gen3Scale(G, viewport)
    local sw, sh
    if type(G.getDimensions) == "function" then sw, sh = G.getDimensions() end
    sw = sw or (viewport and viewport.width) or 430
    sh = sh or (viewport and viewport.height) or 245
    local raw = math.min(sw / 430, sh / 245)
    if raw <= 4.5 then return math.max(2.85, math.min(raw, 3.85)) end
    return math.max(3.85, math.min(3.85 + (raw - 4.5) * 0.72, 7.0))
  end

  local function drawGen3Readout(view, viewport)
    local figure = formatReadout(view.hp, view.maxHp, format, true)
    if not figure then return false end
    return withGraphics(function(G)
      assert(type(G.setColor) == "function", "setColor unavailable")
      local scale = gen3Scale(G, viewport)
      local font = screenFont(4.75 * scale, G)
      if font and type(G.setFont) == "function" then G.setFont(font) end
      local x, y = 7 * scale, 7 * scale
      local tx, ty, tw = x + 51 * scale, y + 24.25 * scale, 53 * scale
      if type(G.printf) == "function" then
        G.setColor(0.14, 0.16, 0.13, 0.24)
        G.printf(figure, tx + 1, ty + 1, tw, "right")
        G.setColor(0.11, 0.12, 0.11, 1)
        G.printf(figure, tx, ty, tw, "right")
      elseif type(G.print) == "function" then
        G.setColor(0.11, 0.12, 0.11, 1)
        G.print(figure, tx, ty)
      else
        error("text drawing unavailable")
      end
    end)
  end

  local function drawModernReadout(view, viewport)
    local figure = formatReadout(view.hp, view.maxHp, format, false)
    if not figure then return false end
    return withGraphics(function(G)
      assert(type(G.print) == "function" and type(G.rectangle) == "function",
        "screen text primitives unavailable")
      local scale = (viewport and viewport.scale) or 1
      local gx = (viewport and viewport.gameX) or 0
      local gy = (viewport and viewport.gameY) or 0
      local gw = (viewport and viewport.gameWidth) or 160 * scale
      local gh = (viewport and viewport.gameHeight) or 144 * scale
      local font = screenFont(math.max(8, 4.5 * scale), G)
      if font and type(G.setFont) == "function" then G.setFont(font) end
      local label = "HP " .. figure
      local x = gx + math.max(8, gw * 0.055)
      local y = gy + math.max(8, gh * 0.13)
      local tw = font and type(font.getWidth) == "function"
        and font:getWidth(label) or #label * 8
      local th = font and type(font.getHeight) == "function"
        and font:getHeight() or 12
      local padX, padY = 6, 3
      G.setColor(0, 0, 0, 0.72)
      G.rectangle("fill", x - padX, y - padY,
        tw + padX * 2, th + padY * 2, 3, 3)
      G.setColor(1, 1, 1, 1)
      G.print(label, x, y)
    end)
  end

  local lastBattle, lastView, lastDrawBackend, lastDrawError
  local nativeRowDrawn = false
  local overlayInstalled, visibilityHooksInstalled = false, false

  mod.hooks:wrap("battle.overlay", function(next, state, ...)
    local result = next(state, ...)
    lastBattle = state
    lastView = viewFor(state)
    if lastView then
      lastView.replacementVisible = replacementVisible(lastView)
    end
    lastDrawError = nil

    if enabled and resolvedCompatibilityMode() == NATIVE
        and lastView and lastView.nativeVisible then
      local figure = formatReadout(lastView.hp, lastView.maxHp, format, false)
      local drawn, err = drawNativeRow(figure, lastView.generation)
      nativeRowDrawn = drawn or nativeRowDrawn
      lastDrawBackend = drawn and "native" or nil
      lastDrawError = err
    end
    return result
  end, 200)
  overlayInstalled = true

  local function shouldHideOriginal(state)
    return hideOriginalBattleUI
      and resolvedCompatibilityMode() ~= NATIVE
      and isBattleScreen(state)
  end

  mod.hooks:wrap("battle.status_hud_visible", function(next, state)
    if shouldHideOriginal(state) then return false end
    return next(state)
  end, 200)

  mod.hooks:wrap("battle.bottom_ui_visible", function(next, state)
    if shouldHideOriginal(state) then return false end
    return next(state)
  end, 200)
  visibilityHooksInstalled = true

  -- Higher priorities are outer wrappers. Calling next first lets the
  -- replacement UI draw its panels; Enemy HP then adds the number on top.
  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local result = next(game, viewport)
    local mode = resolvedCompatibilityMode()
    if enabled and lastView and lastView.replacementVisible then
      local drawn, err
      if mode == GEN3 then
        drawn, err = drawGen3Readout(lastView, viewport)
        if drawn then lastDrawBackend = GEN3 end
      elseif mode == MODERN then
        drawn, err = drawModernReadout(lastView, viewport)
        if drawn then lastDrawBackend = MODERN end
      end
      if err then lastDrawError = err end
    end
    return result
  end, 12000)

  local function clearBattle()
    lastBattle, lastView = nil, nil
    lethalState, lethalZeroFrames = nil, 0
    lastDrawBackend, lastDrawError = nil, nil
  end
  mod.events:on("battle.started", clearBattle)
  mod.events:on("battle.ended", clearBattle)

  local function expected(state)
    local view = viewFor(state)
    return view and view.nativeVisible or false
  end

  local function lastHp() return lastView and lastView.hp or nil end
  local function lastMaxHp() return lastView and lastView.maxHp or nil end
  local function lastVisible()
    return lastView and (lastView.nativeVisible or lastView.replacementVisible) or false
  end
  local function inactivePatch()
    return false, "retired by the v0.1.86 public-hook migration"
  end

  mod.exports.readout = function(state)
    return readout(state, false)
  end
  mod.exports.readoutForScreen = function(state)
    local figure, view = readout(state, false)
    if not (view and (view.nativeVisible or view.replacementBaseVisible)) then
      return nil, view
    end
    return figure, view
  end
  mod.exports.ruleMoved = function() return nativeRowDrawn end
  mod.exports.compat = {
    version = 8,
    generation = "shared",
    backend = "battle.overlay + render.hud",
    publicApiMigration = true,
    testStrategy = "v0.1.86-public-hooks",
    compatibilityMode = function() return compatMode end,
    resolvedCompatibilityMode = resolvedCompatibilityMode,
    gen3Integration = "public-render.hud-after-next",
    gen3DirectInstalled = function() return false end,
    gen3DirectReason = function()
      return "private upvalue patching retired; public render.hud is active"
    end,
    gen3V14OverlayInstalled = function() return overlayInstalled end,
    gen3V14Active = function() return resolvedCompatibilityMode() == GEN3 end,
    gen3V14Reason = function() return nil end,
    gen3V14LastVisible = lastVisible,
    gen3V14LastHp = lastHp,
    gen3V14LastMaxHp = lastMaxHp,
    gen3V14LastDrawError = function() return lastDrawError end,
    gen3V14RenderPriority = 12000,
    gen3HideBridgeInstalled = function() return visibilityHooksInstalled end,
    gen3HideBridgeReason = function() return nil end,
    hideOriginalBattleUI = function() return hideOriginalBattleUI end,
    hardHideInstalled = function() return visibilityHooksInstalled end,
    hardHideDramalessInstalled = function() return false end,
    hardHideReason = function()
      return "native UI is controlled by shared visibility hooks"
    end,
    finalNativeSuppressor = inactivePatch,
    finalDramalessSuppressor = inactivePatch,
    v12NativeKillSwitch = inactivePatch,
    v12DramalessKillSwitch = inactivePatch,
    primitiveHudKill = function()
      return hideOriginalBattleUI and resolvedCompatibilityMode() ~= NATIVE
    end,
    hpBarPrimitiveKill = function()
      return lastBattle ~= nil
        and hideOriginalBattleUI
        and resolvedCompatibilityMode() ~= NATIVE
    end,
    hpBarIdentityPatchCount = function() return 0 end,
    patchCapturedHPBarReferences = inactivePatch,
    renderHookPriority = 12000,
    overlayInstalled = function() return overlayInstalled end,
    nativeAnchorSeen = function() return nativeRowDrawn end,
    enemyHudExpected = expected,
    goldNativeInstalled = function()
      return lastView and lastView.generation == 2
        and lastDrawBackend == NATIVE or false
    end,
    goldOverlayInstalled = function() return overlayInstalled end,
    goldOverlayPriority = 12000,
    goldNativeOverlayPriority = 200,
    goldNativeOverlayInstalled = function() return overlayInstalled end,
    gen3BattleUiEnabled = function() return gen3Handle ~= nil end,
    goldReplacementUi = function()
      return lastView and lastView.generation == 2 and lastDrawBackend or nil
    end,
    goldLastVisible = lastVisible,
    goldLastHp = lastHp,
    goldLastMaxHp = lastMaxHp,
    goldReadoutSource = function() return lastView and lastView.source or nil end,
    goldLastDrawError = function() return lastDrawError end,
    goldEnemyHudLatched = lastVisible,
    goldFallbackReason = function() return nil end,
    lastDrawBackend = function() return lastDrawBackend end,
  }
end
