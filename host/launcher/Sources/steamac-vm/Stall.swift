import AppKit
import CoreImage
import Darwin
import QuartzCore

/// "Still working" indicator (Settings > General). Shown after `ready`, never during the
/// boot/shutdown overlay, when the guest sends no GPU work for `idleThreshold` while a game has
/// focus (`focus game <appid>`; the idle Steam UI legitimately sends none for minutes), or —
/// whatever has focus — when the guest's heartbeat has also stopped for `heartbeatTimeout`.
/// Hidden as soon as GPU work arrives, the game loses focus or the guest answers again. No
/// heartbeat is expected between sessions (the agent ends with each gamescope session, gaming or
/// Desktop Mode), and both clocks start over after the VM was paused (suspend, guest sleep) or
/// the Mac slept.
///
/// GPU work = libkrun's krun_gpu_get_activity counters (libkrun patch 0015), sampled every
/// `tick`: virtio-gpu control-queue commands (SUBMIT_3D, RESOURCE_FLUSH, SET_SCANOUT*, …) and
/// Venus commands virglrenderer dispatched from its in-process rings (virglrenderer patch 0009).
/// The idle window starts at the latest of: last GPU work, gate opening (overlay gone, setting
/// on), the game getting focus — so stale idle time never fires at once. The wording comes from
/// the guest agent's heartbeat (`alive <uptime_ms> <loadavg1>` once a second over fx.progress)
/// and this process's CPU time (vCPU threads included): alive → loading guidance, no
/// heartbeat for `heartbeatTimeout` → "SteamOS is not responding…". With perf stats on it also
/// logs the counter rates and the longest idle stretch every 5 s. Main thread only.
final class StallMonitor {
    typealias Counters = (ctrl: UInt64, ring: UInt64)

    static let idleThreshold: TimeInterval = 2
    static let heartbeatTimeout: TimeInterval = 5
    static let tick: TimeInterval = 0.25
    static let perfPeriod: TimeInterval = 5

    struct Diagnostic {
        let idle: TimeInterval
        let heartbeatAge: TimeInterval
        let history: String
        let memoryHistory: String
        let threadSnapshot: String
    }

    private struct Reading {
        let at: CFTimeInterval
        let counters: Counters?
        let heartbeatAge: TimeInterval?
        let uptimeMs: Int
        let load: Double
        let cpu: Double
        let pollGap: TimeInterval
        let game: Bool
        let gate: Bool
        let hostActive: Bool
        let hostKey: Bool
        let hostWindow: String
    }
    // Independent of Settings > Performance statistics: reports otherwise had only the first
    // 2 s of GPU idleness and could not distinguish agent loss, host scheduling and GPU stalls.
    private var readings: [Reading] = []
    private var nextReading = 0
    private var lastReading: CFTimeInterval = 0
    private var lastPoll: CFTimeInterval = 0
    private var guestUptimeMs = 0
    // A delayed main-queue timer cannot establish guest silence: queued progress
    // callbacks have not had a chance to run either (STEAMAC-8).
    private var heartbeatObservationStarted = CACurrentMediaTime()

    let view: StallIndicatorView
    /// nil = no counters (VM not running, no GPU): never shows.
    private let sample: () -> Counters?
    private var timer: DispatchSourceTimer?
    private var counters: Counters?
    private var countersAvailable = false
    private var lastActivity = CACurrentMediaTime()
    private var cpuAtActivity = StallMonitor.cpuSeconds()
    /// When the gate last opened (enabled, not suppressed, game focus): idle time counts from
    /// here at the earliest.
    private var gateOpenedAt = CACurrentMediaTime()
    private var lastAlive: CFTimeInterval = 0
    private var guestLoad = 0.0
    /// Per-second CPU readings while shown: (time, process CPU seconds).
    private var cpuSamples: [(CFTimeInterval, Double)] = []
    private var shownSince: (idleStart: CFTimeInterval, cpu: Double)?
    private var notRespondingReported = false
    private var longStallLogged = false
    // perf stats window
    private var perfStart: CFTimeInterval = 0
    private var perfCounters: Counters?
    private var perfLongestIdle: CFTimeInterval = 0

