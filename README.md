# Crystal Ball

A Balatro seed searcher mod using the [Immolate](https://github.com/SpectralPack/Immolate) backend.

This mod is still in beta, expect issues and bugs!

https://github.com/user-attachments/assets/7027d0c5-a9bc-4c73-bbf7-b06c00de24ad

## Install

### Windows

1. Install `Lovely` and `smods` (see [Balatro Modding Guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3400691352)).
2. Download the latest release.
3. Extract the zip file into its own folder inside your Balatro mods folder (`%appdata%\Balatro\Mods`).

### Linux (Proton)

1. Install `Lovely` and `smods` (see [Linux Balatro Modding Guide](https://gist.github.com/pjobson/b33bd7798271e07d6a4aec9120056395)).
2. Download the latest release.
3. Extract the zip file into its own folder inside your Balatro mods folder (`~/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods`).
4. Set the Steam Balatro launch options (`Balatro → Properties → Launch Options`) to:

```
bash "${STEAM_COMPAT_DATA_PATH}/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/CrystalBall/CrystalBall/linux/launch.sh" %command%
```

## Usage

> [!WARNING]
> The first time the mod is ran, it will take a long time to find a seed. If the search timeout is exceeded YOU MUST EXIT AND REOPEN BALATRO.
> After the first search, subsequent runs will be _much_ faster.

**Non-legendary Jokers:** 
- Found in shop & buffoon packs.
- Number of re-rolls scales per ante:
  - Ante 1 ⇒ 0 re-rolls, Ante 2 ⇒ 1 re-roll, etc.

**Legendary Jokers:**
- Found in arcana & spectral packs.

This mod does not search for jokers found in skip vouchers packs.

## Future Plans

- Search for vouchers / spectral cards / playing cards
- Customisation options (custom re-rolls per ante, adjustable search timeouts, etc.)

## Thanks

Thank you to the team behind [Immolate](https://github.com/SpectralPack/Immolate) for making this mod possible!
