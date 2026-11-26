import AppKit
import CoreText
import QuartzCore

/// Figma's top-left terminal layout, with a fixed heading above the newest console rows.
final class VerboseBootLayer: CALayer {
    var lines: () -> [NSAttributedString] = { [] }
    private let wordmark = StellaPDFLayer(resource: StellaBrand.verboseWordmark)
    private var heading = String(localized: "Booting up SteamOS...")

    override init() {
        super.init()
        backgroundColor = OverlayView.color(0)
        masksToBounds = true
        needsDisplayOnBoundsChange = true
        addSublayer(wordmark)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    override func action(forKey event: String) -> CAAction? { nil }

    private var k: CGFloat { min(bounds.width / 1920, bounds.height / 1080) }

    func fit(_ rect: CGRect, scale: CGFloat) {
        frame = rect
        if contentsScale != scale {
            contentsScale = scale
            wordmark.contentsScale = scale
            wordmark.setNeedsDisplay()
            setNeedsDisplay()
        }
        // The exported vector includes the half-stroke outside Figma’s 185.14 × 24 layout box.
        wordmark.frame = CGRect(x: 38.57 * k, y: bounds.height - 65.43 * k, width: 188 * k, height: 26.86 * k)
    }

    func update(_ state: ProgressState) {
        if state.stageId == "boot-failed" {
            heading = state.title
        } else if case .shutdown(let reboot) = state.phase {
            heading = reboot ? String(localized: "Restarting SteamOS...") : String(localized: "Shutting down SteamOS...")
        } else {
            heading = String(localized: "Booting up SteamOS...")
        }
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard k > 0 else { return }
        let font = StellaBrand.monoRegular(size: max(8, 14 * k))
        let headingFont = StellaBrand.monoMedium(size: max(10, 18 * k))
        let attributes: [NSAttributedString.Key: Any] = [.font: headingFont, .foregroundColor: NSColor.white]
        let inset = 40 * k
        let width = bounds.width - 2 * inset
        let headingHeight = max(24 * k, CTFontGetAscent(headingFont) + CTFontGetDescent(headingFont))
        let lineHeight = max(20 * k, CTFontGetAscent(font) + CTFontGetDescent(font))
        let rowGap = 5 * k
        let step = lineHeight + rowGap
        let top = bounds.height - 79 * k
        let logTop = top - headingHeight - 10 * k
        let firstBaseline = logTop - (lineHeight + CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        let capacity = max(0, Int((logTop - inset + rowGap) / step))
        guard width > 1 else { return }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: inset, y: top - (headingHeight + CTFontGetAscent(headingFont) - CTFontGetDescent(headingFont)) / 2)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: heading, attributes: attributes)), ctx)
        var rows: [CTLine] = []
        for message in lines().reversed() {
            guard rows.count < capacity else { break }
            let value = NSMutableAttributedString(attributedString: message)
            value.addAttribute(.font, value: font, range: NSRange(location: 0, length: value.length))
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var wrapped: [CTLine] = []
            var start = 0
            while start < value.length {
                let length = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                guard length > 0 else { break }
                wrapped.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length)))
                start += length
            }
            rows.append(contentsOf: wrapped.reversed().prefix(capacity - rows.count))
        }
        for (index, row) in rows.reversed().enumerated() {
            ctx.textPosition = CGPoint(x: inset, y: firstBaseline - CGFloat(index) * step)
            CTLineDraw(row, ctx)
        }
    }
}
