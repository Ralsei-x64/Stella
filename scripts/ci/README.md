# Apple Silicon DMGs

Every push to `stella`, every `v*` tag, and manual runs of **Apple Silicon DMG** build Stella on a hosted Apple Silicon Mac. Open a completed run and download the DMG under **Artifacts**. The image contains the ad-hoc-signed app and a shortcut to Applications. Apple notarization is a separate release step.

The job compiles the current Swift launcher, bundled resources, translations, and app icon. It uses the tested VM libraries and guest images pinned in `runtime.env`. It checks the archive hash, compares the runtime source fingerprint to the checkout, and mounts the finished DMG to check the ARM64 executable, signature, and hypervisor entitlement. The SteamOS disk is downloaded during setup.

To run the same build locally, use a clean checkout on Apple Silicon with Xcode 27 selected and run `scripts/ci/build-dmg.sh`. The DMG is written to `work/out/dist/`.

## Updating the runtime

1. Commit the runtime changes, build the affected components, assemble `work/out/Stella.app`, and test the app on a Mac. For a full build, run `./build.sh dxmt`, `./build.sh guest`, then `./build.sh host`. The app and `work/out/host` headers must come from the same build.
2. Run `python3 scripts/ci/runtime.py export work/out/Stella.app work/out/host stella-runtime-arm64.tar.gz` and `scripts/gpl-sources.sh HEAD`. The SDK contains VM libraries, headers, guest boot images, driver revision information, and license notices.
3. Attach the SDK and the corresponding source archive from `work/out/dist/` to a new, versioned runtime prerelease. Put the SDK asset URL and its `shasum -a 256` value in `runtime.env`. Push the updated pin with the source changes. Existing pins should always resolve to their original bytes.
