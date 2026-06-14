#!/usr/bin/env bash
# Steam launch-option wrapper: starts the SeedFinder watcher tied to the game's
# lifetime, then runs the real game command (%command%). No machine-specific
# paths -- everything is derived from this script's location and the environment
# Steam provides, so the same launch-option line works on any install.
#
# Paste into Balatro -> Properties -> Launch Options:
#   bash "${STEAM_COMPAT_DATA_PATH}/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/SeedFinder/launch.sh" %command%
#
# The only assumptions: this mod lives at <save-dir>/Mods/SeedFinder and the
# Immolate binary + watcher.py sit beside this script.
set -u

# Mod assets (Immolate binary + watcher.py) sit next to this script. pwd keeps
# the logical path, so a symlinked Mods/SeedFinder still resolves correctly.
MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMMOLATE="$MOD_DIR/Immolate"
WATCHER="$MOD_DIR/watcher.py"

# Balatro's LOVE save dir holds the handshake folder the mod's Lua writes to.
# Under Proton, Steam exports STEAM_COMPAT_DATA_PATH (the per-game Wine prefix);
# fall back to the native-Linux LOVE path otherwise.
if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
    SAVE_DIR="$STEAM_COMPAT_DATA_PATH/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro"
else
    SAVE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Balatro"
fi
HANDSHAKE_DIR="$SAVE_DIR/SeedFinder"

# Start the watcher only if both assets are present; never block the game launch.
WPID=""
if [[ -x "$IMMOLATE" && -f "$WATCHER" ]]; then
    python3 "$WATCHER" --immolate "$IMMOLATE" --dir "$HANDSHAKE_DIR" &
    WPID=$!
fi

"$@"                                       # exec the real game command
status=$?

[[ -n "$WPID" ]] && kill "$WPID" 2>/dev/null   # tear the watcher down with the game
exit $status
