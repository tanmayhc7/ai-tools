// Draws the animated walkthroughs used in each tool's DEVELOPER.md.
// Usage (from the repo root): swift tools/make_animations.swift
// Set ANIM_FRAMES=<folder> to also save each step's final frame as a PNG (for checking).
import AppKit
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 880, H: CGFloat = 480

struct Node {
    let id: String
    let title: String
    var sub: String
    let x: CGFloat, y: CGFloat
    var w: CGFloat = 170
    var h: CGFloat = 74
    let color: UInt32
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
}

/// One step: something travels `from` → `to` (or the node pulses when they are the same).
struct Step {
    let from: String
    let to: String
    let token: String
    let caption: String
    /// Node subtitles to change once this step has happened.
    var set: [String: String] = [:]
}

struct Scene {
    let file: String
    let title: String
    var nodes: [Node]
    let steps: [Step]
}

// MARK: Drawing helpers (top-left origin)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func text(_ s: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
          align: NSTextAlignment = .left, mono: Bool = false) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byWordWrapping
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]).draw(in: rect)
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight, mono: Bool = false) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: font]).size().width
}

/// Where the line from this rect's centre toward `p` leaves the rect.
func edgePoint(_ r: CGRect, toward p: CGPoint, pad: CGFloat = 6) -> CGPoint {
    let c = CGPoint(x: r.midX, y: r.midY)
    let dx = p.x - c.x, dy = p.y - c.y
    guard dx != 0 || dy != 0 else { return c }
    let sx = dx == 0 ? CGFloat.infinity : (r.width / 2 + pad) / abs(dx)
    let sy = dy == 0 ? CGFloat.infinity : (r.height / 2 + pad) / abs(dy)
    let s = min(sx, sy)
    return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
}