    /// Settings > General "Show indicator when the GPU goes idle".
    var enabled = true { didSet { if enabled != oldValue { gateChanged() } } }
    /// Before `ready`, boot / shutdown overlay on screen, or the guest is shutting down.
    var suppressed = true { didSet { if suppressed != oldValue { gateChanged() } } }
    /// A game has focus in the guest (`focus game <appid>`).
    var gameFocused = false { didSet { if gameFocused != oldValue { gateChanged() } } }
    /// The focused game is frozen (GamePause): an idle GPU is expected.
    var paused = false { didSet { if paused != oldValue { gateChanged() } } }
    /// The indicator is up (or about to fade in).
    var indicatorShown: Bool { shownSince != nil }
    /// Once per indicator stretch, when its wording turns to "SteamOS is not responding…".
    /// Recent counter/heartbeat samples accompany the report even when perf stats are off.
    var onNotResponding: ((Diagnostic) -> Void)?

    init(view: StallIndicatorView, sample: @escaping () -> Counters?) {
        self.view = view
        self.sample = sample
        readings.reserveCapacity(32)
        VMMemoryDiagnostics.shared.start()
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + StallMonitor.tick, repeating: StallMonitor.tick, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hide(reason: "stopped")
    }

    /// The VM ran again after a pause (suspend, guest sleep) or the Mac woke from sleep (stopped
    /// meanwhile): the guest could neither send GPU work nor heartbeats, so idle time and
    /// heartbeat age start over.
    func resumeAfterSuspend() {
        let now = CACurrentMediaTime()
        lastActivity = now
        cpuAtActivity = StallMonitor.cpuSeconds()
        gateOpenedAt = now
        if lastAlive > 0 { lastAlive = now }
        counters = nil
        lastPoll = now
        heartbeatObservationStarted = now
        start()
    }

    /// Guest heartbeat (`alive <uptime_ms> <loadavg1>`).
    func alive(uptimeMs: Int, load: Double) {
        lastAlive = CACurrentMediaTime()
        guestLoad = load
        guestUptimeMs = uptimeMs
    }

    /// The agent ended with the gamescope session (bare `focus desktop`: Switch to Desktop, Return
    /// to Gaming Mode, relogin): no heartbeat is expected until the next session's agent sends one.
    func heartbeatsEnded() {
        guard lastAlive > 0 else { return }
        lastAlive = 0
        log("stall: guest agent ended with its session; no heartbeat expected until it is back")
        evaluate(CACurrentMediaTime())
    }

    private var gateOpen: Bool { enabled && !suppressed && !paused }

    /// Any gate input changed: a newly opened window starts now; a closed one hides at once.
    private func gateChanged() {
        let now = CACurrentMediaTime()
        if gateOpen { gateOpenedAt = now }
        evaluate(now)
    }

    // MARK: sampling

    private func poll() {
        let now = CACurrentMediaTime()
        if lastPoll > 0 && now - lastPoll > Self.heartbeatTimeout {
            heartbeatObservationStarted = now
            log("stall: host polling gap \(String(format: "%.2f", now - lastPoll)) s; observing fresh heartbeat window")
        }
        let c = sample()
        let active: Bool
        noteReading(now: now, counters: c)
        if let c, let prev = counters { active = c != prev } else { active = false }
        if let c { counters = c }
        perfNote(now: now, counters: c, active: active)
        if active {
            hide(reason: nil, now: now)
            lastActivity = now
            cpuAtActivity = StallMonitor.cpuSeconds()
            return
        }
        countersAvailable = c != nil
        evaluate(now)
    }

