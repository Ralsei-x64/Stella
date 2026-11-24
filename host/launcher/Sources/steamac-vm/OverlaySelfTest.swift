import AppKit
import CKrun
import Foundation

/// `--selftest-overlay`: a real window + Metal view + FX overlay, driven exactly like a boot:
/// console bytes go through LineSplitter → BootProgress.consoleLine, guest lines are written into
/// the real fx.progress pipe (the fd libkrun would write) and read back by ProgressPort's thread.
/// At each step it captures the presented drawable with the overlay composited at 2x, writes a
/// PNG and checks state + pixels (overlay visible/hidden, bar fill position).
enum OverlaySelfTest {
    struct Step {
        let name: String
        let console: String
        let guest: String
        let wait: Double
        let check: (BootProgress, OverlayView) -> String?
    }

    static func run(_ o: Options) -> Never {
        let app = SteamacApplication.shared
        app.setActivationPolicy(.accessory)
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let W = o.displayWidth, H = o.displayHeight
        let wc = WindowController(title: windowTitleForTest, width: W, height: H, renderer: renderer, inputs: nil, mouseMode: .auto)
        presenter.view = wc.view
        wc.view.metalLayer.framebufferOnly = false
        presenter.onScanoutResize = { w, h in wc.scanoutResized(width: w, height: h) }
        wc.onCloseRequest = { exit(2) }
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let progress = BootProgress()
        var rebootIntents = 0
        progress.onRebootIntent = { rebootIntents += 1 }
        wc.attach(progress: progress)
        let port: ProgressPort
        do { port = try ProgressPort() } catch { fatal("\(error)") }
        port.start { progress.guestLine($0) }
        var splitter = LineSplitter()
        func console(_ s: String) {
            var bytes = Array(s.utf8)
            bytes.withUnsafeMutableBytes { p in splitter.feed(UnsafeRawBufferPointer(p)) { progress.consoleLine($0) } }
        }
        func guest(_ s: String) {
            _ = s.withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
        }

        wc.window.ignoresMouseEvents = true
        wc.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        wc.window.orderBack(nil)
        log("overlay selftest: window \(wc.window.windowNumber) backingScale=\(wc.window.backingScaleFactor)")

        let ok = "[\u{1b}[0;32m  OK  \u{1b}[0m] "
        let startedLines = (1...40).map { "\(ok)Started Example Service \($0).\r\n" }.joined()
        let stoppedLines = (1...30).map { "\(ok)Stopped Example Service \($0).\r\n" }.joined()
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        var shutdownPillAppeared = false
        let pillVisibilityChanged = wc.pill.onVisibilityChange
        wc.pill.onVisibilityChange = {
            pillVisibilityChanged?()
            if case .shutdown = progress.state.phase, wc.pill.shown { shutdownPillAppeared = true }
        }
        let steps: [Step] = [
            Step(name: "01-vm", console: "", guest: "", wait: 0.8) { p, ov in
                p.state.stageId == "vm" && ov.shown ? nil : "expected vm stage, overlay shown" },
            Step(name: "02-kernel", console: "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]\n",
                 guest: "", wait: 0.6) { p, _ in
                p.state.stageId == "kernel" && near(p.state.fraction, 0.03) ? nil : "expected kernel 3%, got \(p.state)" },
            Step(name: "02a-console-colors", console: "\(ok)Mounted root file system.\r\n"
                 + "[ WARN ] Optional disk is taking longer than expected.\r\n"
                 + "[\u{1b}[0;31mFAILED\u{1b}[0m] Optional disk mount failed.\r\n",
                 guest: "", wait: 0.6) { p, _ in
                p.verboseLines.last?.string == "[FAILED] Optional disk mount failed." ? nil : "unexpected console text"
            },
            Step(name: "03-systemd", console: "steamac-init: switching to rootfs-A (/dev/vda4), init /sbin/init\r\n\r\nWelcome to \u{1b}[1mSteamOS\u{1b}[0m!\r\n" + startedLines,
                 guest: "", wait: 0.8) { p, _ in
                p.state.stageId == "systemd" && p.state.fraction > 0.2 && p.state.fraction < 0.3
                    && p.state.detail == "Started Example Service 40" ? nil : "expected systemd 20-30%, got \(p.state)" },
            Step(name: "04-download", console: "\(ok)Reached target \u{1b}[0;1;39mGraphical Interface\u{1b}[0m.\r\n",
                 guest: "stage session 100 Starting Steam session\nstage steam-check 100 Checking for Steam updates\n"
                    + "stage steam-download 37 Downloading Steam update\nlog 245 / 662 MB · 12.4 MB/s\n", wait: 0.8) { p, _ in
                p.state.stageId == "steam-download" && near(p.state.fraction, 0.40 + 0.45 * 0.37)
                    && p.state.detail == "245 / 662 MB · 12.4 MB/s" ? nil : "expected download 56.65%, got \(p.state)" },
            Step(name: "04a-download-total-unknown", console: "", guest: "stage steam-download -1 Downloading Steam update\n",
                 wait: 0.6) { p, _ in
                near(p.state.fraction, 0.5665) ? nil : "lost the last reported download progress" },
            Step(name: "05-starting", console: "", guest: "stage steam-install 100 Installing\nstage steam-start -1 Starting Steam\n",
                 wait: 0.9) { p, ov in
                p.state.stageId == "steam-start" && near(p.state.fraction, 0.95)
                    && (ov.accessibilityValue() as? NSNumber)?.doubleValue == p.state.fraction
                    ? nil : "expected 95% while waiting for Steam, got \(p.state)" },
            Step(name: "05a-loading-ui", console: "", guest: "stage steam-start 50 Loading Steam UI\n", wait: 0.6) { p, _ in
                near(p.state.fraction, 0.975) ? nil : "expected 97.5% when Steam UI starts loading" },
            Step(name: "06-ready-hidden", console: "", guest: "ready\n", wait: 1.4) { p, ov in
                p.state.phase == .running && near(p.state.fraction, 1) && ov.isIdle ? nil : "expected 100% and an idle overlay (hidden=\(ov.isHidden), animations=\(ov.layer?.sublayers?.flatMap { $0.animationKeys() ?? [] } ?? []))" },
            Step(name: "06a-shutdown-entry", console: "         Stopping Session 2 of User steamos...\r\n\(ok)Stopped target Graphical Interface.\r\n",
                 guest: "", wait: 0) { p, ov in
                CATransaction.flush()
                guard p.state.phase == .shutdown(reboot: false), ov.shown, !ov.isHidden, ov.alphaValue == 1,
                      let layer = ov.layer, layer.opacity == 1,
                      layer.animation(forKey: "opacity") == nil, layer.animation(forKey: kCATransition) == nil
                else { return "expected the shutdown screen at full opacity immediately" }
                if shutdownPillAppeared { return "compact progress flashed before the shutdown screen" }
                let loaders: [LoaderCardView] = [wc.pill, wc.stallView, wc.resumeChip]
                for loader in loaders {
                    guard loader.isHidden, loader.surface.isHiddenOrHasHiddenAncestor,
                          loader.surface.layer?.animation(forKey: "statusPop") == nil else {
                        return "\(type(of: loader)) still presents its material at shutdown"
                    }
                }
                guard wc.sleepView.isHidden, wc.pauseView.isHidden else { return "sleep or pause card still visible at shutdown" }
                if let screen = wc.windowServerImage() {
                    let image = NSBitmapImageRep(cgImage: screen)
                    if let color = image.colorAt(x: screen.width * 3 / 4, y: screen.height / 4)?.usingColorSpace(.sRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 {
                        return "guest frame showed through the shutdown background"
                    }
                    do { try PNG.write(screen, to: "\(outDir)/shutdown-first-frame.png") }
                    catch { return "could not capture shutdown entry: \(error)" }
                }
                return nil
            },
            Step(name: "07-shutting-down", console: stoppedLines,
                 guest: "", wait: 1.0) { p, ov in
                p.state.phase == .shutdown(reboot: false) && ov.shown && p.state.fraction > 0.4 && p.state.fraction < 0.9
                    ? nil : "expected shutdown in progress with overlay shown, got \(p.state)" },
            Step(name: "08-final-step", console: "\(ok)Reached target \u{1b}[0;1;39mFinal Step\u{1b}[0m.\r\n", guest: "", wait: 0.6) { p, _ in
                near(p.state.fraction, 0.95) ? nil : "expected 95% at Final Step, got \(p.state)" },
            Step(name: "09-restarting", console: "", guest: "shutdown reboot\n", wait: 0.6) { p, ov in
                p.state.phase == .shutdown(reboot: true) && ov.currentTitle == String(localized: "Restarting…") && rebootIntents == 1
                    ? nil : "expected Restarting… + one reboot intent, got \(p.state) intents=\(rebootIntents)" },
            Step(name: "10-power-down", console: "[  123.456789] reboot: Restarting system\r\n", guest: "", wait: 0.6) { p, _ in
                near(p.state.fraction, 1) ? nil : "expected 100%, got \(p.state)" },
        ]

        let driver = Thread {
            // Guest picture behind the overlay (quadrants), through the real display vtable.
            let cb = display.makeCBackend()
            var inst: UnsafeMutableRawPointer?
            _ = cb.create!(&inst, cb.create_userdata, nil)
            let fb = cb.vtable.basic_framebuffer
            let fmt = UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM)
            _ = fb.configure_scanout!(inst, 0, UInt32(W), UInt32(H), UInt32(W), UInt32(H), fmt)
            var ptr: UnsafeMutablePointer<UInt8>?
            var size = 0
            let id = fb.alloc_frame!(inst, 0, &ptr, &size)
            SelfTest.fill(ptr!, width: W, height: H, format: fmt, square: true)
            _ = fb.present_frame!(inst, 0, UInt32(id), nil)

            var failures: [String] = []
            for step in steps {
                DispatchQueue.main.sync {
                    if step.name == "06a-shutdown-entry" {
                        // Shutdown can interrupt a resume indicator while its exit blur is still running.
                        wc.resumeChip.show(String(localized: "Resuming…"))
                        wc.resumeChip.hide()
                    }
                    if !step.console.isEmpty { console(step.console) }
                    if !step.guest.isEmpty { guest(step.guest) }
                }
                Thread.sleep(forTimeInterval: step.wait)
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var shot: CGImage?
                DispatchQueue.main.sync {
                    if let msg = step.check(progress, wc.overlay) { failures.append("\(step.name): \(msg)") }
                    if wc.overlay.verbose && wc.overlay.shown {
                        let rows = progress.verboseLines.map(\.string)
                        if rows.isEmpty || rows.count > 96 { failures.append("\(step.name): invalid log history") }
                        if case .shutdown = progress.state.phase, rows.contains("245 / 662 MB · 12.4 MB/s") {
                            failures.append("\(step.name): boot output leaked into shutdown")
                        }
                    }
                    wc.captureWindow { _, composite in shot = composite; sem.signal() }
                }
                guard sem.wait(timeout: .now() + 5) == .success, let img = shot else {
                    failures.append("\(step.name): capture timed out")
                    continue
                }
                let path = "\(outDir)/overlay-\(step.name).png"
                do { try PNG.write(img, to: path) } catch { failures.append("\(step.name): \(error)") }
                failures += DispatchQueue.main.sync { pixelChecks(step.name, img, wc, progress.state) }
                log("overlay selftest: \(step.name) \(progress.state.stageId) \(Int(progress.state.fraction * 100))% "
                    + "overlay=\(wc.overlay.shown ? "shown" : "hidden") -> \(path)")
            }
            // Host-requested power-off must never be mistaken for a reboot (libkrun's power key is KEY_RESTART).
            DispatchQueue.main.sync {
                let p2 = BootProgress()
                let sample = VerboseLogStyle.line("💿\u{1b}[32mgreen\u{1b}[0m plain", stage: false)
                func color(_ at: Int) -> NSColor? {
                    (sample.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                }
                if sample.string != "💿green plain" || color(2)?.greenComponent == color(2)?.redComponent
                        || color(7)?.redComponent != 1 {
                    failures.append("ANSI foreground or reset lost after a non-ASCII character")
                }
                for i in 0..<110 { p2.consoleLine("kernel line \(i)") }
                if p2.verboseLines.count != 96 || p2.verboseLines.first?.string != "kernel line 14" {
                    failures.append("verbose history did not retain the newest 96 lines")
                }
                p2.consoleLine("\u{1b}]0;terminal title\u{7}[1.00] console ready")
                if p2.verboseLines.last?.string != "[1.00] console ready" { failures.append("verbose console retained terminal controls") }
                wc.overlay.verbose.toggle()
                if wc.overlay.verboseScreen.isHidden == wc.overlay.verbose {
                    failures.append("changing mode did not update the visible overlay")
                }
                wc.overlay.verbose = false
                wc.overlay.update(p2.state)
                CATransaction.flush()
                func textHasAnimation(_ layer: CALayer) -> Bool {
                    if layer is CATextLayer && !(layer.animationKeys() ?? []).isEmpty { return true }
                    return (layer.sublayers ?? []).contains(where: textHasAnimation) || (layer.mask.map(textHasAnimation) ?? false)
                }
                if let root = wc.overlay.layer, textHasAnimation(root) {
                    failures.append("text update started a layer animation")
                }
                var intents = 0
                p2.onRebootIntent = { intents += 1 }
                p2.consoleLine("Welcome to SteamOS!")
                p2.hostRequestedShutdown()
                p2.consoleLine("[  OK  ] Reached target System Reboot.")
                p2.consoleLine("reboot: Restarting system")
                if intents != 0 || p2.state.phase != .shutdown(reboot: false) {
                    failures.append("host power-off was treated as reboot: \(p2.state) intents=\(intents)")
                }
            }
            if failures.isEmpty {
                log("overlay selftest: PASS (\(steps.count) steps) -> \(outDir)")
            } else {
                failures.forEach { log("overlay selftest: FAIL \($0)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        driver.name = "overlay-selftest"
        driver.start()
        NSApp.run()
        exit(0)
    }

    static let windowTitleForTest = "Stella"

    /// Overlay visible → background is the dark gradient where the guest frame is red;
    /// hidden → the guest frame shows. The bar fills from the left to the overall boot fraction.
    static func pixelChecks(_ name: String, _ img: CGImage, _ wc: WindowController, _ s: ProgressState) -> [String] {
        guard let px = pixels(img) else { return ["\(name): cannot read pixels"] }
        let scale = CGFloat(img.width) / wc.overlay.bounds.width
        func at(_ p: CGPoint) -> (Int, Int, Int) {
            let x = min(img.width - 1, Int(p.x * scale)), y = min(img.height - 1, Int((wc.overlay.bounds.height - p.y) * scale))
            let i = (y * img.width + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        var f: [String] = []
        let b = wc.overlay.bounds
        let probe = at(CGPoint(x: b.width * 0.08, y: b.height * 0.85))   // guest frame: red quadrant
        if wc.overlay.shown {
            if wc.overlay.verbose {
                let k = min(b.width / 1920, b.height / 1080)
                func containsInk(_ y: ClosedRange<Int>, xRange: Range<Int>) -> Bool {
                    for row in y {
                        for x in xRange where at(CGPoint(x: CGFloat(x) * k, y: b.height - CGFloat(row) * k)).0 > 80 {
                            return true
                        }
                    }
                    return false
                }
                if !containsInk(39...65, xRange: 198..<227) { f.append("\(name): verbose wordmark missing") }
                if !containsInk(79...103, xRange: 40..<350) { f.append("\(name): verbose heading missing") }
                if !containsInk(113...137, xRange: 40..<550) { f.append("\(name): verbose log missing") }
                if name == "02a-console-colors" {
                    var green = false, amber = false, red = false
                    for row in 171..<256 {
                        for x in 40..<135 {
                            let (r, g, bValue) = at(CGPoint(x: CGFloat(x) * k, y: b.height - CGFloat(row) * k))
                            if g - r > 25 && g - bValue > 25 { green = true }
                            if r - bValue > 55 && g - bValue > 35 { amber = true }
                            if r - g > 45 && r - bValue > 45 { red = true }
                        }
                    }
                    if !green || !amber || !red { f.append("missing status colors in verbose rendering") }
                }
                let background = at(CGPoint(x: b.width * 0.85, y: b.height * 0.10))
                if max(background.0, background.1, background.2) > 2 { f.append("\(name): expected black background") }
                return f
            }
            if probe.0 > 60 { f.append("\(name): overlay should cover the guest frame, got \(probe)") }
            // Sample across the wordmark as a whole. A missing vector resource and an
            // opaque PDF page can otherwise both pass the background and progress checks.
            let k = min(b.width / 1920, b.height / 1080)
            var lit = 0
            for row in 0..<12 {
                for col in 0..<84 {
                    let p = at(CGPoint(x: b.midX + (CGFloat(col) - 41.5) * 6 * k,
                                       y: b.midY + (CGFloat(row) - 5.5) * 5.33 * k))
                    if min(p.0, p.1, p.2) > 80 { lit += 1 }
                }
            }
            if lit < 85 || lit > 650 { f.append("\(name): unexpected Stella wordmark coverage (\(lit)/1008)") }
            if s.stageId != "boot-failed" {
                f += checkBar(name, wc.overlay.barFrame, fraction: s.fraction, scale: scale, pixel: at)
            }
        } else if probe.0 < 200 || probe.1 > 60 {
            f.append("\(name): hidden overlay should reveal the guest frame (red), got \(probe)")
        }
        return f
    }

    static func checkBar(_ name: String, _ bar: CGRect, fraction: Double, scale: CGFloat,
                         pixel: (CGPoint) -> (Int, Int, Int)) -> [String] {
        let width = Int(bar.width * scale)
        let end = CGFloat(fraction) * bar.width
        let tolerance = max(2 / scale, bar.height / 2)
        for i in 0..<width {
            let x = (CGFloat(i) + 0.5) / scale
            if x < tolerance || x > bar.width - tolerance || abs(x - end) < tolerance { continue }
            let (r, g, b) = pixel(CGPoint(x: bar.minX + x, y: bar.midY))
            if x < end ? min(r, g, b) < 230 : max(r, g, b) > 120 {
                return ["\(name): unexpected bar color \([r, g, b]) at pixel \(i) for fraction \(fraction)"]
            }
        }
        for x in [bar.minX + bar.width * 0.25, bar.maxX - bar.width * 0.25] {
            for y in [bar.minY + 0.5 / scale, bar.maxY - 0.5 / scale] {
                let (r, g, b) = pixel(CGPoint(x: x, y: y))
                if max(r, g, b) > 8 {
                    return ["\(name): progress rim at (\(x), \(y)) should be black, got \([r, g, b])"]
                }
            }
        }
        return []
    }

    static func pixels(_ img: CGImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return true
        }
        return ok ? buf : nil
    }
}
