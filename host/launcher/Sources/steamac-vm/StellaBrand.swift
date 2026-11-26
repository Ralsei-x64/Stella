import AppKit
import CoreText
import CoreImage
import QuartzCore
import SwiftUI

/// Vector assets and the background shared by Stella’s full-window screens.
enum StellaBrand {
    static let introduction: LocalizedStringResource = "Stella seeks to run your Steam games on your Mac with minimal hassle.\n\nStella works by running a SteamOS ARM microVM that has access to your Mac’s graphics capabilities to provide near-native graphics performance."
    static let silver = Bundle.module.url(forResource: "WordmarkSilver", withExtension: "pdf", subdirectory: "Brand")
    static let verboseWordmark = Bundle.module.url(forResource: "VerboseWordmark", withExtension: "pdf", subdirectory: "Brand")
    static let onDark = silver.flatMap(NSImage.init(contentsOf:))
    static let onLight = Bundle.module.url(forResource: "WordmarkInk", withExtension: "pdf", subdirectory: "Brand")
        .flatMap(NSImage.init(contentsOf:))
    private static func typeface(_ name: String) -> CGFont? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Brand"),
              let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGFont(provider)
    }
    private static let regular = typeface("JetBrainsMono-Regular")
    private static let medium = typeface("JetBrainsMono-Medium")

    static func monoMedium(size: CGFloat) -> CTFont {
        medium.map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) as CTFont
    }

    static func monoRegular(size: CGFloat) -> CTFont {
        regular.map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }

    static func backgroundLayer() -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.colors = [OverlayView.color(0x121212), OverlayView.color(0x050505)]
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 1.17, y: 0.67)
        return layer
    }
}

/// Draw the PDF at this window's backing scale whenever the overlay resizes or moves screens.
final class StellaPDFLayer: CALayer {
    private let document: CGPDFDocument?

    init(resource: URL?) {
        document = resource.flatMap { CGPDFDocument($0 as CFURL) }
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        document = (layer as? StellaPDFLayer)?.document
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let page = document?.page(at: 1) else { return }
        ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
    }
}

/// Exterior-only Figma drop shadow. The card material and its backdrop can stay translucent.
final class StellaCardShadowLayer: CALayer {
    private static let renderer = CIContext()
    private var cardBounds = CGRect.zero
    private var cardRadius: CGFloat = 0
    private var continuous = false
    private var designScale: CGFloat = 1

