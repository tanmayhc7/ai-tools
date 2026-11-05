// Renders the KeyVault logo to a 1024×1024 PNG.
// Usage: swift tools/make_icon.swift <output.png>
import AppKit

let size = 1024
let S = CGFloat(size)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt tile centred in a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1A1F4A))
ctx.fillPath()
ctx.restoreGState()

// Tile background: deep indigo gradient + soft highlight.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x6D5CFF), rgb(0x3B2FB8), rgb(0x12163A)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 800), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 800), endRadius: 520, options: [])
// Faint inner rim.
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// Key, tilted 45°: ring bow upper-left, bit lower-right.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x05061A, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

ctx.saveGState()
ctx.translateBy(x: S / 2, y: S / 2)
ctx.rotate(by: -.pi / 4)
ctx.translateBy(x: 20, y: 0)
let keyShape = CGMutablePath()
keyShape.addEllipse(in: CGRect(x: -330, y: -150, width: 300, height: 300))                      // bow
keyShape.addRoundedRect(in: CGRect(x: -60, y: -38, width: 370, height: 76), cornerWidth: 26, cornerHeight: 26)   // shaft
keyShape.addRoundedRect(in: CGRect(x: 190, y: -128, width: 52, height: 120), cornerWidth: 14, cornerHeight: 14)  // teeth
keyShape.addRoundedRect(in: CGRect(x: 262, y: -104, width: 48, height: 96), cornerWidth: 14, cornerHeight: 14)
ctx.addPath(keyShape)
ctx.clip()
let keyFill = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xDCD8FF)] as CFArray,
                         locations: [0, 1])!
ctx.drawLinearGradient(keyFill, start: CGPoint(x: -330, y: 150), end: CGPoint(x: 310, y: -150), options: [])
ctx.restoreGState()

// Upright keyhole punched through the bow (bow centre is at 399, 625 in canvas space).
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: CGRect(x: 399 - 46, y: 650 - 46, width: 92, height: 92))
let slot = CGMutablePath()
slot.move(to: CGPoint(x: 399 - 22, y: 640))
slot.addLine(to: CGPoint(x: 399 + 22, y: 640))
slot.addLine(to: CGPoint(x: 399 + 38, y: 545))
slot.addLine(to: CGPoint(x: 399 - 38, y: 545))
slot.closeSubpath()
ctx.addPath(slot)
ctx.fillPath()
ctx.setBlendMode(.normal)

ctx.endTransparencyLayer()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
