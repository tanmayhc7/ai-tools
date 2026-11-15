// Draws the README banner: assets/banner.png
// Usage (from the repo root): swift tools/make_banner.swift
import AppKit

let width = 1600, height = 460
let tools = ["keyvault", "leakguard", "redact", "chatkeep", "contextpack"]
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/banner.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let W = CGFloat(width), H = CGFloat(height)

// Background: deep navy to indigo, with two soft colour glows
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0B1020), rgb(0x1B1646), rgb(0x2A1456)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
for (center, radius, color) in [(CGPoint(x: 260, y: 360), CGFloat(520), rgb(0x2DD4BF, 0.20)),
                                (CGPoint(x: 1380, y: 120), CGFloat(560), rgb(0xE879F9, 0.22)),
                                (CGPoint(x: 800, y: 40), CGFloat(420), rgb(0x6D5CFF, 0.16))] {
    let glow = CGGradient(colorsSpace: cs, colors: [color, rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
// A faint dot grid for texture
ctx.setFillColor(rgb(0xFFFFFF, 0.05))
for x in stride(from: 24, to: width, by: 32) { for y in stride(from: 24, to: height, by: 32) { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)) } }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, spacing: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: spacing]
    let str = NSAttributedString(string: s, attributes: attrs)
    str.draw(at: NSPoint(x: (W - str.size().width) / 2, y: y))
}
text("ai-tools", size: 112, weight: .heavy, color: .white, y: 318, spacing: -2)
text("Local-first tools for people who build with AI", size: 34, weight: .medium, color: NSColor(white: 1, alpha: 0.78), y: 268)
text("KeyVault   ·   LeakGuard   ·   Redact   ·   ChatKeep   ·   ContextPack", size: 22, weight: .semibold,
     color: NSColor(srgbRed: 0.72, green: 0.8, blue: 1, alpha: 0.7), y: 226, spacing: 1)

// The five app icons in a row (the PNGs carry ~10% transparent padding, so draw them a little larger)
let iconSize: CGFloat = 188, gap: CGFloat = 44
let total = CGFloat(tools.count) * iconSize + CGFloat(tools.count - 1) * gap
var x = (W - total) / 2
for t in tools {
    if let img = NSImage(contentsOfFile: "assets/icons/\(t).png") {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.45))
        img.draw(in: NSRect(x: x, y: 10, width: iconSize, height: iconSize))
        ctx.restoreGState()
    } else { print("missing icon: \(t)") }
    x += iconSize + gap
}
NSGraphicsContext.restoreGraphicsState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
