import AppKit

/// "Siftr" at the leading edge of the toolbar: a small mark of four bars in
/// the look's colors (low to high, bottom to top, like the visualizer), then
/// the name in solid gray with a very light shadow. Both are vector shapes,
/// centered on their own ink (not a line of text) so they sit level with the
/// window buttons. Redrawn only when the look changes, never per frame.
@MainActor
final class Wordmark: NSView {
    static let name = "Siftr"
    private static let size: CGFloat = 23
    private static let lead: CGFloat = 8          // room after the window's buttons
    private static let markGap: CGFloat = 7       // between the mark and the name
    private let mark = CAGradientLayer()          // the look's colors, cut to the bars
    private let bars = CAShapeLayer()
    private let letters = CAShapeLayer()
    private var hex: [String] = []

    init(colors: [String]) {
        let text = Self.letterPath()
        let box = text.boundingBoxOfPath
        let markSize = CGSize(width: 18, height: (box.height * 0.92).rounded())
        let height = ceil(box.height + 8)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(Self.lead + markSize.width + Self.markGap + box.width + 4), height: height))
        wantsLayer = true

        mark.frame = CGRect(x: Self.lead, y: ((height - markSize.height) / 2).rounded(), width: markSize.width, height: markSize.height)
        mark.startPoint = CGPoint(x: 0.5, y: 0)       // bottom (a layer's y runs up here)
        mark.endPoint = CGPoint(x: 0.5, y: 1)
        bars.path = Self.barsPath(in: mark.bounds.size)
        bars.fillColor = .black                       // only its shape counts: it's the mask
        mark.mask = bars

        var shift = CGAffineTransform(translationX: mark.frame.maxX + Self.markGap - box.minX,
                                      y: (height - box.height) / 2 - box.minY)
        letters.path = text.copy(using: &shift)
        letters.frame = bounds
        letters.shadowColor = .black
        letters.shadowOffset = CGSize(width: 0, height: -1)     // just below
        letters.shadowRadius = 1.5
        layer?.addSublayer(mark)
        layer?.addSublayer(letters)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.name)
        setColors(colors)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { bounds.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // the title bar still drags the window

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [mark, bars, letters] { l.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setColors(hex)
    }

    /// The look's low, middle and high colors, as the page has them (#rrggbb),
    /// and the name's gray for this appearance.
    func setColors(_ colors: [String]) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        letters.fillColor = CGColor(gray: dark ? 0.74 : 0.36, alpha: 1)
        letters.shadowOpacity = dark ? 0.5 : 0.18
        let c = colors.compactMap(Self.color)
        if c.count == 3 {
            hex = colors
            mark.colors = c.map { Self.readable($0, dark: dark) }
        }
        CATransaction.commit()
    }

    /// Four rounded bars of different heights: a still of the visualizer.
    private static func barsPath(in size: CGSize) -> CGPath {
        let heights: [CGFloat] = [0.5, 1, 0.72, 0.36]
        let w: CGFloat = 3, gap = (size.width - w * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        let path = CGMutablePath()
        for (i, h) in heights.enumerated() {
            let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: max(w, size.height * h))
            path.addRoundedRect(in: rect, cornerWidth: w / 2, cornerHeight: w / 2)
        }
        return path
    }

    /// The name's outline in the system face, heavy, set a touch tight.
    private static func letterPath() -> CGPath {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: font, .kern: -0.3]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var places = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &places)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font as CTFont
            for i in 0..<n {
                if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: places[i].x, y: places[i].y))
                }
            }
        }
        return path
    }

    private static func color(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// A look's color, lightened (dark mode) or darkened (light mode) just
    /// enough to show against the toolbar -- Hilltop ends in black. The hue
    /// stays; 3:1 is the bar for graphics.
    static func readable(_ color: CGColor, dark: Bool) -> CGColor {
        guard let rgb = color.components, rgb.count >= 3 else { return color }
        let background = dark ? luminance(0x12 / 255, 0x13 / 255, 0x1c / 255) : luminance(0xF4 / 255, 0xF5 / 255, 0xF9 / 255)
        let toward: CGFloat = dark ? 1 : 0
        for step in 0...10 {
            let t = CGFloat(step) / 10
            let mixed = (0..<3).map { rgb[$0] + (toward - rgb[$0]) * t }
            let l = luminance(mixed[0], mixed[1], mixed[2])
            if (max(l, background) + 0.05) / (min(l, background) + 0.05) >= 3 {
                return CGColor(srgbRed: mixed[0], green: mixed[1], blue: mixed[2], alpha: 1)
            }
        }
        return CGColor(gray: toward, alpha: 1)
    }

    private static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
