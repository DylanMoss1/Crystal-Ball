# Crystal Ball

A Balatro seed searcher mod using the [Immolate](https://github.com/SpectralPack/Immolate) backend.

This mod is still in beta, expect issues and bugs!

https://github.com/user-attachments/assets/7027d0c5-a9bc-4c73-bbf7-b06c00de24ad

## Install

### Windows

1. Install `Lovely` and `smods` (see [Balatro Modding Guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3400691352)).
2. Download the latest [release](https://github.com/DylanMoss1/CrystalBall/releases/download/v0.1/CrystalBall-windows.zip).
3. Extract the zip file into its own folder inside your Balatro mods folder (`%appdata%\Balatro\Mods`).

### Linux (Proton)

1. Install `Lovely` and `smods` (see [Linux Balatro Modding Guide](https://gist.github.com/pjobson/b33bd7798271e07d6a4aec9120056395)).
2. Download the latest [release](https://github.com/DylanMoss1/CrystalBall/releases/download/v0.1/CrystalBall-linux-proton.zip).
3. Extract the zip file into its own folder inside your Balatro mods folder (`~/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods`).
4. Set the Steam Balatro launch options (`Balatro → Properties → Launch Options`) to:

```
bash "${STEAM_COMPAT_DATA_PATH}/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/CrystalBall/CrystalBall/linux/launch.sh" %command%
```

## Usage

> [!WARNING]
> Expect the **first** seed search to take a very long time (>1 min) in order to compile the backend.
> Subsequent searches will be _much_ faster.

1. Go to `Mods -> Crystal Ball -> Edit seed filter`
2. Add a new filter with `Add row`
3. Configure the filter
    - Select the min/max ante the jokers will appear (inclusive)
    - Select the _minimum_ number of jokers that must be found (or `All` to search for all selected jokers)
5. Start a new game as normal
    - Expect the first seed search to take a long time

### Where Can Jokers Be Found?

**Non-legendary Jokers:** 
- Found in shop & buffoon packs.
- Number of re-rolls scales per ante:
  - Ante 1 ⇒ 0 re-rolls, Ante 2 ⇒ 1 re-roll, etc.

**Legendary Jokers:**
- Found in arcana & spectral packs.

This mod does not search for jokers found in skip vouchers packs.

## Future Plans

- Search for vouchers / spectral cards / playing cards
- Customisation options (custom re-rolls per ante, search timeouts, etc.)
- Support for Showman / duplicate jokers
- Support for Cavendish
- Prevent jokers from appearing in the same pack
- Prevent the selection of locked jokers
- Option to fix the order in which jokers appear
- Option to define/select multiple filter sets

## Thanks

Thank you to the team behind [Immolate](https://github.com/SpectralPack/Immolate) for making this mod possible!