func ease(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

// MARK: One frame

/// `progress` is 0…1 while the dot travels (or the node pulses); 1 is the resting frame.
func frame(_ scene: Scene, subs: [String: String], stepIndex: Int, progress: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)                  // top-left origin
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Background
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0B1020).cgColor, rgb(0x1A1740).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: W, y: H), options: [])

    let step = scene.steps[stepIndex]
    let byID = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
    let from = byID[step.from]!, to = byID[step.to]!
    let pulse = step.from == step.to

    // Header
    text(scene.title, in: CGRect(x: 28, y: 18, width: 600, height: 30), size: 20, weight: .bold)
    let counter = "Step \(stepIndex + 1) of \(scene.steps.count)"
    text(counter, in: CGRect(x: W - 228, y: 22, width: 200, height: 24), size: 14, weight: .semibold, color: rgb(0xFFFFFF, 0.6), align: .right)
    for i in 0..<scene.steps.count {
        let dot = CGRect(x: W - 28 - CGFloat(scene.steps.count - i) * 16, y: 48, width: 9, height: 9)
        ctx.setFillColor((i <= stepIndex ? rgb(0xFFFFFF, 0.9) : rgb(0xFFFFFF, 0.22)).cgColor)
        ctx.fillEllipse(in: dot)
    }

    // Edges (every pair that any step uses), then the active one on top
    var seen = Set<String>()
    for s in scene.steps where s.from != s.to {
        let key = [s.from, s.to].sorted().joined(separator: "|")
        guard seen.insert(key).inserted, let a = byID[s.from], let b = byID[s.to] else { continue }
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.16).cgColor); ctx.setLineWidth(2)
        ctx.move(to: edgePoint(a.rect, toward: b.center)); ctx.addLine(to: edgePoint(b.rect, toward: a.center)); ctx.strokePath()
    }
    var dot: CGPoint?
    if !pulse {
        let p0 = edgePoint(from.rect, toward: to.center), p1 = edgePoint(to.rect, toward: from.center)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.75).cgColor); ctx.setLineWidth(2.5)
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        // arrowhead at the destination
        let angle = atan2(p1.y - p0.y, p1.x - p0.x), size: CGFloat = 11
        ctx.setFillColor(rgb(0xFFFFFF, 0.9).cgColor)
        ctx.move(to: p1)
        ctx.addLine(to: CGPoint(x: p1.x - size * cos(angle - 0.45), y: p1.y - size * sin(angle - 0.45)))
        ctx.addLine(to: CGPoint(x: p1.x - size * cos(angle + 0.45), y: p1.y - size * sin(angle + 0.45)))
        ctx.closePath(); ctx.fillPath()
        let t = ease(min(max(progress, 0), 1))
        dot = CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t)
    }

    // Nodes
    for node in scene.nodes {
        let active = node.id == step.from || node.id == step.to
        let path = CGPath(roundedRect: node.rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(path); ctx.setFillColor(rgb(node.color, active ? 1 : 0.38).cgColor); ctx.fillPath()
        if active {
            let strength: CGFloat = pulse ? 0.45 + 0.55 * abs(sin(progress * .pi * 2)) : 0.9
            ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFFFFF, strength).cgColor); ctx.setLineWidth(pulse ? 4 : 2.5); ctx.strokePath()
        }
        let alpha: CGFloat = active ? 1 : 0.55
        text(node.title, in: CGRect(x: node.x + 6, y: node.y + 12, width: node.w - 12, height: 22), size: 15, weight: .bold,
             color: rgb(0xFFFFFF, alpha), align: .center)
        text(subs[node.id] ?? node.sub, in: CGRect(x: node.x + 6, y: node.y + 35, width: node.w - 12, height: 34), size: 11.5,
             color: rgb(0xFFFFFF, alpha * 0.85), align: .center)
    }

    // The travelling dot
    if let dot {
        ctx.setFillColor(rgb(0xFDE047, 0.25).cgColor); ctx.fillEllipse(in: CGRect(x: dot.x - 15, y: dot.y - 15, width: 30, height: 30))
        ctx.setFillColor(rgb(0xFDE047).cgColor); ctx.fillEllipse(in: CGRect(x: dot.x - 8, y: dot.y - 8, width: 16, height: 16))
    }

    // Caption panel
    let panel = CGRect(x: 24, y: 356, width: W - 48, height: 104)
    ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(rgb(0x000000, 0.35).cgColor); ctx.fillPath()
    let chipLabel = pulse ? step.token : "● " + step.token
    let chipW = min(textWidth(chipLabel, size: 13, weight: .semibold, mono: true) + 24, panel.width - 32)
    let chip = CGRect(x: panel.minX + 16, y: panel.minY + 13, width: chipW, height: 26)
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(rgb(0xFDE047).cgColor); ctx.fillPath()
    text(chipLabel, in: CGRect(x: chip.minX + 12, y: chip.minY + 4.5, width: chip.width - 20, height: 18), size: 13, weight: .semibold,
         color: rgb(0x1F2937), mono: true)
    text(step.caption, in: CGRect(x: panel.minX + 16, y: panel.minY + 47, width: panel.width - 32, height: 52), size: 15.5,
         color: rgb(0xFFFFFF, 0.95))

    return ctx.makeImage()!
}

// MARK: Rendering a scene to a GIF

