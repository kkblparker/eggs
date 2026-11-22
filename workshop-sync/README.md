# Workshop sync (Barotrauma and Starbound)

This folder builds `../barotrauma/egg-barotrauma.json` and `../starbound/egg-starbound.json`. They are custom builds of the community eggs from `pelican-eggs/games-steamcmd`, adapted for the NightHowl panel. Edit the files here, not the generated eggs.

| File | Game | What's added |
|---|---|---|
| `barotrauma/egg-barotrauma.json` | Barotrauma | Steam Workshop tab, server name / password / max players / public settings, and the panel's assigned ports |
| `starbound/egg-starbound.json` | Starbound | Steam Workshop tab |

Both are imported into the **NightHowl Nest**.

## How the Workshop support works

The panel extension `dev.kkblparker.steamworkshop` already gives Arma 3 and Project Zomboid a **Workshop** tab. It shows up for any egg that has:

- the feature `steam_workshop`
- a hidden `WORKSHOP_APPID` variable, set to the Steam app the mods belong to:
  - Barotrauma: `602960`
  - Starbound: `211820`
- a hidden `WORKSHOP_MODS_VARIABLE` variable naming the variable that holds the mod list (`WORKSHOP_MODS`)

The tab only edits `WORKSHOP_MODS` (`@id;@id;`). The actual work is done by [`nighthowl-workshop.sh`](nighthowl-workshop.sh). The egg install script writes it into the server, and the startup command runs it before the game on every start. It:

1. Downloads or updates every listed item with `steamcmd +login anonymous`. Workshop items for both games download without a Steam account; this was tested 2026-11-22.
2. Enables them:
   - **Barotrauma:** links `LocalMods/ws_<id>` to the downloaded item, and rewrites the `<regularpackages>` list in `config_player.xml` in list order. Entries that aren't `ws_` (hand-uploaded mods) are kept.
   - **Starbound:** links each `.pak` into `mods/ws_<id>_<n>.pak`.
3. Removes anything it added earlier that's no longer on the list, including the links, the config entries and the downloaded files.

A failed download only prints a warning; the server still starts.

## Game notes

**Barotrauma**
- It needs **2 UDP ports**: the game port and the game port + 1 (Steam query). Give the egg an allocation offset of +1 so both ports land on the same node.
- The server never downloads mods itself; the script does it. Players get mods automatically from the server when they join.

**Starbound**
- The game itself needs a Steam account that owns Starbound. Set it in the admin-only `STEAM_USER` and `STEAM_PASS` variables.
- If Steam Guard is on, put the code in `STEAM_AUTH` for the first install.
- Workshop mods don't need that account.
- Players need the same mods subscribed to join.

## Changing things

1. Edit `nighthowl-workshop.sh` or `build.py`.
2. Run `python build.py` from this folder. It writes both eggs in `PLCN_v1` format, like the rest of this repo.
3. Re-import the egg into the panel.
4. Reinstall existing servers to get the new script. Reinstalling keeps saves and worlds.

`upstream/` holds the unmodified community eggs the build starts from. To pick up upstream fixes, replace them and rebuild.

## Tested (2026-11-22, throwaway containers on wing1)

**Barotrauma 1.13.5.0**
- The install script runs as-is.
- The startup command was run through the real `ghcr.io/parkervcp/steamcmd:debian` entrypoint.
- The server listened on the assigned port and port + 1.
- Name, password (with spaces), empty password, max players and the public setting all applied.
- Mods downloaded and loaded.
- Mod removal and the empty list both cleaned up.
- A hand-installed mod was kept.
- The game-written `config_player.xml`, including multi-line elements, was handled correctly.

**Starbound**
- Download, linking and cleanup were tested in `ghcr.io/parkervcp/games:source`.
- The game itself was **not** booted, because no Steam account that owns it was available.