    /// Show / refresh / hide the indicator for the current state (no GPU work since `lastActivity`).
    private func evaluate(_ now: CFTimeInterval) {
        let dead = notResponding(at: now)
        // Durations shown and logged are the GPU's whole idle time.
        guard countersAvailable, gateOpen, gameFocused || dead,
              now - max(lastActivity, gateOpenedAt) >= StallMonitor.idleThreshold else {
            if shownSince != nil {
                let response = (heartbeatAge(at: now) ?? 0) > Self.heartbeatTimeout
                    ? "host observation restarted" : "guest responding again"
                hide(reason: !enabled ? "setting off" : suppressed ? "overlay"
                     : notRespondingReported && !dead ? response : "game focus lost", now: now)
            }
            return
        }
        noteCPU(now)
        let starting = shownSince == nil
        if starting { shownSince = (lastActivity, cpuAtActivity) }
        let (title, detail) = text(now: now, idle: now - lastActivity)
        view.showsReportLink = dead
        view.update(title: title, detail: detail)
        if starting {
            view.show()
            log("stall: gpu idle \(String(format: "%.1f", now - lastActivity)) s, indicator shown (\(status(now)))")
        }
        if !notRespondingReported && dead {
            notRespondingReported = true
            log("stall: guest not responding (no heartbeat for \(Int(heartbeatAge(at: now) ?? 0)) s, gpu idle \(Int(now - lastActivity)) s)")
            onNotResponding?(Diagnostic(idle: now - lastActivity, heartbeatAge: heartbeatAge(at: now) ?? 0,
                                       history: diagnosticHistory(now: now),
                                       memoryHistory: VMMemoryDiagnostics.shared.history(),
                                       threadSnapshot: StallThreadDiagnostics.snapshot()))
        }
        if !longStallLogged && now - max(lastActivity, gateOpenedAt) >= 10 {
            longStallLogged = true
            for line in diagnosticHistory(now: now).split(separator: "\n") {
                log("stall: history \(line)")
            }
            for line in StallThreadDiagnostics.snapshot().split(separator: "\n") {
                log("stall: \(line)")
            }
        }
    }

    private func hide(reason: String?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let since = shownSince else { return }
        shownSince = nil
        notRespondingReported = false
        longStallLogged = false
        let duration = now - since.idleStart
        let cpu = duration > 0 ? (StallMonitor.cpuSeconds() - since.cpu) / duration : 0
        log("stall: gpu idle \(String(format: "%.1f", duration)) s (\(status(now, cpu: cpu)))"
            + (reason.map { ", ended by \($0)" } ?? ""))
        cpuSamples.removeAll()
        view.hide()
    }

    // MARK: wording

    private func heartbeatAge(at now: CFTimeInterval) -> CFTimeInterval? {
        lastAlive > 0 ? max(0, now - lastAlive) : nil
    }

    // One poll uses one timestamp, including after diagnostic persistence or UI work.
    // Advancing only the heartbeat clock mid-poll turns host paging into a guest hang
    // (STEAMAC-8 b546e448: last history hb=1.14, report hb=6).
    static func heartbeatTimedOut(at now: CFTimeInterval, lastAlive: CFTimeInterval,
                                  observationStarted: CFTimeInterval, lastPoll: CFTimeInterval) -> Bool {
        lastAlive > 0 && now - lastAlive > heartbeatTimeout
            && now - observationStarted > heartbeatTimeout
            && lastPoll > 0 && now - lastPoll <= heartbeatTimeout
    }

    private func notResponding(at now: CFTimeInterval) -> Bool {
        Self.heartbeatTimedOut(at: now, lastAlive: lastAlive,
                              observationStarted: heartbeatObservationStarted, lastPoll: lastPoll)
    }

    private func text(now: CFTimeInterval, idle: CFTimeInterval) -> (String, String) {
        if notResponding(at: now) {
            return (String(localized: "SteamOS is not responding…"), String(localized: "waiting (\(Int(idle)) s)"))
        }
        return (String(localized: "Don’t Panic!"),
                String(localized: "If the screen is frozen, the VM is most likely compiling shaders or loading content."))
    }

