# Stella features

Stella runs SteamOS in a local virtual machine on an Apple silicon Mac. SteamOS manages your Steam account, library, and games. The macOS app manages the virtual machine and connects it to the Mac’s display, GPU, input devices, and speakers.

## From first launch to your library

Open Stella with an existing FX Steam Launcher disk, or choose **Create New Disk…**. When creating a disk, Stella downloads Valve’s SteamOS image, verifies its signature, and writes it to a disk image on your Mac. That image keeps your Steam installation, settings, and locally installed games between sessions.

At startup, Stella boots Linux, mounts the SteamOS disk, and starts Steam in Gaming Mode. The progress bar follows those milestones until the Steam interface is ready. **Settings → General → Verbose boot and shutdown** shows the live log. From Steam’s power menu, **Switch to Desktop** opens the KDE Plasma desktop in the same virtual machine.

## How a game reaches the screen

For compatible Windows games, Proton provides the Windows environment inside SteamOS. FEX translates x86 instructions so that code can run on Apple silicon. The graphics path depends on the API the game uses.

| Game graphics API | How Stella renders it |
| --- | --- |
| Vulkan | The Venus virtual GPU forwards Vulkan commands to the Mac, where KosmicKrisp or MoltenVK translates them to Metal. |
| Direct3D 9, 10, or 11 | DXVK translates Direct3D to Vulkan, which follows the same path to Metal. |
| Direct3D 12 | vkd3d-proton translates Direct3D 12 to Vulkan. |
| Direct3D 10 or 11 with DXMT selected | DXMT sends Metal work directly to the Mac. Enable **Allow DXMT** in Advanced settings and restart the VM before using this path. |

## Per-game compatibility

Open **Settings → Games → Compatibility…** beside a title. Choose a preset, inspect its settings, then click **Apply**. For example, the *Lay of the Land* preset reports Shader Model 6.6 and exposes the driver’s 64-bit atomics. This combination was verified in gameplay on an M4 Max using KosmicKrisp. Other games keep their own settings.

- **Graphics** selects the renderer, Vulkan driver, reported GPU identity, shader model, feature level, and 64-bit atomics. Changing the reported GPU identity can help with an adapter check. Rendering still depends on the features the driver implements.
- **Runtime** controls the DirectX 12 frame-rate limit, DXVK performance overlay, microphone access, and Proton logging.
- **My presets…** saves the current settings for reuse with another title. Stella prompts when a change needs Steam to restart. A host Vulkan driver change takes effect on a VM restart.

## Displays, controls, and sound

With **Settings → Display → Guest display follows the window size** enabled, SteamOS resizes with the window. In fullscreen, Stella uses the active monitor’s pixel dimensions within the virtual display’s limits. On a MacBook with a notch, it uses the area below the camera. A fixed guest resolution lets you keep the same rendering workload when moving between displays.

The pointer follows the Mac cursor in Steam. Games can capture it for relative movement, such as looking around in first person. **Settings → Mouse** controls capture and cursor size. **Controller** maps connected gamepads for SteamOS, and **Sound** lets playback follow the Mac’s default output or use a specific device.

## Storage, suspend, and streaming

- **Storage.** In **Settings → Advanced**, **Grow Disk…** adds room inside SteamOS. After uninstalling games, **Reclaim Disk Space…** can return unused blocks to an APFS volume. You can also share a Mac folder and register it as a Steam library.
- **Suspend.** In **Settings → General**, choose what happens when the window closes. Suspend keeps the VM and running game in memory. Click Stella’s Dock icon to resume. Quitting Stella shuts SteamOS down.
- **Streaming.** Enable Moonlight in **Settings → Streaming** to play the current SteamOS session from another device on your local network. Select the Mac in Moonlight, enter its four-digit pairing PIN on the Mac, then choose **SteamOS**. The client receives the game picture and sound and sends input back to the same session.
