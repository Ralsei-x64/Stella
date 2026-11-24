import AppKit
import CKrun
import Foundation
import Synchronization

/// `--selftest-stall`: a real window + Metal view + FX overlay + GPU-idle indicator, wired like a
/// VM boot (WindowController.attach(progress:) / attach(stall:)), with synthetic GPU counters in
/// place of krun_gpu_get_activity and guest lines (`ready`, `alive …`, `shutdown …`) written into
/// the real fx.progress pipe. Each step waits, checks the monitor / view state, captures the
/// presented drawable with overlay + indicator composited at 2x, writes a PNG and checks pixels
/// (card over the guest frame, frame still visible around it, spinner drawn; nothing when hidden).
enum StallSelfTest {
    /// Synthetic counters: the activity thread bumps `ctrl` or `ring` at 60 Hz in modes 1 / 2.
    static let ctrl = Atomic<UInt64>(0)
    static let ring = Atomic<UInt64>(0)
    static let mode = Atomic<Int>(0)
    static let heartbeats = Atomic<Bool>(true)

    struct Step {
        let name: String
        let action: () -> Void
        let wait: Double
        let check: () -> String?
    }

    static func run(_ o: Options) -> Never {
        if let error = StallThreadDiagnostics.selfCheck() { fatal(error) }
        log("stall selftest: PASS bounded host thread snapshot includes named waiting worker")
        // A poll observes hb=1 before host paging delays persistence/UI work by 5 s.
        // Re-reading the clock inside evaluate used to report hb=6 against that hb=1 row.
        guard !StallMonitor.heartbeatTimedOut(at: 101, lastAlive: 100, observationStarted: 1, lastPoll: 101),
              !StallMonitor.heartbeatTimedOut(at: 106.1, lastAlive: 100, observationStarted: 1, lastPoll: 101),
              !StallMonitor.heartbeatTimedOut(at: 106.1, lastAlive: 100, observationStarted: 106.1, lastPoll: 106.1),
              StallMonitor.heartbeatTimedOut(at: 112, lastAlive: 100, observationStarted: 106.1, lastPoll: 112),
              !StallMonitor.heartbeatTimedOut(at: 112, lastAlive: 0, observationStarted: 1, lastPoll: 112) else {
            fatal("stall heartbeat observation must use a coherent poll timestamp and a fresh host window")
        }
        log("stall selftest: PASS coherent heartbeat timestamp across host delays")
        let cardPattern = #"3[47](?:[ -]*[0-9]){13}"#
        let counters = StallMonitor.diagnosticCounterText((ctrl: 340577, ring: 89246731)) + " hb=0.65"
        guard counters.contains("ctrl=340577 ring=89246731"),
              counters.range(of: cardPattern, options: .regularExpression) == nil else {
            fatal("stall counters can be mistaken for a payment-card number: \(counters)")
        }
        log("stall selftest: PASS counter labels prevent payment-card scrubbing")
        let app = SteamacApplication.shared
        app.setActivationPolicy(.regular)
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let W = o.displayWidth, H = o.displayHeight
        let wc = WindowController(title: OverlaySelfTest.windowTitleForTest, width: W, height: H, renderer: renderer,
                                  inputs: nil, mouseMode: .auto)
        presenter.view = wc.view
        wc.view.metalLayer.framebufferOnly = false
        // The card pixel test must not depend on saved HUD/upscaler preferences.
        wc.view.metalHUD = false
        renderer.superResolution = false
        presenter.onScanoutResize = { w, h in wc.scanoutResized(width: w, height: h) }
        wc.onCloseRequest = { exit(2) }
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let progress = BootProgress()
        wc.attach(progress: progress)
        let monitor = StallMonitor(view: wc.stallView) {
            (StallSelfTest.ctrl.load(ordering: .relaxed), StallSelfTest.ring.load(ordering: .relaxed))
        }
        wc.attach(stall: monitor)
        monitor.enabled = true   // independent of the saved setting
        let port: ProgressPort
        do { port = try ProgressPort() } catch { fatal("\(error)") }
        port.start { progress.guestLine($0) }
        func guest(_ s: String) {
            _ = s.withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
        }
        func heartbeat() {
            guest("alive \(Int(ProcessInfo.processInfo.systemUptime * 1000)) 1.25\n")
        }

        wc.show()
        wc.overlay.show(animated: false)
        log("stall selftest: window \(wc.window.windowNumber) backingScale=\(wc.window.backingScaleFactor)")

        // Activity (60 Hz) and heartbeat (1 Hz) generators.
        let activity = Thread {
            var nextHeartbeat = ProcessInfo.processInfo.systemUptime + 1
            while true {
                switch mode.load(ordering: .relaxed) {
                case 1: ctrl.add(1, ordering: .relaxed)
                case 2: ring.add(1, ordering: .relaxed)
                default: break
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextHeartbeat && heartbeats.load(ordering: .relaxed) {
                    nextHeartbeat = now + 1
                    let ms = Int(now * 1000)
                    _ = "alive \(ms) 1.25\n".withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
                }
                Thread.sleep(forTimeInterval: 1.0 / 60)
            }
        }
        activity.name = "stall-selftest-activity"
        activity.start()

        let view = wc.stallView
        // The card's "Report…" link (only with the not-responding wording).
        view.onReport = { log("stall selftest: Report… link activated") }
        var stallDiagnostic: StallMonitor.Diagnostic?
        monitor.onNotResponding = { stallDiagnostic = $0 }
        let working = String(localized: "Don’t Panic!")
        let sampleSeconds = 987   // < 1000: no digit grouping in the localized template
        let workingDetail = String(localized: "If the screen is frozen, the VM is most likely compiling shaders or loading content.")
        func expectHidden(_ what: String) -> String? {
            !monitor.indicatorShown && !view.shown ? nil : "\(what): indicator should be hidden"
        }
        func expectShown(title: String, detail: String) -> String? {
            guard monitor.indicatorShown, view.shown else { return "indicator should be shown" }
            guard view.currentTitle == title else { return "title \"\(view.currentTitle)\", expected \"\(title)\"" }
            let pattern = "^" + NSRegularExpression.escapedPattern(for: detail)
                .replacingOccurrences(of: "\(sampleSeconds)", with: "[0-9]+") + "$"
            return view.currentDetail.range(of: pattern, options: .regularExpression) != nil
                ? nil : "detail \"\(view.currentDetail)\" does not match \"\(detail)\""
        }
        let steps: [Step] = [
            Step(name: "01-boot-overlay-gpu-idle", action: {}, wait: 3.0) {
                wc.overlay.shown ? expectHidden("boot overlay up, GPU idle 3 s") : "boot overlay should be shown"
            },
            Step(name: "02-ready-gpu-busy", action: { mode.store(1, ordering: .relaxed); guest("ready\n") }, wait: 3.0) {
                progress.state.phase == .running && !wc.overlay.shown
                    ? expectHidden("ctrl commands at 60 Hz") : "expected running, overlay hidden"
            },
            Step(name: "03-steam-ui-idle-3s", action: { mode.store(0, ordering: .relaxed) }, wait: 3.0) {
                expectHidden("Steam UI focused, GPU idle 3 s")
            },
            Step(name: "04-game-focused-1.5s", action: { guest("focus game 4242\n") }, wait: 1.5) {
                wc.guestFocus == .game(4242) ? expectHidden("game focused 1.5 s ago (stale idle must not count)")
                                             : "expected game focus, got \(wc.guestFocus)"
            },
            Step(name: "05-game-idle-2.5s-shown", action: {}, wait: 1.0) {
                expectShown(title: working, detail: workingDetail)
                    ?? (view.reportLinkFrame.isEmpty ? nil : "Report… link shown while the guest is alive")
            },
            Step(name: "06-resized", action: { wc.window.setContentSize(NSSize(width: 1000, height: 700)) }, wait: 0.6) {
                let card = view.cardFrame, b = view.bounds
                guard b.width == 1000 else { return "view did not resize: \(b)" }
                guard abs(card.midX - b.midX) <= 1, card.minY > 0, card.maxY < b.height / 2 else {
                    return "card not centered in the lower half after resize: \(card) in \(b)"
                }
                return expectShown(title: working, detail: workingDetail)
            },
            Step(name: "07-ring-resumes", action: { mode.store(2, ordering: .relaxed) }, wait: 0.6) {
                view.isIdle ? expectHidden("Venus ring commands") : "indicator view not hidden + idle after the fade"
            },
            Step(name: "08-game-idle-again", action: { mode.store(0, ordering: .relaxed) }, wait: 2.5) {
                expectShown(title: working, detail: workingDetail)
            },
            Step(name: "08a-long-idle-live-heartbeat", action: {}, wait: 8.5) {
                expectShown(title: working, detail: workingDetail)
                    ?? (stallDiagnostic == nil ? nil : "live heartbeat incorrectly reported as unresponsive")
            },
            Step(name: "09-focus-steam-hides", action: { guest("focus steam\n") }, wait: 0.5) {
                view.isIdle ? expectHidden("focus back to Steam") : "indicator view not hidden + idle after focus steam"
            },
            // Real timer starvation: the heartbeat source is quiet while the main
            // queue cannot drain progress callbacks. Its first delayed poll must
            // not turn host scheduling latency into a guest hang (STEAMAC-8).
            Step(name: "09a-host-main-queue-delayed", action: {
                heartbeats.store(false, ordering: .relaxed)
                stallDiagnostic = nil
                monitor.gameFocused = true
                Thread.sleep(forTimeInterval: 6)
            }, wait: 0.4) {
                expectShown(title: working, detail: workingDetail)
                    ?? (stallDiagnostic == nil ? nil : "host polling gap incorrectly reported as a guest hang")
            },
            Step(name: "09b-host-queue-heartbeat-back", action: {
                // The previous screenshot may take longer than the observation
                // window; a real silence during that capture is not a false report.
                stallDiagnostic = nil
                monitor.gameFocused = false
                heartbeats.store(true, ordering: .relaxed)
                heartbeat()
            }, wait: 1.8) {
                expectHidden("queued guest heartbeat recovered")
                    ?? (stallDiagnostic == nil ? nil : "recovered heartbeat incorrectly reported as a guest hang")
            },
            // Establish a heartbeat at the transition, rather than relying on a
            // 60 Hz activity generator or screenshot latency for a 5 s deadline.
            Step(name: "10-steam-ui-heartbeat-lost-3s", action: {
                heartbeats.store(false, ordering: .relaxed)
                heartbeat()
            }, wait: 3.0) {
                expectHidden("Steam UI, heartbeat lost < 5 s")
            },
            Step(name: "11-steam-ui-not-responding", action: {}, wait: 3.0) {
                expectShown(title: String(localized: "SteamOS is not responding…"),
                            detail: String(localized: "waiting (\(sampleSeconds) s)"))
                    ?? (view.cardFrame.contains(view.reportLinkFrame) && !view.reportLinkFrame.isEmpty
                        ? nil : "Report… link missing on the not-responding card: \(view.reportLinkFrame) in \(view.cardFrame)")
                    ?? (stallDiagnostic.map {
                        $0.idle >= StallMonitor.idleThreshold && $0.heartbeatAge > StallMonitor.heartbeatTimeout
                            && $0.history.contains("GPU activity samples")
                            && $0.history.contains("ctrl=") && $0.history.contains(" hb=")
                            && $0.history.contains(" host-active=") && $0.history.contains(" host-key=")
                            && $0.history.contains(" window=") && !$0.history.contains("window=detached")
                            && $0.memoryHistory.contains("VM memory snapshots")
                            && $0.memoryHistory.contains("malloc-in-use=")
                            && $0.memoryHistory.contains("malloc-allocated=")
                            && $0.memoryHistory.contains("host-pressure=")
                            && $0.memoryHistory.contains("host-swap-used=")
                            && $0.threadSnapshot.contains("Host thread snapshot:")
                            && $0.threadSnapshot.contains("cpu-permille=")
                            && $0.history.split(separator: "\n").count > 5
                    } == true ? nil : "missing counter/heartbeat history in the stall report")
            },
            Step(name: "12-heartbeat-back", action: {
                heartbeats.store(true, ordering: .relaxed)
                heartbeat()
            }, wait: 1.8) {
                view.isIdle ? expectHidden("heartbeat back in the Steam UI") : "indicator view not hidden + idle after heartbeat"
            },
            // Switch to Desktop: the agent ends with the gamescope session, no heartbeat follows.
            Step(name: "12a-desktop-no-heartbeat-6.5s", action: { heartbeats.store(false, ordering: .relaxed); guest("focus desktop\n") },
                 wait: 6.5) {
                expectHidden("desktop mode, no heartbeat for 6.5 s")
            },
            Step(name: "12b-session-back", action: { heartbeats.store(true, ordering: .relaxed); guest("focus steam\n") }, wait: 1.5) {
                expectHidden("gamescope session back")
            },
            Step(name: "13-setting-off", action: { guest("focus game 4242\n"); monitor.enabled = false }, wait: 2.6) {
                view.isIdle ? expectHidden("setting off") : "indicator view not hidden + idle with the setting off"
            },
            Step(name: "14-setting-on", action: { monitor.enabled = true }, wait: 2.6) {
                expectShown(title: working, detail: workingDetail)
            },
            Step(name: "15-shutdown", action: { guest("shutdown poweroff\n") }, wait: 0.6) {
                wc.overlay.shown && progress.state.phase == .shutdown(reboot: false)
                    ? expectHidden("shutdown overlay") : "shutdown overlay should be shown"
            },
        ]

        let driver = Thread {
            // Guest picture behind the indicator (quadrants), through the real display vtable.
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
                DispatchQueue.main.sync { step.action() }
                Thread.sleep(forTimeInterval: step.wait)
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var shot: (CGImage?, CGImage?) = (nil, nil)
                DispatchQueue.main.sync {
                    if let msg = step.check() { failures.append("\(step.name): \(msg)") }
                    wc.captureWindow { drawable, composite in shot = (drawable, composite); sem.signal() }
                }
                guard sem.wait(timeout: .now() + 5) == .success, let img = shot.1 else {
                    failures.append("\(step.name): capture timed out")
                    continue
                }
                let path = "\(outDir)/stall-\(step.name).png"
                do { try PNG.write(img, to: path) } catch { failures.append("\(step.name): \(error)") }
                failures += DispatchQueue.main.sync {
                    pixelChecks(step.name, img, drawable: wc.overlay.isHidden ? shot.0 : nil, view)
                }
                if step.name == "05-game-idle-2.5s-shown" || step.name == "06-resized" {
                    failures += DispatchQueue.main.sync {
                        var errors = materialChecks(img, view)
                        if let screen = wc.windowServerImage(), hasWindowPixels(screen) {
                            do { try PNG.write(screen, to: "\(outDir)/stall-\(step.name)-screen.png") }
                            catch { errors.append("writing WindowServer image: \(error)") }
                            errors += materialChecks(screen, view).map { "WindowServer: \($0)" }
                        } else {
                            log("stall selftest: \(step.name) skipped live material check: WindowServer returned no window pixels")
                        }
                        return errors.map { "\(step.name): \($0)" }
                    }
                }
                log("stall selftest: \(step.name) indicator=\(view.shown ? "shown" : "hidden")"
                    + (view.shown ? " \"\(view.currentTitle)\" / \"\(view.currentDetail)\"" : "") + " -> \(path)")
            }
            if failures.isEmpty {
                log("stall selftest: PASS (\(steps.count) steps) -> \(outDir)")
            } else {
                failures.forEach { log("stall selftest: FAIL \($0)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        driver.name = "stall-selftest"
        driver.start()
        NSApp.run()
        exit(0)
    }

    /// An offscreen window can yield a valid-sized, fully transparent WindowServer image,
    /// including its title bar. The separate drawable checks still run in that case.
    static func hasWindowPixels(_ image: CGImage) -> Bool {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixel = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3] > 0
    }

    /// The blue/white boundary runs vertically through the card. Probe its empty lower
    /// padding and both straight rims, in the drawable dump and the actual Metal window.
    static func materialChecks(_ image: CGImage, _ view: StallIndicatorView) -> [String] {
        guard let pixels = OverlaySelfTest.pixels(image) else { return ["cannot read card material"] }
        let card = view.cardFrame
        let scale = CGFloat(image.width) / view.bounds.width
        let k = card.width / 573
        func red(_ x: CGFloat, _ y: CGFloat) -> Int {
            let col = max(0, min(image.width - 1, Int(x * scale)))
            let row = max(0, min(image.height - 1, image.height - 1 - Int(y * scale)))
            return Int(pixels[(row * image.width + col) * 4])
        }
        let x = card.midX, y = card.minY + 11 * k, halfPixel = 0.5 / scale
        let left = red(x - 85 * k, y), right = red(x + 85 * k, y)
        let a = red(x - halfPixel, y), b = red(x + halfPixel, y)
        var errors: [String] = []
        // The native HUD material tints the backdrop. Check the edge relative to its
        // local contrast, then verify the exact same guest edge remains sharp outside.
        let contrast = right - left
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency &&
            (contrast < 8 || a - left < contrast / 5 || right - b < contrast / 5 || abs(b - a) > contrast / 2) {
            errors.append("backdrop did not soften the color boundary (\([left, a, b, right]))")
        }
        let outsideY = card.maxY + 15 * k
        // A resized Metal scanout linearly samples between the two boundary pixels.
        // Sample just beyond that footprint while staying well inside the blur diameter.
        let outsideEdge = red(x + 3 * halfPixel, outsideY) - red(x - 3 * halfPixel, outsideY)
        let outsideContrast = red(x + 20 * k, outsideY) - red(x - 20 * k, outsideY)
        if outsideContrast < 80 || outsideEdge < outsideContrast * 3 / 4 {
            errors.append("card blur escaped its silhouette (edge \(outsideEdge), contrast \(outsideContrast))")
        }
        let rimX = card.minX + card.width / 4
        for (edge, inward) in [(card.minY, CGFloat(1)), (card.maxY, CGFloat(-1))] {
            if red(rimX, edge + inward * halfPixel) > 8 {
                errors.append("inner shadow shows through the black outline at y=\(edge)")
            }
            let peak = (1...4).map { red(rimX, edge + inward * CGFloat($0) * k) }.max()!
            if peak < red(rimX, edge + inward * 10 * k) + 12 {
                errors.append("missing inner shadow at y=\(edge)")
            }
        }
        // The black stroke sits over the highlights. Allow partial coverage on
        // fractional pixels and check that the fill returns just inside the rim.
        let inside = red(card.maxX - 8 * k, card.midY)
        let edge = (0...Int(ceil(k * scale))).map { red(card.maxX - (CGFloat($0) + 0.5) / scale, card.midY) }
        if k * scale >= 1 && edge.min()! > inside * 2 / 3 {
            errors.append("missing black outline over inner shadow (interior \(inside), edge \(edge))")
        }
        if red(card.maxX - 3 * k, card.midY) < inside - 5 {
            errors.append("outline extends into the card fill")
        }
        return errors
    }

    /// Shown: the card's padding is dark (card over the frame), the spinner has neutral highlights and the
    /// guest frame is still visible outside the card (top-left red quadrant). Hidden: the composite
    /// equals `drawable` there (nil while the boot/shutdown overlay covers the picture).
    static func pixelChecks(_ name: String, _ img: CGImage, drawable: CGImage?, _ view: StallIndicatorView) -> [String] {
        guard let pixels = OverlaySelfTest.pixels(img) else { return ["\(name): cannot read pixels"] }
        let scale = CGFloat(img.width) / view.bounds.width
        func at(_ p: CGPoint, _ buf: [UInt8], _ width: Int, _ height: Int) -> (Int, Int, Int) {
            let x = max(0, min(width - 1, Int(p.x * scale))), y = max(0, min(height - 1, Int((view.bounds.height - p.y) * scale)))
            let i = (y * width + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        func px(_ p: CGPoint) -> (Int, Int, Int) { at(p, pixels, img.width, img.height) }
        var f: [String] = []
        let b = view.bounds, card = view.cardFrame
        let frameProbe = px(CGPoint(x: b.width * 0.08, y: b.height * 0.85))
        let pad = CGPoint(x: card.maxX - 8, y: card.midY)
        if view.shown {
            if frameProbe.0 < 200 || frameProbe.1 > 60 { f.append("\(name): guest frame should stay visible around the card, got \(frameProbe)") }
            let c = px(pad)
            if c.0 > 75 || c.1 > 80 || c.2 > 90 { f.append("\(name): card padding should be dark, got \(c)") }
            let s = view.spinnerFrame
            var highlights = 0
            for yi in 0..<Int(s.height) {
                for xi in 0..<Int(s.width) {
                    let p = px(CGPoint(x: s.minX + CGFloat(xi), y: s.minY + CGFloat(yi)))
                    if min(p.0, p.1, p.2) > 100 && max(p.0, p.1, p.2) - min(p.0, p.1, p.2) < 50 { highlights += 1 }
                }
            }
            if highlights < Int(s.width * s.height * 0.035) { f.append("\(name): spinner not drawn (\(highlights) highlighted points)") }
        } else if !view.isHidden {
            f.append("\(name): hidden indicator view should be isHidden")
        } else if let d = drawable, let dpx = OverlaySelfTest.pixels(d), d.width == img.width, d.height == img.height {
            let a = px(pad), e = at(pad, dpx, d.width, d.height)
            if abs(a.0 - e.0) > 3 || abs(a.1 - e.1) > 3 || abs(a.2 - e.2) > 3 {
                f.append("\(name): hidden indicator changed the picture at the card: \(a) vs \(e)")
            }
        }
        return f
    }
}
