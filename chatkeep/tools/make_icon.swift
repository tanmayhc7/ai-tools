// Renders the ChatKeep logo to a 1024×1024 PNG.
// Usage: swift tools/make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "logo.png"
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt rounded tile centred in a 1024 canvas.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0.35))
ctx.addPath(tile); ctx.setFillColor(rgb(0x111111)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xE879F9), rgb(0x9333EA), rgb(0x3B0764)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 800), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 800), endRadius: 520, options: [])
ctx.addPath(tile); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()

/// Fills a glyph shape with a soft white gradient and drop shadow.
func fillGlyph(_ path: CGPath, shadow: Bool = true) {
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x05061A, 0.4)) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE7E5F4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 300, y: 820), end: CGPoint(x: 724, y: 200), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

ctx.beginTransparencyLayer(auxiliaryInfo: nil)

// Glyph: a speech bubble with a padlock cut out of it.
let bubble = CGMutablePath()
bubble.addRoundedRect(in: CGRect(x: 262, y: 360, width: 500, height: 380), cornerWidth: 120, cornerHeight: 120)
bubble.move(to: CGPoint(x: 350, y: 372)); bubble.addLine(to: CGPoint(x: 318, y: 250)); bubble.addLine(to: CGPoint(x: 462, y: 366)); bubble.closeSubpath()
fillGlyph(bubble)
ctx.saveGState()
ctx.setBlendMode(.clear)
ctx.addPath(CGPath(roundedRect: CGRect(x: 448, y: 470, width: 128, height: 104), cornerWidth: 24, cornerHeight: 24, transform: nil))
ctx.fillPath()
ctx.setLineWidth(28); ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 512, y: 574), radius: 40, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.strokePath()
ctx.restoreGState()
// keyhole dot, drawn back in the bubble colour
ctx.setFillColor(rgb(0x7E22CE)); ctx.fillEllipse(in: CGRect(x: 500, y: 506, width: 24, height: 24))
ctx.addPath(CGPath(roundedRect: CGRect(x: 507, y: 482, width: 10, height: 34), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
ctx.endTransparencyLayer()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
