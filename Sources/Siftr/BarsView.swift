import AppKit
import QuartzCore

/// The visualizer's bars, drawn natively with Core Animation over the
/// spot the page leaves for them (the page says where; see `viz` in
/// AppController). The page used to draw them on a canvas, and the web
/// engine redrawing that 30 times a second was most of the app's CPU while
/// sifting; moving 112 small rectangles is next to nothing for Core Animation.
/// Same look as before: low -> middle -> high colors from the bottom up, and
/// a faint reflection below.
@MainActor
final class BarsView: NSView {
    private let root = CALayer()
    private let content = CALayer()             // ours: AppKit manages the flip of the view's own layer
    private let fill = CAGradientLayer()        // the bars' colors, masked to their shapes
    private let fillMask = CALayer()
    private let mirror = CAGradientLayer()      // the reflection
    private let mirrorMask = CALayer()
    private var bars: [CALayer] = []
    private var mirrors: [CALayer] = []
    private(set) var levels = [Float](repeating: 0, count: 96)
    private(set) var updates = 0
    var reflection = true { didSet { if reflection != oldValue { relayout() } } }
    var heightScale: CGFloat = 0.85 { didSet { if heightScale != oldValue { relayout() } } }   // Settings -> Visualizer

    init() {
        super.init(frame: .zero)
        layer = root                             // layer-hosting: the layers are ours to arrange
        wantsLayer = true
        content.isGeometryFlipped = true         // y grows downward, like the page (checked on screen)
        root.addSublayer(content)
        fill.mask = fillMask
        mirror.mask = mirrorMask
        mirror.opacity = 0.13
        content.addSublayer(fill)
        content.addSublayer(mirror)
        makeBars(levels.count)
        setColors(["#5478ff", "#966eff", "#ff78be"])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the page underneath

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    var peak: Float { levels.max() ?? 0 }

    /// The look's low, middle and high colors, as the page has them (#rrggbb).
    func setColors(_ hex: [String]) {
        let c = hex.compactMap(Self.color)
        guard c.count == 3 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.colors = c.map { $0.copy(alpha: 0.92)! }
        fill.locations = [0, 0.5, 1]
        fill.startPoint = CGPoint(x: 0.5, y: 1)             // bottom (flipped geometry)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        mirror.colors = [c[0], c[1].copy(alpha: 0)!]
        mirror.startPoint = CGPoint(x: 0.5, y: 0)           // from the baseline down
        mirror.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
    }

    private func makeBars(_ n: Int) {
        for l in bars + mirrors { l.removeFromSuperlayer() }
        bars = (0..<n).map { _ in let l = CALayer(); l.backgroundColor = .white; fillMask.addSublayer(l); return l }
        mirrors = (0..<n).map { _ in let l = CALayer(); l.backgroundColor = .white; mirrorMask.addSublayer(l); return l }
    }

    /// New levels (0...1 each); only redrawn when something changed.
    func show(_ new: [Float]) {
        guard !new.isEmpty, new != levels else { return }
        if new.count != bars.count { makeBars(new.count) }
        levels = new
        updates += 1
        relayout()
    }

    private func relayout() {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let count = bars.count
        // gaps shrink in a narrow spot (the corner on Now Playing) so the bars keep some width
        let n = CGFloat(count), gap: CGFloat = min(n > 70 ? 2.5 : 3, max(1, W / n * 0.3))
        let bw = max((W - gap * (n - 1)) / n, 1)
        // most of the height for the bars, a shallow reflection under them
        let base = reflection ? (H + 0.8) / 1.28 : H - 2
        let maxH = max((base - 4) * heightScale, 2), minH: CGFloat = 2, radius = min(bw / 2, 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        fill.frame = CGRect(x: 0, y: 0, width: W, height: base)
        fillMask.frame = fill.bounds
        mirror.isHidden = !reflection
        mirror.frame = CGRect(x: 0, y: base, width: W, height: max(H - base, 0))
        mirrorMask.frame = mirror.bounds
        for b in 0..<count {
            let h = max(CGFloat(levels[b]) * maxH, minH)
            let x = CGFloat(b) * (bw + gap)
            bars[b].frame = CGRect(x: x, y: base - h, width: bw, height: h)
            bars[b].cornerRadius = radius
            if reflection {
                mirrors[b].frame = CGRect(x: x, y: 1, width: bw, height: h * 0.28)
                mirrors[b].cornerRadius = radius
            }
        }
        CATransaction.commit()
    }

    private static func color(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