func render(_ scene: Scene) {
    var frames: [(CGImage, Double)] = []
    var subs: [String: String] = [:]
    let moving = 14
    let dumpDir = ProcessInfo.processInfo.environment["ANIM_FRAMES"]
    for (i, step) in scene.steps.enumerated() {
        for f in 0..<moving { frames.append((frame(scene, subs: subs, stepIndex: i, progress: CGFloat(f) / CGFloat(moving)), 0.07)) }
        for (k, v) in step.set { subs[k] = v }
        let rest = frame(scene, subs: subs, stepIndex: i, progress: 1)
        // Reading time grows with the caption length.
        frames.append((rest, min(4.2, 1.6 + Double(step.caption.count) / 55)))
        if let dumpDir {
            try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
            let name = "\(scene.file.replacingOccurrences(of: "/", with: "_"))-\(i + 1).png"
            try? NSBitmapImageRep(cgImage: rest).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dumpDir).appendingPathComponent(name))
        }
    }
    let url = URL(fileURLWithPath: scene.file)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { print("can't write \(scene.file)"); return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (image, delay) in frames {
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    let size = (try? FileManager.default.attributesOfItem(atPath: scene.file)[.size] as? Int).flatMap { $0 } ?? 0
    print("wrote \(scene.file)  (\(frames.count) frames, \(size / 1024) KB, \(String(format: "%.0f", frames.reduce(0) { $0 + $1.1 })) s loop)")
}

// MARK: The scenes

let slate: UInt32 = 0x334155, indigo: UInt32 = 0x4338CA, teal: UInt32 = 0x0F766E, rose: UInt32 = 0xBE123C
let violet: UInt32 = 0x7E22CE, amber: UInt32 = 0xB45309, brown: UInt32 = 0x92400E

let scenes: [Scene] = [
    Scene(file: "keyvault/docs/unlock.gif", title: "KeyVault · Unlocking the vault", nodes: [
        Node(id: "you", title: "You", sub: "type the master password", x: 30, y: 90, color: slate),
        Node(id: "kdf", title: "PBKDF2", sub: "stretches the password", x: 245, y: 90, color: indigo),
        Node(id: "aes", title: "AES-256-GCM", sub: "decrypts and verifies", x: 460, y: 90, color: indigo),
        Node(id: "mem", title: "Memory", sub: "empty while locked", x: 675, y: 90, color: teal),
        Node(id: "disk", title: "vault.json", sub: "salt · settings · ciphertext", x: 350, y: 240, w: 180, color: brown),
    ], steps: [
        Step(from: "you", to: "kdf", token: "password", caption: "You type your master password. It is never written to disk, and no hash of it is stored."),
        Step(from: "disk", to: "kdf", token: "salt + iteration count", caption: "The random salt and the iteration count are read from the top of vault.json. They are not secret."),
        Step(from: "kdf", to: "kdf", token: "about half a second of work", caption: "PBKDF2-HMAC-SHA256 repeats its hash hundreds of thousands to millions of times, so every guess is slow for an attacker."),
        Step(from: "kdf", to: "aes", token: "256-bit key", caption: "Out comes a 256-bit key. The same password and salt always give the same key."),
        Step(from: "disk", to: "aes", token: "ciphertext + header", caption: "The encrypted payload is read. The header (format, salt, iterations) is checked along with it, so editing the file breaks decryption."),
        Step(from: "aes", to: "mem", token: "your entries", caption: "Right password and untouched file: the entries decrypt into memory. A wrong password simply fails this check.",
             set: ["mem": "your keys, while unlocked"]),
        Step(from: "mem", to: "mem", token: "lock", caption: "Locking (or sleep, or idle time) drops the key and the entries. Decrypted data never touches the disk.",
             set: ["mem": "empty again"]),
    ]),

    Scene(file: "keyvault/docs/agent-handoff.gif", title: "KeyVault · Handing one key to a script", nodes: [
        Node(id: "script", title: "Your script", sub: "keyvault_client.py", x: 30, y: 150, color: slate),
        Node(id: "sock", title: "agent.sock", sub: "private Unix socket", x: 240, y: 150, color: brown),
        Node(id: "ctrl", title: "AccessController", sub: "rules · grants · log", x: 450, y: 150, color: indigo),
        Node(id: "you", title: "Approval window", sub: "you decide", x: 680, y: 60, color: teal),
        Node(id: "vault", title: "Unlocked vault", sub: "keys in memory", x: 680, y: 240, color: indigo),
    ], steps: [
        Step(from: "script", to: "sock", token: "get \"OpenAI – prod\"", caption: "A script asks for one key, by name, over a socket file that only your user account can open. There is no \"list\" or \"give me everything\"."),
        Step(from: "sock", to: "ctrl", token: "request + who sent it", caption: "AgentServer checks the caller is you, then looks up the program: its path, script, folder and code signature."),
        Step(from: "ctrl", to: "ctrl", token: "checking the rules", caption: "AccessController checks rate limits and blocks, and whether this exact process already has a time-limited grant."),
        Step(from: "ctrl", to: "you", token: "who is asking, for which key", caption: "No grant, so a window appears in front of everything. Deny is the default button, and Allow is disabled for the first second."),
        Step(from: "you", to: "ctrl", token: "Allow once", caption: "You choose. Closing the window is a refusal, and so is ignoring it for 60 seconds."),
        Step(from: "vault", to: "ctrl", token: "the secret", caption: "Only now is the secret read, and only if the script is still connected and the vault has not been locked meanwhile."),
        Step(from: "ctrl", to: "sock", token: "{\"ok\":true,\"secret\":…}", caption: "One line of JSON goes back. A refusal, an unknown name and an ambiguous name all return the same \"denied\"."),
        Step(from: "sock", to: "script", token: "the key", caption: "The script has its key. KeyVault logs who asked for what and the outcome, never the key itself."),
    ]),

    Scene(file: "leakguard/docs/scan.gif", title: "LeakGuard · Scanning a project", nodes: [
        Node(id: "folder", title: "Project folder", sub: "the files you have now", x: 30, y: 90, color: slate),
        Node(id: "git", title: "Git history", sub: "every past commit", x: 30, y: 240, color: brown),
        Node(id: "scan", title: "Scanner", sub: "reads carefully", x: 345, y: 165, color: teal),
        Node(id: "rules", title: "SecretRules", sub: "20 key patterns", x: 670, y: 90, color: teal),
        Node(id: "out", title: "Findings", sub: "masked previews only", x: 670, y: 240, color: rose),
    ], steps: [
        Step(from: "folder", to: "scan", token: "text files", caption: "The scanner walks the folder. It skips dependency folders, binaries and files over 5 MB, and never follows symlinks out of the folder."),
        Step(from: "scan", to: "rules", token: "each file's text", caption: "Each file goes to SecretRules: a fast check for trigger words first, then 20 patterns for known key formats."),
        Step(from: "rules", to: "scan", token: "matches", caption: "Matches come back. A generic \"key = …\" match only counts if the value also looks random, so placeholders are ignored."),
        Step(from: "git", to: "scan", token: "git log -p (streamed)", caption: "Then history. Git runs with every program-launching feature switched off, and its output is read line by line, never all at once."),
        Step(from: "scan", to: "rules", token: "lines that commits added", caption: "Only added lines are checked. That is how a key you deleted months ago is still found, with the commit it came from."),
        Step(from: "scan", to: "out", token: "sk-p••••••••Ab3x", caption: "A finding keeps the file, the line, a masked preview and a short hash. The secret itself is never stored or shown."),
    ]),

    Scene(file: "redact/docs/roundtrip.gif", title: "Redact · There and back again", nodes: [
        Node(id: "you", title: "Your text", sub: "names, emails, keys", x: 30, y: 90, color: slate),
        Node(id: "eng", title: "RedactionEngine", sub: "detect and replace", x: 355, y: 90, color: rose),
        Node(id: "ai", title: "The AI", sub: "sees placeholders only", x: 680, y: 90, color: slate),
        Node(id: "map", title: "RedactionMap", sub: "empty", x: 355, y: 240, color: brown),
        Node(id: "out", title: "Restored reply", sub: "with your real details", x: 30, y: 240, color: teal),
    ], steps: [
        Step(from: "you", to: "eng", token: "Email Priya at priya@acme.com", caption: "You paste text. Detection runs on your Mac: patterns, checksums and Apple's on-device language model for names."),
        Step(from: "eng", to: "map", token: "priya@acme.com → [EMAIL_1]", caption: "Each value gets a placeholder. The same value always gets the same one. The mapping lives in memory only.",
             set: ["map": "[NAME_1] = Priya\n[EMAIL_1] = priya@acme.com"]),
        Step(from: "eng", to: "ai", token: "Email [NAME_1] at [EMAIL_1]", caption: "You copy the redacted text into any AI. That is the only thing that leaves your Mac, and you are the one who pastes it."),
        Step(from: "ai", to: "eng", token: "Sure! Hi [name_1], …", caption: "You paste the answer back. Restore recognises placeholders even if the AI changed their case, spacing or escaped them."),
        Step(from: "map", to: "eng", token: "[NAME_1] → Priya", caption: "One left-to-right pass swaps the real values back in. Placeholders it never created are left alone and listed."),
        Step(from: "eng", to: "out", token: "Sure! Hi Priya, …", caption: "You get the answer with your real details. Quit or press Clear All and the mapping is gone for good.",
             set: ["map": "kept until you quit\nor Clear All"]),
    ]),

    Scene(file: "chatkeep/docs/import.gif", title: "ChatKeep · Importing an export", nodes: [
        Node(id: "zip", title: "Export zip", sub: "from ChatGPT or Claude", x: 14, y: 90, w: 140, color: slate),
        Node(id: "zr", title: "ZipReader", sub: "streams, never extracts", x: 192, y: 90, w: 140, color: violet),
        Node(id: "js", title: "JSON splitter", sub: "one chat at a time", x: 370, y: 90, w: 140, color: violet),
        Node(id: "imp", title: "Importers", sub: "two formats, one shape", x: 548, y: 90, w: 140, color: violet),
        Node(id: "store", title: "ArchiveStore", sub: "merge and encrypt", x: 726, y: 90, w: 140, color: violet),
        Node(id: "index", title: "SearchIndex", sub: "not built yet", x: 470, y: 240, w: 170, color: teal),
        Node(id: "disk", title: "archive.chatkeep", sub: "encrypted on disk", x: 721, y: 240, w: 150, color: brown),
    ], steps: [
        Step(from: "zip", to: "zr", token: "conversations.json", caption: "ZipReader finds the conversation files inside the zip and ignores the rest (images, HTML). Nothing is ever extracted to disk."),
        Step(from: "zr", to: "js", token: "1 MB pieces", caption: "The file is decompressed a megabyte at a time, with a size limit and a checksum, so a \"zip bomb\" cannot fill your memory."),
        Step(from: "js", to: "imp", token: "one conversation", caption: "JSONStreamSplitter cuts the stream into single conversations by counting brackets. The whole file is never held in memory."),
        Step(from: "imp", to: "store", token: "Conversation", caption: "The importers turn ChatGPT's branching tree or Claude's list into one simple shape: title, dates, messages."),
        Step(from: "store", to: "store", token: "merging", caption: "New chats are added, chats with more messages replace older copies, and chats you removed stay removed."),
        Step(from: "store", to: "disk", token: "encrypted chunks", caption: "Everything is compressed, encrypted with AES-256-GCM in chunks, read back to verify, then saved in one atomic step."),
        Step(from: "store", to: "index", token: "message text", caption: "A full-text index is built in memory so search is instant. It is never written to disk, and locking throws it away.",
             set: ["index": "in memory only"]),
    ]),

    Scene(file: "contextpack/docs/pack.gif", title: "ContextPack · From folder to prompt", nodes: [
        Node(id: "folder", title: "Project folder", sub: "your code", x: 30, y: 90, color: slate),
        Node(id: "git", title: "git ls-files", sub: "knows your .gitignore", x: 30, y: 240, color: brown),
        Node(id: "load", title: "Packer", sub: "filters and reads", x: 345, y: 165, color: amber),
        Node(id: "rules", title: "SecretRules", sub: "finds keys", x: 670, y: 90, color: teal),
        Node(id: "out", title: "Packed prompt", sub: "ready to paste", x: 670, y: 240, color: amber),
    ], steps: [
        Step(from: "folder", to: "git", token: "which files count?", caption: "ContextPack asks git for the file list, so your .gitignore rules are followed exactly. Outside a repo it uses a built-in ignore list."),
        Step(from: "git", to: "load", token: "file list", caption: "The list arrives null-separated, so file names with spaces, quotes or even line breaks cannot confuse it."),
        Step(from: "load", to: "load", token: "filtering", caption: "Credential files (.env, *.pem, SSH keys…) are listed with a lock but never opened. Binaries, symlinks and files over 1 MB are skipped."),
        Step(from: "folder", to: "load", token: "file contents", caption: "The remaining text files are read once. Each is opened in a way that refuses anything except a plain file."),
        Step(from: "load", to: "rules", token: "each file's text", caption: "Every file is checked for secrets and its tokens are estimated. That is what the shield icon and the counts in the list show."),
        Step(from: "load", to: "out", token: "[REDACTED OpenAI API key]", caption: "When you copy, secrets are replaced and each file is wrapped in XML tags or Markdown fences its own content cannot break."),
    ]),
]

for scene in scenes { render(scene) }
