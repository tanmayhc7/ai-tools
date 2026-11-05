// Renders the Redact logo to a 1024×1024 PNG.
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
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFB7185), rgb(0xBE123C), rgb(0x4C0519)] as CFArray, locations: [0, 0.5, 1])!
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

// Glyph: a page of text with black redaction bars.
let page = CGPath(roundedRect: CGRect(x: 312, y: 215, width: 400, height: 590), cornerWidth: 44, cornerHeight: 44, transform: nil)
fillGlyph(page)
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y - h / 2, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(c); ctx.fillPath()
}
let grey = rgb(0xCBD5E1), ink = rgb(0x1F1A24)
bar(372, 700, 200, 26, grey)
bar(372, 625, 110, 26, grey); bar(500, 625, 152, 46, ink)
bar(372, 545, 280, 46, ink)
bar(372, 465, 240, 26, grey)
bar(372, 390, 90, 26, grey); bar(480, 390, 172, 46, ink)
bar(372, 310, 150, 26, grey)

ctx.endTransparencyLayer()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
