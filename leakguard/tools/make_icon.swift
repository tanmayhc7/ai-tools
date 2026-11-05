// Renders the LeakGuard logo to a 1024×1024 PNG.
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
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2DD4BF), rgb(0x0F766E), rgb(0x042F2E)] as CFArray, locations: [0, 0.5, 1])!
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

// Glyph: shield with a check mark cut through it.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 800))
shield.addCurve(to: CGPoint(x: 730, y: 735), control1: CGPoint(x: 590, y: 775), control2: CGPoint(x: 660, y: 745))
shield.addLine(to: CGPoint(x: 730, y: 520))
shield.addCurve(to: CGPoint(x: 512, y: 225), control1: CGPoint(x: 730, y: 380), control2: CGPoint(x: 630, y: 285))
shield.addCurve(to: CGPoint(x: 294, y: 520), control1: CGPoint(x: 394, y: 285), control2: CGPoint(x: 294, y: 380))
shield.addLine(to: CGPoint(x: 294, y: 735))
shield.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 364, y: 745), control2: CGPoint(x: 434, y: 775))
shield.closeSubpath()
fillGlyph(shield)
ctx.saveGState()
ctx.setBlendMode(.clear)
ctx.setLineWidth(62); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 405, y: 525)); ctx.addLine(to: CGPoint(x: 485, y: 440)); ctx.addLine(to: CGPoint(x: 628, y: 610))
ctx.strokePath()
ctx.restoreGState()

ctx.endTransparencyLayer()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
