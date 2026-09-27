// Draws the app icon (1024x1024 PNG): the visualizer's bars in its own
// colors on the app's dark background. build.sh turns it into AppIcon.icns.
// Usage: swift scripts/make_icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: an 824-point rounded square centred in 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x141621))
ctx.fillPath()
ctx.restoreGState()

// background: BG1 at the top to BG0 at the bottom
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1d2031), rgb(0x0d0e14)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
// a faint glow behind the bars
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x6c8cff, 0.22), rgb(0x6c8cff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

// the bars, a spectrum-like shape
let heights: [CGFloat] = [0.30, 0.52, 0.78, 0.95, 0.70, 0.86, 0.60, 0.42, 0.56, 0.34, 0.22]
let barW: CGFloat = 46, gap: CGFloat = 20
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let left = (CGFloat(size) - totalW) / 2
let baseline: CGFloat = 400, maxH: CGFloat = 400
let bars = CGGradient(colorsSpace: space,
                      colors: [rgb(0x5478ff), rgb(0x966eff), rgb(0xff78be)] as CFArray, locations: [0, 0.5, 1])!
for (i, h) in heights.enumerated() {
    let x = left + CGFloat(i) * (barW + gap)
    let bar = CGRect(x: x, y: baseline, width: barW, height: h * maxH)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(bars, start: CGPoint(x: 0, y: baseline), end: CGPoint(x: 0, y: baseline + maxH), options: [])
    ctx.restoreGState()
    // reflection
    let refl = CGRect(x: x, y: baseline - 12 - h * maxH * 0.35, width: barW, height: h * maxH * 0.35)
    ctx.saveGState()
    ctx.setAlpha(0.16)
    ctx.addPath(CGPath(roundedRect: refl, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(bars, start: CGPoint(x: 0, y: refl.maxY), end: CGPoint(x: 0, y: refl.minY), options: [])
    ctx.restoreGState()
}
ctx.restoreGState()

// a hairline edge
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0xffffff, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
