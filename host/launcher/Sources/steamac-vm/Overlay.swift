import AppKit
import Metal
import QuartzCore

/// Stella’s boot and shutdown overlay, composited over the Metal view.
/// Never takes mouse events (hitTest → nil); when hidden it is `isHidden` with every animation
/// removed, so it costs nothing per frame.
final class OverlayView: NSView {
    /// AppKit can request a contents transition on unhiding the surface even at opacity 1.
    /// The view’s explicit alpha animations own the boot and manual show/hide transitions.
    private final class SurfaceLayer: CALayer {
        var instant = false
        override func action(forKey event: String) -> CAAction? {
            instant ? nil : super.action(forKey: event)
        }
    }

    private let surfaceLayer = SurfaceLayer()
    private let background = StellaBrand.backgroundLayer()
    private let wordmark = StellaPDFLayer(resource: StellaBrand.silver)
    private let titleLayer = StellaTitleLayer(glyphs: ImmediateTextLayer())
    private let detailLayer = ImmediateTextLayer()
    let verboseScreen = VerboseBootLayer()
    var verbose = false {
        didSet {
            guard oldValue != verbose else { return }
            if shown { apply(state, animated: false) }
        }
    }
    private let track = CALayer()
    private let fill = StellaInsetLayer()
    private let trackInset = StellaInsetLayer()
    private let trackBorder = StellaBorderLayer()
    private var state = ProgressState()
    private(set) var shown = false
    private var fading = false
    /// Called with the new `shown` value when the overlay starts showing / starts fading out.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Progress bar track, in view coordinates (self-test pixel checks).
    var barFrame: CGRect { track.frame }
    var currentTitle: String { state.title }
    var isShuttingDown: Bool {
        if case .shutdown = state.phase { return true }
        return false
    }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Host Vulkan driver of this boot (VM.start).
    static var vulkanDriver = LauncherSettings.VulkanDriver.moltenvk

    static var gpuFooter: String {
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        let short = gpu.hasPrefix("Apple ") ? String(gpu.dropFirst(6)) : gpu
        return "SteamOS · Venus → \(vulkanDriver.name) · \(short)"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = surfaceLayer
        layer!.masksToBounds = true
        autoresizingMask = [.width, .height]

        detailLayer.alignmentMode = .center
        detailLayer.isWrapped = true
        detailLayer.truncationMode = .end
        track.backgroundColor = Self.color(0x373737)
        track.masksToBounds = true
        fill.backgroundColor = Self.color(0xffffff)
        fill.insetColor = Self.color(0, 0.25)
        fill.needsDisplayOnBoundsChange = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        track.addSublayer(trackInset)
        track.addSublayer(trackBorder)
        for l in [background, wordmark, titleLayer, track, detailLayer] as [CALayer] {
            layer!.addSublayer(l)
        }
        verboseScreen.isHidden = true
        layer!.addSublayer(verboseScreen)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func accessibilityHelp() -> String? {
        verbose ? verboseScreen.lines().map(\.string).joined(separator: "\n") : super.accessibilityHelp()
    }

    // MARK: visibility

    /// Show the latest milestone. Shutdown takes over the window immediately.
    func show(animated: Bool = true) {
        let fadeIn: Bool
        switch state.phase {
        case .shutdown: fadeIn = false
        case .boot, .running: fadeIn = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        surfaceLayer.instant = !fadeIn
        if !shown {
            shown = true
            fading = false
            onVisibilityChange?(true)
            isHidden = false
            setAccessibilityHelp(Self.gpuFooter)
            apply(state, animated: false)
        } else if fadeIn {
            return
        }
        if fadeIn {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            layer?.removeAllAnimations()
        }
    }

    /// Fade out (0.6 s), then hide and drop every animation.
    func hide(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard shown, !fading else { completion?(); return }
        surfaceLayer.instant = !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let finish = { [weak self] in
            guard let self else { return }
            self.fading = false
            guard !self.shown else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.isHidden = true
            for item in self.overlayLayers { item.removeAllAnimations() }
            CATransaction.commit()
            completion?()
        }
        shown = false
        onVisibilityChange?(false)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fading = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            alphaValue = 0
            finish()
        }
    }

    private var overlayLayers: [CALayer] {
        [layer!] + (layer?.sublayers ?? []) + (track.sublayers ?? [])
    }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool {
        isHidden && overlayLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty }
    }

