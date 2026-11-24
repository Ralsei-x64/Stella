import AppKit
import QuartzCore

/// "Game paused" over the VM picture while GamePause has the focused game frozen (the launcher
/// is in the background): the last frame dimmed to 65 % plus the Stella status box with
/// the game's name (if known) and "Click to resume". Input passes through to the
/// window controller, which swallows the resuming click (WindowController.pointerButton).
/// Guest sleep uses the full-window Stella sleep artwork; the window handles wake input.
final class PauseOverlayView: NSView {
    enum Style { case gamePaused, sleeping }

    private let style: Style
    private let background: CALayer
    private let cardShadow = StellaCardShadowLayer()
    let surface = StellaCardSurface()
    private var card: StellaStatusCardLayer { surface.card }
    private let titleLayer = StellaTitleLayer()
    private let nameLayer = CATextLayer()
    private let hintLayer = CATextLayer()
    private let heading: String
    private let instruction: String
    private var name: String?
    private(set) var shown = false

    static let dimAlpha: CGFloat = 0.35
    init(frame: NSRect, style: Style = .gamePaused) {
        self.style = style
        switch style {
        case .sleeping:
            background = StellaBrand.backgroundLayer()
            heading = String(localized: "SteamOS is sleeping...")
            instruction = String(localized: "Click anywhere to wake up the VM.")
        case .gamePaused:
            background = CALayer()
            background.backgroundColor = OverlayView.color(0, Self.dimAlpha)
            heading = String(localized: "Game paused")
            instruction = String(localized: "Click to resume")
        }
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        alphaValue = 0
        isHidden = true
        for text in [nameLayer, hintLayer] {
            text.alignmentMode = .left
            text.isWrapped = true
        }
        for child in [titleLayer, nameLayer, hintLayer] as [CALayer] { card.addSublayer(child) }
        for child in [background, cardShadow] { layer!.addSublayer(child) }
        addSubview(surface)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(heading)
        setAccessibilityHelp(instruction)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the VM view (the controller decides what to swallow).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    /// The card, in view coordinates (self-test pixel checks).
    var cardFrame: CGRect { surface.frame }
    var currentName: String? { name }

    func show(gameName: String?) {
        if gameName != name {
            name = gameName
            setAccessibilityValue(gameName)
            needsLayout = true
        }
        guard !shown else { return }
        shown = true
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        surface.transition(appearing: true, in: self, shadow: cardShadow)
    }

    func hide(animated: Bool = true) {
        guard shown || (!animated && !isHidden) else { return }
        shown = false
        surface.transition(appearing: false, in: self, shadow: cardShadow, animated: animated) { [weak self] in
            self?.isHidden = true
        }
    }

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
        let k = min(b.width / 1920, b.height / 1080)
        guard k > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = 531 * k, pad = 36 * k, gap = 8 * k, textWidth = width - 2 * pad
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18 * k), .foregroundColor: OverlayView.color(0xffffff, 0.5)]
        let hint = NSAttributedString(string: instruction, attributes: attributes)
        let game = name.map { NSAttributedString(string: $0, attributes: attributes) }
        func lineHeight(_ text: NSAttributedString) -> CGFloat {
            max(21 * k, text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let hintHeight = lineHeight(hint)
        let nameHeight = game.map(lineHeight) ?? 0
        let nameBlock = game == nil ? 0 : gap + nameHeight
        let height = 52 * k + 29 * k + gap + nameBlock + hintHeight
        let centerY = b.midY - (style == .sleeping ? 15 * k : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = b
        surface.fit(CGRect(x: b.midX - width / 2, y: centerY - height / 2, width: width, height: height),
                    shadow: cardShadow, designScale: k, backingScale: scale)
        for item in [titleLayer, nameLayer, hintLayer] as [CALayer] { item.contentsScale = scale }
        hintLayer.frame = CGRect(x: pad, y: 26 * k, width: textWidth, height: hintHeight)
        hintLayer.string = hint
        nameLayer.isHidden = game == nil
        nameLayer.frame = CGRect(x: pad, y: hintLayer.frame.maxY + gap, width: textWidth, height: nameHeight)
        nameLayer.string = game
        titleLayer.frame = CGRect(x: pad, y: hintLayer.frame.maxY + gap + nameBlock, width: textWidth, height: 29 * k)
        titleLayer.setText(heading, font: .systemFont(ofSize: 24 * k, weight: .medium), alignment: .left)
        CATransaction.commit()
    }
}
