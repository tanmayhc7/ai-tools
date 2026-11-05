import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case text
        /// Package-manager lock files: usually noise for an AI, so off by default.
        case lockfile
        /// Credential files (.env, keys, …): never read, never packed.
        case sensitive
        case tooLarge
    }

    let path: String
    let size: Int
    let kind: Kind
    let tokens: Int
    let secretCount: Int

    var id: String { path }
    var selectable: Bool { kind == .text || kind == .lockfile }
    var selectedByDefault: Bool { kind == .text }
}

struct Project: Sendable {
    let root: URL
    let name: String
    let files: [FileItem]
    /// Text of every selectable file, read once at load time.
    let contents: [String: String]
    let usedGitIgnore: Bool
    let skippedBinary: Int
    let skippedSymlinks: Int
    let truncated: Bool
}

struct PackResult: Sendable {
    let text: String
    let tokens: Int
    let fileCount: Int
    let redactedSecrets: Int
}

final class LoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

enum Packer {
    static let maxFileBytes = 1_000_000
    static let maxFiles = 20_000
    static let maxTotalBytes = 150 * 1024 * 1024

    static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage", ".venv", "venv",
        "__pycache__", ".mypy_cache", ".pytest_cache", ".tox", "dist", ".next", ".nuxt", ".gradle",
        "target", ".idea", ".svn", ".hg", "bower_components", ".terraform", ".cache", ".swiftpm", "coverage",
    ]

    static let lockfiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "Cargo.lock", "Gemfile.lock",
        "poetry.lock", "composer.lock", "Podfile.lock", "Package.resolved", "go.sum", "uv.lock", "Pipfile.lock",
    ]

    // MARK: Sensitive files

    private static let sensitiveNames: Set<String> = [
        ".env", ".envrc", ".npmrc", ".pypirc", ".netrc", "_netrc", ".git-credentials", ".htpasswd", ".pgpass",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "secrets.yml", "secrets.yaml", "secrets.json",
        "secrets.toml", "terraform.tfstate", "terraform.tfstate.backup", ".dockercfg", "local.properties",
        "vault.json", "keystore.properties", "google-services.json", "googleservice-info.plist",
    ]
    private static let sensitiveExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "jks", "keystore", "kdbx", "ovpn", "mobileprovision", "p8", "gpg", "asc",
        "ppk", "tfvars",
    ]
    private static let safeEnvSuffixes = [".example", ".sample", ".template", ".dist", ".defaults"]
    private static let sensitiveDirs = [".ssh/", ".aws/", ".gnupg/", ".docker/", ".kube/"]

    /// Files that commonly hold credentials. They're listed (so you know they exist) but never read.
    static func isSensitive(_ path: String) -> Bool {
        let lowerPath = path.lowercased()
        let name = (lowerPath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension

        if name.hasPrefix(".env") || name.hasSuffix(".env") {
            return !safeEnvSuffixes.contains { name.hasSuffix($0) }
        }
        if sensitiveNames.contains(name) || sensitiveExtensions.contains(ext) { return true }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") { return true }
        if ext == "json" && (name.contains("credential") || name.contains("service-account")
                             || name.contains("serviceaccount") || name.contains("client_secret")) { return true }
        let wrapped = "/" + lowerPath
        return sensitiveDirs.contains { wrapped.contains("/" + $0) }
    }

    // MARK: Listing

    /// Uses git's own ignore logic when the folder is in a repo; otherwise walks the folder.
    static func listFiles(root: URL, cancel: LoadCancellation) -> (paths: [String], usedGit: Bool, symlinks: Int) {
        if GitRunner.repoRoot(of: root) != nil,
           let data = try? GitRunner.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                         in: root, timeout: 60) {
            let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.isEmpty && !$0.split(separator: "/").contains(".git") }
            return (Array(Set(paths)).sorted(), true, 0)
        }
        var out: [String] = []
        var symlinks = 0
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return ([], false, 0) }
        while let rel = walker.nextObject() as? String {
            if cancel.isCancelled || out.count > maxFiles * 2 { break }
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if skipDirectories.contains((rel as NSString).lastPathComponent) { walker.skipDescendants() }
            } else if type == .typeSymbolicLink {
                symlinks += 1
            } else if type == .typeRegular {
                out.append(rel)
            }
        }
        return (out.sorted(), false, symlinks)
    }

    // MARK: Loading

    static func load(root: URL, cancel: LoadCancellation, progress: (Int, Int) -> Void = { _, _ in }) -> Project {
        let fm = FileManager.default
        let (paths, usedGit, listedSymlinks) = listFiles(root: root, cancel: cancel)
        var files: [FileItem] = []
        var contents: [String: String] = [:]
        var skippedBinary = 0, symlinks = listedSymlinks, totalBytes = 0
        var truncated = paths.count > maxFiles

        for (i, rel) in paths.prefix(maxFiles).enumerated() {
            if cancel.isCancelled { truncated = true; break }
            if i % 100 == 0 { progress(i, min(paths.count, maxFiles)) }
            let url = root.appendingPathComponent(rel)
            // attributesOfItem does not follow symlinks, so links out of the project are caught here.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }   // deleted but still tracked
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { symlinks += 1; continue }
            guard type == .typeRegular else { continue }                                      // submodules, sockets…
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0

            if isSensitive(rel) {
                files.append(FileItem(path: rel, size: size, kind: .sensitive, tokens: 0, secretCount: 0))
                continue                                                                       // never read
            }
            if size > maxFileBytes {
                files.append(FileItem(path: rel, size: size, kind: .tooLarge, tokens: 0, secretCount: 0))
                continue
            }
            if totalBytes + size > maxTotalBytes { truncated = true; break }
            guard let data = SafeRead.regularFile(at: url.path, maxBytes: maxFileBytes) else { continue }
            if data.prefix(8_000).contains(0) { skippedBinary += 1; continue }
            totalBytes += data.count

            let text = String(decoding: data, as: UTF8.self)
            let name = (rel as NSString).lastPathComponent
            files.append(FileItem(path: rel, size: size, kind: lockfiles.contains(name) ? .lockfile : .text,
                                  tokens: estimateTokens(text), secretCount: SecretRules.scan(text).count))
            contents[rel] = text
        }
        return Project(root: root, name: root.lastPathComponent, files: files, contents: contents,
                       usedGitIgnore: usedGit, skippedBinary: skippedBinary, skippedSymlinks: symlinks,
                       truncated: truncated)
    }

    /// Rough token estimate (≈4 characters per token for code and English; CJK and other
    /// non-Latin scripts count about one token per character).
    static func estimateTokens(_ s: String) -> Int {
        var ascii = 0, other = 0
        for u in s.unicodeScalars { if u.isASCII { ascii += 1 } else { other += 1 } }
        return Int((Double(ascii) / 4.0).rounded(.up)) + other
    }

    // MARK: Packing

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case xml = "XML tags", markdown = "Markdown"
        var id: String { rawValue }
    }

    static func pack(_ project: Project, selected: Set<String>, format: Format) -> PackResult {
        let paths = project.files.filter { selected.contains($0.path) && $0.selectable }.map(\.path)
        var redacted = 0
        var bodies: [(String, String)] = []
        for p in paths {
            guard let raw = project.contents[p] else { continue }
            let (clean, found) = SecretRules.redact(raw) { "[REDACTED \($0.ruleName)]" }
            redacted += found.count
            bodies.append((p, clean))
        }
        let tree = renderTree(bodies.map(\.0))
        var out = ""
        switch format {
        case .xml:
            out += "<project name=\"\(xmlEscape(project.name))\">\n<file_tree>\n\(tree)</file_tree>\n\n"
            for (p, body) in bodies {
                // A file that itself contains "</file>" would otherwise end the block early.
                let safe = body.replacingOccurrences(of: "</file>", with: "<\\/file>")
                out += "<file path=\"\(xmlEscape(p))\">\n\(safe)\(safe.hasSuffix("\n") ? "" : "\n")</file>\n\n"
            }
            out += "</project>\n"
        case .markdown:
            out += "# Project: \(project.name)\n\n## File tree\n\n```text\n\(tree)```\n\n## Files\n\n"
            for (p, body) in bodies {
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(body) + 1))
                out += "### `\(p)`\n\n\(fence)\(language(for: p))\n\(body)\(body.hasSuffix("\n") ? "" : "\n")\(fence)\n\n"
            }
        }
        return PackResult(text: out, tokens: estimateTokens(out), fileCount: bodies.count, redactedSecrets: redacted)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    static func longestBacktickRun(_ s: String) -> Int {
        var best = 0, cur = 0
        for c in s { if c == "`" { cur += 1; best = max(best, cur) } else { cur = 0 } }
        return best
    }

    private static let languages: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "tsx", "jsx": "jsx", "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "c": "c", "h": "c", "m": "objectivec", "mm": "objectivec", "cpp": "cpp", "cc": "cpp",
        "hpp": "cpp", "cs": "csharp", "php": "php", "sh": "bash", "zsh": "bash", "bash": "bash", "sql": "sql",
        "html": "html", "css": "css", "scss": "scss", "json": "json", "yml": "yaml", "yaml": "yaml",
        "toml": "toml", "xml": "xml", "md": "markdown", "dart": "dart", "lua": "lua", "r": "r", "vue": "vue",
        "svelte": "svelte", "ex": "elixir", "exs": "elixir", "scala": "scala", "tf": "hcl", "dockerfile": "dockerfile",
    ]

    static func language(for path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" { return "makefile" }
        return languages[(name as NSString).pathExtension] ?? ""
    }

    /// Draws a folder tree like `tree`:  ├── src/  └── main.swift
    static func renderTree(_ paths: [String]) -> String {
        final class Node { var children: [String: Node] = [:]; var isFile = false }
        let root = Node()
        for p in paths {
            var node = root
            let parts = p.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                let next = node.children[part] ?? Node()
                if i == parts.count - 1 { next.isFile = true }
                node.children[part] = next
                node = next
            }
        }
        var out = ""
        func walk(_ node: Node, _ prefix: String) {
            let keys = node.children.keys.sorted { a, b in
                let da = !(node.children[a]!.children.isEmpty), db = !(node.children[b]!.children.isEmpty)
                return da != db ? da : a.localizedStandardCompare(b) == .orderedAscending
            }
            for (i, k) in keys.enumerated() {
                let child = node.children[k]!
                let last = i == keys.count - 1
                let isDir = !child.children.isEmpty
                out += prefix + (last ? "└── " : "├── ") + k + (isDir ? "/" : "") + "\n"
                if isDir { walk(child, prefix + (last ? "    " : "│   ")) }
            }
        }
        walk(root, "")
        return out
    }
}