    // MARK: content

    func update(_ s: ProgressState) {
        state = s
        guard shown else { return }
        apply(s, animated: true)
    }

    private var scaleFactor: CGFloat { min(bounds.width / 1920, bounds.height / 1080) }

    private func apply(_ s: ProgressState, animated: Bool) {
        let failed = s.stageId == "boot-failed"
        let starting = s.phase == .boot && !failed
        let title = starting ? String(localized: "Starting Session...") : s.title
        var status = starting ? s.title : ""
        if !s.detail.isEmpty && s.detail != status {
            status = status.isEmpty ? s.detail : status + " · " + s.detail
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        verboseScreen.isHidden = !verbose
        for item in [background, wordmark, titleLayer, detailLayer] as [CALayer] { item.isHidden = verbose }
        track.isHidden = verbose || failed
        setAccessibilityLabel([title, status].filter { !$0.isEmpty }.joined(separator: ". "))
        setAccessibilityValue(failed ? nil : NSNumber(value: s.fraction))
        if verbose {
            verboseScreen.update(s)
            CATransaction.commit()
            return
        }
        titleLayer.setText(title, font: .systemFont(ofSize: max(14, 32 * scaleFactor), weight: .medium), alignment: .center)
        detailLayer.string = NSAttributedString(string: status, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, 24 * scaleFactor)),
            .foregroundColor: Self.color(0xffffff, 0.5)])
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.35)
        fill.bounds.size.width = track.bounds.width * CGFloat(s.fraction)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        wordmark.setNeedsDisplay()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let k = scaleFactor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer!] + layer!.sublayers! + [fill] { l.contentsScale = scale }
        verboseScreen.fit(b, scale: scale)
        background.frame = b
        let wmSize = CGSize(width: 501.33 * k, height: 71.62 * k)
        wordmark.frame = CGRect(x: b.midX - wmSize.width / 2, y: b.midY - wmSize.height / 2,
                                width: wmSize.width, height: wmSize.height)
        let titleHeight = max(20, 40 * k)
        titleLayer.frame = CGRect(x: b.width * 0.04, y: b.height * (319 / 1080.0) - titleHeight / 2,
                                  width: b.width * 0.92, height: titleHeight)
        let barWidth = 261 * k, barHeight = max(3, 10 * k)
        let barFrame = CGRect(x: b.midX - barWidth / 2, y: b.height * (125 / 1080.0) - barHeight / 2,
                              width: barWidth, height: barHeight)
        track.frame = StellaBorderLayer.alignedFrame(barFrame, scale: scale)
        track.cornerRadius = track.bounds.height / 2
        trackBorder.fit(to: track, width: k, scale: scale)
        trackInset.fit(track.bounds, corner: track.cornerRadius, offset: 2 * k, blur: k, scale: scale)
        fill.fit(CGRect(x: 0, y: k, width: track.bounds.width * CGFloat(state.fraction), height: track.bounds.height - 2 * k),
                 corner: 0, offset: k, blur: k, scale: scale)
        let statusTop = track.frame.minY - 22 * k
        detailLayer.frame = CGRect(x: b.width * 0.05, y: 2, width: b.width * 0.90, height: max(0, statusTop - 2))
        CATransaction.commit()
        apply(state, animated: false)
    }

    /// Render the overlay (model values) into a context at `scale` pixels per point.
    func renderImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if !isHidden && alphaValue > 0 {
            ctx.saveGState()
            ctx.setAlpha(alphaValue)
            ctx.scaleBy(x: scale, y: scale)
            layer!.render(in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
