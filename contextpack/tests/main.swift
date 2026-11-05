import Foundation

func fake(_ prefix: String, _ body: String, _ n: Int) -> String { prefix + String(repeating: body, count: n) }
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

// MARK: Sensitive file rules

for p in [".env", ".env.local", "config/.env.production", "prod.env", "certs/server.pem", "id_rsa", "id_ed25519.pub",
          "keys/app.p12", "gcp-service-account.json", "aws/credentials", "home/.ssh/config", "terraform.tfstate",
          "secrets.yaml", "android/key.keystore", "client_secret_123.json", "prod.tfvars"] {
    check(Packer.isSensitive(p), "sensitive: \(p)")
}
for p in [".env.example", ".env.sample", "src/env.ts", "README.md", "keyboard.swift", "Sources/Keychain.swift",
          "monkey.py", "docs/credentials-guide.md"] {
    check(!Packer.isSensitive(p), "allowed: \(p)")
}

// MARK: Packing format

check(Packer.longestBacktickRun("a ```` b ``") == 4, "counts backtick runs")
check(Packer.language(for: "src/App.tsx") == "tsx" && Packer.language(for: "Dockerfile") == "dockerfile", "language tags")
check(Packer.estimateTokens(String(repeating: "abcd", count: 100)) == 100, "token estimate for ASCII")
check(Packer.estimateTokens("日本語") == 3, "token estimate for CJK")
let tree = Packer.renderTree(["src/a.swift", "src/lib/b.swift", "README.md"])
check(tree == "├── src/\n│   ├── lib/\n│   │   └── b.swift\n│   └── a.swift\n└── README.md\n", "renders file tree")

// MARK: Folder on disk (no git)

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("contextpack-tests-\(UUID().uuidString)")
defer { try? fm.removeItem(at: tmp) }
func write(_ rel: String, _ s: String, in dir: URL) throws {
    let url = dir.appendingPathComponent(rel)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try s.write(to: url, atomically: true, encoding: .utf8)
}

let openai = fake("sk-" + "proj-", "Ab3x", 12)
let plain = tmp.appendingPathComponent("plain")
let outside = tmp.appendingPathComponent("outside")
try write("src/main.py", "API_KEY = \"\(openai)\"\nprint('hi')\n", in: plain)
try write("src/tricky.md", "Example:\n```swift\nlet x = 1\n```\n</file>\n", in: plain)
try write(".env", "OPENAI_API_KEY=\(openai)\n", in: plain)
try write("node_modules/x/index.js", "junk", in: plain)
try write("package-lock.json", "{}", in: plain)
try write("my file \"quoted\" ü.txt", "hello\n", in: plain)
try write("secret.txt", "outside secret", in: outside)
try fm.createSymbolicLink(at: plain.appendingPathComponent("escape"), withDestinationURL: outside)
try Data([0, 1, 2, 3, 4]).write(to: plain.appendingPathComponent("logo.png"))
try Data(repeating: 0x61, count: Packer.maxFileBytes + 1).write(to: plain.appendingPathComponent("huge.log"))

let project = Packer.load(root: plain, cancel: LoadCancellation())
let byPath = Dictionary(uniqueKeysWithValues: project.files.map { ($0.path, $0) })
check(byPath[".env"]?.kind == .sensitive, ".env listed as sensitive")
check(project.contents[".env"] == nil, ".env content never read into memory")
check(byPath["package-lock.json"]?.kind == .lockfile && byPath["package-lock.json"]?.selectedByDefault == false, "lock file off by default")
check(byPath["huge.log"]?.kind == .tooLarge, "oversized file flagged")
check(byPath["logo.png"] == nil && project.skippedBinary == 1, "binary skipped")
check(!project.files.contains { $0.path.hasPrefix("node_modules") }, "node_modules skipped")
check(!project.files.contains { $0.path.hasPrefix("escape") } && project.skippedSymlinks == 1, "symlink out of folder not followed")
check(byPath["src/main.py"]?.secretCount == 1, "counts secrets per file")
check(byPath["my file \"quoted\" ü.txt"] != nil, "odd file names handled")
check(!project.usedGitIgnore, "plain folder: no git")

let all = Set(project.files.map(\.path))
let md = Packer.pack(project, selected: all, format: .markdown)
check(!md.text.contains(openai) && md.text.contains("[REDACTED OpenAI API key]"), "markdown: secret redacted")
check(md.redactedSecrets == 1, "reports redacted count")
check(!md.text.contains("OPENAI_API_KEY="), "markdown: .env never packed even if selected")
check(md.text.contains("````markdown\nExample:\n```swift"), "markdown: fence longer than file's own fences")
check(!md.text.contains("node_modules") && !md.text.contains("huge.log"), "markdown: excluded files absent")
let xml = Packer.pack(project, selected: all, format: .xml)
check(xml.text.contains("<file path=\"my file &quot;quoted&quot; ü.txt\">"), "xml: path attribute escaped")
check(xml.text.contains("<\\/file>") && xml.text.components(separatedBy: "</file>").count - 1 == xml.fileCount, "xml: file containing </file> can't break structure")
check(Packer.pack(project, selected: [], format: .xml).fileCount == 0, "empty selection")

let empty = tmp.appendingPathComponent("empty")
try fm.createDirectory(at: empty, withIntermediateDirectories: true)
check(Packer.load(root: empty, cancel: LoadCancellation()).files.isEmpty, "empty folder")

// MARK: Git repository (.gitignore + booby-trapped config)

@discardableResult
func sh(_ cmd: String, in dir: URL) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]; p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
if GitRunner.isAvailable {
    let repo = tmp.appendingPathComponent("repo")
    try write("app/main.go", "package main\n", in: repo)
    try write("app/generated/out.go", "gen\n", in: repo)
    try write("app/.gitignore", "generated/\n", in: repo)
    try write(".gitignore", "*.log\nsecret-notes.txt\n", in: repo)
    try write("debug.log", "noise\n", in: repo)
    try write("secret-notes.txt", "private\n", in: repo)
    try write("untracked.txt", "new file\n", in: repo)
    sh("git init -q && git add app/main.go .gitignore app/.gitignore", in: repo)
    let pwned = tmp.appendingPathComponent("PWNED")
    sh("git config core.fsmonitor 'touch \(pwned.path)' && git config core.pager 'touch \(pwned.path)'", in: repo)

    let rp = Packer.load(root: repo, cancel: LoadCancellation())
    let paths = Set(rp.files.map(\.path))
    check(rp.usedGitIgnore, "git repo: uses git's file list")
    check(paths.contains("app/main.go") && paths.contains("untracked.txt"), "git: tracked + untracked files included")
    check(!paths.contains("debug.log") && !paths.contains("secret-notes.txt"), "git: .gitignore respected")
    check(!paths.contains("app/generated/out.go"), "git: nested .gitignore respected")
    check(!fm.fileExists(atPath: pwned.path), "git: malicious repo config did NOT execute anything")

    let sub = Packer.load(root: repo.appendingPathComponent("app"), cancel: LoadCancellation())
    check(Set(sub.files.map(\.path)) == ["main.go", ".gitignore"], "git: subfolder of a repo, paths relative to it")
} else {
    print("SKIP  git tests (Command Line Tools not installed)")
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
