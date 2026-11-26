# Stella

Stella lets you play games from your Steam library in SteamOS on an Apple silicon Mac running macOS 15 or later. You can play in a window or go fullscreen on your chosen monitor. Stella is a fork of [FX Steam Launcher](https://github.com/fxgl/steamac).

## How it works

Stella boots SteamOS in a virtual machine on your Mac. On first launch, you can reuse an existing FX Steam Launcher disk or let Stella download SteamOS from Valve and create a new one. Sign in to Steam inside the virtual machine to install and launch games.

For compatible Windows games, SteamOS uses Proton to run the game and FEX to translate x86 instructions for Apple silicon. Direct3D graphics normally go through Vulkan and then Metal. Direct3D 10 and 11 games can also use DXMT to render directly through Metal.

In **Settings → Compatibility**, you can choose a renderer for each game, apply a compatibility preset, or save your own.

[Explore Stella’s features and how they work](features.md)
