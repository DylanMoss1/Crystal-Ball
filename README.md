# seed-filter

A Balatro mod that finds a seed matching structured criteria, then starts a run on
it. The in-game UI builds a query; an out-of-process searcher does the brute-force.

## Layout

| Path         | What                                                                 |
|--------------|---------------------------------------------------------------------|
| `SeedFinder/`| The Steamodded mod (Lua UI + handshake) shipped to players.          |
| `Immolate/`  | GPU seed searcher (C / OpenCL). Vendored as a git subtree of upstream.|

### How they talk

```
Balatro + SeedFinder (Lua)
   │  writes a JSON query to <LOVE save dir>/SeedFinder/
   ▼
watcher.py            (started by SeedFinder/launch.sh as a Steam launch wrapper)
   │  runs the searcher
   ▼
Immolate binary       (built from Immolate/)
   │  writes the matching seed back to the handshake dir
   ▼
SeedFinder (Lua)      starts a run on the seed
```

## Build the searcher

```sh
cd Immolate
cmake -B build && cmake --build build      # requires a system OpenCL
cp build/Immolate ./Immolate               # place binary beside watcher.py / launch.sh
```

## Install the mod

Copy `SeedFinder/` into Balatro's `Mods/` directory (Steamodded required). Add the
launch wrapper from `SeedFinder/launch.sh` to the game's Steam launch options so the
searcher watcher runs alongside the game.

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
