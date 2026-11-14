import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)   // a client writing to a connection the server already closed must not kill the test
var failures = 0
func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)  [\(detail())]")
    if !ok { failures += 1 }
}

// MARK: - Test doubles

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if opened { lock.unlock(); cont.resume() } else { waiters.append(cont); lock.unlock() }
        }
    }
    func open() {
        lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

final class FakeHost: AgentHost, @unchecked Sendable {
    private let lock = NSLock()
    var unlocked = true
    var canUnlockFlag = true
    var unlockResult = true
    var entriesList: [HostEntry]
    var secrets: [UUID: String]
    var decisions: [Decision] = []
    var defaultDecision: Decision = .allowOnce
    var approvalHook: (@Sendable () async -> Void)?
    private(set) var unlockCalls = 0
    private(set) var approveCalls = 0
    private(set) var secretCalls = 0
    private(set) var cancelCalls = 0
    private(set) var maxConcurrentApprovals = 0
    private var concurrentApprovals = 0
    private(set) var approvals: [ApprovalRequest] = []

    init(entries: [(String, String)] = [("OpenAI – prod", "sk-test-OPENAI-secret-0001")]) {
        var list: [HostEntry] = [], map: [UUID: String] = [:]
        for (name, secret) in entries { let id = UUID(); list.append(HostEntry(id: id, name: name)); map[id] = secret }
        entriesList = list; secrets = map
    }

    func isUnlocked() async -> Bool { lock.lock(); defer { lock.unlock() }; return unlocked }
    func canUnlock() async -> Bool { lock.lock(); defer { lock.unlock() }; return canUnlockFlag }
    func requestUnlock(for requester: Requester) async -> Bool {
        lock.lock(); unlockCalls += 1; let result = unlockResult; lock.unlock()
        if result { lock.lock(); unlocked = true; lock.unlock() }
        return result
    }
    func entries() async -> [HostEntry] { lock.lock(); defer { lock.unlock() }; return unlocked ? entriesList : [] }
    func secret(for id: UUID) async -> String? {
        lock.lock(); defer { lock.unlock() }
        secretCalls += 1
        return unlocked ? secrets[id] : nil
    }
    func approve(_ request: ApprovalRequest) async -> Decision {
        lock.lock()
        approveCalls += 1; approvals.append(request)
        concurrentApprovals += 1; maxConcurrentApprovals = max(maxConcurrentApprovals, concurrentApprovals)
        let hook = approvalHook
        lock.unlock()
        if let hook { await hook() }
        lock.lock()
        concurrentApprovals -= 1
        let d = decisions.isEmpty ? defaultDecision : decisions.removeFirst()
        lock.unlock()
        return d
    }
    func cancelPendingApprovals() async { lock.lock(); cancelCalls += 1; lock.unlock() }
    func lockVault() { lock.lock(); unlocked = false; lock.unlock() }
}

func makeController(_ host: FakeHost, clock: TestClock = TestClock(),
                    tweak: (inout AccessController.Config) -> Void = { _ in }) -> AccessController {
    var config = AccessController.Config()
    tweak(&config)
    return AccessController(host: host, config: config, clock: { clock.now })
}

func pause(_ seconds: Double) { usleep(UInt32(seconds * 1_000_000)) }

let selfRequester = ProcessInspector.inspect(pid: getpid())!

func fakeRequester(_ n: Int, like base: Requester = selfRequester) -> Requester {
    Requester(pid: base.pid, startTime: base.startTime, path: "/fake/program\(n)", arguments: ["program\(n)"],
              workingDirectory: "/", parentPid: 1, parentPath: "/sbin/launchd", signature: .unsigned)
}

func request(_ name: String = "OpenAI – prod", reason: String? = nil) -> AgentProtocol.Request {
    AgentProtocol.Request(key: name, reason: reason)
}

func json(_ data: Data?) -> [String: Any] {
    guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}
func errorCode(_ data: Data?) -> String? { json(data)["error"] as? String }
func secretValue(_ data: Data?) -> String? { json(data)["secret"] as? String }

@Sendable func always() -> Bool { true }
@Sendable func never() -> Bool { false }

var spawned: [Process] = []
func spawn(_ executable: String, _ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run()
    spawned.append(p)
    pause(0.25)
    return p
}
defer { spawned.forEach { $0.terminate() } }

// MARK: - Protocol parsing

func parse(_ s: String) -> Result<AgentProtocol.Request, AgentProtocol.ParseError> { AgentProtocol.parse(Data(s.utf8)) }
check(parse(#"{"v":1,"op":"get","key":"OpenAI – prod","reason":"agentp"}"#) == .success(request(reason: "agentp")), "protocol: valid request")
check(parse(#"{"v":1,"op":"get","key":"k","extra":[1,2],"more":{"a":1}}"#) == .success(request("k")), "protocol: unknown fields ignored")
check(parse(#"{"v":1,"op":"get","key":"  spaced  "}"#) == .success(request("spaced")), "protocol: key trimmed")
check(parse(#"{"op":"get","key":"k"}"#) == .failure(.wrongVersion), "protocol: missing version")
check(parse(#"{"v":2,"op":"get","key":"k"}"#) == .failure(.wrongVersion), "protocol: wrong version")
check(parse(#"{"v":"1","op":"get","key":"k"}"#) == .failure(.wrongVersion), "protocol: version must be a number")
check(parse(#"{"v":1,"op":"list","key":"k"}"#) == .failure(.unsupportedOperation), "protocol: only 'get' exists (no list/dump)")
check(parse(#"{"v":1,"op":"get"}"#) == .failure(.badKey), "protocol: missing key")
check(parse(#"{"v":1,"op":"get","key":"   "}"#) == .failure(.badKey), "protocol: blank key")
check(parse(#"{"v":1,"op":"get","key":5}"#) == .failure(.badKey), "protocol: key must be a string")
check(parse(#"{"v":1,"op":"get","key":"a\u0000b"}"#) == .failure(.badKey), "protocol: NUL in key")
check(parse(#"{"v":1,"op":"get","key":"a\nb"}"#) == .failure(.badKey), "protocol: newline in key")
check(parse("{\"v\":1,\"op\":\"get\",\"key\":\"" + String(repeating: "k", count: 257) + "\"}") == .failure(.badKey), "protocol: key too long")
check(parse(#"{"v":1,"op":"get","key":"k","reason":7}"#) == .failure(.badReason), "protocol: reason must be a string")
check(parse("not json") == .failure(.notJSON) && parse("[1,2]") == .failure(.notJSON) && parse("") == .failure(.notJSON), "protocol: non-JSON / array / empty")
check(AgentProtocol.parse(Data(repeating: 0x7B, count: 5000)) == .failure(.tooLarge), "protocol: oversized")
check(AgentProtocol.parse(Data([0xFF, 0xFE, 0x00])) == .failure(.notJSON), "protocol: binary garbage")
check(String(decoding: AgentProtocol.ok(secret: "x"), as: UTF8.self).hasSuffix("\n") && errorCode(AgentProtocol.error(.denied)) == "denied", "protocol: replies are one JSON line")
check(AgentProtocol.names("OpenAI – Prod", match: "  openai – prod ") && !AgentProtocol.names("OpenAI", match: "OpenAI – prod"), "names: case-insensitive exact, never prefix")
check(AgentProtocol.names("Caf\u{00E9}", match: "Cafe\u{0301}") && !AgentProtocol.names("Cafe", match: "Caf\u{00E9}"), "names: Unicode-normalised, accents not folded")

// MARK: - Sanitising text shown to the user

check(AgentProtocol.sanitize("line1\nFAKE: Allow access to Bank?\r\n", maxLength: 100) == "line1 FAKE: Allow access to Bank?", "sanitize: newlines can't fake extra lines")
check(AgentProtocol.sanitize("safe\u{202E}gnp.exe", maxLength: 100) == "safegnp.exe", "sanitize: bidi override removed")
check(AgentProtocol.sanitize("a\u{200B}b\u{FEFF}c\u{2066}d", maxLength: 100) == "abcd", "sanitize: zero-width and isolate characters removed")
check(AgentProtocol.sanitize("a\u{0007}\u{001B}[31mb", maxLength: 100) == "a [31mb", "sanitize: control characters / escapes neutralised")
check(AgentProtocol.sanitize(String(repeating: "x", count: 500), maxLength: 50).count == 50, "sanitize: truncated")
check(AgentProtocol.sanitize("  a    b  ", maxLength: 50) == "a b", "sanitize: whitespace collapsed")
check(AgentProtocol.sanitize("日本語 ✅ é", maxLength: 50) == "日本語 ✅ é", "sanitize: ordinary Unicode kept")

// MARK: - Process inspection

check(selfRequester.pid == getpid() && selfRequester.startTime > 0 && !selfRequester.path.isEmpty, "inspect: own pid, start time, path")
check(selfRequester.arguments.first.map { ($0 as NSString).lastPathComponent == (selfRequester.path as NSString).lastPathComponent } == true, "inspect: argv[0] read")
check(URL(fileURLWithPath: selfRequester.workingDirectory).resolvingSymlinksInPath().path
      == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path, "inspect: working directory")
check(selfRequester.parentPid > 0 && !selfRequester.parentPath.isEmpty, "inspect: parent process")
let sleeper = spawn("/bin/sleep", ["30"])
let sleeperInfo = ProcessInspector.inspect(pid: sleeper.processIdentifier)
check(sleeperInfo?.program == "sleep" && sleeperInfo?.arguments == ["/bin/sleep", "30"] && sleeperInfo?.signature == .apple, "inspect: child program, args, Apple signature")
let py = spawn("/usr/bin/python3", ["-I", "-c", "import time; time.sleep(30)"])
check(ProcessInspector.inspect(pid: py.processIdentifier)?.script == "inline code", "inspect: python -c → 'inline code'")
let py2 = spawn("/usr/bin/python3", ["-I", "-m", "http.server", "0"])
check(ProcessInspector.inspect(pid: py2.processIdentifier)?.script == "module http.server", "inspect: python -m → module name")
let scriptDir = FileManager.default.temporaryDirectory.appendingPathComponent("kv-agent-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scriptDir) }
let sleepScript = scriptDir.appendingPathComponent("agentp_main.py")
try "import time\ntime.sleep(30)\n".write(to: sleepScript, atomically: true, encoding: .utf8)
let py3 = spawn("/usr/bin/python3", ["-I", sleepScript.path])
check(ProcessInspector.inspect(pid: py3.processIdentifier)?.script == sleepScript.path, "inspect: python script path")
check(ProcessInspector.inspect(pid: py3.processIdentifier)?.label.contains("agentp_main.py") == true, "inspect: label names the script")
let deadPid = spawn("/bin/sleep", ["30"]); let deadID = deadPid.processIdentifier
deadPid.terminate(); deadPid.waitUntilExit()
check(ProcessInspector.inspect(pid: deadID) == nil && ProcessInspector.startTime(of: deadID) == nil, "inspect: exited process returns nil")
check(ProcessInspector.inspect(pid: 0) == nil && ProcessInspector.inspect(pid: -5) == nil && ProcessInspector.inspect(pid: 99_999_999) == nil, "inspect: bogus pids return nil")
check(ProcessInspector.parseProcessArguments([]).argv.isEmpty && ProcessInspector.parseProcessArguments([1, 0, 0]).argv.isEmpty, "args parser: empty/truncated buffers")
var hostile: [UInt8] = withUnsafeBytes(of: Int32(2_000_000_000).littleEndian) { Array($0) } + Array("/bin/x\0\0a\0b\0".utf8)
check(ProcessInspector.parseProcessArguments(hostile).argv.isEmpty, "args parser: absurd argc rejected")
hostile = withUnsafeBytes(of: Int32(50).littleEndian) { Array($0) } + Array("/bin/x\0\0a\0b".utf8)
check(ProcessInspector.parseProcessArguments(hostile).argv == ["a", "b"], "args parser: argc larger than data doesn't overrun")
let adhocCopy = scriptDir.appendingPathComponent("unsigned-copy")
try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: adhocCopy.path)
let strip = Process(); strip.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
strip.arguments = ["--remove-signature", adhocCopy.path]
strip.standardOutput = FileHandle.nullDevice; strip.standardError = FileHandle.nullDevice
try strip.run(); strip.waitUntilExit()
let unsignedSig = ProcessInspector.signature(ofExecutableAt: adhocCopy.path)
check(unsignedSig == .unsigned || unsignedSig == .invalid, "signature: stripped binary is not trusted (\(unsignedSig))")
check(ProcessInspector.signature(ofExecutableAt: "/nonexistent/x") == .unknown && Requester.Signature.adHoc.isUnverified && !Requester.Signature.apple.isUnverified, "signature: missing file / unverified classes")

// MARK: - Controller: grants

do {
    let host = FakeHost(); let c = makeController(host)
    var r = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(secretValue(r) == "sk-test-OPENAI-secret-0001" && host.approveCalls == 1, "allowOnce: key delivered after approval")
    r = await c.handle(request(), from: selfRequester, peerStillValid: always)
    let snap = await c.snapshot()
    check(host.approveCalls == 2 && snap.grants.isEmpty, "allowOnce: asks again next time, no grant left")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let clock = TestClock(); let c = makeController(host, clock: clock)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    let r = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(secretValue(r) != nil && host.approveCalls == 1, "window: second request served by the grant, no new dialog")
    check((await c.snapshot()).log.last?.outcome == .allowedByGrant, "window: logged as 'by grant'")

    let other = ProcessInspector.inspect(pid: sleeper.processIdentifier)!
    _ = await c.handle(request(), from: other, peerStillValid: always)
    check(host.approveCalls == 2, "window: grant belongs to one process; another process is asked")

    let reused = Requester(pid: selfRequester.pid, startTime: selfRequester.startTime &+ 1, path: selfRequester.path,
                           arguments: selfRequester.arguments, workingDirectory: "/", parentPid: 1, parentPath: "", signature: .unsigned)
    _ = await c.handle(request(), from: reused, peerStillValid: always)
    check(host.approveCalls == 3, "window: same pid with a different start time (pid reuse) is asked")

    clock.advance(601)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(host.approveCalls == 4, "window: expires after its time")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 10_000_000)
    let clock = TestClock(); let c = makeController(host, clock: clock)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    clock.advance(3601)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(host.approveCalls == 2, "window: requested time is capped at one hour")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let c = makeController(host)
    let child = ProcessInspector.inspect(pid: spawn("/bin/sleep", ["30"]).processIdentifier)!
    _ = await c.handle(request(), from: child, peerStillValid: always)
    check((await c.snapshot()).grants.count == 1, "window: grant created for child process")
    kill(child.pid, SIGKILL); pause(0.4)
    check((await c.snapshot()).grants.isEmpty, "window: grant disappears when its process exits")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let c = makeController(host)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    await c.revokeAll()
    let afterRevoke = await c.snapshot()
    check(afterRevoke.grants.isEmpty && host.cancelCalls == 1, "lock: revokeAll clears grants and dismisses dialogs")
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(host.approveCalls == 2, "lock: after revoke the next request is asked again")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let c = makeController(host)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    let grantID = (await c.snapshot()).grants[0].id
    await c.revoke(grantID: grantID)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(host.approveCalls == 2, "revoke: single grant can be revoked from the panel")
}

// MARK: - Controller: refusals, throttling, enumeration

do {
    let host = FakeHost(); host.defaultDecision = .deny
    let clock = TestClock(); let c = makeController(host, clock: clock)
    let denied = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(errorCode(denied) == "denied" && host.secretCalls == 0, "deny: refused, key never fetched")
    let unknown = await c.handle(request("Nope"), from: fakeRequester(1), peerStillValid: always)
    check(unknown == denied, "deny: unknown key gets the identical reply (can't probe which keys exist)")
    check(host.approveCalls == 1, "deny: no dialog for a key that doesn't exist")

    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    _ = await c.handle(request(), from: selfRequester, peerStillValid: always)
    let blocked = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(errorCode(blocked) == "rate_limited" && host.approveCalls == 3, "throttle: 3 refusals block the program, no 4th dialog")
    check(errorCode(await c.handle(request(), from: fakeRequester(9), peerStillValid: always)) == "denied", "throttle: a different program isn't blocked")
    clock.advance(301)
    host.defaultDecision = .allowOnce
    check(secretValue(await c.handle(request(), from: selfRequester, peerStillValid: always)) != nil, "throttle: block ends after 5 minutes")
}
do {
    let host = FakeHost(); host.defaultDecision = .deny
    let clock = TestClock(); let c = makeController(host, clock: clock) { $0.denialsBeforePause = 100 }   // isolate the per-program block
    for _ in 0..<3 { _ = await c.handle(request(), from: selfRequester, peerStillValid: always) }
    clock.advance(301)
    for _ in 0..<3 { _ = await c.handle(request(), from: selfRequester, peerStillValid: always) }
    clock.advance(301)
    check(errorCode(await c.handle(request(), from: selfRequester, peerStillValid: always)) == "rate_limited", "throttle: repeat offenders are blocked for twice as long")
    clock.advance(301)
    check(errorCode(await c.handle(request(), from: selfRequester, peerStillValid: always)) == "denied", "throttle: …and the longer block then ends")
}
do {
    let host = FakeHost(); host.decisions = [.deny, .deny, .allowOnce, .deny, .deny]
    let c = makeController(host)
    for _ in 0..<5 { _ = await c.handle(request(), from: selfRequester, peerStillValid: always) }
    check(host.approveCalls == 5, "throttle: an approval resets the refusal count")
}
do {
    let host = FakeHost(); host.defaultDecision = .timedOut
    let c = makeController(host)
    var codes: [String?] = []
    for _ in 0..<6 { codes.append(errorCode(await c.handle(request(), from: selfRequester, peerStillValid: always))) }
    check(codes.allSatisfy { $0 == "timeout" }, "throttle: ignoring the dialog is not counted as a refusal")
}
do {
    let host = FakeHost(entries: [("Dup", "one"), ("dup", "two")]); let c = makeController(host)
    check(errorCode(await c.handle(request("Dup"), from: selfRequester, peerStillValid: always)) == "denied" && host.approveCalls == 0, "ambiguous name: refused, no dialog, same 'denied' reply")
}
do {
    let host = FakeHost(); let c = makeController(host)
    _ = await c.handle(request("openai – PROD"), from: selfRequester, peerStillValid: always)
    check(host.approvals.first?.entryName == "OpenAI – prod", "dialog shows the vault's real entry name, not the requester's spelling")
    _ = await c.handle(request("OpenAI – prod", reason: "line1\nline2"), from: selfRequester, peerStillValid: always)
    check(host.approvals.last?.reason == "line1\nline2", "reason is passed through raw (sanitised by the dialog)")
}
do {
    let host = FakeHost(); let clock = TestClock()
    let c = makeController(host, clock: clock) { $0.globalRequestsPerMinute = 5 }
    var limited = 0
    for i in 0..<8 { if errorCode(await c.handle(request(), from: fakeRequester(i), peerStillValid: always)) == "rate_limited" { limited += 1 } }
    check(limited == 3, "rate limit: requests beyond 5/minute are refused (\(limited) refused)")
    clock.advance(61)
    check(secretValue(await c.handle(request(), from: fakeRequester(99), peerStillValid: always)) != nil, "rate limit: resets after a minute")
}

do {   // dialog fatigue: many refusals from programs that keep changing name pause everything
    let host = FakeHost(); host.defaultDecision = .deny
    let clock = TestClock(); let c = makeController(host, clock: clock)
    for i in 0..<5 { _ = await c.handle(request(), from: fakeRequester(100 + i), peerStillValid: always) }
    let paused = await c.handle(request(), from: fakeRequester(200), peerStillValid: always)
    check(errorCode(paused) == "rate_limited" && host.approveCalls == 5, "fatigue: after 5 refusals in 10 min, a brand-new program gets no dialog")
    check((await c.snapshot()).log.last?.outcome == .paused, "fatigue: logged as paused")
    clock.advance(301)
    host.defaultDecision = .allowOnce
    check(secretValue(await c.handle(request(), from: fakeRequester(201), peerStillValid: always)) != nil, "fatigue: requests resume after 5 minutes")
}
do {   // a few refusals spread out over time don't pause anything
    let host = FakeHost(); host.defaultDecision = .deny
    let clock = TestClock(); let c = makeController(host, clock: clock)
    for i in 0..<8 { _ = await c.handle(request(), from: fakeRequester(300 + i), peerStillValid: always); clock.advance(200) }
    check(host.approveCalls == 8, "fatigue: occasional refusals (one every few minutes) never pause requests")
}

// MARK: - Controller: locked vault

do {
    let host = FakeHost(); host.unlocked = false
    let clock = TestClock(); let c = makeController(host, clock: clock)
    let r = await c.handle(request(), from: selfRequester, peerStillValid: always)
    check(secretValue(r) != nil && host.unlockCalls == 1 && host.approveCalls == 1, "locked: asks the user to unlock, then still asks for approval")
}
do {
    let host = FakeHost(); host.unlocked = false; host.unlockResult = false
    let clock = TestClock(); let c = makeController(host, clock: clock)
    check(errorCode(await c.handle(request(), from: selfRequester, peerStillValid: always)) == "locked" && host.approveCalls == 0, "locked: unlock refused → 'locked', no dialog")
    check(errorCode(await c.handle(request(), from: fakeRequester(2), peerStillValid: always)) == "locked" && host.unlockCalls == 1, "locked: unlock prompt shown at most once per 30 s")
    clock.advance(31)
    _ = await c.handle(request(), from: fakeRequester(3), peerStillValid: always)
    check(host.unlockCalls == 2, "locked: …and again after the cooldown")
}
do {
    let host = FakeHost(); host.unlocked = false; host.canUnlockFlag = false
    let c = makeController(host)
    check(errorCode(await c.handle(request(), from: selfRequester, peerStillValid: always)) == "locked" && host.unlockCalls == 0, "locked: no vault yet → no unlock prompt")
}

// MARK: - Controller: delivery safety

do {
    let host = FakeHost(); let c = makeController(host)
    let r = await c.handle(request(), from: selfRequester, peerStillValid: never)
    check(r == nil && host.approveCalls == 0 && host.secretCalls == 0, "gone before dialog: no dialog, nothing sent")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let c = makeController(host)
    let flag = FlagBox()
    host.approvalHook = { flag.set(false) }          // the requester vanishes while the dialog is open
    let r = await c.handle(request(), from: selfRequester, peerStillValid: { flag.value })
    check(r == nil && host.secretCalls == 0, "gone during dialog: key is not fetched or sent")
    let abandoned = await c.snapshot()
    check(abandoned.grants.isEmpty && abandoned.log.last?.outcome == .abandoned, "gone during dialog: no grant is created, logged as abandoned")
}
do {
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let gate = Gate(); host.approvalHook = { await gate.wait() }
    let c = makeController(host)
    async let pending = c.handle(request(), from: selfRequester, peerStillValid: always)
    try? await Task.sleep(for: .milliseconds(200))
    host.lockVault(); await c.revokeAll()            // the vault locks while the dialog is open
    gate.open()
    let r = await pending
    let afterLock = await c.snapshot()
    check(errorCode(r) == "locked" && host.secretCalls == 0 && afterLock.grants.isEmpty, "lock during dialog: even an 'allow' delivers nothing and leaves no grant")
}
do {
    let host = FakeHost(); host.defaultDecision = .allowOnce
    let gate = Gate(); host.approvalHook = { await gate.wait() }
    let c = makeController(host)
    async let pending = c.handle(request(), from: selfRequester, peerStillValid: always)
    try? await Task.sleep(for: .milliseconds(200))
    await c.revokeAll()                              // lock then (instant) unlock: vault is open again
    gate.open()
    check(errorCode(await pending) == "locked" && host.secretCalls == 0, "lock→unlock during dialog: the old request still can't get the key")
}
do {
    let host = FakeHost(); host.defaultDecision = .allowOnce
    let gate = Gate(); host.approvalHook = { await gate.wait() }
    let c = makeController(host) { $0.maxPendingApprovals = 4 }
    let results = await withTaskGroup(of: (Int, Data?).self) { group -> [Data?] in
        for i in 0..<7 { group.addTask { (i, await c.handle(request(), from: fakeRequester(i), peerStillValid: always)) } }
        try? await Task.sleep(for: .milliseconds(400))
        gate.open()
        var out: [Data?] = []
        for await (_, r) in group { out.append(r) }
        return out
    }
    check(host.maxConcurrentApprovals == 1, "queue: only one dialog is ever open at a time")
    check(results.filter { secretValue($0) != nil }.count == 4 && results.filter { errorCode($0) == "rate_limited" }.count == 3, "queue: 4 wait their turn, the other 3 are refused outright")
}

// MARK: - Controller: log

do {
    let host = FakeHost(); let c = makeController(host) { $0.maxLogEntries = 10 }
    for i in 0..<25 { _ = await c.handle(request("name \(i) " + String(repeating: "y", count: 200)), from: fakeRequester(i), peerStillValid: always) }
    let log = (await c.snapshot()).log
    check(log.count == 10 && log.allSatisfy { $0.keyName.count <= 60 }, "log: capped, names truncated")
    _ = await c.handle(request("Bad\u{202E}name"), from: selfRequester, peerStillValid: always)
    check(!(await c.snapshot()).log.last!.keyName.contains("\u{202E}"), "log: requested names are sanitised")
    let host2 = FakeHost(entries: [("K", "sk-SUPER-SECRET-VALUE-xyz")]); let c2 = makeController(host2)
    _ = await c2.handle(request("K"), from: selfRequester, peerStillValid: always)
    check(!String(describing: (await c2.snapshot()).log).contains("SUPER-SECRET"), "log: never contains a secret")
    let changes = ChangeCounter(); await c2.setOnChange { changes.bump() }
    _ = await c2.handle(request("K"), from: selfRequester, peerStillValid: always)
    check(changes.value > 0, "change notifications fire for the UI")
}

// MARK: - Server (real Unix sockets, real processes)

/// Unix socket paths are limited to 103 bytes, so these folders must be short.
func shortDir() -> URL {
    var base = NSTemporaryDirectory()
    if base.utf8.count > 60 { base = "/tmp/" }
    let d = URL(fileURLWithPath: base).appendingPathComponent("kvt-\(UInt32.random(in: 0...999_999))")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return d
}
func openFDCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

/// Raw client: sends bytes, optionally half-closes, returns whatever comes back (nil if nothing).
func rawClient(_ path: String, send: Data, closeWrite: Bool = false, waitFor: TimeInterval = 5) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
    var addr = AgentServer.address(for: path)
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return "CONNECT-FAILED" }
    if !send.isEmpty { _ = send.withUnsafeBytes { write(fd, $0.baseAddress!, send.count) } }
    if closeWrite { shutdown(fd, SHUT_WR) }
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, Int32(waitFor * 1000)) > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 8192)
    let n = read(fd, &buf, buf.count)
    return n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : nil
}
let good = Data((#"{"v":1,"op":"get","key":"OpenAI – prod"}"# + "\n").utf8)

do {
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host)
    let server = AgentServer(path: path, controller: c, config: .init(readTimeout: 0.6))
    try server.start()
    var st = stat(); lstat(path, &st)
    check((st.st_mode & 0o777) == 0o600 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid(), "server: socket is owner-only (0600) and ours")
    check(rawClient(path, send: good).flatMap { secretValue(Data($0.utf8)) } == "sk-test-OPENAI-secret-0001", "server: valid request returns the key")
    check(host.approvals.last?.requester.pid == getpid(), "server: requester identified from the connection, not from the message")

    // Malformed input
    check(errorCode(rawClient(path, send: Data("garbage\n".utf8)).map { Data($0.utf8) }) == "bad_request", "server: garbage → bad_request")
    check(rawClient(path, send: Data(repeating: 0x41, count: 20_000)).map { $0.contains("bad_request") } == true, "server: >4 KB without newline → bad_request, not buffered forever")
    check(rawClient(path, send: Data([0xFF, 0x00, 0xFE, 0x0A])).map { $0.contains("bad_request") } == true, "server: binary junk → bad_request")
    check(rawClient(path, send: Data("{\"v\":1,\"op\":\"get\",".utf8), waitFor: 3).map { $0.contains("bad_request") } == true, "server: stalled partial request is cut off after the read timeout")
    check(rawClient(path, send: Data(), closeWrite: true) == nil, "server: silent connection closed without a reply")
    server.stop()
    check(!FileManager.default.fileExists(atPath: path), "server: stop() removes the socket file")
    check(!server.isRunning && rawClient(path, send: good) == "CONNECT-FAILED", "server: nothing listens after stop")
    try server.start(); server.stop(); try server.start(); server.stop()
    check(!FileManager.default.fileExists(atPath: path), "server: can be started and stopped repeatedly")
}
do {   // half-close: indistinguishable from "gone" on macOS, so the request is dropped and no key is sent
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host)
    let server = AgentServer(path: path, controller: c); try server.start()
    let reply = rawClient(path, send: good, closeWrite: true, waitFor: 2)
    check(reply == nil && host.secretCalls == 0, "server: a client that hangs up its sending side right after the request gets no key (documented: keep the connection open)", detail: reply ?? "nil")
    check(rawClient(path, send: Data(#"{"v":1,"op":"get","key":"OpenAI – prod"}"#.utf8), closeWrite: true, waitFor: 2) == nil && host.approveCalls == 0,
          "server: an unfinished request followed by hang-up is dropped without a dialog")
    server.stop()
}
do {   // garbage from one program gets that program blocked
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host)
    let server = AgentServer(path: path, controller: c); try server.start()
    for _ in 0..<3 { _ = rawClient(path, send: Data("junk\n".utf8)) }
    check(rawClient(path, send: good).map { $0.contains("rate_limited") } == true && host.approveCalls == 0, "server: repeated garbage gets the program blocked before any dialog")
    server.stop()
}
do {   // path safety
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let host = FakeHost(); let c = makeController(host)
    let path = dir.appendingPathComponent("a.sock").path

    try "precious".write(toFile: path, atomically: true, encoding: .utf8)
    var failed = false
    do { try AgentServer(path: path, controller: c).start() } catch AgentServerError.pathOccupied { failed = true } catch {}
    check(failed && (try? String(contentsOfFile: path, encoding: .utf8)) == "precious", "path: regular file at the path → refuses to start, file untouched")
    try FileManager.default.removeItem(atPath: path)

    let target = dir.appendingPathComponent("target.txt"); try "keep me".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
    failed = false
    do { try AgentServer(path: path, controller: c).start() } catch AgentServerError.pathOccupied { failed = true } catch {}
    check(failed && (try? String(contentsOf: target, encoding: .utf8)) == "keep me", "path: symlink at the path → refuses, target untouched")
    try FileManager.default.removeItem(atPath: path)

    let first = AgentServer(path: path, controller: c); try first.start()
    failed = false
    do { try AgentServer(path: path, controller: c).start() } catch AgentServerError.alreadyRunning { failed = true } catch {}
    check(failed, "path: a live socket is never stolen")
    first.stop()

    // stale socket (crash): bind, close without unlinking
    let s = socket(AF_UNIX, SOCK_STREAM, 0); var addr = AgentServer.address(for: path)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(s)
    let revived = AgentServer(path: path, controller: c)
    check((try? revived.start()) != nil && rawClient(path, send: good) != nil, "path: stale socket from a crash is replaced")
    revived.stop()

    failed = false
    do { try AgentServer(path: "/tmp/" + String(repeating: "x", count: 120), controller: c).start() } catch AgentServerError.pathTooLong { failed = true } catch {}
    check(failed, "path: over-long path is a clear error, not a silent truncation")
}
do {   // wrong user
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host)
    let server = AgentServer(path: path, controller: c, config: .init(expectedUID: geteuid() &+ 1))
    try server.start()
    check(rawClient(path, send: good, waitFor: 2) == nil && host.approveCalls == 0 && host.secretCalls == 0, "uid check: a caller whose user doesn't match is dropped, host never consulted")
    server.stop()
}
do {   // concurrency cap and flood
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let gate = Gate(); host.approvalHook = { await gate.wait() }
    let c = makeController(host) { $0.maxPendingApprovals = 50 }
    let server = AgentServer(path: path, controller: c, config: .init(readTimeout: 2, maxConcurrent: 3)); try server.start()
    let held = (0..<3).map { _ in Thread { _ = rawClient(path, send: good, waitFor: 8) } }
    held.forEach { $0.start() }
    pause(0.6)
    check(rawClient(path, send: good, waitFor: 2).map { $0.contains("rate_limited") } == true, "cap: with 3 connections in flight, the 4th is refused immediately")
    gate.open()
    pause(1.0)
    check(rawClient(path, send: good).flatMap { secretValue(Data($0.utf8)) } != nil, "cap: server serves again once connections finish")
    server.stop()
}
do {
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host) { $0.globalRequestsPerMinute = 100_000 }
    let server = AgentServer(path: path, controller: c, config: .init(readTimeout: 0.5, maxConcurrent: 8)); try server.start()
    let before = openFDCount()
    let group = DispatchGroup()
    for _ in 0..<40 {
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<10 {   // connect and vanish, or send junk, as fast as possible
                let fd = socket(AF_UNIX, SOCK_STREAM, 0); var addr = AgentServer.address(for: path)
                _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                if Bool.random() { _ = write(fd, "junk\n", 5) }
                close(fd)
            }
            group.leave()
        }
    }
    group.wait()
    pause(1.5)
    check(server.isRunning && rawClient(path, send: good).flatMap { secretValue(Data($0.utf8)) } != nil, "flood: 400 hostile connections later, the server still answers")
    var leaked = 0
    for _ in 0..<5 { pause(0.3); leaked = openFDCount() - before; if leaked <= 1 { break } }
    check(leaked <= 1, "flood: no file descriptors leaked (\(leaked))")
    server.stop()
}
do {   // client disappears while the dialog is open
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let gate = Gate(); host.approvalHook = { await gate.wait() }
    let c = makeController(host)
    let server = AgentServer(path: path, controller: c); try server.start()

    let fd = socket(AF_UNIX, SOCK_STREAM, 0); var addr = AgentServer.address(for: path)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    _ = good.withUnsafeBytes { write(fd, $0.baseAddress!, good.count) }
    pause(0.5)
    close(fd)                                         // hang up while the dialog is showing
    pause(0.3)
    gate.open()
    pause(0.8)
    let snap = await c.snapshot()
    check(host.secretCalls == 0 && snap.grants.isEmpty && snap.log.last?.outcome == .abandoned, "disconnect: user clicks Allow but the key is not fetched, no grant, logged as abandoned")
    server.stop()
}
do {   // 500 sequential requests
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); let c = makeController(host) { $0.globalRequestsPerMinute = 100_000 }
    let server = AgentServer(path: path, controller: c); try server.start()
    let before = openFDCount()
    var allOK = true
    for _ in 0..<500 { if rawClient(path, send: good).flatMap({ secretValue(Data($0.utf8)) }) == nil { allOK = false; break } }
    check(allOK && openFDCount() - before <= 1, "stability: 500 requests in a row, no failures, no descriptor growth")
    server.stop()
}

// MARK: - Python client against the real server

if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
    let dir = shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    let host = FakeHost(); host.defaultDecision = .allow(seconds: 600)
    let c = makeController(host) { $0.failuresBeforeBlock = 100 }
    let server = AgentServer(path: path, controller: c); try server.start()
    let clientDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "agent").path

    func runPython(_ code: String) -> (status: Int32, out: String) {
        let script = scriptDir.appendingPathComponent("client_test_\(UUID().uuidString.prefix(6)).py")
        try! ("import sys; sys.path.insert(0, \(String(reflecting: clientDir)))\nfrom keyvault_client import *\nP = \(String(reflecting: path))\n" + code).write(to: script, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", script.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try! p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    let ok = runPython("print(get_key('OpenAI – prod', reason='integration test', socket_path=P))")
    check(ok.status == 0 && ok.out.trimmingCharacters(in: .whitespacesAndNewlines) == "sk-test-OPENAI-secret-0001", "python: real client gets the key through the real server")
    let seen = host.approvals.last
    check(seen?.requester.program.lowercased().contains("python") == true && seen?.requester.script?.hasSuffix(".py") == true && seen?.reason == "integration test",
          "python: dialog sees the interpreter, the script, and the stated reason",
          detail: "program=\(seen?.requester.program ?? "nil") script=\(seen?.requester.script ?? "nil") reason=\(seen?.reason ?? "nil") out=\(ok.out.prefix(200))")
    let calls = host.approveCalls
    _ = runPython("print(get_key('OpenAI – prod', socket_path=P))")
    check(host.approveCalls == calls + 1, "python: a new process is asked again (grants are per process)")
    let childScript = scriptDir.appendingPathComponent("child_probe.py")
    try! ("import sys; sys.path.insert(0, \(String(reflecting: clientDir)))\nfrom keyvault_client import *\nprint(get_key('OpenAI – prod', socket_path=\(String(reflecting: path)))[:6])\n")
        .write(to: childScript, atomically: true, encoding: .utf8)
    let both = runPython("""
    import subprocess, sys
    print(get_key('OpenAI – prod', socket_path=P)[:6])
    r = subprocess.run([sys.executable, '-I', \(String(reflecting: childScript.path))], capture_output=True, text=True)
    print(r.stdout.strip()[:6], r.returncode)
    """)
    check(both.status == 0 && host.approveCalls == calls + 3 && both.out.contains("sk-tes"),
          "python: a child process can't ride on its parent's grant (it's asked too)",
          detail: "status=\(both.status) approvals=\(host.approveCalls - calls) out=\(both.out.prefix(300))")
    host.defaultDecision = .deny
    let denied = runPython("""
    try:
        get_key('OpenAI – prod', socket_path=P)
    except KeyVaultDenied:
        print('DENIED')
    """)
    check(denied.out.contains("DENIED") && !denied.out.contains("sk-test"), "python: denial raises KeyVaultDenied and reveals nothing")
    let missing = runPython("""
    try:
        get_key('No such key', socket_path=P)
    except KeyVaultDenied:
        print('SAME-AS-DENIED')
    """)
    check(missing.out.contains("SAME-AS-DENIED"), "python: unknown key looks exactly like a refusal")
    server.stop()
} else {
    print("SKIP  python integration (python3 not installed)")
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
}
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

print(failures == 0 ? "\nAll agent tests passed." : "\n\(failures) agent test(s) failed.")
exit(failures == 0 ? 0 : 1)
