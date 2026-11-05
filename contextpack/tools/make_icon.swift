// Renders the ContextPack logo to a 1024×1024 PNG.
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
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFBBF24), rgb(0xD97706), rgb(0x451A03)] as CFArray, locations: [0, 0.5, 1])!
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

// Glyph: a stack of files, the front one showing code lines.
for (offset, alpha) in [(CGFloat(70), CGFloat(0.35)), (CGFloat(35), CGFloat(0.65))] {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    fillGlyph(CGPath(roundedRect: CGRect(x: 290 + offset, y: 230 + offset, width: 380, height: 500),
                     cornerWidth: 40, cornerHeight: 40, transform: nil), shadow: false)
    ctx.restoreGState()
}
fillGlyph(CGPath(roundedRect: CGRect(x: 290, y: 230, width: 380, height: 500), cornerWidth: 40, cornerHeight: 40, transform: nil))
func line(_ indent: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 340 + indent, y: y - 14, width: w, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(c); ctx.fillPath()
}
let accent = rgb(0xD97706), grey = rgb(0xCBD5E1)
line(0, 650, 170, accent)
line(40, 590, 220, grey)
line(40, 530, 130, grey)
line(80, 470, 190, accent)
line(40, 410, 150, grey)
line(0, 350, 100, accent)

ctx.endTransparencyLayer()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
