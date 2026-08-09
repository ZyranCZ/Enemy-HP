# Enemy HP Readout

A mod for [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

Gen 1 shows the foe's HP as a bar and nothing else. This opens a line inside the
foe's HUD, directly under its bar, and puts the figure there:

```
   PONYTA                PONYTA
   :L34                  :L34
   HP: ▔▔▔▔▔▔▔    ->     HP: ▔▔▔▔▔▔▔
   └────────                 83/83
                         └────────
```
<img width="812" height="760" alt="image" src="https://github.com/user-attachments/assets/ba44efd3-fcaf-47b1-805e-f51054864a85" />

Numbers or percentage, switchable in Options. Numbers reveal the foe's maximum
HP, which the original never tells you; percentage keeps that unknown.

<img width="812" height="760" alt="image" src="https://github.com/user-attachments/assets/2e1ab541-63ed-40d5-9bb9-1b4e3a948fc6" />

**Check out my other mods:**<br>
* [Autofire A/B + Directional Keys Mod](https://github.com/ZyranCZ/autofire)<br>
* [Steel and/or Fairy and/or Typing Charts](https://github.com/ZyranCZ/Steel-and-or-Fairy-and-or-Typing-Charts)<br>
* [Move Category (PHYS/SPEC) Preview](https://github.com/ZyranCZ/Move-Category-Preview)<br>
* [Special Stat Split
](https://github.com/ZyranCZ/Special-Stat-Split/)<br>
* [Enemy HP Visible](https://github.com/ZyranCZ/Enemy-HP)
* [Can Always Escape](https://github.com/ZyranCZ/Can-Always-Escape)
* [Trainers Let You Choose Lead Pokemon](https://github.com/ZyranCZ/Trainers-Let-You-Choose-Lead-Pokemon)
* [Evolve in Battle](https://github.com/ZyranCZ/Evolve-in-Battle)
* [HELP Story Guide](https://github.com/ZyranCZ/HELP-Story-Guide/)


## Install

Unzip the latest release into your game's `mods/` folder, press <kbd>F10</kbd>,
enable **Enemy HP Readout**.

## Notes

The room comes from dropping the HUD's L-shaped rule one row — row 4 below it
is empty until the player's sprite starts. The vertical stroke is carried down
a tile so the L still meets the bar, and the figure ends on the same column the
bar does. Nothing else moves.
<img width="812" height="760" alt="image" src="https://github.com/user-attachments/assets/8b85d347-a37a-4fb0-a07f-6bd5bfe5afa7" />

Reaching that rule needs `debug.setupvalue`: the tiles are drawn through a
file-scope local, and patching the `HudTiles` module instead only half-works —
one call path picks it up and another doesn't, which draws the tile twice. The
search walks through foreign wrappers too, since the voxel battle-art mod
replaces `drawHUDs` outright. If it can't reach the binding, nothing moves and
the figure goes below the rule instead.

Gen 1's font has no `%`, so the mod ships that one glyph as its own font page.
Without it the sign prints as a blank block.

The figure is drawn from inside the engine's own HUD pass rather than as an
overlay, so it gets the same palette, fade and shake as the level beside it,
and appears and clears exactly when the HUD does. The value follows the bar's
drain animation, not the raw HP, so the number and the bar stay in step.

No save changes, no effect on link play.

Tests run headless: `lua tests/enemy_hp_test.lua`

MIT.