    /// For the log: "guest alive, CPU 2.9 cores".
    private func status(_ now: CFTimeInterval, cpu: Double? = nil) -> String {
        let guest: String
        if let age = heartbeatAge(at: now) {
            if age <= Self.heartbeatTimeout {
                guest = "guest alive, load \(String(format: "%.2f", guestLoad))"
            } else if notResponding(at: now) {
                guest = "guest not responding for \(Int(age)) s"
            } else {
                guest = "heartbeat delayed \(Int(age)) s, observing after host scheduling gap"
            }
        } else {
            guest = "no guest heartbeat"
        }
        return "\(guest), CPU \(String(format: "%.1f", cpu ?? currentCPU())) cores"
    }

    // MARK: CPU

    /// User + system CPU time of this process (all threads: vCPUs, GPU worker, renderer).
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    private func noteCPU(_ now: CFTimeInterval) {
        cpuSamples.append((now, StallMonitor.cpuSeconds()))
        // Keep ~1 s of readings (one per tick).
        while let first = cpuSamples.first, now - first.0 > 1.01, cpuSamples.count > 2 { cpuSamples.removeFirst() }
    }

    /// Cores busy over the last second (since the idle start until a second of readings exists).
    private func currentCPU() -> Double {
        if cpuSamples.count >= 2, let a = cpuSamples.first, let b = cpuSamples.last, b.0 - a.0 >= 0.5 {
            return max(0, (b.1 - a.1) / (b.0 - a.0))
        }
        guard let since = shownSince else { return 0 }
        let dt = CACurrentMediaTime() - since.idleStart
        return dt > 0 ? max(0, (StallMonitor.cpuSeconds() - since.cpu) / dt) : 0
    }

    // MARK: stall evidence

    private func noteReading(now: CFTimeInterval, counters: Counters?) {
        let gap = lastPoll > 0 ? now - lastPoll : 0
        lastPoll = now
        guard now - lastReading >= 1 else { return }
        lastReading = now
        // Guest game focus is not host application focus (STEAMAC-8N/8P).
        // Keep presentation state in the same bounded timeline as GPU activity:
        // otherwise a later foreground report cannot establish when occlusion began.
        let window = view.window
        let windowState: String
        if let window {
            windowState = window.isMiniaturized ? "miniaturized"
                : !window.isVisible ? "hidden"
                : window.occlusionState.contains(.visible) ? "visible" : "occluded"
        } else {
            windowState = "detached"
        }
        let reading = Reading(at: now, counters: counters, heartbeatAge: heartbeatAge(at: now),
                              uptimeMs: guestUptimeMs, load: guestLoad, cpu: Self.cpuSeconds(),
                              pollGap: gap, game: gameFocused, gate: gateOpen,
                              hostActive: NSApp.isActive, hostKey: window?.isKeyWindow ?? false,
                              hostWindow: windowState)
        if readings.count < 32 {
            readings.append(reading)
        } else {
            readings[nextReading] = reading
        }
        nextReading = (nextReading + 1) % 32
        CrashReporting.updateGPUHistory(diagnosticHistory(now: now) + "\n" + VMMemoryDiagnostics.shared.history())
    }

    // Unlabelled neighbouring counters can resemble a payment-card number to
    // Sentry's scrubber (1.9.9 events 3859f512 / 4b047457, STEAMAC-8).
    static func diagnosticCounterText(_ counters: Counters?) -> String {
        counters.map { "ctrl=\($0.ctrl) ring=\($0.ring)" } ?? "ctrl=unavailable ring=unavailable"
    }

