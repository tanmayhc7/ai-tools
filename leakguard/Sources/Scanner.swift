import Foundation
import CryptoKit

struct Finding: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case workingCopy
        case history(commit: String, date: String)

        var label: String {
            switch self {
            case .workingCopy: return "Current files"
            case .history(let c, let d): return "Commit \(c.prefix(8)) · \(d)"
            }
        }
        var isHistory: Bool { if case .history = self { return true }; return false }
    }

    let id = UUID()
    let ruleName: String
    let file: String
    let line: Int
    /// Only a masked preview is kept — the full secret is never stored or displayed.
    let masked: String
    /// Short SHA-256 of the secret, used to group the same key across files and commits.
    let fingerprint: String
    let source: Source
    var vaultEntryName: String?
}

struct VaultSecret: Sendable {
    let name: String
    let secret: String
}

struct ScanSummary: Sendable {
    var filesScanned = 0
    var commitsScanned = 0
    var skippedLarge = 0
    var skippedBinary = 0
    var skippedUnreadable = 0
    var skippedSymlinks = 0
    var historyError: String?
    var truncated = false
    var cancelled = false
}

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

enum Scanner {
    static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage", ".venv", "venv",
        "__pycache__", ".mypy_cache", ".pytest_cache", ".tox", "dist", ".next", ".nuxt", ".gradle",
        "target", ".idea", ".svn", ".hg", "bower_components", ".terraform", ".cache",
    ]
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxFindings = 5_000
    /// Vault entries shorter than this would match too much ordinary text.
    static let minVaultSecretLength = 12
    static let historyTimeout: TimeInterval = 600

    static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Text

    /// Finds rule matches and KeyVault keys in one piece of text.
    static func scanText(_ text: String, file: String, source: Finding.Source, firstLine: Int,
                         vault: [VaultSecret], into findings: inout [Finding]) {
        var seenRanges: [(Range<String.Index>, Int)] = []   // range → index in findings

        for m in SecretRules.scan(text) {
            findings.append(Finding(ruleName: m.ruleName, file: file,
                                    line: firstLine + lineOffset(of: m.range.lowerBound, in: text),
                                    masked: SecretRules.mask(m.value), fingerprint: fingerprint(m.value),
                                    source: source))
            seenRanges.append((m.range, findings.count - 1))
        }

        for entry in vault where entry.secret.count >= minVaultSecretLength {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let r = text.range(of: entry.secret, options: .literal, range: searchStart..<text.endIndex) {
                if let hit = seenRanges.first(where: { $0.0.overlaps(r) }) {
                    findings[hit.1].vaultEntryName = entry.name
                } else {
                    var f = Finding(ruleName: "Key from your KeyVault", file: file,
                                    line: firstLine + lineOffset(of: r.lowerBound, in: text),
                                    masked: SecretRules.mask(entry.secret),
                                    fingerprint: fingerprint(entry.secret), source: source)
                    f.vaultEntryName = entry.name
                    findings.append(f)
                }
                searchStart = r.upperBound
            }
        }
    }

    private static func lineOffset(of index: String.Index, in text: String) -> Int {
        text.utf8[..<index].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8_000).contains(0)
    }

    // MARK: Working copy

    static func scanWorkingCopy(root: URL, vault: [VaultSecret], cancel: ScanCancellation,
                                summary: inout ScanSummary, findings: inout [Finding],
                                progress: (Int, String) -> Void) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { return }
        while let rel = walker.nextObject() as? String {
            if cancel.isCancelled { summary.cancelled = true; return }
            if findings.count >= maxFindings { summary.truncated = true; return }
            let attrs = walker.fileAttributes ?? [:]
            let type = attrs[.type] as? FileAttributeType
            let name = (rel as NSString).lastPathComponent

            if type == .typeDirectory {
                if skipDirectories.contains(name) { walker.skipDescendants() }
                continue
            }
            if type == .typeSymbolicLink { summary.skippedSymlinks += 1; continue }   // never follow out of the folder
            guard type == .typeRegular else { continue }

            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > maxFileBytes { summary.skippedLarge += 1; continue }
            guard let data = SafeRead.regularFile(at: root.appendingPathComponent(rel).path, maxBytes: maxFileBytes) else {
                summary.skippedUnreadable += 1; continue
            }
            if isBinary(data) { summary.skippedBinary += 1; continue }

            summary.filesScanned += 1
            if summary.filesScanned % 25 == 0 { progress(summary.filesScanned, rel) }
            let text = String(decoding: data, as: UTF8.self)   // invalid UTF-8 becomes U+FFFD, never crashes
            scanText(text, file: rel, source: .workingCopy, firstLine: 1, vault: vault, into: &findings)
        }
    }

    // MARK: History

    /// Streams `git log -p` and scans only lines that commits *added*.
    static func scanHistory(repo: URL, vault: [VaultSecret], cancel: ScanCancellation,
                            summary: inout ScanSummary, findings: inout [Finding],
                            progress: (Int, String) -> Void) {
        var commit = "", date = ""
        var file: String?
        var newLine = 0
        var inHeader = false
        // Same secret in the same file across many commits → report it once, at the oldest commit.
        var firstSeen: [String: Int] = [:]
        var historyFindings: [Finding] = []
        var splitter = LineSplitter()

        func handle(_ line: String) {
            if line.hasPrefix("\u{1}") {
                let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
                commit = parts.first.map(String.init) ?? ""
                date = parts.count > 1 ? String(parts[1]) : ""
                file = nil
                summary.commitsScanned += 1
                if summary.commitsScanned % 50 == 0 { progress(summary.commitsScanned, "commit \(commit.prefix(8))") }
                return
            }
            if line.hasPrefix("diff --git ") { inHeader = true; file = nil; return }
            if inHeader {
                if line.hasPrefix("+++ ") {
                    file = parseDiffPath(String(line.dropFirst(4)))
                } else if line.hasPrefix("@@") {
                    inHeader = false
                    newLine = parseNewStart(line)
                }
                return
            }
            if line.hasPrefix("@@") { newLine = parseNewStart(line); return }
            guard let file, line.hasPrefix("+") else { return }
            let content = String(line.dropFirst())
            defer { newLine += 1 }
            guard SecretRules.mightContainSecret(content) || !vault.isEmpty else { return }

            var lineFindings: [Finding] = []
            scanText(content, file: file, source: .history(commit: commit, date: date), firstLine: newLine,
                     vault: vault, into: &lineFindings)
            for f in lineFindings {
                let key = f.fingerprint + "|" + f.file
                if let i = firstSeen[key] { historyFindings[i] = f }   // log is newest-first: keep the older one
                else {
                    firstSeen[key] = historyFindings.count
                    historyFindings.append(f)
                }
            }
        }

        do {
            try GitRunner.stream(
                ["log", "--all", "-p", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                 "--no-renames", "--format=%x01%H %ad", "--date=short"],
                in: repo, timeout: historyTimeout, isCancelled: { cancel.isCancelled }
            ) { chunk in
                splitter.feed(chunk, handle)
                return historyFindings.count + findings.count < maxFindings
            }
            splitter.finish(handle)
        } catch GitError.cancelled {
            summary.cancelled = true
        } catch {
            summary.historyError = error.localizedDescription
        }
        if historyFindings.count + findings.count >= maxFindings { summary.truncated = true }
        findings.append(contentsOf: historyFindings)
    }

    /// Parses the path from a "+++ " diff header. Git appends a tab to names containing
    /// spaces, and C-quotes names with special characters ("b/a\\tb" or octal UTF-8 bytes).
    static func parseDiffPath(_ raw: String) -> String? {
        var s = raw
        if s.hasSuffix("\t") { s.removeLast() }
        if s == "/dev/null" { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = unquoteC(String(s.dropFirst().dropLast()))
        }
        if s.hasPrefix("b/") { s.removeFirst(2) }
        return s
    }

    private static func unquoteC(_ s: String) -> String {
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let n = it.popFirst() else { bytes.append(c); continue }
            switch n {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(n - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let d = it.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(d) else { break }
                    value = value * 8 + Int(d - UInt8(ascii: "0")); it.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(n)   // \\ and \"
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "@@ -12,3 +40,7 @@" → 40
    static func parseNewStart(_ header: String) -> Int {
        guard let plus = header.range(of: " +") else { return 1 }
        let digits = header[plus.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 1
    }

    // MARK: Entry point

    static func scan(root: URL, includeHistory: Bool, vault: [VaultSecret], cancel: ScanCancellation,
                     progress: @escaping (String) -> Void) -> ([Finding], ScanSummary) {
        var summary = ScanSummary()
        var findings: [Finding] = []
        scanWorkingCopy(root: root, vault: vault, cancel: cancel, summary: &summary, findings: &findings) { n, path in
            progress("Scanned \(n) files · \(path)")
        }
        if includeHistory && !cancel.isCancelled && findings.count < maxFindings,
           let repo = GitRunner.repoRoot(of: root) {
            progress("Reading git history…")
            scanHistory(repo: repo, vault: vault, cancel: cancel, summary: &summary, findings: &findings) { n, what in
                progress("Scanned \(n) commits · \(what)")
            }
        }
        return (findings, summary)
    }
}
