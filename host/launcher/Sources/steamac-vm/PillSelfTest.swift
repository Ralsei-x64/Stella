import AppKit
import Carbon.HIToolbox
import CKrun
import Foundation

/// Exercises embedded startup progress, sleep and wake, the missing-picture diagnostic, and
/// compact shutdown progress in a native VM window. Guest events use the progress port and
/// display vtable. Each step checks state and captures the layer tree and WindowServer output.
enum PillSelfTest {
    enum Frames { case none, black, pattern }

    struct Step {
        let name: String
        let action: () -> Void
        let wait: Double
        let check: () -> String?
    }

    static func run(_ o: Options) -> Never {
        let app = SteamacApplication.shared
        app.setActivationPolicy(.accessory)
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let W = o.displayWidth, H = o.displayHeight
        let inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(), mouse: InputDevices.mouse())
        let title = OverlaySelfTest.windowTitleForTest
        let wc = WindowController(title: title, width: W, height: H, renderer: renderer, inputs: inputs, mouseMode: .auto)
        presenter.view = wc.view
        wc.view.metalLayer.framebufferOnly = false
        presenter.onScanoutResize = { w, h in wc.scanoutResized(width: w, height: h) }
        wc.onCloseRequest = { exit(2) }
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let progress = BootProgress()
        wc.attach(progress: progress)
        // Constant counters: the GPU is idle all the time (the GPU-idle card shows for games).
        let stall = StallMonitor(view: wc.stallView) { (0, 0) }
        wc.attach(stall: stall)
        stall.enabled = true
        let noPicture = NoPictureGuard { presenter.scanout.probe(sampleIfNewerThan: $0) }
        wc.attach(noPicture: noPicture)
        let port: ProgressPort
        do { port = try ProgressPort() } catch { fatal("\(error)") }
        port.start { progress.guestLine($0) }
        func guest(_ s: String) {
            _ = (s + "\n").withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
        }

        // Synthetic events go directly to the VM view. Keep desktop input with the user.
        wc.window.ignoresMouseEvents = true
        wc.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        wc.window.orderBack(nil)
        log("pill selftest: window \(wc.window.windowNumber) backingScale=\(wc.window.backingScaleFactor)")

