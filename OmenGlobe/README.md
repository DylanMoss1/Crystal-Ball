# Omen Globe (template)

A Steamodded mod that finds a Balatro seed matching structured criteria using the
[Immolate](../Immolate) searcher, then starts a run on it.

The mod can't run Immolate itself portably (under Proton the game is a Windows
process), so it does a **file handshake** with an external `watcher.py` on the host:

```
mod   --writes-->  <savedir>/OmenGlobeBackendCommunication/request.txt    id + query JSON
watcher           runs Immolate, --writes--> response.txt   id + seed
mod   <--polls--   <savedir>/OmenGlobeBackendCommunication/response.txt    then Game:start_run
```

Identical on Linux and Windows — only the watcher's paths differ.

## 1. Install the mod

Symlink (or copy) this folder into the Balatro `Mods` directory:

```sh
ln -sfn "$PWD/OmenGlobe" \
  "$HOME/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/OmenGlobe"
```

Requires Steamodded + Lovely (already in your `Mods/`).

## 2. Put the Immolate binary in the mod folder

The watcher needs the native `Immolate` binary alongside `launch.sh`/`watcher.py`.
Symlink (or copy) it in:

```sh
ln -sf "$PWD/../Immolate/Immolate" "$PWD/Immolate"   # adjust to your build
```

## 3. Auto-start the watcher (recommended)

The watcher must run on the **host OS** (Immolate uses the GPU; under Proton the
game can't reach it). Rather than starting it by hand, let Steam launch it with
the game. Balatro → **Properties → General → Launch Options**:

```
bash "${STEAM_COMPAT_DATA_PATH}/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/OmenGlobe/launch.sh" %command%
```

`launch.sh` self-locates its assets and derives the save dir from
`STEAM_COMPAT_DATA_PATH`, so this line has **no machine-specific paths** — it
works on any install regardless of where Steam/the prefix live. It backgrounds
the watcher, runs the game, and kills the watcher on exit.

<details><summary>Manual / non-Steam invocation</summary>

If you don't launch via Steam, run the watcher yourself. Point `--dir` at the
`OmenGlobeBackendCommunication` folder inside the LÖVE **save directory**:

| Host | Save dir |
|------|----------|
| Steam + Proton | `…/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/OmenGlobeBackendCommunication` |
| Native Linux | `~/.local/share/Balatro/OmenGlobeBackendCommunication` |
| Native Windows | `%APPDATA%\Balatro\OmenGlobeBackendCommunication` |

The exact path is logged once at mod load — search the Balatro/Lovely log for
`[OmenGlobe] handshake dir:`.

```sh
python3 watcher.py --immolate ./Immolate \
  --dir "$HOME/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/OmenGlobeBackendCommunication"
```

```powershell
python watcher.py --immolate .\Immolate.exe --dir "$env:APPDATA\Balatro\OmenGlobeBackendCommunication"
```
</details>

## 4. Use it

Just **start a new run** (blank seed). The mod intercepts it, runs the search,
and starts the run on the found seed. The **Mods → Omen Globe → Config** button
still works as a manual trigger.

## Configure what to search for

Edit `mod.criteria` in `OmenGlobe.lua` (hardcoded for now; in-game editing is the
end goal). Fixed 3-level schema:

| Level | Key | Meaning |
|-------|-----|---------|
| top   | `any` | OR over groups |
| group | `all` | AND over clauses |
| clause| `atLeast` / `of` | at least N of its criteria |
| crit  | `item`,`minAnte`,`maxAnte` | item appears in a shop within that ante range |

The shipped default is the minimal example: *one Blueprint in a shop within antes 1–8*.
Item names use the enum identifier form (underscores), e.g. `Gros_Michel`, `Mr_Bones`.

## Files

- `OmenGlobe.json` — Steamodded metadata header.
- `OmenGlobe.lua` — criteria → JSON, file handshake + frame poll, new-run interception.
- `watcher.py` — host-side bridge; cross-platform.
- `launch.sh` — Steam launch-option wrapper; auto-starts/stops the watcher with the game.

## Smoke-testing the bridge without the game

```sh
T=/tmp/sf; mkdir -p "$T"
printf '%s\n%s\n' "test-1" '{"any":[{"all":[{"atLeast":1,"of":[{"item":"Blueprint","minAnte":1,"maxAnte":8}]}]}]}' > "$T/request.txt"
python3 watcher.py --dir "$T" --immolate ../Immolate/Immolate &
sleep 3; cat "$T/response.txt"   # -> test-1 / <seed>
```
