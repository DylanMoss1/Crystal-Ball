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
> The first seed search will take a long time (and may crash / timeout). 
> This is expected while the search searcher compiles, subsequent runs will be _much_ faster.

**Non-legendary Jokers:** Can be found in shop and buffoon packs. Number of re-rolls scales per ante (ante 1 assumes 0 re-rolls, ante 2 assumes 1 re-roll, etc.).

Non-legendary jokers can be found in shop (either as buyable jokers or in buffoon packs). The number of re-rolls per ante = `(ante - 1)`.

Legendary jokers can be found in shop arcana / spectral packs.

This mod does not search for packs obtained from tags.

## Future Work

Currently this mod only supports jokers, but there are future plans to support vouchers and other cards.

There are plans to add custom configuration options (such as number of re-rolls per ante, and adjustable search timeouts).

## Thanks

Thank you to the team behind [Immolate](https://github.com/SpectralPack/Immolate) for making this mod possible!
