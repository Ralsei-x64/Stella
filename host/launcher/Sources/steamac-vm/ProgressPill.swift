import AppKit
import QuartzCore

/// Compact shutdown progress and the post-boot no-picture diagnostic. A click on
/// shutdown progress expands it into the window. Startup progress lives in OverlayView.
final class ProgressPillView: LoaderCardView {
    struct Content: Equatable {
        var title: String
        var detail: String
        /// Overall fraction, when available.
        var fraction: Double?
        init(title: String, detail: String, fraction: Double?) {
            self.title = title
            self.detail = detail
            self.fraction = fraction
        }

        init(_ s: ProgressState) {
            self.init(title: s.title, detail: s.detail, fraction: s.stageId == "boot-failed" ? nil : s.fraction)
        }

        var percentText: String {
            guard let fraction else { return "" }
            return "\(Int((fraction * 100).rounded(.down)))%"
        }
    }

    private(set) var content = Content(title: "", detail: "", fraction: nil)
    var onClick: (() -> Void)?
    var clickable: () -> Bool = { false }

    func update(_ value: Content) {
        content = value
        update(title: value.title, detail: value.detail, status: value.percentText)
    }

    private var acceptsClick: Bool { shown && onClick != nil && clickable() }

    /// The click that activates the window expands the pill too (as clicks reach the guest).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, acceptsClick, let superview else { return nil }
        return cardFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsClick, cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        if acceptsClick { addCursorRect(cardFrame, cursor: .pointingHand) }
    }

}

/// "Waiting for SteamOS to draw…" after `ready`: the window has had no guest picture at all for
/// `missingThreshold` (scanout off, or no frame since the last scanout set / resize) or the
/// presented picture has been black for `blackThreshold`, while Steam or the desktop has focus
/// and SteamOS neither sleeps nor is paused / suspended (a game's idle GPU is the GPU-idle card's
/// job). The report says what is known: a guest detail line received after `ready` if any, why
/// (display off / no frame / black picture), the heartbeat and the VM's CPU. It ends with the
/// first non-black frame. Black = at least `blackFraction` of Scanout's sparse sample points
/// below its luma threshold; a frame is sampled only when a newer one was presented, at most
/// once per `tick`. Main thread only.
final class NoPictureGuard {
    struct Report: Equatable {
        var title: String
        var detail: String
    }

    static let tick: TimeInterval = 0.25
    static let missingThreshold: TimeInterval = 3
    static let blackThreshold: TimeInterval = 5
    static let blackFraction = 0.995
    static let title = String(localized: "Waiting for SteamOS to draw…")

    private let probe: (UInt64) -> Scanout.Probe
    private var timer: DispatchSourceTimer?
    /// `presented` of the last sampled frame (`.max`: sample the current one).
    private var seen = UInt64.max
    /// Darkness of the latest sampled frame of the current picture.
    private var lastDark: Double?
    /// No picture since (scanout off, or no frame since the last set / resize).
    private var missingSince: CFTimeInterval?
    /// No picture or a black one since; a non-black frame resets it.
    private var darkSince: CFTimeInterval?
    private var shownSince: CFTimeInterval?
    private var lastAlive: CFTimeInterval = 0
    private var cpuSamples: [(CFTimeInterval, Double)] = []

    /// Steam is ready (the boot overlay / pill is gone; the guest is not shutting down).
    var ready = false { didSet { if ready != oldValue { gateChanged("not ready") } } }
    /// A game has focus: the GPU-idle card covers games.
    var gameFocused = false { didSet { if gameFocused != oldValue { gateChanged("game focused") } } }
    /// "Game paused" (GamePause confirmed a frozen game).
    var gamePaused = false { didSet { if gamePaused != oldValue { gateChanged("game paused") } } }
    /// SteamOS sleeps.
    var asleep = false { didSet { if asleep != oldValue { gateChanged("SteamOS asleep") } } }
    /// The VM is paused (suspend, guest sleep).
    var vmPaused = false { didSet { if vmPaused != oldValue { gateChanged("VM paused") } } }
    /// A guest detail line received after `ready` (`log …`), if any.
    var lastKnown: () -> String? = { nil }
    /// Report to show, or nil to hide.
    var onChange: ((Report?) -> Void)?
    private(set) var report: Report?

    init(probe: @escaping (UInt64) -> Scanout.Probe) {
        self.probe = probe
    }

