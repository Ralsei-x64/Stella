# Stella features

Stella runs SteamOS in a local virtual machine on an Apple silicon Mac. SteamOS manages your Steam account, library, and games. The macOS app manages the virtual machine and connects it to the Mac’s display, GPU, input devices, and speakers.

## From first launch to your library

Open Stella with an existing FX Steam Launcher disk, or choose **Create New Disk…**. When creating a disk, Stella downloads Valve’s SteamOS image, verifies its signature, and writes it to a disk image on your Mac. That image keeps your Steam installation, settings, and locally installed games between sessions.

At startup, Stella boots Linux, mounts the SteamOS disk, and starts Steam in Gaming Mode. The progress bar follows those milestones until the Steam interface is ready. **Settings → General → Verbose boot and shutdown** shows the live log. From Steam’s power menu, **Switch to Desktop** opens the KDE Plasma desktop in the same virtual machine.

## CPU and unified memory

Under **Settings → Advanced → CPU core count**, choose **Custom** and enter the number of virtual cores SteamOS can use.

The **Memory** menu offers three modes. **Automatic** picks the guest RAM and graphics budget for your Mac. **Balanced (custom RAM)** lets you type a guest RAM size while Stella calculates VRAM. **Advanced** remembers separate RAM and VRAM values. Enter either in whole MiB. For example, enter `24576` for a 24 GiB VRAM budget. Vulkan games see up to the heap size the Mac’s graphics driver provides. These settings take effect on the next SteamOS start.

## Additional storage

Open **Settings → Advanced → Manage Drives… → Add Drive…**. Choose a source, give it a name, and review it. Changes take effect the next time SteamOS starts.

| Source | What SteamOS receives |
| --- | --- |
| Virtual disk | A sparse ext4 disk, sized from 1 to 8192 GiB. It uses Mac storage as you fill it and is registered as a Steam library on first use. |
| Mounted Mac volume | The files on an external volume, shared live with Finder. |
| Mac folder | The contents of one directory, mounted at the path shown in the wizard. |
| Raw physical disk | The whole external disk, including its partition table. Unmount its volumes in Disk Utility and keep the device connected. macOS may request authorization. Raw mode supports 512-byte logical sectors. |

Mounted volumes, folders, and raw disks default to read-only. Enable writes in the wizard if SteamOS should change their contents. Managed disks and shared folders appear under `/run/media/stella/`. Raw disks appear as block devices in SteamOS.

Clear **Attach on startup** to disconnect a drive on the next boot. The drive’s menu can move a Stella-created image to the Mac Trash once it is idle. **Remove from Stella** forgets a shared folder or external disk and preserves its contents.

## How a game reaches the screen

For compatible Windows games, Proton provides the Windows environment inside SteamOS. FEX translates x86 instructions so that code can run on Apple silicon. The graphics path depends on the API the game uses.

| Game graphics API | How Stella renders it |
| --- | --- |
| Vulkan | The Venus virtual GPU forwards Vulkan commands to the Mac, where KosmicKrisp or MoltenVK translates them to Metal. |
| Direct3D 9, 10, or 11 | DXVK translates Direct3D to Vulkan, which follows the same path to Metal. |
| Direct3D 12 | vkd3d-proton translates Direct3D 12 to Vulkan. |
| Direct3D 10 or 11 with DXMT selected | DXMT sends Metal work directly to the Mac. Enable **Allow DXMT** in Advanced settings and restart the VM before using this path. |

## Per-game compatibility

Under **Settings → Compatibility**, click **Compatibility…** beside a title. Open **Preset** and look under **For this game** for its compatibility settings. Choose a preset, inspect the values, then click **Apply**. Each title keeps its own settings.

| Game | What its preset does |
| --- | --- |
| Titanfall 2 | Uses DXMT with KosmicKrisp. A second preset disables microphone capture for stalls when the game opens voice input. Game audio stays on. |
| DOOM Eternal | Uses Vulkan with KosmicKrisp and reports an AMD Radeon RX 6800 XT. Stella’s SteamOS launcher starts the game executable directly. |
| Lay of the Land | Uses Vulkan with KosmicKrisp, exposes 64-bit atomics, and reports Shader Model 6.6. This configuration rendered a world on an M4 Max. |
| PRAGMATA | Uses Vulkan with KosmicKrisp, exposes 64-bit atomics, and reports feature level 12.1 and Shader Model 6.6. This preset is experimental. The game may still show its unsupported GPU warning. |
| The Exit 8 | Selects Vulkan with KosmicKrisp, the combination used in local play sessions. |
| Dragon’s Dogma 2 | Selects Vulkan with KosmicKrisp. SteamOS enables feature level 12.1 and Shader Model 6.6 after checking the driver for 64-bit buffer and image atomics. |

- **Graphics** selects the renderer, Vulkan driver, reported GPU identity, shader model, feature level, and 64-bit atomics. Changing the reported GPU identity can help with an adapter check. Rendering still depends on the features the driver implements.
- Each game in **Settings → Compatibility** has a **Microphone** checkbox. Clear it to block voice capture for that game on its next launch. Game audio still plays. **Runtime** also offers this switch, the DirectX 12 frame-rate limit, the DXVK performance overlay, and Proton logging.
- **My presets…** saves the current settings for reuse with another title. Stella prompts when a change needs Steam to restart. A host Vulkan driver change takes effect on a VM restart.

## Displays, controls, and sound

With **Settings → Display → Guest display follows the window size** enabled, SteamOS resizes with the window. In fullscreen, Stella uses the active monitor’s pixel dimensions within the virtual display’s limits. On a MacBook with a notch, it uses the area below the camera. A fixed guest resolution lets you keep the same rendering workload when moving between displays.

**Close overlay apps while Stella runs** is an optional Display setting for direct Metal presentation. It quits Alcove while Stella is visible in fullscreen and reopens it when you leave that Space, turn the setting off, or quit Stella. It only reopens an app Stella closed.

**Settings → General → Share Mac battery with SteamOS** is on by default. SteamOS shows the MacBook’s battery percentage and charging status. Turning it off removes the battery from SteamOS immediately. Macs without an internal battery leave the indicator hidden.

With Discord open on your Mac, **Settings → General → Discord Rich Presence** shows **Steam Library** while you browse Steam and the game title and Steam cover art while you play, with Stella’s logo as a small badge. Both cards show elapsed time and link to Stella’s GitHub repository. Discord shows the **Stella on GitHub** button to other people viewing your activity. You can turn it off during a game.

The pointer follows the Mac cursor in Steam. Games can capture it for relative movement, such as looking around in first person. **Settings → Mouse** controls capture and cursor size. **Controller** maps connected gamepads for SteamOS, and **Sound** lets playback follow the Mac’s default output or use a specific device.

## Storage, suspend, and streaming

- **Storage.** In **Settings → Advanced**, **Grow Disk…** adds room inside SteamOS. After uninstalling games, **Reclaim Disk Space…** can return unused blocks to an APFS volume. You can also share a Mac folder and register it as a Steam library.
- **Suspend.** In **Settings → General**, choose what happens when the window closes. Suspend keeps the VM and running game in memory. Click Stella’s Dock icon to resume. Quitting Stella shuts SteamOS down.
- **Streaming.** Enable Moonlight in **Settings → Streaming** to play the current SteamOS session from another device on your local network. Select the Mac in Moonlight, enter its four-digit pairing PIN on the Mac, then choose **SteamOS**. The client receives the game picture and sound and sends input back to the same session.
