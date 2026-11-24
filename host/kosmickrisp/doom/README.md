# Doom Eternal renderer experiment

This directory contains the Stella changes for the MacLauncher MCLv15 build of
KosmicKrisp. It is a development target. The regular launcher continues to use
the Stella renderer with the Doom shader fixes in patch 0101.

The first patch connects Metal textures to the shared memory used by Venus and
Gamescope. The second preserves the width of unstippled default and rectangular
line segments during the software depth-bounds pass. Each pair of generated
triangles shares the source segment's primitive ID and coverage record.

## Reproduce on Apple silicon

Use checkouts of [MacLauncher KosmicKrisp](https://github.com/procrastinine/maclauncher-kosmickrisp)
at `01afe442d9186433a7a60d0527ad0ae8209f58eb` and
[Mesa](https://gitlab.freedesktop.org/mesa/mesa) at
`4f071f891d63396c799b267172c19ba6b0301682`. The commands below assume those
checkouts are called `maclauncher-kosmickrisp` and `mesa`. They create
`doom-mesa` for the adapted source and `doom-build` for build products.

Use a full Xcode installation with its Metal toolchain, Node.js 22 or newer,
Meson, Ninja, pkg-config, glslang, Vulkan headers and loader, LLVM with clang,
SPIRV-Tools, zstd and the Mesa Python build dependencies. The upstream native
file uses ccache for its Objective-C compiler. Put the LLVM binaries and the
Python environment on PATH before running Meson.

```sh
node host/kosmickrisp/doom/prepare.mjs maclauncher-kosmickrisp mesa doom-mesa
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MESA_GIT_SHA1_OVERRIDE=4f071f891d63396c799b267172c19ba6b0301682
meson setup doom-build doom-mesa --native-file doom-mesa/maclauncher/arm64.ini -Db_ndebug=true
ninja -C doom-build src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib
```

Point a Vulkan ICD manifest at the resulting dylib and run the regression on
the Mac GPU. The test runner sets the relevant emulation options locally.

```sh
host/kosmickrisp/doom/tests/run.sh /absolute/path/to/driver-icd.json
```

The line spans a 32 × 32 target with stored depth 0.25 on the left and 0.75
on the right. The test checks a four-pixel line with both static and dynamic
width, with and without depth bounds. Fragment color also depends on the exact
FP64 product of 4097 × 4097. In two VM launches this driver stalled at the loading screen. The regular
renderer with patch 0101 reached the Fortress checkpoint and displayed the
shotgun without the black patches on Ultra Nightmare.
