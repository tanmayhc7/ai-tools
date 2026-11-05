import Foundation

// Fake keys are assembled at runtime so this file never contains a literal key
// (keeps GitHub secret scanning and LeakGuard itself quiet on this repo).
func fake(_ prefix: String, _ body: String, _ n: Int) -> String { prefix + String(repeating: body, count: n) }

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}
func ids(_ text: String) -> [String] { SecretRules.scan(text).map(\.ruleID) }

// MARK: Rules

let keys: [(String, String)] = [
    ("openai", fake("sk-" + "proj-", "Ab3x", 12)),
    ("anthropic", fake("sk-" + "ant-api03-", "Zq9_", 20)),
    ("aws-access-key", "AK" + "IA" + "QWERTYUIOPASDFGH"),
    ("github-token", fake("gh" + "p_", "aB1c", 9)),
    ("stripe", fake("sk_" + "live_", "4eC3", 6)),
    ("google", "AI" + "za" + String(repeating: "Sy9", count: 11) + "xx"),
    ("huggingface", fake("hf" + "_", "Ab1C", 9)),
    ("slack-token", fake("xo" + "xb-", "12345-", 4)),
    ("npm", fake("np" + "m_", "a1B2", 9)),
]
for (id, key) in keys {
    check(ids("let k = \"\(key)\"").contains(id), "detects \(id)")
}
let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIEow\nabc\n-----END " + "RSA PRIVATE KEY-----"
check(ids(pem) == ["private-key"] && SecretRules.scan(pem).first?.value == pem, "detects whole private key block once")
check(SecretRules.scan("x -----BEGIN " + "PRIVATE KEY----- truncated").first?.ruleID == "private-key", "detects lone private key header")
check(ids("DATABASE_URL=postgres://app:" + "S3cr3tPw" + "@db.local:5432/x") == ["db-url"], "detects password in database URL")
check(ids("api_key = \"" + "h7Gk2LmQ9xPz4RtW8vNc" + "\"") == ["generic"], "detects random-looking generic secret")

// False positives that must stay quiet
check(ids("let secret = \"sk-test-123\"").isEmpty, "ignores short test value")
check(ids("password = \"please-change-this-later\"").isEmpty, "ignores low-entropy config value")
check(ids("api_key = \"your-api-key-goes-here-1\"").isEmpty, "ignores placeholder")
check(ids("token: process.env.OPENAI_API_KEY").isEmpty, "ignores env var reference")
check(ids("func ask(task: String) -> Bool { return true }").isEmpty, "ignores ordinary code")

let ant = keys[1].1
check(ids(ant) == ["anthropic"], "Anthropic key not double-reported as OpenAI")
let masked = SecretRules.mask(keys[0].1)
check(!masked.contains(String(keys[0].1.dropFirst(6).prefix(10))), "mask hides the middle of a key")

