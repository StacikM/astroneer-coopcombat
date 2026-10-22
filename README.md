# CoopCombat for Astroneer

An experimental co-op combat mod for Astroneer (Steam, Windows): knocked-down (downed) state with a crawl and bleed-out timer,
walk-up revive, fall damage that downs you instead of killing you, an aimed sniper shot, dynamite explosions on a player,
and a local web admin panel.

Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) with a Lua mod. It can crash the game. Use it only with friends.

## Install / update (players)

1. Download [`CoopCombat-update.zip`](https://github.com/StacikM/astroneer-coopcombat/releases/latest/download/CoopCombat-update.zip) and extract it anywhere.
2. Close Astroneer, then double-click `Install-or-Update.bat`.
3. Next time, double-click the **Update CoopCombat** shortcut on your desktop.

Made for Astroneer 1.45.1.0. Remove it by deleting `dwmapi.dll` and the `ue4ss` folder from `Astro\Binaries\Win64`.

## Admin panel (host)

Run `panel/run_panel.bat` while the game is open. It only listens on `127.0.0.1`.

## Layout

- `mods/CoopCombat/Scripts/main.lua` - the mod
- `panel/` - local web admin panel (`server.py`, `index.html`)
- `friend-package/` - installer/updater sources, `build_package.py`, `publish.py`