    private func diagnosticHistory(now: CFTimeInterval) -> String {
        var lines = ["GPU activity samples (ago seconds; counters cumulative; CPU cumulative seconds)"]
        for offset in 0..<readings.count {
            let r = readings[(readings.count == 32 ? nextReading + offset : offset) % 32]
            let heartbeat = r.heartbeatAge.map { String(format: "%.2f", $0) } ?? "none"
            lines.append(String(format: "ago=%.2f ", now - r.at) + Self.diagnosticCounterText(r.counters)
                         + " hb=\(heartbeat) up=\(r.uptimeMs)"
                         + String(format: " load=%.2f cpu=%.2f gap=%.2f", r.load, r.cpu, r.pollGap)
                         + " game=\(r.game) gate=\(r.gate)"
                         + " host-active=\(r.hostActive) host-key=\(r.hostKey) window=\(r.hostWindow)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: perf stats

    private func perfNote(now: CFTimeInterval, counters c: Counters?, active: Bool) {
        guard PerfStats.shared != nil else { perfStart = 0; return }
        if perfStart == 0 {
            perfStart = now
            perfCounters = c
            perfLongestIdle = 0
        }
        if !active { perfLongestIdle = max(perfLongestIdle, now - max(lastActivity, perfStart)) }
        guard now - perfStart >= StallMonitor.perfPeriod - StallMonitor.tick / 2 else { return }
        let dt = now - perfStart
        if let c, let p = perfCounters {
            log(String(format: "perf: gpu ctrl/s=%.1f ring/s=%.1f longest-idle=%.2f s",
                       Double(c.ctrl &- p.ctrl) / dt, Double(c.ring &- p.ring) / dt, perfLongestIdle))
        } else {
            log("perf: gpu counters unavailable")
        }
        perfStart = now
        perfCounters = c
        perfLongestIdle = 0
    }
}

/// A pass-through status card over the last guest frame. The Report link accepts clicks
/// when the monitor confirms a lost heartbeat.
final class StallIndicatorView: LoaderCardView {
    override var minimumCardHeight: CGFloat { 128 }
}

class LoaderCardView: NSView {
    var minimumCardHeight: CGFloat { 84 }
    private let cardShadow = StellaCardShadowLayer()
    let surface = StellaCardSurface()
    private var card: StellaStatusCardLayer { surface.card }
    private static let snapshotContext = CIContext()
    private let spinner = CALayer()
    private let titleLayer = StellaTitleLayer()
    private let detailLayer = CATextLayer()
    private let statusLayer = CATextLayer()
    private let linkLayer = CATextLayer()
    private var title = ""
    private var detail = ""
    private var status = ""
    private(set) var shown = false
    /// Shown or hidden (after the fade-out), and the "Report…" link placed or removed on a card
    /// already shown: the window hides the Mac cursor over the picture and shows it over the
    /// link, so it re-decides then.
    var onVisibilityChange: (() -> Void)?

    var currentTitle: String { title }
    var currentDetail: String { detail }
    /// The card and the spinner, in view coordinates (self-test pixel checks).
    var cardFrame: CGRect { surface.frame }
    var spinnerFrame: CGRect { spinner.frame.offsetBy(dx: cardFrame.minX, dy: cardFrame.minY) }
    /// "Report…" on the card (Report a Problem), in view coordinates; empty when not shown.
    var reportLinkFrame: CGRect {
        showsReportLink && onReport != nil ? linkLayer.frame.offsetBy(dx: cardFrame.minX, dy: cardFrame.minY) : .zero
    }
    /// Opens Report a Problem (the link is shown only when this is set).
    var onReport: (() -> Void)?
    /// The "not responding" wording: show the link.
    var showsReportLink = false {
        didSet {
            guard showsReportLink != oldValue else { return }
            reportLinkChanged = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// layout() places the link, then onVisibilityChange re-decides the cursor over it.
    private var reportLinkChanged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        layer!.backgroundColor = OverlayView.color(0, 0.20)
        spinner.opacity = 0.55
        for alpha in [1.0, 0.87, 0.75, 0.63, 0.51, 0.39, 0.27, 0.15] {
            let blade = CALayer()
            blade.backgroundColor = OverlayView.color(0xd9d9d9, alpha)
            spinner.addSublayer(blade)
        }
        detailLayer.alignmentMode = .left
        detailLayer.isWrapped = true
        statusLayer.alignmentMode = .left
        linkLayer.alignmentMode = .left
        linkLayer.truncationMode = .end
        for l in [spinner, titleLayer, detailLayer, statusLayer, linkLayer] { card.addSublayer(l) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        layer!.addSublayer(cardShadow)
        addSubview(surface)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, alphaValue > 0, let superview else { return nil }
        return reportLinkFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard reportLinkFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        log("stall: Report… clicked")
        onReport?()
    }

    override func resetCursorRects() {
        if !reportLinkFrame.isEmpty { addCursorRect(reportLinkFrame, cursor: .pointingHand) }
    }

    override var isOpaque: Bool { false }

    // MARK: visibility

    /// Pop in on first appearance and start the spinner.
    func show() {
        guard !shown else { return }
        shown = true
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        surface.transition(appearing: true, in: self, shadow: cardShadow)
        startSpinner()
        onVisibilityChange?()
    }

    func hide(animated: Bool = true) {
        guard shown || (!animated && !isHidden) else { return }
        shown = false
        surface.transition(appearing: false, in: self, shadow: cardShadow, animated: animated) { [weak self] in
            guard let self else { return }
            self.isHidden = true
            for l in [self.layer!, self.card, self.spinner, self.titleLayer, self.detailLayer, self.statusLayer, self.linkLayer] { l.removeAllAnimations() }
            self.onVisibilityChange?()
        }
    }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool {
        isHidden && [layer!, surface.layer!, card, spinner, titleLayer, detailLayer, statusLayer, linkLayer].allSatisfy { ($0.animationKeys() ?? []).isEmpty }
    }

    private func startSpinner() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = (0...8).map { -Double($0) * .pi / 4 }
        rotation.calculationMode = .discrete
        rotation.duration = 0.8
        rotation.repeatCount = .infinity
        spinner.add(rotation, forKey: "spin")
    }

    // MARK: content

    func update(title: String, detail: String, status: String = "") {
        guard title != self.title || detail != self.detail || status != self.status else { return }
        self.title = title
        self.detail = detail
        self.status = status
        setAccessibilityLabel(title)
        setAccessibilityValue([detail, status].filter { !$0.isEmpty }.joined(separator: "\n"))
        needsLayout = true
    }

    private var scaleFactor: CGFloat { max(0.62, min(bounds.width / 1920, bounds.height / 1080)) }
    // Figma exports its 10 px background blur as a Gaussian with a 5 px standard deviation.
    private var backdropSigma: CGFloat { 5 * scaleFactor }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let k = scaleFactor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pad = 31 * k, spin = 32 * k, gap = 20 * k
        let width = min(573 * k, max(0, b.width - 16))
        let textX = pad + spin + gap
        let textWidth = max(1, width - textX - pad)
        let titleFont = NSFont.systemFont(ofSize: 24 * k, weight: .medium)
        let bodyFont = NSFont.systemFont(ofSize: 18 * k)
        let body = NSAttributedString(string: detail, attributes: [
            .font: bodyFont, .foregroundColor: OverlayView.color(0xffffff, 0.5)])
        let detailHeight = ceil(body.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let titleHeight = ceil(29 * k)
        let statusHeight = status.isEmpty ? 0 : ceil(21 * k)
        let statusBlock = status.isEmpty ? 0 : 5 * k + statusHeight
        let hasLink = showsReportLink && onReport != nil
        let linkHeight = hasLink ? ceil(23 * k) : 0
        let linkGap = hasLink ? 5 * k : 0
        let textHeight = titleHeight + (detail.isEmpty ? 0 : 5 * k + detailHeight) + statusBlock + linkGap + linkHeight
        let height = max(minimumCardHeight * k, textHeight + 52 * k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer!, spinner, titleLayer, detailLayer, statusLayer, linkLayer] { l.contentsScale = scale }
        let cardFrame = CGRect(x: b.midX - width / 2, y: min(56 * k, b.height * 0.06), width: width, height: height)
        surface.fit(cardFrame, shadow: cardShadow, designScale: k, backingScale: scale)
        spinner.bounds = CGRect(x: 0, y: 0, width: spin, height: spin)
        spinner.position = CGPoint(x: pad + spin / 2, y: height / 2)
        for (i, blade) in (spinner.sublayers ?? []).enumerated() {
            let angle = CGFloat(i) * .pi / 4
            blade.bounds = CGRect(x: 0, y: 0, width: 4 * k, height: 10 * k)
            blade.position = CGPoint(x: spin / 2 - sin(angle) * 11 * k, y: spin / 2 + cos(angle) * 11 * k)
            blade.cornerRadius = 2 * k
            blade.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        let bottom = (height - textHeight) / 2
        titleLayer.frame = CGRect(x: textX, y: bottom + textHeight - titleHeight, width: textWidth, height: titleHeight)
        titleLayer.setText(title, font: titleFont, alignment: .left)
        detailLayer.frame = CGRect(x: textX, y: bottom + linkHeight + linkGap + statusBlock, width: textWidth, height: detailHeight)
        detailLayer.string = body
        statusLayer.isHidden = status.isEmpty
        statusLayer.frame = CGRect(x: textX, y: bottom + linkHeight + linkGap, width: textWidth, height: statusHeight)
        statusLayer.string = NSAttributedString(string: status, attributes: [
            .font: NSFont.systemFont(ofSize: 18 * k, weight: .medium),
            .foregroundColor: OverlayView.color(0xffffff, 0.5)])
        linkLayer.isHidden = !hasLink
        let link = NSAttributedString(string: String(localized: "Report…", comment: "Link to report an unresponsive VM to the developer"),
                                      attributes: [.font: bodyFont, .foregroundColor: OverlayView.color(0x72bfff),
                                                   .underlineStyle: NSUnderlineStyle.single.rawValue])
        linkLayer.frame = hasLink ? CGRect(x: textX, y: bottom, width: min(textWidth, ceil(link.size().width) + 2), height: linkHeight) : .zero
        linkLayer.string = link
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        if reportLinkChanged {
            reportLinkChanged = false
            onVisibilityChange?()
        }
    }

    /// Render the indicator (model values) over `background` at `scale` pixels per point.
    func renderImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        renderLayerImage(scale: scale, under: background) { ctx in
            // A layer-tree snapshot has no WindowServer backdrop. Sample the same guest
            // pixels at output resolution, including pixels beyond the card's rounded edges.
            guard let background else { return }
            let target = self.bounds.size
            let input = CIImage(cgImage: background).transformed(by: CGAffineTransform(
                scaleX: target.width * scale / CGFloat(background.width),
                y: target.height * scale / CGFloat(background.height)))
            let crop = self.cardFrame.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: self.backdropSigma * scale)
            guard let patch = Self.snapshotContext.createCGImage(blurred, from: crop) else { return }
            ctx.addPath(StellaInsetLayer.continuousPath(in: self.cardFrame, radius: self.card.cornerRadius))
            ctx.clip()
            ctx.draw(patch, in: crop.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)))
        }
    }
}

extension NSView {
    /// This layer-backed view (if shown) over `background` at `scale` pixels per point: window
    /// dumps of the cards over the guest frame. A hidden view returns a `background` of that size
    /// as is (no copy on the main thread).
    func renderLayerImage(scale: CGFloat, under background: CGImage?,
                          drawBackdrop: ((CGContext) -> Void)? = nil) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        let visible = !isHidden && alphaValue > 0
        if !visible, let background, background.width == w, background.height == h { return background }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if visible, let layer {
            ctx.saveGState()
            ctx.setAlpha(alphaValue)
            ctx.scaleBy(x: scale, y: scale)
            if let drawBackdrop {
                ctx.saveGState()
                drawBackdrop(ctx)
                ctx.restoreGState()
            }
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