        // Black-test cost on a full-size frame (Scanout.darkFraction): 200 runs.
        let costBuffer = FrameBuffer(width: W, height: H, format: UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM))
        let t0 = CACurrentMediaTime()
        var sink = 0.0
        for _ in 0..<200 { sink += Scanout.darkFraction(costBuffer) }
        let costUs = (CACurrentMediaTime() - t0) / 200 * 1e6
        log(String(format: "pill selftest: black test %.1f µs per frame (%dx%d, %d points, dark %.3f)",
                   costUs, W, H, Scanout.sampleColumns * Scanout.sampleRows, sink / 200))

        func windowPoint(unit ux: Double, _ uy: Double) -> NSPoint {
            let fit = wc.view.fitRect
            return wc.view.convert(NSPoint(x: fit.minX + CGFloat(ux) * fit.width, y: fit.maxY - CGFloat(uy) * fit.height), to: nil)
        }
        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    wc.pointerButton(e, down: type == .leftMouseDown)
                }
            }
        }
        func key(_ code: Int) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: wc.window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                    _ = wc.processKey(e)
                }
            }
        }
        let pill = wc.pill
        func status(_ s: String?) -> String { s.map { String(localized: "\(title) — \($0)") } ?? title }
        func expectTitle(_ s: String?) -> String? {
            wc.window.title == status(s) ? nil : "window title \"\(wc.window.title)\", expected \"\(status(s))\""
        }
        func overallPercent() -> Int { Int((progress.state.fraction * 100).rounded(.down)) }
        let downloading = BootProgress.localizedGuestText("Downloading Steam update")
        let checking = BootProgress.localizedGuestText("Checking for Steam updates")
        let starting = BootProgress.localizedGuestText("Starting Steam")
        let sampleCPU = "CPUVALUE"
        let sampleSeconds = 987   // < 1000: no digit grouping in the localized template
        func containsDetail(_ text: String, _ template: String) -> Bool {
            let pattern = NSRegularExpression.escapedPattern(for: template)
                .replacingOccurrences(of: sampleCPU, with: "[0-9]+\\.[0-9]")
                .replacingOccurrences(of: "\(sampleSeconds)", with: "[0-9]+")
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        func expectPill(_ t: String, detail: String, percent: Bool) -> String? {
            guard pill.shown, !wc.overlay.shown else { return "expected the pill (overlay \(wc.overlay.shown), pill \(pill.shown))" }
            let c = pill.content
            guard c.title == t else { return "pill title \"\(c.title)\", expected \"\(t)\"" }
            guard detail.isEmpty || containsDetail(c.detail, detail) else { return "pill detail \"\(c.detail)\" lacks \"\(detail)\"" }
            if percent && c.percentText != "\(overallPercent())%" { return "pill percent \"\(c.percentText)\", expected \(overallPercent())%" }
            return nil
        }
        func expectOverlay() -> String? {
            wc.overlay.shown && wc.overlay.window === wc.window && !pill.shown
                ? nil : "expected boot progress embedded in the VM window"
        }
        func expectBootHidden() -> String? {
            !wc.overlay.shown && !pill.shown ? nil : "hiding boot progress should hide both presentations"
        }
        func expectNoPill(_ what: String) -> String? {
            !pill.shown ? nil : "\(what): pill should be hidden, shows \"\(pill.content.title)\" / \"\(pill.content.detail)\""
        }
        var wakeRequests = 0
        wc.onWakeRequest = { _ in
            wakeRequests += 1
            wc.guestSleeping(false)
            noPicture.vmPaused = false
        }
        let waiting = NoPictureGuard.title

        // Frames: the driver thread presents `frames` at 20 Hz while it waits, plus a heartbeat a second.
        nonisolated(unsafe) var frames = Frames.pattern
        nonisolated(unsafe) var configure: (Int, Int)?
        nonisolated(unsafe) var disable = false

        let steps: [Step] = [
            Step(name: "01-check-overlay", action: {
                guest("stage session 100 Starting Steam session")
                guest("stage steam-check -1 Checking for Steam updates")
            }, wait: 0.8) {
                expectOverlay() ?? expectNoPill("overlay up") ?? expectTitle(String(localized: "\(checking) \(overallPercent())%"))
            },
            Step(name: "02-click-keeps-startup-screen", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectOverlay() ?? expectTitle(String(localized: "\(checking) \(overallPercent())%"))
            },
            Step(name: "03-download-in-main-window", action: {
                guest("stage steam-download 0 Downloading Steam update")
                guest("log 129 / 564 MB · 7.3 MB/s")
            }, wait: 0.8) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "04a-click-during-download-keeps-overlay", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "04b-key-during-download-keeps-overlay", action: { key(kVK_ANSI_A) }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "05-live-update-in-overlay", action: {
                guest("stage steam-download 67 Downloading Steam update")
                guest("log 378 / 564 MB · 1.9 MB/s")
            }, wait: 0.7) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
                    ?? (progress.state.detail == "378 / 564 MB · 1.9 MB/s" ? nil : "detail \(progress.state.detail)")
            },
            Step(name: "06-menu-hides-progress", action: { wc.toggleOverlay() }, wait: 0.7) {
                expectBootHidden()
            },
            Step(name: "07-stage-update-while-hidden", action: {
                guest("stage steam-download 89 Downloading Steam update")
                guest("log 501 / 564 MB · 3.8 MB/s")
            }, wait: 0.7) {
                expectBootHidden() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "08-menu-restores-progress", action: { wc.toggleOverlay() }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "09a-starting-steam", action: {
                guest("stage steam-install 100 Installing Steam update")
                guest("stage steam-start -1 Starting Steam")
            }, wait: 0.7) {
                expectOverlay() ?? expectTitle(String(localized: "\(starting) \(overallPercent())%"))
            },
            Step(name: "09b-key-during-start", action: { key(kVK_ANSI_A) }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "09c-click-during-start", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectOverlay()
            },
            Step(name: "10-ready-fades", action: { guest("ready") }, wait: 1.0) {
                progress.state.phase == .running && pill.isIdle && !wc.overlay.shown
                    ? expectTitle(nil) : "expected running, pill hidden + idle, overlay hidden"
            },
            Step(name: "11-display-off-2s", action: { disable = true; frames = .none }, wait: 2.0) {
                expectNoPill("display off 2 s")
            },
            Step(name: "12-display-off-3.5s", action: {}, wait: 1.5) {
                expectPill(waiting, detail: String(localized: "display off \(sampleSeconds) s"), percent: false)
                    ?? (pill.content.detail.contains(String(localized: "guest alive"))
                        && containsDetail(pill.content.detail, String(localized: "VM CPU \(sampleCPU) cores"))
                        ? nil : "detail lacks heartbeat / CPU: \(pill.content.detail)")
                    ?? expectTitle(nil)
            },
            Step(name: "13-picture-back-hides", action: { configure = (W, H); frames = .pattern }, wait: 0.8) {
                expectNoPill("non-black frame after display off")
            },
            Step(name: "14-black-4s", action: { frames = .black }, wait: 4.0) {
                expectNoPill("black 4 s")
            },
            Step(name: "15-black-5.5s", action: {}, wait: 1.5) {
                expectPill(waiting, detail: String(localized: "black picture \(sampleSeconds) s"), percent: false)
            },
            Step(name: "16-non-black-hides", action: { frames = .pattern }, wait: 0.8) {
                expectNoPill("non-black frame")
            },
            Step(name: "17-game-black-6s-never", action: { guest("focus game 4242"); frames = .black }, wait: 6.0) {
                expectNoPill("game focused, black 6 s") ?? (wc.stallView.shown ? nil : "GPU-idle card should cover the game")
            },
            Step(name: "18-steam-black-5.5s", action: { guest("focus steam") }, wait: 5.5) {
                expectPill(waiting, detail: String(localized: "black picture \(sampleSeconds) s"), percent: false)
            },
            Step(name: "19-sleep-hides", action: { frames = .pattern; wc.guestSleeping(true); noPicture.vmPaused = true }, wait: 6.0) {
                expectNoPill("SteamOS asleep") ?? (wc.sleepView.shown ? nil : "sleep screen missing")
            },
            Step(name: "20-awake-black-2s", action: { frames = .black; click(windowPoint(unit: 0.5, 0.5)) }, wait: 2.0) {
                expectNoPill("awake again") ?? (wakeRequests == 1 && wc.sleepView.isHidden ? nil : "click did not wake the session")
            },
            Step(name: "21-resize-no-frame-3.5s", action: { frames = .none; configure = (W - 256, H - 160) }, wait: 3.5) {
                expectPill(waiting, detail: String(localized: "no frame \(sampleSeconds) s"), percent: false)
            },
            Step(name: "22-new-size-frame-hides", action: { frames = .pattern }, wait: 0.8) {
                expectNoPill("frame at the new size")
            },
            Step(name: "22a-resume-loader", action: {
                wc.resumeChip.show(String(localized: "Resuming…"))
            }, wait: 0.5) {
                wc.resumeChip.shown && wc.resumeChip.currentDetail == waiting ? nil : "resume loader missing"
            },
            Step(name: "22b-resume-complete", action: { wc.resumeChip.hide() }, wait: 0.5) {
                wc.resumeChip.isIdle ? nil : "resume loader still visible"
            },
            Step(name: "22c-game-paused-card", action: { wc.gamePaused(4242) }, wait: 0.5) {
                wc.pauseView.shown ? nil : "game pause card missing"
            },
            Step(name: "22c-pause-interrupted-dismissal", action: {
                wc.gamePaused(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { wc.gamePaused(4242) }
            }, wait: 0.6) {
                wc.pauseView.shown && !wc.pauseView.isHidden ? nil : "interrupted dismissal hid the reopened card"
            },
            Step(name: "22d-game-resumed", action: { wc.gamePaused(nil) }, wait: 0.5) {
                wc.pauseView.isHidden ? nil : "game pause card still visible"
            },
            Step(name: "23-shutdown-overlay", action: { configure = (W, H); guest("shutdown poweroff") }, wait: 0.8) {
                expectOverlay() ?? expectTitle(String(localized: "Shutting down…"))
            },
            Step(name: "24-shutdown-click-collapses", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectPill(String(localized: "Shutting down…"), detail: "", percent: true) ?? expectTitle(String(localized: "Shutting down…"))
            },
        ]

        let driver = Thread {
            let cb = display.makeCBackend()
            var inst: UnsafeMutableRawPointer?
            _ = cb.create!(&inst, cb.create_userdata, nil)
            let fb = cb.vtable.basic_framebuffer
            let fmt = UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM)
            var size = (W, H)
            _ = fb.configure_scanout!(inst, 0, UInt32(W), UInt32(H), UInt32(W), UInt32(H), fmt)
            func present(_ f: Frames) {
                var ptr: UnsafeMutablePointer<UInt8>?
                var len = 0
                let id = fb.alloc_frame!(inst, 0, &ptr, &len)
                guard id >= 0, let ptr else { return }
                if f == .black { memset(ptr, 0, len) } else { SelfTest.fill(ptr, width: size.0, height: size.1, format: fmt, square: true) }
                _ = fb.present_frame!(inst, 0, UInt32(id), nil)
            }
            var lastAlive = 0.0
            func idle(_ seconds: Double) {
                let end = CACurrentMediaTime() + seconds
                while CACurrentMediaTime() < end {
                    if disable {
                        disable = false
                        _ = fb.disable_scanout!(inst, 0)
                    }
                    if let c = configure {
                        configure = nil
                        size = c
                        _ = fb.configure_scanout!(inst, 0, UInt32(c.0), UInt32(c.1), UInt32(c.0), UInt32(c.1), fmt)
                    }
                    if frames != .none { present(frames) }
                    let now = CACurrentMediaTime()
                    if now - lastAlive >= 1 {
                        lastAlive = now
                        guest("alive \(Int(ProcessInfo.processInfo.systemUptime * 1000)) 1.25")
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            idle(0.5)

            var failures: [String] = []
            if costUs > 100 { failures.append(String(format: "black test too slow: %.1f µs", costUs)) }
            for step in steps {
                DispatchQueue.main.sync {
                    let views: [NSView] = [wc.sleepView, wc.pauseView, wc.resumeChip]
                    let entering = views.filter(\.isHidden)
                    let leaving = views.filter { !$0.isHidden }
                    step.action()
                    for view in entering where !view.isHidden {
                        if let error = motionError(view, appearing: true) { failures.append("\(step.name): \(error)") }
                    }
                    for view in leaving where !view.isHidden {
                        let shown = (view as? PauseOverlayView)?.shown ?? (view as? LoaderCardView)?.shown ?? true
                        if !shown, let error = motionError(view, appearing: false) {
                            failures.append("\(step.name): \(error)")
                        }
                    }
                }
                idle(step.wait)
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var shot: (CGImage?, CGImage?) = (nil, nil)
                DispatchQueue.main.sync {
                    if let msg = step.check() { failures.append("\(step.name): \(msg)") }
                    for view in [wc.sleepView, wc.pauseView] where view.shown {
                        let k = min(view.bounds.width / 1920, view.bounds.height / 1080)
                        let centerY = view.bounds.midY - (view === wc.sleepView ? 15 * k : 0)
                        let card = view.surface.card
                        if abs(view.cardFrame.midX - view.bounds.midX) > 1 || abs(view.cardFrame.midY - centerY) > 1 ||
                            card.filters?.isEmpty == false {
                            failures.append("\(step.name): card did not settle in focus at its original position")
                        }
                    }
                    if let screen = wc.windowServerImage() {
                        do { try PNG.write(screen, to: "\(outDir)/pill-\(step.name)-screen.png") }
                        catch { failures.append("\(step.name): \(error)") }
                        if wc.overlay.shown && progress.state.phase == .boot && progress.state.fraction >= 0.3 {
                            // A hidden stall backdrop once blurred this fill only in WindowServer.
                            let bar = wc.overlay.barFrame
                            let scale = CGFloat(screen.width) / wc.overlay.bounds.width
                            let sample = CGRect(x: floor((bar.minX + 0.2 * bar.width) * scale),
                                                y: floor(CGFloat(screen.height) - bar.midY * scale), width: 1, height: 1)
                            if let point = screen.cropping(to: sample), let rgba = OverlaySelfTest.pixels(point) {
                                if rgba.prefix(3).contains(where: { $0 < 225 }) {
                                    failures.append("\(step.name): native window blurred the white progress fill")
                                }
                            } else {
                                failures.append("\(step.name): could not sample native progress fill")
                            }
                        }
                    } else if step.name == "05-live-update-in-overlay" {
                        failures.append("\(step.name): native progress window capture unavailable")
                    }
                    wc.captureWindow { drawable, composite in shot = (drawable, composite); sem.signal() }
                }
                guard sem.wait(timeout: .now() + 5) == .success, let img = shot.1 else {
                    failures.append("\(step.name): capture timed out")
                    continue
                }
                let path = "\(outDir)/pill-\(step.name).png"
                do { try PNG.write(img, to: path) } catch { failures.append("\(step.name): \(error)") }
                failures += DispatchQueue.main.sync { pixelChecks(step.name, img, wc, patternBehind: frames == .pattern) }
                DispatchQueue.main.sync {
                    log("pill selftest: \(step.name) overlay=\(wc.overlay.shown ? "shown" : "hidden") pill="
                        + (pill.shown ? "\"\(pill.content.title)\" / \"\(pill.content.detail)\" \(pill.content.percentText)" : "hidden")
                        + " title=\"\(wc.window.title)\" -> \(path)")
                }
            }
            if failures.isEmpty {
                log("pill selftest: PASS (\(steps.count) steps) -> \(outDir)")
            } else {
                failures.forEach { log("pill selftest: FAIL \($0)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        driver.name = "pill-selftest"
        driver.start()
        NSApp.run()
        exit(0)
    }

    private static func motionError(_ view: NSView, appearing: Bool) -> String? {
        guard let surface = view.subviews.compactMap({ $0 as? StellaCardSurface }).first,
              let material = surface.layer, surface.card.superlayer === material, material.masksToBounds else {
            return "blur and artwork must share a clipped surface"
        }
        let pop = material.animation(forKey: "statusPop") as? CAKeyframeAnimation
        let focus = surface.card.animation(forKey: "statusFocus") as? CABasicAnimation
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return pop == nil && focus == nil ? nil : "Reduce Motion still animates the card"
        }
        guard let frames = pop?.values as? [NSValue], let small = (appearing ? frames.first : frames.last)?.caTransform3DValue,
              small.m11 < 1, let radius = (appearing ? focus?.fromValue : focus?.toValue) as? NSNumber,
              radius.doubleValue > 0 else {
            return "missing scale or blur on \(appearing ? "entry" : "dismissal")"
        }
        for value in frames {
            let m = value.caTransform3DValue
            let x = material.frame.midX - material.position.x, y = material.frame.minY - material.position.y
            if abs(x * m.m11 + m.m41 - x) > 0.01 || abs(y * m.m22 + m.m42 - y) > 0.01 {
                return "card moved away from its bottom-center anchor"
            }
        }
        return nil
    }

    /// Loader cards have dark padding and a silver spinner. The guest frame stays
    /// visible above the pill (top-left red quadrant). Hidden: nothing drawn at the pill's place
    /// beyond the guest frame (pattern: blue bottom-left quadrant left of centre).
    static func pixelChecks(_ name: String, _ img: CGImage, _ wc: WindowController, patternBehind: Bool) -> [String] {
        guard let px = OverlaySelfTest.pixels(img) else { return ["\(name): cannot read pixels"] }
        let view = wc.pill
        let scale = CGFloat(img.width) / view.bounds.width
        func at(_ p: CGPoint) -> (Int, Int, Int) {
            let x = max(0, min(img.width - 1, Int(p.x * scale))), y = max(0, min(img.height - 1, Int((view.bounds.height - p.y) * scale)))
            let i = (y * img.width + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        var f: [String] = []
        let card = view.cardFrame
        let pad = at(CGPoint(x: card.minX + 6, y: card.midY))
        // The test pattern's right half has a full green channel above and below either card.
        // Its lower edge should cast a stronger shadow at equal distance from the silhouette.
        if patternBehind && (wc.resumeChip.shown || wc.pauseView.shown) {
            let box = wc.resumeChip.shown ? wc.resumeChip.cardFrame : wc.pauseView.cardFrame
            let x = box.midX + box.width * 0.25
            let above = at(CGPoint(x: x, y: box.maxY + 4)).1
            let below = at(CGPoint(x: x, y: box.minY - 4)).1
            let distant = at(CGPoint(x: x, y: box.maxY + box.height)).1
            if above >= distant - 10 || below >= above - 5 {
                f.append("\(name): expected a downward exterior shadow (below \(below), above \(above), distant \(distant))")
            }
        }
        if wc.sleepView.shown {
            let bounds = wc.sleepView.bounds
            let k = min(bounds.width / 1920, bounds.height / 1080)
            let outside = at(CGPoint(x: bounds.width * 0.08, y: bounds.height * 0.85))
            if max(outside.0, outside.1, outside.2) > 30 { f.append("\(name): guest frame visible through sleep screen") }
            let box = wc.sleepView.cardFrame
            for (rows, threshold) in [(26..<55, 120), (63..<84, 65)] {
                let hasText = rows.contains { row in
                    (36..<310).contains { col in
                        at(CGPoint(x: box.minX + CGFloat(col) * k, y: box.maxY - CGFloat(row) * k)).0 > threshold
                    }
                }
                if !hasText { f.append("\(name): missing text in the sleep status box") }
            }
        } else if view.shown || wc.resumeChip.shown {
            if view.shown && (pad.0 > 75 || pad.1 > 80 || pad.2 > 90) { f.append("\(name): card padding should be dark") }
            let loader: LoaderCardView = view.shown ? view : wc.resumeChip
            let spinner = loader.spinnerFrame
            let visibleBlade = (0..<Int(spinner.height)).contains { y in
                let p = at(CGPoint(x: spinner.midX, y: spinner.minY + CGFloat(y)))
                return min(p.0, p.1, p.2) > 75 && max(p.0, p.1, p.2) - min(p.0, p.1, p.2) < 25
            }
            if !visibleBlade { f.append("\(name): silver spinner missing") }
            if patternBehind && !wc.overlay.shown {
                let b = view.bounds
                let probe = at(CGPoint(x: b.width * 0.08, y: b.height * 0.85))
                if probe.0 < 200 || probe.1 > 60 { f.append("\(name): guest frame should stay visible above the pill, got \(probe)") }
            }
        } else if !view.isHidden && view.alphaValue > 0.01 {
            f.append("\(name): hidden pill should be isHidden (alpha \(view.alphaValue))")
        } else if patternBehind && !wc.overlay.shown && wc.view.fitRect.width >= view.bounds.width - 1 {
            if pad.2 < 150 || pad.0 > 100 { f.append("\(name): guest frame (blue quadrant) should show where the pill was, got \(pad)") }
        }
        return f
    }
}
