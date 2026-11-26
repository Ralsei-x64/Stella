import AppKit
import SwiftUI
import Vision
import Carbon.HIToolbox

/// `--selftest-settings [--selftest-out DIR]`: open the Settings window without a VM, write
/// DIR/settings-<tab>.png for every tab (command-line overrides of this run are shown as in a
/// real run), then DIR/settings-create-disk.png of the "Create New Disk…" window,
/// DIR/settings-first-run.png of the first-run alert, DIR/settings-what-is-sent.png (the crash
/// reports popover), DIR/settings-display-presets.png (window size popup open; screen capture),
/// DIR/settings-display-custom.png (Custom… fields) and DIR/settings-advanced-custom.png (custom VM
/// size with its warnings), and check that each capture has content.
/// Also checks that crash-report scrubbing redacts the user, host, computer and Bonjour names,
/// that a guest process's GPU teardown is no crash report (LineScanner), and the automatic VM size
/// (VMSizing) on simulated Macs, the update check's version ordering and release selection,
/// the Mac time zone and clock format kernel parameters (MacTime), and the clipboard port's frame codec and
/// concealed-item filter (ClipboardSync), plus shared-library preferences and boot arguments.
enum SettingsSelfTest {
    /// Use a private preferences domain, like ProvisionSelfTest's disk-selection checks.
    private static func sharedLibrarySelfCheck() -> [String] {
        let domain = "es.fxgam.steamac.selftest-share-library-\(UUID().uuidString)"
        let previousDomain = getenv("STEAMAC_DEFAULTS_DOMAIN").map { String(cString: $0) }
        setenv("STEAMAC_DEFAULTS_DOMAIN", domain, 1)
        let settings = LauncherSettings()
        defer {
            settings.defaults.removePersistentDomain(forName: domain)
            if let previousDomain { setenv("STEAMAC_DEFAULTS_DOMAIN", previousDomain, 1) }
            else { unsetenv("STEAMAC_DEFAULTS_DOMAIN") }
        }
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            if !ok { failures.append("shared library: \(name)") }
        }
        check(settings.sharedLibrary && Options().shareLibrary, "default is on")
        check(LauncherSettings.Key.sharedLibrary.nextStart, "key applies on next start")
        check(settings.set("sharedLibrary", "off") && !settings.sharedLibrary, "debug set off")
        check(settings.defaults.object(forKey: "sharedLibrary") as? Bool == false, "off is persisted")
        check(!LauncherSettings().sharedLibrary, "off is loaded")
        check(!settings.set("sharedLibrary", "invalid") && !settings.sharedLibrary, "invalid debug value rejected")
        check(settings.set("sharedLibrary", "on") && settings.sharedLibrary, "debug set on")
        check(LauncherSettings().sharedLibrary, "on is loaded")
        settings.noteBoot(overrides: [:], autoCapture: nil)
        check(!settings.restartPending, "initial boot snapshot")
        settings.sharedLibrary = false
        check(settings.restartPending, "changing the preference needs a restart")
        settings.sharedLibrary = true
        check(!settings.restartPending, "restoring the preference clears restart")
        settings.noteBoot(overrides: [.sharedLibrary: "--no-share-library"], autoCapture: nil)
        settings.sharedLibrary = false
        check(!settings.restartPending, "CLI override is excluded from restart tracking")
        settings.resetAll()
        check(settings.sharedLibrary && LauncherSettings().sharedLibrary, "reset restores default")
        check(settings.defaults.object(forKey: "sharedLibrary") == nil, "reset removes saved key")
        let folder = NSTemporaryDirectory() + "steamac-share-library-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: folder) }
            let boot = folder + "/boot"
            try Data().write(to: URL(fileURLWithPath: boot))
            let base = ["steamac-vm", "--kernel", boot, "--disk", boot, "--no-ssh",
                        "--headless", "--frame-dump", "/dev/null", "--vulkan-driver", "moltenvk"]
            failures += try resourceSettingsSelfCheck(settings, arguments: base)
            let cases: [(String, String, Bool, [String], [String], String?)] = [
                ("no folder", "", true, [], [], nil),
                ("folder enabled", folder, true, [], ["1"], nil),
                ("folder disabled", folder, false, [], [], nil),
                ("missing saved folder", folder + "/missing", true, [], [], nil),
                ("no share", folder, true, ["--no-share"], [], nil),
                ("CLI folder", "", true, ["--share", folder], ["1"], nil),
                ("CLI on", folder, false, ["--share-library"], ["1"], "--share-library"),
                ("CLI off", folder, true, ["--no-share-library"], [], "--no-share-library"),
                ("CLI on without folder", "", false, ["--share-library"], [], "--share-library"),
                ("CLI last on", folder, false, ["--no-share-library", "--share-library"], ["1"], "--share-library"),
                ("CLI last off", folder, true, ["--share-library", "--no-share-library"], [], "--no-share-library"),
                ("cmdline off", folder, true, ["--cmdline", "steamac.share_library=0"], ["0"], nil),
                ("cmdline on", folder, false, ["--cmdline", "steamac.share_library=1"], ["1"], nil),
            ]
            for (name, path, enabled, flags, expected, override) in cases {
                settings.sharedFolder = path
                settings.sharedLibrary = enabled
                let (options, overrides) = try Options.resolve(base + flags, settings: settings)
                let prefix = "steamac.share_library="
                let values = options.cmdline.split(separator: " ").filter { $0.hasPrefix(prefix) }
                    .map { String($0.dropFirst(prefix.count)) }
                check(values == expected, "\(name): boot argument \(values), expected \(expected)")
                check(overrides[.sharedLibrary] == override, "\(name): CLI override note")
                check(options.shareLibrary == (override.map { $0 == "--share-library" } ?? enabled),
                      "\(name): effective option")
                check(settings.sharedLibrary == enabled && LauncherSettings().sharedLibrary == enabled,
                      "\(name): one-run override did not change saved preference")
            }
            settings.sharedFolder = folder
            settings.sharedLibrary = true
            let mount = "/home/steamos/OtherShare"
            let (options, _) = try Options.resolve(base + ["--cmdline", "steamac.share=\(mount)"], settings: settings)
            let mounts = options.cmdline.split(separator: " ").filter { $0.hasPrefix("steamac.share=") }
            check(mounts == [Substring("steamac.share=\(mount)")], "explicit share mount is preserved")
            check(options.cmdline.split(separator: " ").contains("steamac.share_library=1"),
                  "library enabled with an explicit share mount")
        } catch {
            failures.append("shared library: \(error)")
        }
        log("selftest-settings: shared library: \(failures.isEmpty ? "ok" : "FAIL: \(failures.joined(separator: "; "))")")
        return failures
    }

    private static func resourceSettingsSelfCheck(_ settings: LauncherSettings, arguments: [String]) throws -> [String] {
        var failures = [String]()
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append("VM resources: " + message) } }
        defer { settings.resetAll() } // caller owns a private test domain
        check(settings.memoryMode == .automatic, "default mode")
        settings.memMiB = 3072
        check(LauncherSettings().memoryMode == .balanced, "existing custom RAM selects Balanced")
        settings.memoryMode = .advanced
        settings.cpus = 3
        let ram = Int(VMSizing.Host.current.memBytes >> 20) + 1
        check(settings.set("advancedRAMMiB", String(ram)) && settings.set("advancedVRAMMiB", "24577"),
              "manual input above the host RAM and the old 16 GiB VRAM limit")
        let restored = LauncherSettings()
        let (custom, _) = try Options.resolve(arguments, settings: restored)
        check(custom.cpus == 3 && custom.memMiB == ram && custom.gpuBudgetMiB == 24577, "exact saved values")
        restored.noteBoot(overrides: [:], autoCapture: nil)
        restored.advancedVRAMMiB = 1345
        check(restored.restartPending, "VRAM change requests restart")
        let (override, keys) = try Options.resolve(arguments + ["--cpus", "2", "--mem", "2048",
            "--cmdline", "console=hvc0 steamac.gpu_mib=777"], settings: settings)
        check(override.cpus == 2 && override.memMiB == 2048 && override.gpuBudgetMiB == 777 &&
              keys[.advancedVRAMMiB] != nil, "command-line overrides")
        settings.memoryMode = .balanced
        let (balanced, _) = try Options.resolve(arguments, settings: settings)
        check(balanced.memMiB == 3072 && balanced.gpuBudgetMiB == VMSizing.gpuBudgetMiB(memMiB: 3072), "balanced RAM and VRAM")
        settings.memoryMode = .advanced
        check(settings.guestRAMMiB == ram && settings.graphicsBudgetMiB(for: ram) == 24577, "advanced values retained")
        check(!settings.set("advancedRAMMiB", "0") && !settings.set("advancedVRAMMiB", "-1"), "positive sizes required")
        for (ram, vram) in [(1, 1), (VMSizing.manualRAMMiB.upperBound, VMSizing.manualVRAMMiB.upperBound)] {
            check(settings.set("advancedRAMMiB", String(ram)) && settings.set("advancedVRAMMiB", String(vram)),
                  "accept representable manual sizes")
            let (limits, _) = try Options.resolve(arguments, settings: LauncherSettings())
            check(limits.memMiB == ram && limits.gpuBudgetMiB == vram, "exact manual sizes at the limits")
        }
        for flags in [["--mem", String(VMSizing.manualRAMMiB.upperBound + 1)],
                      ["--cmdline", "steamac.gpu_mib=\(VMSizing.manualVRAMMiB.upperBound + 1)"]] {
            do {
                _ = try Options.resolve(arguments + flags, settings: settings)
                check(false, "rejected unrepresentable command-line value")
            } catch is OptionError {}
        }
        settings.memoryMode = .balanced
        check(settings.set("memMiB", String(ram)), "Balanced accepts manual RAM")
        let (customBalanced, _) = try Options.resolve(arguments, settings: LauncherSettings())
        check(customBalanced.memMiB == ram && customBalanced.gpuBudgetMiB == VMSizing.gpuBudgetMiB(memMiB: ram),
              "Balanced preserves the exact RAM and computes VRAM")
        log("selftest-settings: VM resource settings: \(failures.isEmpty ? "ok" : "failed")")
        return failures
    }

    private static func additionalDriveSelfCheck() -> [String] {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var failures = [String]()
        func check(_ value: Bool, _ detail: String) {
            if !value { failures.append("additional drives: " + detail) }
        }
        do {
            var drive = AdditionalDrive(id: UUID(), kind: .image, name: "Games with spaces", sizeGiB: 1)
            try drive.createImage(in: directory)
            defer { try? fm.removeItem(at: directory) }
            let url = drive.imageURL(in: directory)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            check(attrs[.size] as? Int64 == 1 << 30, "incorrect image capacity")
            do { try drive.createImage(in: directory); check(false, "overwrote existing image") } catch {}
            let fd = try DiskLock.lock(url.path)
            do { try drive.trashImage(in: directory); check(false, "deleted busy image") }
            catch is DiskLock.InUse {} catch { failures.append("unexpected busy error: \(error)") }
            close(fd)
            var folder = AdditionalDrive(id: UUID(), kind: .folder, name: "Files", readOnly: true)
            folder.bookmark = try directory.bookmarkData()
            let restored = try JSONDecoder().decode([AdditionalDrive].self, from: JSONEncoder().encode([drive, folder]))
            check(restored == [drive, folder], "saved drive inventory round trip")
            var boot = Options()
            boot.disks = [DiskSpec(path: "boot", readOnly: false), DiskSpec(path: "layer", readOnly: true)]
            var standard = boot
            AdditionalDrive.attach(restored, to: &standard, directory: directory)
            check(standard.disks.map(\.path) == ["boot", "layer", url.path], "boot and layer order")
            check(standard.driveShares.count == 1 && standard.driveShares[0].readOnly, "read-only folder")
            check(standard.cmdline.contains("i:\(drive.uuid):\(drive.mountName)"), "guest mount record")
            drive.enabled = false
            AdditionalDrive.attach([drive], to: &boot, directory: directory)
            check(boot.disks.count == 2, "disabled image was attached")
            boot.explicit.insert("--disk")
            AdditionalDrive.attach(restored, to: &boot, directory: directory)
            check(boot.disks.count == 2 && boot.driveShares.isEmpty, "explicit CLI disks inherited saved devices")
            do { try folder.trashImage(in: directory); check(false, "folder eligible for deletion") } catch {}
            let trashed = try drive.trashImage(in: directory)
            check(!fm.fileExists(atPath: url.path), "idle disk was not trashed")
            if let trashed { try fm.removeItem(at: trashed) } // only this test's newly created disk
        } catch { failures.append("additional drives: \(error)") }
        log("selftest-settings: additional drives: \(failures.isEmpty ? "ok" : "failed")")
        return failures
    }

    private static func cursorSizeSelfCheck() -> [String] {
        let domain = "io.github.ralsei-x64.Stella.cursor-test-" + UUID().uuidString
        let previous = getenv("STEAMAC_DEFAULTS_DOMAIN").map { String(cString: $0) }
        setenv("STEAMAC_DEFAULTS_DOMAIN", domain, 1)
        let settings = LauncherSettings()
        defer {
            settings.defaults.removePersistentDomain(forName: domain)
            if let previous { setenv("STEAMAC_DEFAULTS_DOMAIN", previous, 1) }
            else { unsetenv("STEAMAC_DEFAULTS_DOMAIN") }
        }
        var failures: [String] = []
        if settings.cursorSize != .small { failures.append("cursor size: default") }
        settings.noteBoot(overrides: [:], autoCapture: nil)
        do {
            let args = ["steamac-vm", "--kernel", "/dev/null", "--disk", "/dev/null:ro", "--no-net", "--headless"]
            for size in LauncherSettings.CursorSize.allCases {
                settings.cursorSize = size
                let (options, _) = try Options.resolve(args, settings: settings)
                if LauncherSettings().cursorSize != size || options.cursorScaleHeight != size.scaleHeight
                    || settings.restartPending != (size != .small) {
                    failures.append("cursor size: persistence or next-start value for \(size)")
                }
            }
            let (overridden, _) = try Options.resolve(args + ["--cmdline", "steamac.cursor_scale_height=720"],
                                                      settings: settings)
            if overridden.cursorScaleHeight != 720 || settings.cursorSize != .large {
                failures.append("cursor size: one-boot override")
            }
        } catch { failures.append("cursor size: \(error)") }
        return failures
    }

    static func run(_ o: Options, overrides: [LauncherSettings.Key: String]) -> Never {
        let settings = LauncherSettings.shared
        let profileID = 2147483646
        let profileTestEnv = "STEAMAC_SELFTEST=\(profileID)"
        let savedProfile = settings.profile(for: profileID)
        let savedName = settings.gameName(profileID)
        settings.setGameName("A Profile self-test", for: profileID)
        settings.setProfile(GameProfile(gfx: "dxmt", driver: LauncherSettings.VulkanDriver.preferred.rawValue,
                                        env: profileTestEnv), for: profileID)
        settings.noteBoot(overrides: overrides, autoCapture: o.autoCapture)
        let app = SteamacApplication.shared
        app.setActivationPolicy(.regular)
        let context = SettingsContext(settings: settings, sound: nil, restart: { log("selftest: Restart VM pressed") },
                                      vmHasPad: o.gamepad, vmHasSound: o.sound)
        let sw = SettingsWindowController(context: context)
        final class Target: NSObject { var sw: SettingsWindowController?; @objc func open() { sw?.show() } }
        let target = Target()
        target.sw = sw
        MainMenu.installMinimal(settings: (#selector(Target.open), target))
        let dir = o.selftestOut ?? "."
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Crash-report scrubbing: the user, host, computer and Bonjour names never leave the Mac.
        var failures = CrashReporting.scrubSelfCheck() + CrashReporting.scannerSelfCheck() + CrashReporting.exitSelfCheck()
            + VMSizing.selfCheck()
            + UpdateChecker.selfCheck() + MacTime.selfCheck() + MacBattery.selfCheck() + Options.shareMountSelfCheck() + KeyboardLayoutSync.selfCheck() + ClipboardSync.selfCheck() + GameProfile.selfCheck()
            + SteamControllerRouting.selfCheck() + GenericHIDRouting.selfCheck() + PadPort.coalesceSelfCheck()
            + sharedLibrarySelfCheck() + additionalDriveSelfCheck() + cursorSizeSelfCheck()
        let savedVirtualPad = settings.virtualPad
        let savedPadType = settings.padType
        context.needsInputMonitoring = true
        settings.virtualPad = true
        for type in [LauncherSettings.PadType.auto, .steamController, .dualSense, .dualShock4, .xbox360] {
            settings.padType = type
            let expected = type == .auto || type == .steamController
            if context.showsInputMonitoringWarning != expected {
                failures.append("Input Monitoring warning: wrong visibility for \(type)")
            }
        }
        settings.padType = .auto
        settings.virtualPad = false
        if context.showsInputMonitoringWarning { failures.append("Input Monitoring warning: passthrough disabled") }
        settings.virtualPad = true
        context.needsInputMonitoring = false
        if context.showsInputMonitoringWarning { failures.append("Input Monitoring warning: permission not needed") }
        settings.virtualPad = savedVirtualPad
        settings.padType = savedPadType
        var tabs = SettingsWindowController.Tab.allCases[...]

        func capture(_ name: String, _ rep: NSBitmapImageRep?) {
            let path = "\(dir)/settings-\(name).png"
            guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
                failures.append("\(name): no capture")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                // Text and controls: a dense sample grid over the content area must find many colours.
                let n = 48
                let distinct = Set((0..<(n * n)).map { i -> UInt32 in
                    let c = rep.colorAt(x: (i % n) * rep.pixelsWide / n, y: (i / n) * rep.pixelsHigh / n)
                    return c.map { UInt32(($0.redComponent * 255).rounded()) << 16 | UInt32(($0.greenComponent * 255).rounded()) << 8
                        | UInt32(($0.blueComponent * 255).rounded()) } ?? 0
                })
                log("selftest-settings: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh), \(distinct.count) distinct sample colours")
                if distinct.count < 8 { failures.append("\(name): blank capture") }
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        func finish() {
            settings.removeGame(profileID)
            if settings.profile(for: profileID) != GameProfile() { failures.append("profiles: removeGame retained profile") }
            if let savedName { settings.setGameName(savedName, for: profileID) }
            settings.setProfile(savedProfile, for: profileID)
            log("selftest-settings: \(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: ", "))")
            exit(failures.isEmpty ? 0 : 1)
        }

        // SwiftUI can draw these buttons without NSButton subviews. Hit the rendered label
        // in our own window so this self-test also runs without macOS Accessibility access.
        func click(_ title: String, in window: NSWindow) -> Bool {
            guard let image = SettingsWindowController.snapshot(window)?.cgImage,
                  let frame = window.contentView?.superview else { return false }
            let text = VNRecognizeTextRequest()
            text.automaticallyDetectsLanguage = true
            do { try VNImageRequestHandler(cgImage: image).perform([text]) } catch { return false }
            func canonical(_ label: String) -> String {
                label.replacingOccurrences(of: "…", with: "...").replacingOccurrences(of: "×", with: "x")
                    .filter { !$0.isWhitespace }
            }
            let expected = canonical(title)
            let matches = (text.results ?? []).filter {
                $0.topCandidates(4).contains { canonical($0.string) == expected }
            }
            guard let box = matches.max(by: { $0.boundingBox.midY < $1.boundingBox.midY })?.boundingBox else {
                log("selftest-settings: button missing in snapshot: " + title)
                return false
            }
            let y = frame.isFlipped ? 1 - box.midY : box.midY
            let location = frame.convert(NSPoint(x: box.midX * frame.bounds.width, y: y * frame.bounds.height), to: nil)
            // AppKit buttons can run a tracking loop inside mouseDown. Queue the mouseUp first.
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            return true
        }

        // Open the visible SwiftUI picker through the window. Newer SwiftUI versions render
        // these controls directly, so there may be no NSPopUpButton in the view hierarchy.
        @MainActor func pickerItems(showing value: String, in window: NSWindow, selecting choice: String) async -> [String] {
            var items: [String] = []
            let center = NotificationCenter.default
            let observer = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu else { return }
                items = menu.items.map { $0.isSeparatorItem ? "----" : $0.title }
                let index = menu.indexOfItem(withTitle: choice)
                let select = Timer(timeInterval: 0.02, repeats: false) { _ in
                    menu.cancelTracking()
                    if index >= 0 { menu.performActionForItem(at: index) }
                }
                RunLoop.main.add(select, forMode: .common)
                RunLoop.main.add(select, forMode: .eventTracking)
            }
            defer { center.removeObserver(observer) }
            for _ in 0..<3 {
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(200))
                guard click(value, in: window) else { continue }
                try? await Task.sleep(for: .milliseconds(300))
                if !items.isEmpty { break }
            }
            return items
        }

        /// The Display tab with the real window-size popup items drawn next to it (a popup menu is
        /// its own window, which cacheDisplay cannot draw and screen capture needs permission for).
        func withMenuItems(_ tab: NSBitmapImageRep, _ items: [String], selected: String) -> NSBitmapImageRep? {
            let font = NSFont.menuFont(ofSize: 13), rowH: CGFloat = 22, pad: CGFloat = 6
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let menuW = (items.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 100) + 44
            let menuH = items.reduce(pad * 2) { $0 + ($1 == "----" ? 11 : rowH) }
            let size = NSSize(width: tab.size.width + menuW + 24, height: max(tab.size.height, menuH + 40))
            let scale = CGFloat(tab.pixelsWide) / tab.size.width
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            tab.draw(in: NSRect(x: 0, y: size.height - tab.size.height, width: tab.size.width, height: tab.size.height))
            let menuRect = NSRect(x: tab.size.width + 12, y: size.height - 30 - menuH, width: menuW, height: menuH)
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: menuRect, xRadius: 6, yRadius: 6)
            path.fill()
            path.stroke()
            ("Window size popup (items read from the live menu)" as NSString)
                .draw(at: NSPoint(x: menuRect.minX, y: menuRect.maxY + 8),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            var y = menuRect.maxY - pad
            for item in items {
                if item == "----" {
                    y -= 11
                    NSColor.separatorColor.setFill()
                    NSRect(x: menuRect.minX + 10, y: y + 5, width: menuW - 20, height: 1).fill()
                    continue
                }
                y -= rowH
                if item == selected { ("✓" as NSString).draw(at: NSPoint(x: menuRect.minX + 10, y: y + 3), withAttributes: attrs) }
                (item as NSString).draw(at: NSPoint(x: menuRect.minX + 28, y: y + 3), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        /// Background mute: a SoundControl with a recording krun_snd_set_volume shim, driven by
        /// simulated NSApplication resign/become-active notifications and user mute changes.
        func backgroundMute(then done: @escaping () -> Void) {
            var calls: [(Float, Bool)] = []
            let sound = SoundControl(volumeShim: { _, g, m in calls.append((g, m)); return 0 })
            let nc = NotificationCenter.default
            var steps: [(String, () -> Void, ([(Float, Bool)]) -> Bool)] = [
                ("attach", { sound.attach(ctx: 7, volume: 0.8, mute: false, muteInBackground: true) },
                 { $0.count == 1 && $0[0] == (0.8, false) }),
                ("resign active: fade out + mute", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) },
                 { c in c.last! == (0.8, true) && c.count >= 3 && c.dropLast().allSatisfy { !$0.1 }
                     && zip(c.dropLast(), c.dropLast().dropFirst()).allSatisfy { $0.0 > $1.0 } }),
                ("become active: unmute + fade in", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) },
                 { c in c.first! == (0, false) && c.last! == (0.8, false) && c.allSatisfy { !$0.1 } }),
                ("user mute", { sound.setUser(volume: 0.8, mute: true) }, { $0.count == 1 && $0[0] == (0.8, true) }),
                ("resign while user-muted", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) }, { $0.isEmpty }),
                ("become active while user-muted", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) }, { $0.isEmpty }),
                ("user unmute", { sound.setUser(volume: 0.8, mute: false) }, { $0.count == 1 && $0[0] == (0.8, false) }),
                ("option off", { sound.setMuteInBackground(false) }, { $0.isEmpty }),
                ("resign with option off", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) }, { $0.isEmpty }),
                ("option on while inactive: fade out + mute", { sound.setMuteInBackground(true) }, { $0.last.map { $0 == (0.8, true) } ?? false }),
                ("become active", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) }, { $0.last.map { $0 == (0.8, false) } ?? false }),
            ]
            func step() {
                guard !steps.isEmpty else {
                    sound.detach(reason: "selftest done")
                    return done()
                }
                let (name, action, check) = steps.removeFirst()
                calls.removeAll()
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let text = calls.map { "(\(String(format: "%.2f", $0.0)), \($0.1 ? "mute" : "on"))" }.joined(separator: " ")
                    let ok = check(calls)
                    log("selftest-settings: background mute: \(name): \(ok ? "ok" : "FAIL") \(text)")
                    if !ok { failures.append("background mute: \(name): \(text)") }
                    step()
                }
            }
            step()
        }

        func compactAlerts(then done: @escaping () -> Void) {
            sw.show(tab: .advanced)
            let reclaimed = DiskCompact.Outcome(path: "selftest.img", beforeAllocated: 8 << 30,
                                                afterAllocated: 4 << 30, detail: "trimmed")
            let unchanged = DiskCompact.Outcome(path: "selftest.img", beforeAllocated: 4 << 30,
                                                afterAllocated: 4 << 30, detail: "already compact")
            var cases: [(String, Result<DiskCompact.Outcome, OptionError>, Bool, Int)] = [
                ("reclaimed sheet", .success(reclaimed), true, 0),
                ("unchanged sheet", .success(unchanged), true, 0),
                ("failure sheet", .failure(OptionError("selftest trim failure")), true, 0),
                ("reclaimed standalone", .success(reclaimed), false, 0),
                ("failure standalone", .failure(OptionError("selftest trim failure")), false, 0),
                ("cancel sheet", .success(reclaimed), true, 1),
                ("cancel standalone", .success(reclaimed), false, 1),
            ]
            func nextAlert() {
                guard !cases.isEmpty else { return done() }
                let (name, result, sheet, button) = cases.removeFirst()
                let alert = DiskCompactAlert.result(result)
                if button == 1 { alert.addButton(withTitle: String(localized: "Cancel")) }
                let expected = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + button)
                var responses: [NSApplication.ModalResponse] = []
                // A regression to runModal must fail rather than leave this self-test hanging.
                let watchdog = Timer(timeInterval: 1.5, repeats: false) { _ in
                    failures.append("compaction \(name): presentation blocked the main queue")
                    NSApp.modalWindow?.orderOut(nil)
                    NSApp.abortModal()
                }
                RunLoop.main.add(watchdog, forMode: .common)
                RunLoop.main.add(watchdog, forMode: .modalPanel)
                DiskCompactAlert.present(alert, for: sheet ? sw.window : nil) { responses.append($0) }
                watchdog.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let visible = alert.window.isVisible && NSApp.modalWindow == nil
                        && (!sheet || sw.window.attachedSheet === alert.window)
                    if !visible || !responses.isEmpty || alert.informativeText.isEmpty {
                        failures.append("compaction \(name): alert missing, modal or completed before dismissal")
                    }
                    log("selftest-settings: compaction \(name): main-queue callback ran while alert remained open: \(visible ? "ok" : "FAIL")")
                    alert.buttons[button].performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if responses != [expected] || alert.window.isVisible {
                            failures.append("compaction \(name): dismissal responses=\(responses.map(\.rawValue)) visible=\(alert.window.isVisible)")
                        }
                        nextAlert()
                    }
                }
            }
            nextAlert()
        }

        /// Display tab: open the real window-size popup, check its items (every size preset, Fit to screen,
        /// Custom…) → DIR/settings-display-presets.{txt,png}, then reveal "Custom…"
        /// (settings-display-custom.png). The saved window size is restored afterwards.
        func displayPresets(then done: @escaping () -> Void) {
            let saved = (settings.windowSizePreset, settings.windowWidth, settings.windowHeight)
            let customTitle = String(localized: "Custom…")
            let fit = LauncherSettings.fitToScreenSize()
            let fitTitle = String(localized: "Fit to screen (\(String(fit.0)) × \(String(fit.1)))")
            let presetTitles = LauncherSettings.sizePresets.map { p in
                String(localized: "\(String(p.width)) × \(String(p.height)) (\(p.label))")
            }
            let largerPresetTitles = LauncherSettings.sizePresets.map { p in
                String(localized: "\(String(p.width)) × \(String(p.height)) (\(p.label)) — larger than this screen")
            }
            sw.show(tab: .display)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                let selected: String
                if let index = LauncherSettings.sizePresets.firstIndex(where: { $0.id == saved.0 }) {
                    let preset = LauncherSettings.sizePresets[index]
                    selected = preset.width > fit.0 || preset.height > fit.1 ? largerPresetTitles[index] : presetTitles[index]
                } else {
                    selected = saved.0 == LauncherSettings.fitPreset ? fitTitle : customTitle
                }
                let tabShot = sw.snapshot()
                let titles = await pickerItems(showing: selected, in: sw.window, selecting: customTitle)
                let path = "\(dir)/settings-display-presets.txt"
                try? (titles.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                let presets = titles.filter { presetTitles.contains($0) || largerPresetTitles.contains($0) }
                log("selftest-settings: \(path): \(titles.count) items, \(presets.count) presets,"
                    + " \(titles.filter { largerPresetTitles.contains($0) }.count) larger than this screen")
                if presets.count != LauncherSettings.sizePresets.count || !titles.contains(customTitle)
                    || !titles.contains(fitTitle) {
                    failures.append("display-presets: unexpected items \(titles)")
                }
                capture("display-presets", tabShot.flatMap { withMenuItems($0, titles, selected: selected) })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if settings.windowSizePreset != LauncherSettings.customPreset { failures.append("display-presets: Custom was not selected") }
                    capture("display-custom", sw.snapshot())
                    (settings.windowSizePreset, settings.windowWidth, settings.windowHeight) = saved
                    done()
                }
            }
        }

        /// Advanced tab with a custom VM size above this Mac's limits (all cores, all the RAM the
        /// stepper allows): both orange warnings (settings-advanced-custom.png). Restored afterwards.
        func advancedCustom(then done: @escaping () -> Void) {
            let saved = (settings.cpus, settings.memMiB)
            settings.cpus = ProcessInfo.processInfo.activeProcessorCount
            settings.memMiB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 4) * 1024
            let host = VMSizing.Host.current
            log("selftest-settings: advanced custom: \(settings.cpus) vCPUs (warning: \(VMSizing.cpuWarning(cpus: settings.cpus, host: host) != nil)), "
                + "\(settings.memMiB) MiB (warning: \(VMSizing.memWarning(memMiB: settings.memMiB, host: host) != nil))")
            sw.show(tab: .advanced)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                capture("advanced-custom", sw.snapshot())
                let savedAdvanced = (settings.advancedMemory, settings.advancedRAMMiB, settings.advancedVRAMMiB)
                settings.memoryMode = .advanced
                settings.advancedRAMMiB = 3584
                settings.advancedVRAMMiB = 24577
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    capture("advanced-memory", sw.snapshot())
                    (settings.advancedMemory, settings.advancedRAMMiB, settings.advancedVRAMMiB) = savedAdvanced
                    (settings.cpus, settings.memMiB) = saved
                    done()
                }
            }
        }

        /// Drive the same sheet used by a player. Draft edits reach disk only when applied.
        func profileLaunchOptions(then done: @escaping () -> Void) {
            func views(_ root: NSView?) -> [NSView] {
                guard let root else { return [] }
                return [root] + root.subviews.flatMap { views($0) }
            }
            @MainActor func openEditor() async -> NSWindow? {
                for _ in 0..<2 {
                    sw.window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(200))
                    guard click(String(localized: "Compatibility…"), in: sw.window) else { continue }
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(75))
                        if let sheet = sw.window.attachedSheet, sheet.isVisible { return sheet }
                    }
                }
                return nil
            }
            Task { @MainActor in
                defer { done() }
                let presetName = "Self-test " + UUID().uuidString
                let initial = settings.profile(for: profileID)
                settings.savePreset(initial, named: presetName)
                if LauncherSettings().savedPresets[presetName] != initial {
                    failures.append("profiles: personal preset did not persist")
                }
                settings.removePreset(named: presetName)
                if LauncherSettings().savedPresets[presetName] != nil || settings.profile(for: profileID) != initial {
                    failures.append("profiles: deleting preset changed a game or retained the preset")
                }
                var expected = profileTestEnv
                let shaderPreset = CompatibilityPreset.builtIns(for: profileID).first { $0.id == "sm66" }!
                for (value, apply) in [(shaderPreset.profile.env, true), ("PROTON_LOG=1", false), ("", true), ("VKD3D_CONFIG=dxr", true), ("", true)] {
                    guard let sheet = await openEditor() else { failures.append("profiles: could not open editor for \(value)"); return }
                    try? await Task.sleep(for: .milliseconds(300))
                    let content = views(sheet.contentView)
                    guard let field = content.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                          field.stringValue == expected else { failures.append("profiles: reopened launch options differ"); return }
                    if value == shaderPreset.profile.env {
                        _ = await pickerItems(showing: String(localized: "Custom settings"), in: sheet, selecting: shaderPreset.name)
                        try? await Task.sleep(for: .milliseconds(250))
                        guard field.stringValue == value else { failures.append("profiles: preset did not populate the editor"); return }
                        capture("compatibility", SettingsWindowController.snapshot(sheet))
                    } else {
                        field.selectText(nil)
                        guard let editor = field.currentEditor() as? NSTextView else { failures.append("profiles: editor missing"); return }
                        editor.selectAll(nil)
                        editor.insertText(value, replacementRange: editor.selectedRange())
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard settings.profile(for: profileID).env == expected else { failures.append("profiles: draft applied early"); return }
                    let title = apply ? String(localized: "Apply") : String(localized: "Cancel")
                    sheet.makeFirstResponder(nil)
                    let key = apply ? "\r" : "\u{1b}"
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                        characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                        keyCode: UInt16(apply ? kVK_Return : kVK_Escape))
                    if event.map(sheet.performKeyEquivalent) != true && !click(title, in: sheet) {
                        failures.append("profiles: missing sheet action " + title); return
                    }
                    for _ in 0..<20 where sw.window.attachedSheet != nil {
                        try? await Task.sleep(for: .milliseconds(75))
                    }
                    guard sw.window.attachedSheet == nil else { failures.append("profiles: \(title) did not dismiss the sheet"); return }
                    if apply { expected = value }
                    if LauncherSettings().profile(for: profileID).env != expected { failures.append("profiles: sheet persistence") }
                }

                // Exercise the title-specific menu section without writing a real game's profile.
                guard LauncherSettings.VulkanDriver.kosmickrisp.unavailableReason == nil else { return }
                let game = GameStatsStore.Game(appid: 3357650, name: "PRAGMATA")
                guard let titlePreset = CompatibilityPreset.forGame(game.appid).first else {
                    failures.append("profiles: missing PRAGMATA preset"); return
                }
                let editor = GameCompatibilityEditor(game: game, profile: GameProfile(), recommendations: GameRecommendations())
                    .environmentObject(settings)
                let window = NSWindow(contentViewController: NSHostingController(rootView: editor))
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                try? await Task.sleep(for: .milliseconds(450))
                let items = await pickerItems(showing: String(localized: "Stella defaults"), in: window, selecting: titlePreset.name)
                try? await Task.sleep(for: .milliseconds(250))
                let field = views(window.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable }
                if !items.contains(titlePreset.name) || field?.stringValue != titlePreset.profile.env {
                    failures.append("profiles: selecting the PRAGMATA preset did not load its launch options")
                }
                capture("compatibility-title", SettingsWindowController.snapshot(window))
            }
        }

        func checkDriveWizard(then done: @escaping () -> Void) {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DriveManager(settings: settings)))
            window.title = String(localized: "Additional drives")
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            Task { @MainActor in
                defer { window.close(); done() }
                for (screen, button) in [("drives", String(localized: "Add Drive…")),
                                         ("drive-type", String(localized: "Continue")),
                                         ("drive-capacity", String(localized: "Cancel"))] {
                    try? await Task.sleep(for: .milliseconds(300))
                    capture(screen, SettingsWindowController.snapshot(window))
                    guard click(button, in: window) else {
                        failures.append("drive wizard: could not press " + button)
                        return
                    }
                }
            }
        }

        func next() {
            guard let tab = tabs.popFirst() else {
                CreateDiskWindowController.show(settings: settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    capture("create-disk", CreateDiskWindowController.visibleWindow.flatMap(SettingsWindowController.snapshot))
                    CreateDiskWindowController.visibleWindow?.close()
                    let alert = FirstRun.makeAlert(settings: settings)
                    alert.layout()
                    alert.window.center()
                    alert.window.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        capture("first-run", SettingsWindowController.snapshot(alert.window))
                        alert.window.orderOut(nil)
                        // The "What is sent" popover content, in a plain window.
                        let host = NSHostingView(rootView: WhatIsSentView())
                        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                                         backing: .buffered, defer: false)
                        w.title = String(localized: "What is sent")
                        w.contentView = host
                        w.isReleasedWhenClosed = false
                        w.center()
                        w.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            capture("what-is-sent", SettingsWindowController.snapshot(w))
                            w.orderOut(nil)
                            compactAlerts { displayPresets { advancedCustom { checkDriveWizard { backgroundMute(then: finish) } } } }
                        }
                    }
                }
                return
            }
            sw.show(tab: tab)
            // Let the tab switch animation and SwiftUI layout settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                capture(tab.name, sw.snapshot())
                if tab == .games { profileLaunchOptions(then: next) }
                else { next() }
            }
        }
        DispatchQueue.main.async {
            app.activate()
            guard let menu = app.mainMenu?.items.first?.submenu,
                  let item = menu.items.first(where: { $0.action == #selector(AboutWindowController.show(_:)) }) else {
                failures.append("About Stella menu item missing")
                return next()
            }
            sw.show()
            if let screen = sw.window.screen {
                let size = sw.window.frame.size
                sw.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
                sw.window.close()
                sw.show()
                let frame = sw.window.frame
                if frame.size != size || abs(frame.midX - screen.visibleFrame.midX) > 1
                    || abs(frame.midY - screen.visibleFrame.midY) > 1 {
                    failures.append("settings: reopen did not center the existing window size")
                }
            }
            if sw.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua {
                failures.append("settings: window did not inherit Stella’s dark appearance")
            }
            if let split = sw.window.contentViewController?.children.compactMap({ $0 as? NSSplitViewController }).first,
               let sidebar = split.splitViewItems.first, let toolbar = sw.window.toolbar {
                for collapsed in [false, true, false] {
                    sidebar.isCollapsed = collapsed
                    sw.window.contentView?.layoutSubtreeIfNeeded()
                    let panes = split.splitView.arrangedSubviews
                    if !collapsed, panes.count == 2, abs(panes[0].frame.maxX - panes[1].frame.minX) > 0.01 {
                        failures.append("settings: sidebar leaves a gap between panes")
                    }
                    let hasTrackingDivider = toolbar.items.contains { $0 is NSTrackingSeparatorToolbarItem }
                    if hasTrackingDivider == collapsed ||
                        (collapsed && toolbar.items.first?.label != String(localized: "Toggle Sidebar")) {
                        failures.append("settings: toolbar layout did not follow sidebar collapse")
                    }
                }
            } else { failures.append("settings: sidebar or toolbar missing") }
            menu.performActionForItem(at: menu.index(of: item))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let about = app.windows.first(where: { $0.isVisible && $0.title == item.title }) {
                    capture("about-popup", SettingsWindowController.snapshot(about))
                    if about.styleMask.contains(.titled) || about.isOpaque || about.backgroundColor.alphaComponent != 0 {
                        failures.append("About Stella has an outer window surface")
                    }
                    if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: about.windowNumber, context: nil, characters: "\u{1b}",
                                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
                        app.sendEvent(escape)
                    }
                    if about.isVisible { failures.append("Escape did not close About Stella") }
                    menu.performActionForItem(at: menu.index(of: item))
                    if let popup = app.windows.first(where: { $0.isVisible && $0.title == item.title }) {
                        let center = CGPoint(x: popup.frame.width / 2, y: popup.frame.height / 2)
                        for (location, inside) in [(center, true), (CGPoint(x: 2, y: 2), false)] {
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let click = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { app.sendEvent(click) }
                            }
                            if popup.isVisible != inside { failures.append("About click hit the wrong region") }
                        }
                    } else { failures.append("About Stella did not reopen") }
                } else {
                    failures.append("About Stella did not open from the application menu")
                }
                next()
            }
        }
        app.run()
        exit(0)
    }
}