// Huge minified line: key at the very end must be found, quickly
let huge = String(repeating: "a=1;", count: 750_000) + keys[0].1
let t0 = Date()
check(ids(huge).contains("openai"), "finds key at end of 3 MB single line")
check(Date().timeIntervalSince(t0) < 10, "3 MB line scanned in under 10 s (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
// Crafted inputs that make naive regexes take quadratic time must stay fast.
for (name, text) in [("'token' ×200k", String(repeating: "token", count: 200_000)),
                     ("PEM headers ×30k", String(repeating: "-----BEGIN " + "RSA PRIVATE KEY-----\n", count: 30_000)),
                     ("'sk-' ×300k", String(repeating: "sk-", count: 300_000)),
                     ("'xoxb-' ×200k", String(repeating: "xo" + "xb-", count: 200_000)),
                     ("'postgres://a:' ×80k", String(repeating: "postgres://a:", count: 80_000)),
                     ("'secret' + 1M spaces", "secret" + String(repeating: " ", count: 1_000_000))] {
    let t = Date(); _ = SecretRules.scan(text); let dt = Date().timeIntervalSince(t)
    check(dt < 5, String(format: "hostile input %@ scanned in %.2fs", name, dt))
}
// Key straddling a window boundary
let boundary = String(repeating: "x", count: SecretRules.windowSize - 10) + " " + keys[0].1
check(ids(boundary).contains("openai"), "finds key straddling scan-window boundary")

// MARK: Text scanning, line numbers, KeyVault matches

var fs: [Finding] = []
Scanner.scanText("a\nb\nkey=\(keys[0].1)\n", file: "x.txt", source: .workingCopy, firstLine: 1, vault: [], into: &fs)
check(fs.first?.line == 3, "reports correct line number")
fs = []
let vaultKey = "my-internal-service-key-77"
Scanner.scanText("cfg: \(vaultKey)\nother: \(keys[0].1)", file: "c.yml", source: .workingCopy, firstLine: 1,
                 vault: [VaultSecret(name: "Internal", secret: vaultKey), VaultSecret(name: "OpenAI", secret: keys[0].1)],
                 into: &fs)
check(fs.count == 2, "vault: unknown-format key found + known key not duplicated (\(fs.count))")
check(fs.contains { $0.vaultEntryName == "Internal" } && fs.contains { $0.vaultEntryName == "OpenAI" }, "vault: both tagged with entry names")
fs = []
Scanner.scanText("short", file: "s", source: .workingCopy, firstLine: 1,
                 vault: [VaultSecret(name: "tiny", secret: "short")], into: &fs)
check(fs.isEmpty, "vault: very short entries ignored (avoids false alarms)")

// KeyVault reader with a throwaway vault and a throwaway lockout store (never the real ones)
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let suite = "leakguard.tests.\(UUID().uuidString)"
    VaultReader.vaultURL = dir.appendingPathComponent("vault.json")
    VaultReader.lockoutDefaults = UserDefaults(suiteName: suite)
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let salt = try VaultCrypto.randomBytes(16)
    let k = try VaultCrypto.deriveKey(password: "right password 123", salt: salt, iterations: 600_000)
    let body = try JSONSerialization.data(withJSONObject: ["entries": [["name": "OpenAI", "secret": "abc-" + "secret-value-123",
        "service": "", "notes": "", "id": UUID().uuidString, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"]]])
    try JSONEncoder().encode(try VaultCrypto.seal(body, key: k, salt: salt, iterations: 600_000)).write(to: VaultReader.vaultURL)

    check((try? VaultReader.readSecrets(password: "right password 123"))?.first?.name == "OpenAI", "vault reader: decrypts KeyVault vault")
    for _ in 0..<3 { _ = try? VaultReader.readSecrets(password: "wrong guess") }
    var throttled = false
    do { _ = try VaultReader.readSecrets(password: "right password 123") } catch VaultError.throttled { throttled = true }
    check(throttled, "vault reader: shares KeyVault's lockout after 3 wrong passwords")
}

check(Scanner.parseNewStart("@@ -12,3 +40,7 @@ func") == 40, "parses hunk header")
check(Scanner.parseNewStart("@@ -1 +1 @@") == 1, "parses short hunk header")
check(Scanner.parseDiffPath("b/my file.txt\t") == "my file.txt", "diff path: trailing tab after spaces stripped")
check(Scanner.parseDiffPath("\"b/tab\\there.txt\"") == "tab\there.txt", "diff path: C-quoted escape decoded")
check(Scanner.parseDiffPath("\"b/\\303\\274.txt\"") == "ü.txt", "diff path: octal UTF-8 decoded")
check(Scanner.parseDiffPath("/dev/null") == nil, "diff path: deleted file")

// MARK: Working copy on disk

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("leakguard-tests-\(UUID().uuidString)")
let proj = tmp.appendingPathComponent("proj")
let outside = tmp.appendingPathComponent("outside")
try fm.createDirectory(at: proj.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

func write(_ rel: String, _ s: String, in dir: URL = proj) throws {
    let url = dir.appendingPathComponent(rel)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try s.write(to: url, atomically: true, encoding: .utf8)
}
try write(".env", "OPENAI_API_KEY=\(keys[0].1)\n")
try write("node_modules/pkg/index.js", "const k = '\(keys[3].1)'")
try write("secret.txt", "AWS=\(keys[2].1)", in: outside)
try fm.createSymbolicLink(at: proj.appendingPathComponent("link"), withDestinationURL: outside)
var bin = Data([0, 1, 2, 3]); bin.append(Data(keys[4].1.utf8))
try bin.write(to: proj.appendingPathComponent("image.bin"))
var badUTF8 = Data("token: \(keys[5].1)\n".utf8); badUTF8.append(contentsOf: [0xFF, 0xFE, 0xC0])
try badUTF8.write(to: proj.appendingPathComponent("weird.txt"))
try Data(repeating: 0x61, count: Scanner.maxFileBytes + 1).write(to: proj.appendingPathComponent("big.log"))
mkfifo(proj.appendingPathComponent("trap.fifo").path, 0o644)      // reading a pipe would block forever
check(SafeRead.regularFile(at: proj.appendingPathComponent("trap.fifo").path, maxBytes: 100) == nil, "safe read: refuses named pipe")
check(SafeRead.regularFile(at: proj.appendingPathComponent("link").path, maxBytes: 100) == nil, "safe read: refuses symlink")

var summary = ScanSummary(); var found: [Finding] = []
Scanner.scanWorkingCopy(root: proj, vault: [], cancel: ScanCancellation(), summary: &summary, findings: &found) { _, _ in }
let files = Set(found.map(\.file))
check(files.contains(".env"), "scans hidden .env files")
check(!files.contains { $0.hasPrefix("node_modules") }, "skips node_modules")
check(!files.contains { $0.hasPrefix("link") } && summary.skippedSymlinks == 1, "never follows symlinks out of the folder")
check(!files.contains("image.bin") && summary.skippedBinary == 1, "skips binary files")
check(files.contains("weird.txt"), "invalid UTF-8 file still scanned, no crash")
check(summary.skippedLarge == 1, "oversized file skipped")

let cancel = ScanCancellation(); cancel.cancel()
summary = ScanSummary(); found = []
Scanner.scanWorkingCopy(root: proj, vault: [], cancel: cancel, summary: &summary, findings: &found) { _, _ in }
check(summary.cancelled && found.isEmpty, "cancel stops the scan")

// MARK: Git history (+ malicious repo config)

@discardableResult
func sh(_ cmd: String, in dir: URL) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

if GitRunner.isAvailable {
    let repo = tmp.appendingPathComponent("repo")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    sh("git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false", in: repo)
    try write("config.py", "KEY = '\(keys[0].1)'\n", in: repo)
    sh("git add . && git commit -qm add-key", in: repo)
    try write("config.py", "KEY = os.environ['KEY']\n", in: repo)
    sh("git commit -qam remove-key", in: repo)
    try write("ünïcode name.txt", "x = '\(keys[3].1)'\n", in: repo)
    sh("git add . && git commit -qm unicode", in: repo)
    try write("ünïcode name.txt", "clean\n", in: repo)
    sh("git commit -qam cleanup", in: repo)

    // Booby-trap: a repo whose own config tries to run a program when diffs are produced.
    let pwned = tmp.appendingPathComponent("PWNED")
    try write(".gitattributes", "* diff=evil\n", in: repo)
    sh("git add . && git commit -qm attrs", in: repo)
    sh("git config diff.evil.textconv 'touch \(pwned.path); cat'", in: repo)
    sh("git config diff.external 'touch \(pwned.path)'", in: repo)
    sh("git config core.fsmonitor 'touch \(pwned.path)'", in: repo)
    sh("git config core.pager 'touch \(pwned.path); cat'", in: repo)

    // Booby-trap 2: a commit carrying a (fake) signature + config that "verifies" it with any program.
    let pwnedSig = tmp.appendingPathComponent("PWNED-SIG")
    sh("""
    tree=$(git write-tree) && parent=$(git rev-parse HEAD) && \
    printf 'tree %s\\nparent %s\\nauthor a <a@a> 1700000000 +0000\\ncommitter a <a@a> 1700000000 +0000\\ngpgsig -----BEGIN PGP SIGNATURE-----\\n \\n iQEzBAABCAAdFiEE\\n -----END PGP SIGNATURE-----\\n\\nsigned\\n' "$tree" "$parent" \
      | git hash-object -t commit -w --stdin | xargs git update-ref HEAD
    """, in: repo)
    sh("git config log.showSignature true && git config gpg.program '\(tmp.path)/evil.sh'", in: repo)
    try "#!/bin/sh\ntouch '\(pwnedSig.path)'\n".write(to: tmp.appendingPathComponent("evil.sh"), atomically: true, encoding: .utf8)
    sh("chmod +x '\(tmp.path)/evil.sh'", in: repo)

    // The setup above used plain git, which itself trips the earlier traps — reset the markers
    // so only what the scanner does is measured.
    try? fm.removeItem(at: pwned); try? fm.removeItem(at: pwnedSig)
    summary = ScanSummary(); found = []
    Scanner.scanHistory(repo: repo, vault: [], cancel: ScanCancellation(), summary: &summary, findings: &found) { _, _ in }
    check(!fm.fileExists(atPath: pwnedSig.path), "malicious gpg.program + log.showSignature did NOT execute")
    check(summary.historyError == nil, "history scan ran (\(summary.historyError ?? "ok"))")
    check(found.contains { $0.file == "config.py" && $0.source.isHistory && $0.line == 1 }, "finds key deleted in a later commit")
    check(found.contains { $0.file == "ünïcode name.txt" }, "handles non-ASCII file names in history")
    check(found.filter { $0.file == "config.py" }.count == 1, "same key in same file reported once")
    check(!fm.fileExists(atPath: pwned.path), "malicious repo config did NOT execute anything")

    summary = ScanSummary(); found = []
    Scanner.scanWorkingCopy(root: repo, vault: [], cancel: ScanCancellation(), summary: &summary, findings: &found) { _, _ in }
    check(found.isEmpty, "current files clean after removal")

    // MARK: Pre-commit hook
    check(HookInstaller.status(repo: repo) == .notInstalled, "hook: starts not installed")
    try HookInstaller.install(repo: repo)
    check(HookInstaller.status(repo: repo) == .installed, "hook: installed")
    try write("leak.txt", "k=\(keys[1].1)\n", in: repo)
    check(sh("git add leak.txt && git commit -qm leak", in: repo) != 0, "hook: blocks commit that adds a key")
    sh("git reset -q leak.txt && rm leak.txt", in: repo)
    try write("ok.txt", "hello\n", in: repo)
    check(sh("git add ok.txt && git commit -qm ok", in: repo) == 0, "hook: allows a clean commit")
    try write("weird name.txt", "k=\(keys[2].1)\n", in: repo)
    check(sh("git add 'weird name.txt' && git commit -qm leak2", in: repo) != 0, "hook: handles file names with spaces")
    sh("git reset -q 'weird name.txt' && rm 'weird name.txt'", in: repo)
    try HookInstaller.uninstall(repo: repo)
    check(HookInstaller.status(repo: repo) == .notInstalled, "hook: uninstalled cleanly")

    let foreign = repo.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\necho mine\n".write(to: foreign, atomically: true, encoding: .utf8)
    check(HookInstaller.status(repo: repo) == .otherHookPresent, "hook: detects someone else's hook")
    check((try? HookInstaller.install(repo: repo)) == nil, "hook: refuses to overwrite it")
    check((try? String(contentsOf: foreign, encoding: .utf8)) == "#!/bin/sh\necho mine\n", "hook: foreign hook untouched")

    check(GitRunner.repoRoot(of: proj) == nil, "non-repo folder detected as not a repo")
} else {
    print("SKIP  git tests (Command Line Tools not installed)")
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