    private var gateOpen: Bool { ready && !gameFocused && !gamePaused && !asleep && !vmPaused }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + NoPictureGuard.tick, repeating: NoPictureGuard.tick, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Guest heartbeat (`alive <uptime_ms> <loadavg1>`).
    func alive() { lastAlive = CACurrentMediaTime() }

    /// The agent ended with the gamescope session (bare `focus desktop`): no heartbeat is expected.
    func heartbeatsEnded() { lastAlive = 0 }

    /// Closed: hide at once. Opened: the clocks start now (stale dark time never counts).
    private func gateChanged(_ closedBy: String) {
        missingSince = nil
        darkSince = nil
        lastDark = nil
        seen = .max
        cpuSamples.removeAll()
        if !gateOpen { hide(closedBy) }
    }

    private func poll() {
        guard gateOpen else { return }
        let now = CACurrentMediaTime()
        let p = probe(seen)
        if let d = p.dark {
            seen = p.presented
            lastDark = d
        }
        let missing = !p.enabled || !p.hasPicture
        if missing {
            lastDark = nil
            if missingSince == nil { missingSince = now }
            if darkSince == nil { darkSince = now }
        } else {
            missingSince = nil
            if let d = lastDark {
                if d >= NoPictureGuard.blackFraction {
                    if darkSince == nil { darkSince = now }
                } else if darkSince != nil {
                    darkSince = nil
                    hide("first non-black frame")
                }
            }
        }
        noteCPU(now)
        let reason = missing ? (p.enabled ? "no frame" : "display off") : "black picture"
        if shownSince == nil {
            let due = missing ? now - (missingSince ?? now) >= NoPictureGuard.missingThreshold
                              : now - (darkSince ?? now) >= NoPictureGuard.blackThreshold
            guard due, let since = darkSince else { return }
            shownSince = since
            log("no-picture: shown after \(String(format: "%.1f", now - since)) s (\(reason)"
                + (missing ? "" : String(format: " %.1f%%", (lastDark ?? 1) * 100)) + "; \(status(now)))")
        }
        guard let since = shownSince else { return }
        var parts: [String] = []
        if let known = lastKnown(), !known.isEmpty { parts.append(known) }
        let seconds = Int(now - since)
        parts.append(missing
            ? (p.enabled ? String(localized: "no frame \(seconds) s") : String(localized: "display off \(seconds) s"))
            : String(localized: "black picture \(seconds) s"))
        if let guest = guestText(now) { parts.append(guest) }
        let cores = String(format: "%.1f", cpu())
        parts.append(String(localized: "VM CPU \(cores) cores"))
        let r = Report(title: NoPictureGuard.title, detail: parts.joined(separator: " · "))
        if r != report {
            report = r
            onChange?(r)
        }
    }

    private func hide(_ why: String) {
        guard let since = shownSince else { return }
        shownSince = nil
        report = nil
        log("no-picture: hidden after \(String(format: "%.1f", CACurrentMediaTime() - since)) s (\(why))")
        onChange?(nil)
    }

    // MARK: wording

    private func guestText(_ now: CFTimeInterval) -> String? {
        guard lastAlive > 0 else { return nil }
        let age = now - lastAlive
        return age > StallMonitor.heartbeatTimeout
            ? String(localized: "guest not responding for \(Int(age)) s")
            : String(localized: "guest alive")
    }

    private func status(_ now: CFTimeInterval) -> String {
        let guest: String
        if lastAlive > 0 {
            let age = now - lastAlive
            guest = age > StallMonitor.heartbeatTimeout ? "guest not responding for \(Int(age)) s" : "guest alive"
        } else {
            guest = "no guest heartbeat"
        }
        return guest + ", CPU \(String(format: "%.1f", cpu())) cores"
    }

    private func noteCPU(_ now: CFTimeInterval) {
        cpuSamples.append((now, StallMonitor.cpuSeconds()))
        while let first = cpuSamples.first, now - first.0 > 1.01, cpuSamples.count > 2 { cpuSamples.removeFirst() }
    }

    /// Cores this process (vCPUs included) kept busy over the last second.
    private func cpu() -> Double {
        guard cpuSamples.count >= 2, let a = cpuSamples.first, let b = cpuSamples.last, b.0 > a.0 else { return 0 }
        return max(0, (b.1 - a.1) / (b.0 - a.0))
    }
}
