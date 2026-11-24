import AppKit

/// Foreground colors only. Console commands never reach the accessibility text or the renderer.
enum VerboseLogStyle {
    private static let palette: [UInt32] = [
        0x59616b, 0xf47777, 0x78cf82, 0xe5c56a, 0x78a9eb, 0xc898da, 0x77cbd7, 0xd8dbe0,
        0x919aa5, 0xff9797, 0x9ae5a2, 0xffdc82, 0x9ec6ff, 0xe0b4ef, 0x9ce4ef, 0xffffff
    ]
    private static let status = try! NSRegularExpression(pattern: #"^\s*\[\s*(OK|FAILED|DEPEND|WARN(?:ING)?|TIME(?:OUT)?|SKIPPED)\s*\]"#)
    private static let timestamp = try! NSRegularExpression(pattern: #"^\s*\[\s*\d+\.\d+\]"#)

    private struct Foreground {
        var index: Int?
        var rgb: UInt32?
        var bold = false

        var color: UInt32? {
            if let index { return palette[bold && index < 8 ? index + 8 : index] }
            return rgb
        }

        mutating func apply(_ parameters: String) {
            // Empty SGR and an empty parameter both mean reset.
            let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? 0 : (Int($0) ?? -1) }
            var i = 0
            while i < codes.count {
                let code = codes[i]
                i += 1
                switch code {
                case 0: self = Foreground()
                case 1: bold = true
                case 22: bold = false
                case 39: index = nil; rgb = nil
                case 30...37: index = code - 30; rgb = nil
                case 90...97: index = code - 90 + 8; rgb = nil
                case 38, 48, 58:
                    // Consume the entire sequence, including ignored background/underline colors.
                    guard i < codes.count else { return }
                    let mode = codes[i]
                    i += 1
                    let count = mode == 5 ? 1 : mode == 2 ? 3 : 0
                    guard count > 0, i + count <= codes.count else { return }
                    let values = codes[i..<i + count]
                    i += count
                    guard code == 38, values.allSatisfy({ (0...255).contains($0) }) else { continue }
                    index = nil
                    if mode == 2 {
                        rgb = values.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    } else {
                        let n = codes[i - 1]
                        if n < 16 { rgb = palette[n] }
                        else if n >= 232 { rgb = UInt32(8 + 10 * (n - 232)) * 0x010101 }
                        else {
                            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
                            let v = n - 16
                            rgb = (steps[v / 36] << 16) | (steps[v / 6 % 6] << 8) | steps[v % 6]
                        }
                    }
                default: continue
                }
            }
        }
    }

    static func line(_ raw: String, stage: Bool) -> NSAttributedString {
        var foreground = Foreground()
        var changes: [(offset: Int, color: UInt32?)] = []
        let text = BootProgress.stripANSI(raw) { parameters, offset in
            foreground.apply(parameters)
            changes.append((offset, foreground.color))
        }
        let result = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.white])
        let full = NSRange(location: 0, length: result.length)
        func paint(_ hex: UInt32, _ range: NSRange) {
            result.addAttribute(.foregroundColor, value: NSColor(cgColor: OverlayView.color(hex))!, range: range)
        }
        if stage { paint(palette[6], full) }
        if let match = timestamp.firstMatch(in: text, range: full) { paint(palette[8], match.range) }
        if let match = status.firstMatch(in: text, range: full) {
            let token = (text as NSString).substring(with: match.range(at: 1))
            let color: UInt32
            switch token {
            case "OK": color = palette[2]
            case "FAILED", "DEPEND": color = palette[1]
            default: color = palette[3]
            }
            paint(color, match.range(at: 1))
        }
        if text.hasPrefix("steamac-init: FATAL:") { paint(palette[1], full) }
        for (i, change) in changes.enumerated() {
            let end = i + 1 == changes.count ? full.length : changes[i + 1].offset
            if let color = change.color, end > change.offset {
                paint(color, NSRange(location: change.offset, length: end - change.offset))
            }
        }
        return result
    }
}
