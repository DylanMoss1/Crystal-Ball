# seed-filter

A Balatro mod that finds a seed matching structured criteria, then starts a run on
it. The in-game UI builds a query; an out-of-process searcher does the brute-force.

## Layout

| Path         | What                                                                 |
|--------------|---------------------------------------------------------------------|
| `CrystalBall/`| The Steamodded mod (Lua UI + handshake) shipped to players.          |
| `Immolate/`  | GPU seed searcher (C / OpenCL). Vendored as a git subtree of upstream.|

### How they talk

```
Balatro + CrystalBall (Lua)
   │  writes a JSON query to <LOVE save dir>/Mods/CrystalBall/CrystalBallHandshake/
   ▼
watcher.py            (started by CrystalBall/linux/launch.sh as a Steam launch wrapper)
   │  runs the searcher
   ▼
Immolate binary       (built from Immolate/)
   │  writes the matching seed back to the handshake dir
   ▼
CrystalBall (Lua)      starts a run on the seed
```

## Build the searcher

```sh
cd Immolate
cmake -B build && cmake --build build      # requires a system OpenCL
cp build/Immolate ./Immolate               # place binary beside watcher.py / launch.sh
```

## Releases

CI (`.github/workflows/release.yml`) builds the searcher on both OSes and publishes
two bundles when a `v*` tag is pushed. Both need an OpenCL runtime (any GPU driver):

| Bundle | Contents | How the search runs |
|--------|----------|---------------------|
| `CrystalBall-windows.zip` | mod + `Immolate/Immolate.exe` | mod runs the binary directly (no watcher) |
| `CrystalBall-linux-proton.zip` | mod + `Immolate/Immolate` + `watcher.py` + `launch.sh` | host watcher runs the binary, file handshake |

Cutting a release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Install the mod

**Windows** — unzip `CrystalBall-windows.zip` into Balatro's `Mods/` directory
(Steamodded required). That's it; the mod execs `Immolate/Immolate.exe` itself.

**Linux/Proton** — unzip `CrystalBall-linux-proton.zip` into `Mods/`, then add the
launch wrapper from `CrystalBall/linux/launch.sh` to the game's Steam launch options
so the watcher runs alongside the game (the game can't exec the host binary under
Proton).

## Immolate subtree

`Immolate/` tracks [SpectralPack/Immolate] via `git subtree` (base `26f41ef`), with
local extensions on top (structured query parsing, item-name table, `find_joker`
filter).

```sh
# pull upstream changes in
git subtree pull --prefix=Immolate immolate-upstream main --squash
# contribute our changes back (to a fork you control)
git subtree push --prefix=Immolate <your-fork-remote> <branch>
```

[SpectralPack/Immolate]: https://github.com/SpectralPack/Immolate
