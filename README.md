# SDCO

R6 fist combat for Roblox: parry/stun-based fighting with battlegrounds-style
animation, camera work and mobility. Everything is animated from pose data in
code, so there's nothing to upload.

## Install into your place

1. Open your place in Studio and open **View → Command Bar**.
2. Copy all of [`install/InstallCombat.lua`](install/InstallCombat.lua), paste it into the command bar, press Enter.
3. The Output window lists every script it updated. It's one undo step, so Ctrl+Z reverts it.

It overwrites the combat scripts wherever they already live, adds
`ReplicatedStorage.Combat.CameraFX`, removes the old `HUD` module and creates
any missing remotes. The `Dummies` script and your dummies are left alone.

If the command bar ever refuses the paste, copy each file from `src/` into
the script of the same name instead.

## Controls

| Input | Move |
|---|---|
| M1 | 4-hit string, 5th press is the finisher (blasts them away) |
| Space + M1 | Uppercut launcher; M1 in the air juggles, last hit slams |
| W W (hold) | Sprint; M1 while sprinting is a superman punch |
| Q | Dash toward your movement keys; side dashes near an enemy curve around them; works in the air |
| Space in the air | Double jump |
| F (tap / hold) | Parry / block |
| Right mouse | Feint (or cancel a dash early) |
| R | Critical (charged, 6s cooldown) |
| Y | Slash skill |
| Alt | Shift lock |

## Tuning

All numbers live in `ReplicatedStorage.Combat.Config`:

- `Config.Camera.Intensity`: scales every camera effect (0 turns them off, 0.5 halves them).
- `Config.HitStop`: freeze length per hit type.
- `Config.WalkSpeed`, `SprintSpeed`, `RollSpeed`, `RollCooldown`, `DoubleJumpVelocity`: movement.
- `Config.Attacks`: damage, stun, knockback and lunges per move.

## Development

Sources are in `src/` (Rojo-style layout). After editing, rebuild the installer:

```sh
python3 tools/build_installer.py      # regenerate install/InstallCombat.lua
LUAU=luau python3 tools/check.py          # animation/attack data sanity checks
LUAU=luau python3 tools/test_installer.py # installer against a mock Studio tree
LUAU=luau python3 tools/preview.py M1_1   # render a move's keyframes to previews/
```

`preview.py` reproduces the R6 joint math, so the pictures match what plays in game.

## Katana skills (Z: Lumen Rush, X: Moonfall Crescent)

Katana drawn (E) only. Install with `install/InstallKatanaSkills.lua` (command bar, one undo step);
it only writes the scripts this feature touches.

- **Lumen Rush (Z)**: coil, glint, dash to the opponent you're aiming at, diagonal cut with a layered slash explosion.
- **Moonfall Crescent (X)**: overhead cut that launches a travelling 17-stud crescent (server-flown hitbox).

Tuning lives in `Config.Attacks.KatanaRush/KatanaCrescent` and `Config.KatanaSkills`.

Custom sprites are in `assets/katana/`. Upload them (Studio > Asset Manager > Bulk Import, or
`tools/katana/upload.py`) and paste the image ids into `Config.KatanaTextures`; until then the
effects fall back to the existing textures.

Python tooling (`tools/katana/`): `moves.py` (pose solver -> KatanaSkillPoses), `fxscore.py`
(VFX score -> KatanaFXData), `textures.py` (sprites), `preview.py` (renders the moves + VFX,
`--slow 3` for slow motion), `verify.py` (checks the in-game bake matches the previews),
`build_installer.py`.
