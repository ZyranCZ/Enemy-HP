-- Enemy HP Readout for Gen1Recomp
-- v2.3.7 - Battle Art + PotatoVoxel 1.6.3 native-row integrations
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
  local battleArtHandle = mod.find("BATTLE_ART_VOXEL_FORK")
  local potatoHandle = mod.find("potato_voxel") or mod.find("POTATO_VOXEL")

  -- Battle Art 1.9.x exposes two deliberately read-only compatibility seams:
  -- battleStage identifies the currently staged battle, while its exported
  -- module namespace provides the exact HUD snap geometry and UI setting
  -- helpers used by Battle Art itself.  We never mutate either table.
  local battleArtExports = battleArtHandle and battleArtHandle.exports or nil
  local battleArtStage = battleArtExports and battleArtExports.battleStage or nil
  local battleArtLib = battleArtExports and battleArtExports.lib or nil


  local function exportedModule(lib, name)
    local loader = lib and lib.require
    if type(loader) ~= "function" then return nil end
    local ok, value = pcall(loader, name)
    if ok and type(value) == "table" then return value end
    return nil
  end

  local battleArtOverworld = exportedModule(battleArtLib, "OverworldBattle")
  local battleArtUi = exportedModule(battleArtLib, "UiBackplates")
  local battleArtBattleHud = exportedModule(battleArtLib, "BattleHud")


  local function stagedState(handle, stage, overworld, state)
    if not handle then return nil end

    local stateFn = stage and stage.state
    if type(stateFn) == "function" then
      local ok, value = pcall(stateFn, state)
      if ok and type(value) == "table" and value.staged == true then
        return value
      end
    end

    local battleFn = overworld and overworld.battle
    if type(battleFn) == "function" then
      local ok, active = pcall(battleFn)
      if ok and active ~= nil and (state == nil or active == state) then
        return { staged = true, battle = active, ready = true }
      end
    end
    return nil
  end

  local function battleArtStageState(state)
    return stagedState(battleArtHandle, battleArtStage, battleArtOverworld, state)
  end

  local function battleArtHudIsInverted()
    local colorFn = battleArtUi and battleArtUi.hudUsesColor
    if type(colorFn) == "function" then
      local ok, usesColor = pcall(colorFn)
      if ok then return not usesColor end
    end

    -- Graceful fallback if Battle Art changes/omits the exported module
    -- namespace. These are its persisted public option keys in 1.9.x.
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game then
      local options = Game.save and Game.save.options
      local bucket = options and options.modOptions
        and options.modOptions.BATTLE_ART_VOXEL_FORK
      if type(bucket) == "table" then
        if bucket.arenaFill == "WHITE" then return false end
        return bucket.hudColor == "INVERTED"
      end
    end
    return false
  end

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

  local function drawNativeRowInk(G, figure, generation)
    G.setColor(0, 0, 0, 1)
    if generation == 2 then
      -- Gold's $73/$77/$76/$6f player-frame tiles are not the same art as
      -- Gen 1's frame: the side is four pixels wide and the bottom rule is
      -- on scanline 6. Draw their exact horizontal mirror.
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
  end

  local function drawNativeRow(figure, generation)
    return withGraphics(function(G)
      assert(type(G.setColor) == "function" and type(G.rectangle) == "function",
        "graphics primitives unavailable")
      -- Clear the original rule row before moving the number down one tile.
      G.setColor(1, 1, 1, 1)
      G.rectangle("fill", 8, 24, 88, 16)
      drawNativeRowInk(G, figure, generation)
    end)
  end

  -- PotatoVoxel 1.6.3 keeps the battle HUD in the classic 160x144 GB frame.
  -- It lays a plain white panel at 84% opacity behind the native enemy HUD
  -- before the engine draws the HUD itself. Extend that exact panel one row
  -- lower, then redraw the mirrored native frame and HP readout in black.
  --
  -- The first transparent replace removes the old lower rule without stacking
  -- alpha over Potato's existing 0.84 backing. The panel itself stays the same
  -- 80-pixel width as PotatoVoxel's HUD_RECT.enemy = {8, 0, 80, 32}; the wider
  -- 88-pixel erase only clears native rule/arrow pixels that need relocating.
  local function drawPotatoNativeRow(figure, generation)
    return withGraphics(function(G)
      assert(type(G.setColor) == "function" and type(G.rectangle) == "function",
        "graphics primitives unavailable")

      if type(G.setBlendMode) == "function" then
        local ok = pcall(G.setBlendMode, "replace", "premultiplied")
        if not ok then pcall(G.setBlendMode, "replace") end
      end
      G.setColor(0, 0, 0, 0)
      G.rectangle("fill", 8, 24, 88, 16)

      if type(G.setBlendMode) == "function" then
        pcall(G.setBlendMode, "alpha")
      end
      G.setColor(1, 1, 1, 0.84)
      G.rectangle("fill", 8, 24, 80, 16)

      drawNativeRowInk(G, figure, generation)
    end)
  end

  local function potatoStagedBattle(state)
    -- PotatoVoxel 1.6.3 sets this on BattleState immediately before it lays
    -- down its semi-opaque HUD panels and calls the engine's native draw.
    -- battle.overlay therefore sees the marker only while Potato is actually
    -- rendering a staged 3D battle, not merely because the mod is installed.
    return potatoHandle ~= nil
      and type(state) == "table"
      and state.dramaticShapeShot ~= nil
  end

  -- Battle Art draws its snapped HUD into a transparent 160x144 texture and
  -- only then blits that texture to the window edge. Inject the Enemy HP row
  -- into THAT texture rather than painting over the final screen. This lets us
  -- remove the old bottom rule without inventing an opaque background, extend
  -- the native bracket downward exactly like the vanilla Enemy HP path, and
  -- pass the new row through Battle Art's own COLOR / INVERTED shader.
  local function clearBattleArtLayerRect(G)
    if type(G.setBlendMode) == "function" then
      local set = pcall(G.setBlendMode, "replace", "premultiplied")
      if not set then pcall(G.setBlendMode, "replace") end
    end
    G.setColor(0, 0, 0, 0)
    G.rectangle("fill", 8, 24, 88, 16)
    if type(G.setBlendMode) == "function" then
      pcall(G.setBlendMode, "alpha")
    end
  end

  local function withLayerCanvas(layer, draw)
    local G = love and love.graphics
    if not (G and type(G.getCanvas) == "function"
        and type(G.setCanvas) == "function"
        and type(G.setColor) == "function"
        and type(G.rectangle) == "function") then
      return false
    end
    local prevCanvas = G.getCanvas()
    local prevBlend, prevAlpha
    if type(G.getBlendMode) == "function" then
      prevBlend, prevAlpha = G.getBlendMode()
    end
    local ok = pcall(function()
      G.setCanvas(layer)
      draw(G)
    end)
    if prevCanvas then G.setCanvas(prevCanvas) else G.setCanvas() end
    if type(G.setBlendMode) == "function" and prevBlend then
      pcall(G.setBlendMode, prevBlend, prevAlpha)
    end
    G.setColor(1, 1, 1, 1)
    return ok
  end

  local battleArtLayerHookInstalled = false
  local function installBattleArtLayerHook()
    if battleArtLayerHookInstalled then return true end
    local hud = battleArtBattleHud
    local original = hud and hud.layerTexture
    local flip = hud and hud.flipGlyphs
    if type(original) ~= "function" or type(flip) ~= "function" then
      return false
    end
    if hud._enemyHpLayerTextureWrapped then
      battleArtLayerHookInstalled = true
      return true
    end

    hud.layerTexture = function(w, h, dark, fn, colorMode, colorShadow, battle, ...)
      local layer = original(w, h, dark, fn, colorMode, colorShadow, battle, ...)
      if not layer or not enabled or resolvedCompatibilityMode() ~= NATIVE then
        return layer
      end
      if not battleArtStageState(battle) then return layer end

      local view = viewFor(battle)
      if not (view and view.nativeVisible) then return layer end
      local figure = formatReadout(view.hp, view.maxHp, format, false)
      if not figure then return layer end

      withLayerCanvas(layer, function(G)
        clearBattleArtLayerRect(G)

        -- `colorMode` is the exact boolean Battle Art itself just used for
        -- this HUD texture: true = COLOR (black ink + light shadow, and also
        -- ARENA FILL WHITE); false = INVERTED (white ink + dark shadow).
        -- Feeding our black source row through the same shader guarantees the
        -- number AND the extended frame switch together, live, with no option
        -- guessing and no reload.
        flip(w, h, function()
          drawNativeRowInk(G, figure, view.generation)
        end, colorMode, nil, colorShadow)
      end)
      return layer
    end

    hud._enemyHpLayerTextureWrapped = true
    battleArtLayerHookInstalled = true
    return true
  end

  installBattleArtLayerHook()

  local function battleArtPlacement(state)
    if not battleArtStageState(state) then
      return nil, "Battle Art staged battle is not active"
    end
    local shotFn = battleArtOverworld and battleArtOverworld.shot
    local snapFn = battleArtOverworld and battleArtOverworld.snapRects
    if type(shotFn) ~= "function" or type(snapFn) ~= "function" then
      return nil, "Battle Art HUD geometry export is unavailable"
    end

    local okShot, shot = pcall(shotFn)
    if not okShot or type(shot) ~= "table" then
      return nil, "Battle Art shot is not ready"
    end
    local okSnap, _, bands = pcall(snapFn, shot)
    local enemy = okSnap and type(bands) == "table" and bands.enemy or nil
    if type(enemy) ~= "table" or type(enemy.x) ~= "number"
        or type(enemy.y) ~= "number" or type(enemy.scale) ~= "number"
        or enemy.scale <= 0 then
      return nil, "Battle Art enemy HUD placement is unavailable"
    end
    return { shot = shot, band = enemy }
  end

  local function drawBattleArtReadout(view)
    local figure = formatReadout(view.hp, view.maxHp, format, false)
    if not figure then return false end
    local placement, why = battleArtPlacement(view.state)
    if not placement then return false, why end

    return withGraphics(function(G)
      assert(type(G.setColor) == "function" and type(G.translate) == "function"
        and type(G.scale) == "function", "screen transform unavailable")

      local shot, band = placement.shot, placement.band
      local sw, sh
      if type(G.getDimensions) == "function" then sw, sh = G.getDimensions() end
      sw, sh = tonumber(sw) or tonumber(shot.pw) or 1,
               tonumber(sh) or tonumber(shot.ph) or 1
      local pw = tonumber(shot.pw) or sw
      local ph = tonumber(shot.ph) or sh
      local kx = pw > 0 and sw / pw or 1
      local ky = ph > 0 and sh / ph or 1
      local hs = band.scale

      -- Battle Art snaps the complete enemy HUD band to the window edge.
      -- Draw the readout at the same native coordinates Enemy HP uses
      -- (right-aligned to x=80, y=24), transformed by that exact snap.
      -- Deliberately do NOT draw the vanilla white clear rectangle/frame: the
      -- voxel HUD is transparent and only the glyphs should sit over the world.
      local tx = math.max(8, 80 - tileTextWidth(figure))
      local x = (band.x + tx * hs) * kx
      local y = (band.y + 24 * hs) * ky

      G.translate(x, y)
      G.scale(hs * kx, hs * ky)

      local inverted = battleArtHudIsInverted()
      if inverted then
        -- Match Battle Art INVERTED: white ink with a one-GB-pixel dark shadow.
        G.setColor(0, 0, 0, 0.72)
        Font.draw(figure, 1, 1)
        G.setColor(1, 1, 1, 1)
        Font.draw(figure, 0, 0)
      else
        -- Match Battle Art COLOR: black ink with its light one-pixel shadow.
        G.setColor(1, 1, 1, 0.38)
        Font.draw(figure, 1, 1)
        G.setColor(0, 0, 0, 1)
        Font.draw(figure, 0, 0)
      end
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
        and lastView and lastView.nativeVisible
        and not battleArtStageState(state) then
      local figure = formatReadout(lastView.hp, lastView.maxHp, format, false)
      local drawn, err
      if potatoStagedBattle(state) then
        drawn, err = drawPotatoNativeRow(figure, lastView.generation)
        if drawn then lastDrawBackend = "potato_native_1_6_3" end
      else
        drawn, err = drawNativeRow(figure, lastView.generation)
        if drawn then lastDrawBackend = "native" end
      end
      nativeRowDrawn = drawn or nativeRowDrawn
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
    if enabled and lastView then
      local drawn, err
      if mode == NATIVE and lastView.nativeVisible
          and battleArtStageState(lastView.state) then
        if battleArtLayerHookInstalled then
          -- Already composed into Battle Art's own transparent HUD texture.
          drawn = true
          lastDrawBackend = "battle_art_layer"
        else
          drawn, err = drawBattleArtReadout(lastView)
          if drawn then lastDrawBackend = "battle_art_fallback" end
        end
      elseif lastView.replacementVisible and mode == GEN3 then
        drawn, err = drawGen3Readout(lastView, viewport)
        if drawn then lastDrawBackend = GEN3 end
      elseif lastView.replacementVisible and mode == MODERN then
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
    version = 9,
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
    battleArtInstalled = function() return battleArtHandle ~= nil end,
    battleArtStaged = function()
      return lastView ~= nil and battleArtStageState(lastView.state) ~= nil
    end,
    battleArtHudInverted = battleArtHudIsInverted,
    battleArtIntegration = "battleStage + exported HUD snap geometry",
    potatoInstalled = function() return potatoHandle ~= nil end,
    potatoStaged = function()
      return lastView ~= nil and potatoStagedBattle(lastView.state)
    end,
    potatoIntegration = "PotatoVoxel 1.6.3 classic GB HUD + 0.84 semi-opaque native-row extension",
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