    func fit(around card: CALayer, designScale: CGFloat, backingScale: CGFloat) {
        // Four Gaussian standard deviations plus the downward offset cover the visible tail.
        let padding = ceil((4 * 25 + 8) * designScale)
        let rect = card.frame.insetBy(dx: -padding, dy: -padding)
        let silhouette = CGRect(origin: CGPoint(x: padding, y: padding), size: card.bounds.size)
        frame = rect
        let usesContinuousCorners = card.cornerCurve == .continuous
        guard cardBounds != silhouette || cardRadius != card.cornerRadius ||
                continuous != usesContinuousCorners || self.designScale != designScale ||
                contentsScale != backingScale else { return }
        cardBounds = silhouette
        cardRadius = card.cornerRadius
        continuous = usesContinuousCorners
        self.designScale = designScale
        contentsScale = backingScale
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard !cardBounds.isEmpty else { return }
        let scale = contentsScale
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let edge = continuous ? StellaInsetLayer.continuousPath(in: cardBounds, radius: cardRadius) :
            CGPath(roundedRect: cardBounds, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        source.scaleBy(x: scale, y: scale)
        source.translateBy(x: 0, y: -8 * designScale)
        source.setFillColor(OverlayView.color(0, 0.8))
        source.addPath(edge)
        source.fillPath()
        guard let mask = source.makeImage() else { return }
        let input = CIImage(cgImage: mask)
        let blurred = input.applyingGaussianBlur(sigma: 25 * designScale * scale)
        guard let image = Self.renderer.createCGImage(blurred, from: input.extent) else { return }
        ctx.addRect(bounds)
        ctx.addPath(edge)
        ctx.clip(using: .evenOdd)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}

/// The topmost stroke on a loader card or progress track.
final class StellaBorderLayer: CAShapeLayer {
    /// Anchor the rim to device pixels so a thin black stroke covers the edge highlights.
    static func alignedFrame(_ rect: CGRect, scale: CGFloat) -> CGRect {
        func snap(_ point: CGFloat) -> CGFloat { (point * scale).rounded() / scale }
        let x = snap(rect.minX), y = snap(rect.minY)
        return CGRect(x: x, y: y, width: snap(rect.maxX) - x, height: snap(rect.maxY) - y)
    }

    func fit(to surface: CALayer, width: CGFloat, scale: CGFloat) {
        frame = surface.bounds
        contentsScale = scale
        fillColor = nil
        strokeColor = OverlayView.color(0)
        lineWidth = max(width, 1 / scale)
        let half = lineWidth / 2
        let rect = bounds.insetBy(dx: half, dy: half)
        guard !rect.isEmpty else { path = nil; return }
        let radius = max(0, surface.cornerRadius - half)
        path = surface.cornerCurve == .continuous ? StellaInsetLayer.continuousPath(in: rect, radius: radius) :
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// The native material clips the live scene and hosts the artwork. Transforming this one
/// view moves the backdrop, stroke, text and controls as one surface.
final class StellaCardSurface: NSVisualEffectView {
    let card = StellaStatusCardLayer()
    private let artwork = NSView()
    private var motionID: UUID?

    init(blending: NSVisualEffectView.BlendingMode = .withinWindow) {
        super.init(frame: .zero)
        blendingMode = blending
        material = .hudWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        artwork.wantsLayer = true
        artwork.layer = card
        addSubview(artwork)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fit(_ rect: CGRect, shadow: StellaCardShadowLayer, designScale k: CGFloat, backingScale scale: CGFloat) {
        frame = StellaBorderLayer.alignedFrame(rect, scale: scale)
        artwork.frame = bounds
        card.fit(bounds, designScale: k, backingScale: scale)
        layer?.cornerRadius = card.cornerRadius
        shadow.fit(around: card, designScale: k, backingScale: scale)
        shadow.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Transform the native material itself around the card’s bottom edge. Only the foreground
    /// artwork has a focus filter; the scene blur is clipped and composited by the material.
    /// Capture the presentation values before replacing an in-flight transition.
    func transition(appearing: Bool, in view: NSView, shadow: CALayer,
                    animated: Bool = true, completion: (() -> Void)? = nil) {
        let id = UUID()
        motionID = id
        let material = layer!
        let parts = [material, shadow]
        let duration = 0.34
        let alpha: CGFloat = appearing ? 1 : 0
        func finish() {
            guard motionID == id else { return }
            motionID = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for part in parts { part.removeAnimation(forKey: "statusPop") }
            card.removeAnimation(forKey: "statusFocus")
            card.filters = nil
            CATransaction.commit()
            completion?()
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !bounds.isEmpty else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                view.animator().alphaValue = alpha
            }
            finish()
            return
        }

        let small: CGFloat = 0.88
        let initial = appearing ? small : 1
        let target = appearing ? 1 : small
        let reversing = material.animation(forKey: "statusPop") != nil
        let current = reversing ? material.presentation()?.transform.m11 ?? initial : initial
        let blurredRadius = 8 * card.cornerRadius / 30
        let currentBlur = (card.presentation()?.filters?.first as? CIFilter)?.value(forKey: kCIInputRadiusKey) as? NSNumber
        let fromRadius = reversing ? CGFloat(currentBlur?.doubleValue ?? 0) : (appearing ? blurredRadius : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: appearing ? 0 : blurredRadius]) {
            blur.name = "statusBlur"
            card.filters = [blur]
            let focus = CABasicAnimation(keyPath: "filters.statusBlur.inputRadius")
            focus.fromValue = fromRadius
            focus.toValue = appearing ? 0 : blurredRadius
            focus.duration = 0.24
            if !appearing && !reversing {
                focus.beginTime = card.convertTime(CACurrentMediaTime(), from: nil) + duration - focus.duration
                focus.fillMode = .backwards
            }
            focus.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
            card.add(focus, forKey: "statusFocus")
        }
        for part in parts {
            let direction: CGFloat = part.superlayer?.isGeometryFlipped == true ? 1 : -1
            let pivot = CGPoint(x: part.frame.midX, y: part.frame.midY + direction * bounds.height / 2)
            let pop = CAKeyframeAnimation(keyPath: "transform")
            let scales: [CGFloat] = reversing ? [current, target] : [initial, 1.016, target]
            pop.values = scales.map { s in
                var transform = CATransform3DMakeScale(s, s, 1)
                transform.m41 = (1 - s) * (pivot.x - part.position.x)
                transform.m42 = (1 - s) * (pivot.y - part.position.y)
                return NSValue(caTransform3D: transform)
            }
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            if reversing {
                pop.keyTimes = [0, 1]
                pop.timingFunctions = [ease]
            } else {
                pop.keyTimes = appearing ? [0, 0.7, 1] : [0, 0.3, 1]
                pop.timingFunctions = appearing ? [CAMediaTimingFunction(name: .easeOut), ease]
                    : [ease, CAMediaTimingFunction(name: .easeIn)]
            }
            pop.duration = duration
            if !appearing {
                pop.fillMode = .forwards
                pop.isRemovedOnCompletion = false
            }
            part.add(pop, forKey: "statusPop")
        }
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
            view.animator().alphaValue = alpha
        }, completionHandler: finish)
    }
}

/// The black rim sits above both inset highlights, on the same pixel-aligned contour.
struct StellaCardEdge {
    private let inset = StellaInsetLayer()
    private let outline = StellaBorderLayer()

    init(insetOpacity: CGFloat = 0.25) {
        inset.insetColor = OverlayView.color(0xffffff, insetOpacity)
    }

    func install(on surface: CALayer) {
        inset.cornerCurve = surface.cornerCurve
        surface.addSublayer(inset)
        outline.zPosition = 1
        surface.addSublayer(outline)
    }

    func fit(to surface: CALayer, designScale k: CGFloat, backingScale scale: CGFloat) {
        outline.fit(to: surface, width: k, scale: scale)
        inset.fit(surface.bounds, corner: surface.cornerRadius, offset: 2 * k, blur: k, scale: scale,
                  clipInset: outline.lineWidth)
    }
}

/// The status boxes share a translucent gradient, two short inset highlights and a foreground stroke.
final class StellaStatusCardLayer: CAGradientLayer {
    private let edge = StellaCardEdge()

    override init() {
        super.init()
        type = .radial
        colors = [OverlayView.color(0x282828, 0.8), OverlayView.color(0x141414, 0.8)]
        startPoint = CGPoint(x: 0.5, y: 0)
        endPoint = CGPoint(x: 1.17, y: 0.67)
        masksToBounds = true
        cornerCurve = .continuous
        edge.install(on: self)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    // All motion is explicit, including changes to the card’s foreground and background filters.
    override func action(forKey event: String) -> CAAction? { nil }

    func fit(_ rect: CGRect, designScale k: CGFloat, backingScale scale: CGFloat) {
        frame = StellaBorderLayer.alignedFrame(rect, scale: scale)
        contentsScale = scale
        cornerRadius = 30 * k
        edge.fit(to: self, designScale: k, backingScale: scale)
    }
}

/// The paired white inner shadows on the stall card and boot progress track.
final class StellaInsetLayer: CALayer {
    private var offset: CGFloat = 0
    private var blur: CGFloat = 0
    private var clipInset: CGFloat = 0
    var insetColor = OverlayView.color(0xffffff, 0.25)

    static func continuousPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    func fit(_ rect: CGRect, corner: CGFloat, offset: CGFloat, blur: CGFloat, scale: CGFloat, clipInset: CGFloat = 0) {
        guard frame != rect || cornerRadius != corner || self.offset != offset ||
                self.blur != blur || contentsScale != scale || self.clipInset != clipInset else { return }
        frame = rect
        cornerRadius = corner
        self.offset = offset
        self.blur = blur
        self.clipInset = clipInset
        contentsScale = scale
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        func contour(_ rect: CGRect, radius: CGFloat) -> CGPath {
            cornerCurve == .continuous ? Self.continuousPath(in: rect, radius: radius) :
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let edge = contour(bounds, radius: cornerRadius)
        // Figma casts from the outer silhouette. Exclude the foreground stroke from the highlight.
        let interior = bounds.insetBy(dx: clipInset, dy: clipInset)
        guard !interior.isEmpty else { return }
        ctx.addPath(clipInset == 0 ? edge : contour(interior, radius: max(0, cornerRadius - clipInset)))
        ctx.clip()
        // Cast each shadow from outside the rounded outline into the clipped interior.
        let margin = ceil(4 * blur + offset + 1)
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -margin, dy: -margin))
        outside.addPath(edge)
        // Move the opaque caster clear of the clip. Only its shadow should contribute,
        // even where the rounded clip has fractional pixel coverage.
        let casterOffset = ceil(bounds.width + 2 * margin)
        ctx.translateBy(x: casterOffset, y: 0)
        ctx.setFillColor(OverlayView.color(0))
        for dy in [-offset, offset] {
            ctx.setShadow(offset: CGSize(width: -casterOffset, height: dy), blur: blur, color: insetColor)
            ctx.addPath(outside)
            ctx.drawPath(using: .eoFill)
        }
    }
}

/// CATextLayer can request a contents transition when it eventually redraws.
final class ImmediateTextLayer: CATextLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// The design's silver heading fill, masked by the actual localized text at runtime.
final class StellaTitleLayer: CAGradientLayer {
    private let glyphs: CATextLayer

    init(glyphs: CATextLayer = CATextLayer()) {
        self.glyphs = glyphs
        super.init()
        colors = [OverlayView.color(0xffffff), OverlayView.color(0x999999)]
        startPoint = CGPoint(x: 0.5, y: 1)
        endPoint = CGPoint(x: 0.5, y: 0)
        glyphs.truncationMode = .end
        mask = glyphs
    }

    override init(layer: Any) {
        glyphs = CATextLayer()
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) {
        glyphs = CATextLayer()
        super.init(coder: coder)
    }

    func setText(_ text: String, font: NSFont, alignment: CATextLayerAlignmentMode) {
        glyphs.frame = bounds
        glyphs.contentsScale = contentsScale
        glyphs.alignmentMode = alignment
        glyphs.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    }
}

