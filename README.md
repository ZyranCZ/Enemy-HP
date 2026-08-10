# Enemy HP Readout

Gen 1 shows the foe's HP as a bar and nothing else. This puts the figure on the
same row as its level — as `24/57` or as `42%`.

## Try it

1. Copy the `enemy_hp` folder into the game's `mods/` directory.
2. Launch the game, press **F10**, enable **Enemy HP Readout**.
3. Start a battle.

## Options

| Row | Values | Default |
| --- | --- | --- |
| `ENEMY HP` | ON / OFF | ON |
| `ENEMY HP AS` | NUMBERS / PERCENT | NUMBERS |

`NUMBERS` does reveal the foe's **maximum** HP, which the original never tells
you. `PERCENT` keeps that unknown.

## Making the room

The foe's HUD ends in an L-shaped white rule on row 3: a corner at column 1 and
a horizontal run out to column 10, hanging off the vertical stroke that starts
on the bar's row. Row 4 below it is empty — the player's back sprite only
starts at hlcoord 1,5.

So the rule moves down one row. That frees row 3 entirely: a full line
immediately under the bar, inside the frame rather than dangling below it. The
vertical stroke is carried down one tile so the L still meets the bar. Nothing
else moves — the level, the `<LV>` tile and the party balls all stay exactly
where the engine put them.

The row could run out to column 11 — the foe's pic occupies a 7×7 tile buffer
at hlcoord 12,0, so columns 12 upward are sprite on rows 0 to 6, row 3
included. The figure ends at column 9 instead, which is where the HP bar itself
ends, so the two finish on the same edge.

It is right-aligned to that column rather than pinned on the left, because it
loses digits from the left as HP drops (`113/166` becomes `99/166`) and a fixed
left edge would drag the slash and the maximum around with it. Seven
characters — the widest Gen 1 can produce, `352/705` — reach back to column 3,
still clear of the L's vertical stroke.

## Reaching the rule

The tiles are drawn through `hudTile`, which `BattleState` binds as a
file-scope local. Patching the `HudTiles` module does **not** reach that
binding, and worse, it half-works: `WideBattle` calls the module directly with
the same coordinates, so a module patch lands on one path and not the other and
the tile ends up drawn twice. That is what put a ghost `<LV>` under the level
digits in an earlier version of this mod.

Mods load with no sandbox, so the debug library is available and the binding
itself can be replaced. `debug.setupvalue` swaps the exact upvalue the engine
calls; file-scope locals are shared by every closure in the chunk, so one swap
covers all of them, with no second path and no load-order race. The current
binding is read first rather than assumed to be `HudTiles.tile`, so another mod
that already wrapped the tile stays in the chain.

The search does not just look at `BattleState.drawHUDs`, because another mod may
have replaced it — `DramaticShapeVoxelMod` does, keeping the original in a local
of its own. So every function the module exposes is searched, and any upvalue
that is itself a function is followed, which reaches the binding through a
foreign wrapper a few closures deep.

If the swap fails for any reason, nothing is moved and the figure goes on row 4
under the untouched rule — less tidy, but it cannot break the HUD.

## It matches the rest of the HUD exactly

Not by imitation. `battle.overlay` draws too late: it runs after the HUD has
been recoloured by region and blitted, so anything drawn there skips the
palette pipeline — and under a render pipeline like the voxel one it lands over
the 3D scene entirely.

So the mod wraps `Font.draw` and hangs off the foe's level draw, uniquely at
(40, 8). That puts the figure on the same canvas in the same pass, coloured and
faded by the engine's own code, riding the HUD shake with everything else.

Hanging off the level also inherits its visibility. The enemy HUD clears on the
intro text, during a send-out and the grow-in, and after a faint — if the level
is not being drawn, neither is this, and there is no duplicate gate to keep in
sync.

The value shown is the one the bar's drain animation has reached, not the raw
current HP, so the number and the bar stay in step.

## The missing percent sign

Gen 1's font has no `%`. `Font.encode` falls back to the space glyph for any
character it cannot find, and that glyph is an opaque tile, so a percentage
would print with a blank block where the sign belongs. The mod ships the glyph
as its own font page with a charmap entry mapping `%` to it.

## Tests

`tests/enemy_hp_test.lua` drives the layout with a stubbed font and tile sheet,
so it runs without a graphics context:

```
lua tests/enemy_hp_test.lua
```
