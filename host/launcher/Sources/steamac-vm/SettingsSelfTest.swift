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
        let app = NSApplication.shared
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
            + UpdateChecker.selfCheck() + MacTime.selfCheck() + Options.shareMountSelfCheck() + KeyboardLayoutSync.selfCheck() + ClipboardSync.selfCheck() + GameProfile.selfCheck()
            + SteamControllerRouting.selfCheck() + GenericHIDRouting.selfCheck() + PadPort.coalesceSelfCheck()
            + sharedLibrarySelfCheck() + cursorSizeSelfCheck()
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

        /// SwiftUI menu pickers (SwiftUIPopupButton, an NSButton with a menu).
        func popups(in view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            if let b = view as? NSButton, "\(type(of: b))".contains("Popup") { return [b] }
            return view.subviews.flatMap { popups(in: $0) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let popup = popups(in: sw.window.contentView)
                    .first(where: { presetTitles.contains($0.title) || largerPresetTitles.contains($0.title)
                        || $0.title == fitTitle || $0.title == customTitle }) else {
                    failures.append("display-presets: no window size popup")
                    return done()
                }
                let selected = popup.title
                let tabShot = sw.snapshot()
                func itemTitles() -> [String] { popup.menu?.items.map { $0.isSeparatorItem ? "----" : $0.title } ?? [] }
                // SwiftUI fills the picker's menu only when it opens. Read the items the moment
                // tracking begins, then close it. While another app is frontmost (the Mac in use)
                // an open can fail — tracking never starts, or ends at once when the other app
                // takes activation — so re-activate and retry a few times.
                var titles: [String] = []
                var attempts = 0
                let nc = NotificationCenter.default
                let began = nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                    guard let menu = n.object as? NSMenu, menu === popup.menu else { return }
                    titles = itemTitles()
                    DispatchQueue.main.async { menu.cancelTracking() }
                }
                DispatchQueue.main.async {
                    while titles.isEmpty && attempts < 4 {
                        attempts += 1
                        NSApp.activate()
                        sw.window.makeKeyAndOrderFront(nil)
                        // Safety net: never leave the menu open if the notification was missed.
                        let timer = Timer(timeInterval: 1, repeats: false) { _ in
                            if titles.isEmpty { titles = itemTitles() }
                            popup.menu?.cancelTracking()
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        popup.performClick(nil)   // returns when the menu closes (or at once if it did not open)
                        timer.invalidate()
                        if titles.isEmpty {
                            log("selftest-settings: window size popup did not open (attempt \(attempts), app active: \(NSApp.isActive))")
                            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                        }
                    }
                    nc.removeObserver(began)
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
                    settings.windowSizePreset = LauncherSettings.customPreset
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        capture("display-custom", sw.snapshot())
                        (settings.windowSizePreset, settings.windowWidth, settings.windowHeight) = saved
                        done()
                    }
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
                (settings.cpus, settings.memMiB) = saved
                done()
            }
        }

        /// Drive the same sheet used by a player. Draft edits reach disk only when applied.
        func profileLaunchOptions(then done: @escaping () -> Void) {
            func views(_ root: NSView?) -> [NSView] {
                guard let root else { return [] }
                return [root] + root.subviews.flatMap { views($0) }
            }
            // SwiftUI can draw these buttons without NSButton subviews. Hit the rendered label
            // in our own window so this self-test also runs without macOS Accessibility access.
            func click(_ title: String, in window: NSWindow) -> Bool {
                guard let image = SettingsWindowController.snapshot(window)?.cgImage,
                      let frame = window.contentView?.superview else { return false }
                let text = VNRecognizeTextRequest()
                text.automaticallyDetectsLanguage = true
                do { try VNImageRequestHandler(cgImage: image).perform([text]) } catch { return false }
                func canonical(_ label: String) -> String { label.replacingOccurrences(of: "…", with: "...") }
                let matches = (text.results ?? []).filter {
                    $0.topCandidates(1).first.map { canonical($0.string) == canonical(title) } == true
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
            @MainActor func selectPreset(_ preset: CompatibilityPreset, from popup: NSButton) async {
                let center = NotificationCenter.default
                let observer = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu, menu === popup.menu else { return }
                    let index = menu.indexOfItem(withTitle: preset.name)
                    DispatchQueue.main.async {
                        menu.cancelTracking()
                        if index >= 0 { menu.performActionForItem(at: index) }
                    }
                }
                let timer = Timer(timeInterval: 1, repeats: false) { _ in popup.menu?.cancelTracking() }
                RunLoop.main.add(timer, forMode: .common)
                popup.performClick(nil)
                timer.invalidate()
                center.removeObserver(observer)
                try? await Task.sleep(for: .milliseconds(250))
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
                    guard click(String(localized: "Compatibility…"), in: sw.window) else { failures.append("profiles: editor button missing"); return }
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let sheet = sw.window.attachedSheet else { failures.append("profiles: sheet missing"); return }
                    let content = views(sheet.contentView)
                    guard let field = content.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                          field.stringValue == expected else { failures.append("profiles: reopened launch options differ"); return }
                    if value == shaderPreset.profile.env {
                        guard let popup = popups(in: sheet.contentView).first(where: { $0.title == String(localized: "Custom settings") })
                        else { failures.append("profiles: preset picker missing"); return }
                        await selectPreset(shaderPreset, from: popup)
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
                    guard click(title, in: sheet) else { failures.append("profiles: missing sheet action " + title); return }
                    try? await Task.sleep(for: .milliseconds(350))
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
                guard let picker = popups(in: window.contentView).first(where: { $0.title == String(localized: "Stella defaults") })
                else { failures.append("profiles: title preset picker missing"); return }
                await selectPreset(titlePreset, from: picker)
                let field = views(window.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable }
                if picker.title != titlePreset.name || field?.stringValue != titlePreset.profile.env {
                    failures.append("profiles: selecting the PRAGMATA preset did not load its launch options")
                }
                capture("compatibility-title", SettingsWindowController.snapshot(window))
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
                            compactAlerts { displayPresets { advancedCustom { backgroundMute(then: finish) } } }
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
            menu.performActionForItem(at: menu.index(of: item))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let about = app.windows.first(where: { $0.isVisible && $0.title == item.title }) {
                    capture("about", SettingsWindowController.snapshot(about))
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
