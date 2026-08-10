# Enemy HP Readout

A mod for [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

Gen 1 shows the foe's HP as a bar and nothing else. This puts the figure on the
same row as its level:

```
   LV23        ->     LV23 24/57
```

Numbers or percentage, switchable in Options. Numbers do reveal the foe's
maximum HP, which the original never tells you; percentage keeps that unknown.

## Install

Unzip the latest release into your game's `mods/` folder, press <kbd>F10</kbd>,
enable **Enemy HP Readout**.

## Notes

The level block slides two columns left to make room — the foe's sprite starts
at column 12, and vanilla left the space before `LV` empty. Widths are
measured, so a status label or a wider level shortens the figure instead of
running under the sprite.

Gen 1's font has no `%`, so the mod ships that one glyph as its own font page.
Without it the sign prints as a blank white block.

The figure is drawn from inside the engine's own HUD pass rather than as an
overlay, so it gets the same palette, fade and shake as the level beside it —
and it inherits the HUD's visibility for free, appearing and clearing exactly
when the HUD does. The value follows the bar's drain animation, not the raw HP,
so the number and the bar stay in step.

No dependencies, no save changes, no effect on link play.

Tests run headless: `lua tests/enemy_hp_test.lua`

MIT.
