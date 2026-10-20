# SDCO: Anime Incremental (Roblox, fully UI)

## How the game is split up

```
ReplicatedStorage
└─ Shared                     (both server AND client can read these)
   ├─ GameConfig   [Module]   settings: characters, chapters, eggs, prices
   └─ Formulas     [Module]   the math: enemy health, rewards, damage

ServerScriptService           (server only, players can't touch it)
├─ GameServer      [Script]   starts everything, connects the RemoteEvents
└─ Services
   ├─ DataService   [Module]  loads + SAVES player data (DataStore)
   ├─ CombatService [Module]  enemies, damage, rewards, auto attack
   └─ ShopService   [Module]  upgrades, eggs, gamepasses

StarterPlayer > StarterPlayerScripts   (runs on the player's computer)
├─ ClientMain      [LocalScript]  builds the UI, sends clicks to the server
└─ UI
   ├─ Theme    [Module]   colors + fonts  <- change the look here
   ├─ UIKit    [Module]   makes buttons, labels, bars
   ├─ Effects  [Module]   damage numbers, shakes, egg hatch scene
   ├─ HUD      [Module]   the main screen (cards, top bar, attack)
   └─ Panels   [Module]   Shop / Eggs / Story windows
```

The client only *asks* ("I clicked attack", "hatch this egg"). The server decides
everything and saves it, so exploiters can't give themselves coins.

## Install (pick ONE way)

**A. Insert from File (recommended)**: download the 3 files in `install/`, then in Studio:
1. Right-click **ReplicatedStorage**, choose **Insert from File...**, and pick `ReplicatedStorage.rbxmx`
2. Right-click **ServerScriptService**, choose **Insert from File...**, and pick `ServerScriptService.rbxmx`
3. Open **StarterPlayer**, right-click **StarterPlayerScripts**, choose **Insert from File...**, and pick `StarterPlayerScripts.rbxmx`

**B. Command Bar**: copy all of `install/StudioCommand.lua` (it's one long line), paste it into
**View > Command Bar** and press Enter. Output should say "Anime game installed!".

**C. Rojo** (for later): `rojo serve` using `default.project.json`.

## Turn on saving
1. **File > Publish to Roblox**
2. **Home > Game Settings > Security**, then turn on **Enable Studio Access to API Services**

Without this the game still runs, but it won't save, and Output shows a warning.

## Editing
Edit files in `src/`, then run `python3 tools/build.py` to rebuild the `install/` files.
Or just edit the scripts straight in Studio.
