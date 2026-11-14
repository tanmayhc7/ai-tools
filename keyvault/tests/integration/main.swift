import Foundation
import AppKit
import SwiftUI

// Runs the real app model (VaultStore + AgentAccess + StoreHost + server) in a throwaway home
// folder, with a stand-in for the approval window. Never touches the user's real vault.

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
    print("SKIP  integration tests (python3 not installed; it comes with the Command Line Tools)")
    exit(0)
}

// Unix socket paths are limited to 103 bytes, so the fake home has to be short.
let home = "/tmp/kvh-\(UInt32.random(in: 0...999_999))"
try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
setenv("HOME", home, 1); setenv("CFFIXED_USER_HOME", home, 1)
let defaults = UserDefaults.standard
for k in ["agentAccessEnabled", "failedUnlocks", "unlockBlockedUntil", "autoLockMinutes"] { defaults.removeObject(forKey: k) }

var failures = 0
func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)  [\(detail())]")
    if !ok { failures += 1 }
}

let clientDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "agent").path
let renderDir = ProcessInfo.processInfo.environment["KV_RENDER_DIR"]
let work = FileManager.default.temporaryDirectory.appendingPathComponent("kv-int-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

@MainActor
final class FakeApprover: Approving {
    var decision: Decision = .allowOnce
    var hold = false
    private(set) var asked: [ApprovalRequest] = []
    private(set) var cancelCalls = 0
    private var pending: CheckedContinuation<Decision, Never>?

    func ask(_ request: ApprovalRequest) async -> Decision {
        asked.append(request)
        if hold { return await withCheckedContinuation { pending = $0 } }
        return decision
    }
    func cancel() { cancelCalls += 1; pending?.resume(returning: .cancelled); pending = nil }
}

/// Runs a Python snippet (off the main thread) that asks for a key and prints KEY:… or ERR:ClassName.
@Sendable func askPython(_ name: String, reason: String? = nil, socket: String, hold: Double = 0) async -> String {
    let script = work.appendingPathComponent("ask_\(UUID().uuidString.prefix(6)).py")
    let reasonArg = reason.map { String(reflecting: $0) } ?? "None"
    try! """
    import sys
    sys.path.insert(0, \(String(reflecting: clientDir)))
    from keyvault_client import *
    import time
    try:
        print("KEY:" + get_key(\(String(reflecting: name)), reason=\(reasonArg), socket_path=\(String(reflecting: socket))), flush=True)
    except KeyVaultError as e:
        print("ERR:" + type(e).__name__ + ":" + str(e), flush=True)
    time.sleep(\(hold))   # stay alive: a grant belongs to a running process
    """.write(to: script, atomically: true, encoding: .utf8)
    return await withCheckedContinuation { cont in
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", script.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { _ in
            cont.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try! p.run()
    }
}

@MainActor
func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return condition()
}

@MainActor
func runAll() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)            // no Dock icon, nothing visible

    let approver = FakeApprover()
    var config = AccessController.Config()
    config.unlockPromptCooldown = 0
    let store = VaultStore(approver: approver, agentConfig: config)
    let agent = store.agent!
    let socket = AgentAccess.socketPath
    let vaultPath = VaultStore.vaultURL.path
    let password = "integration test password 42"
    check(socket.hasPrefix(home), "setup: running in the throwaway home, not the real one")

    // --- Off by default
    check(!agent.enabled && !FileManager.default.fileExists(atPath: socket), "default: feature is off and no socket exists")

    // --- No vault yet
    agent.setEnabled(true)
    check(agent.enabled && FileManager.default.fileExists(atPath: socket), "enable: socket appears")
    var st = stat(); lstat(socket, &st)
    var dst = stat(); lstat(VaultStore.directoryURL.path, &dst)
    check((st.st_mode & 0o777) == 0o600 && (dst.st_mode & 0o777) == 0o700, "enable: socket 0600 inside a 0700 folder")
    let noVault = await askPython("OpenAI – prod", socket: socket)
    check(noVault.contains("ERR:KeyVaultLocked") && approver.asked.isEmpty && store.unlockRequestNote == nil, "no vault yet: 'locked', no dialog, no unlock prompt", detail: noVault)

    // --- Create the vault
    do { try await store.createVault(password: password) } catch { print("FATAL createVault: \(error)"); exit(2) }
    try! store.add(APIKeyEntry(name: "OpenAI – prod", service: "api.openai.com", secret: "sk-INTEG-" + "OPENAI-0001", notes: ""))
    try! store.add(APIKeyEntry(name: "Stripe", service: "stripe.com", secret: "stripe-INTEG-" + "secret-0002", notes: ""))
    let vaultBefore = try! Data(contentsOf: URL(fileURLWithPath: vaultPath))

    // --- Approved request
    approver.decision = .allowOnce
    var out = await askPython("openai – PROD", reason: "integration test", socket: socket)
    check(out == "KEY:sk-INTEG-OPENAI-0001", "request: approved key arrives (name matched case-insensitively)", detail: out)
    check(approver.asked.last?.entryName == "OpenAI – prod" && approver.asked.last?.reason == "integration test", "request: dialog gets the real entry name and the stated reason")
    check(approver.asked.last?.requester.program.lowercased().contains("python") == true, "request: dialog identifies the Python interpreter")

    // --- Denied / unknown
    approver.decision = .deny
    let denied = await askPython("OpenAI – prod", socket: socket)
    let unknown = await askPython("Nope", socket: socket)
    check(denied.hasPrefix("ERR:KeyVaultDenied") && unknown.hasPrefix("ERR:KeyVaultDenied"), "deny: refusal and unknown key look the same to the program", detail: "\(denied) | \(unknown)")
    check(approver.asked.count == 2, "deny: no dialog for a key that doesn't exist")

    // --- Timed window, then lock revokes it
    approver.decision = .allow(seconds: 600)
    async let holder = askPython("Stripe", socket: socket, hold: 4)
    var granted = false
    for _ in 0..<60 { await agent.refresh(); if !agent.grants.isEmpty { granted = true; break }; try? await Task.sleep(for: .milliseconds(100)) }
    check(granted && agent.grants.first?.entryName == "Stripe", "window: grant recorded and visible to the panel while the program runs")
    store.lock()                                      // the program is still running and holds a live grant
    var cleared = false
    for _ in 0..<60 { await agent.refresh(); if agent.grants.isEmpty { cleared = true; break }; try? await Task.sleep(for: .milliseconds(100)) }
    check(cleared, "lock: a live grant is revoked the moment the vault locks")
    check(store.entries.isEmpty && store.phase == .locked, "lock: vault is locked and entries are gone from memory")
    _ = await holder
    // A program whose grant ended with its process:
    approver.decision = .allow(seconds: 600)

    // --- Request while locked: unlock prompt, user unlocks, then approval
    approver.decision = .allowOnce
    let asksBefore = approver.asked.count
    async let lockedRequest = askPython("OpenAI – prod", socket: socket)
    let noted = await waitUntil(5) { store.unlockRequestNote != nil }
    check(noted && (store.unlockRequestNote ?? "").lowercased().contains("python"), "locked: lock screen explains which program is asking", detail: store.unlockRequestNote ?? "nil")
    check(approver.asked.count == asksBefore, "locked: no approval dialog until the user has unlocked")
    do { try await store.unlock(password: password) } catch { print("FATAL unlock: \(error)"); exit(2) }
    out = await lockedRequest
    check(out == "KEY:sk-INTEG-OPENAI-0001" && approver.asked.count == asksBefore + 1, "locked: after unlocking, the approval dialog is still required", detail: out)
    check(store.unlockRequestNote == nil, "locked: the banner is cleared after unlocking")

    // --- Nobody unlocks
    store.lock()
    StoreHost.unlockWait = 1.5
    let ignored = await askPython("OpenAI – prod", socket: socket)
    StoreHost.unlockWait = 60
    check(ignored.hasPrefix("ERR:KeyVaultLocked") && store.unlockRequestNote == nil, "locked: if nobody unlocks, the program gets 'locked' and the banner goes away", detail: ignored)
    do { try await store.unlock(password: password) } catch { print("FATAL unlock: \(error)"); exit(2) }

    // --- Vault locks while a dialog is open
    approver.hold = true
    async let heldRequest = askPython("OpenAI – prod", socket: socket)
    let opened = await waitUntil(5) { approver.asked.count > asksBefore + 1 }
    store.lock()
    out = await heldRequest
    approver.hold = false
    check(opened && out.hasPrefix("ERR:KeyVaultLocked") && approver.cancelCalls >= 1, "lock during dialog: dialog is dismissed and nothing is released", detail: out)
    do { try await store.unlock(password: password) } catch { print("FATAL unlock: \(error)"); exit(2) }

    // --- Agent activity never changes the vault file
    let vaultAfter = try! Data(contentsOf: URL(fileURLWithPath: vaultPath))
    check(vaultAfter == vaultBefore, "integrity: requests, grants and locking never rewrite the vault file")

    // --- Log
    await agent.refresh()
    check(agent.log.count >= 8 && !String(describing: agent.log).contains("INTEG"), "log: records activity and never contains a key (\(agent.log.count) entries)")

    // --- Switching off removes everything
    approver.decision = .allow(seconds: 600)
    _ = await askPython("Stripe", socket: socket)
    agent.setEnabled(false)
    let afterOff = await askPython("Stripe", socket: socket)
    await agent.refresh()
    check(!FileManager.default.fileExists(atPath: socket) && afterOff.contains("ERR:KeyVaultUnavailable") && afterOff.contains("Agent Access"), "disable: socket removed and the client explains how to turn it on", detail: afterOff)
    check(agent.grants.isEmpty && !defaults.bool(forKey: "agentAccessEnabled"), "disable: grants revoked and the setting is saved")

    // --- Refuses to start on an occupied path
    try! "precious".write(toFile: socket, atomically: true, encoding: .utf8)
    agent.setEnabled(true)
    check(!agent.enabled && agent.statusMessage != nil && (try? String(contentsOfFile: socket, encoding: .utf8)) == "precious" && !defaults.bool(forKey: "agentAccessEnabled"),
          "occupied path: stays off, says why, leaves the file alone", detail: agent.statusMessage ?? "nil")
    try? FileManager.default.removeItem(atPath: socket)
    agent.setEnabled(true)
    check(agent.enabled && defaults.bool(forKey: "agentAccessEnabled") && FileManager.default.fileExists(atPath: socket), "re-enable after clearing the path works and is saved")

    // --- The real approval window object (built but never shown in this headless process)
    let presenter = ApprovalPresenter()
    let sampleRequest = ApprovalRequest(entryName: "Stripe", requester: ProcessInspector.inspect(pid: getpid())!, reason: nil)
    func requestWindow() -> NSWindow? { NSApp.windows.first { $0.title == "KeyVault: key request" && $0.delegate != nil } }

    async let cancelled = presenter.ask(sampleRequest)
    try? await Task.sleep(for: .milliseconds(200))
    let w = requestWindow()
    check(w?.level == .modalPanel && w?.sharingType == NSWindow.SharingType.none && (w as? NSPanel)?.isFloatingPanel == true
          && w?.styleMask.contains(.closable) == true && w?.styleMask.contains(.resizable) == false,
          "window: floats above other windows, hidden from screen capture, not resizable",
          detail: "level=\(w?.level.rawValue ?? -1) (modalPanel=\(NSWindow.Level.modalPanel.rawValue)) sharing=\(w?.sharingType.rawValue ?? 99) floating=\((w as? NSPanel)?.isFloatingPanel ?? false) mask=\(w?.styleMask.rawValue ?? 0)")
    presenter.cancel()
    check(await cancelled == .cancelled && requestWindow() == nil, "window: locking dismisses it with 'cancelled'")

    async let closed = presenter.ask(sampleRequest)
    try? await Task.sleep(for: .milliseconds(200))
    requestWindow()?.close()
    check(await closed == .deny, "window: the close button counts as Deny")

    ApprovalPresenter.timeout = 0.4
    let timed = await presenter.ask(sampleRequest)
    ApprovalPresenter.timeout = 60
    check(timed == .timedOut && requestWindow() == nil, "window: refuses on its own after the timeout")

    async let first = presenter.ask(sampleRequest)
    try? await Task.sleep(for: .milliseconds(150))
    async let second = presenter.ask(sampleRequest)
    try? await Task.sleep(for: .milliseconds(150))
    presenter.cancel()
    let (f, sec) = await (first, second)
    check(f == .cancelled && sec == .cancelled && NSApp.windows.filter({ $0.title == "KeyVault: key request" && $0.isVisible }).isEmpty,
          "window: a second request never stacks a second window (the first is cancelled)")

    // --- Pictures of the windows (never shown on screen)
    if let renderDir {
        try? FileManager.default.createDirectory(atPath: renderDir, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, _ name: String) {
            let r = ImageRenderer(content: view); r.scale = 2
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: renderDir).appendingPathComponent(name))
            }
        }
        let sample = Requester(pid: 4242, startTime: 1, path: "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
                               arguments: ["python3", "-I", "/Users/tanmay/Desktop/agent-platform/src/agentp/main.py", "--model", "claude"],
                               workingDirectory: "/Users/tanmay/Desktop/agent-platform", parentPid: 99, parentPath: "/Applications/Terminal.app/Contents/MacOS/Terminal", signature: .adHoc)
        render(ApprovalView(request: ApprovalRequest(entryName: "Anthropic – production", requester: sample, reason: "agentp session\nFAKE: Allow everything"),
                            deadline: Date().addingTimeInterval(47), windowMinutes: 10, onDecide: { _ in }), "approval.png")
        let evil = Requester(pid: 1, startTime: 1, path: "/tmp/x\u{202E}gnp.exe", arguments: ["x", "payload.sh"], workingDirectory: "/", parentPid: 1, parentPath: "", signature: .unsigned)
        render(ApprovalView(request: ApprovalRequest(entryName: "Anthropic – production", requester: evil, reason: nil),
                            deadline: Date().addingTimeInterval(30), windowMinutes: 10, onDecide: { _ in }), "approval-unsigned.png")
        // Leave one live grant and a varied log for the picture.
        approver.decision = .allow(seconds: 600)
        async let holding = askPython("OpenAI – prod", reason: "agentp", socket: socket, hold: 3)
        for _ in 0..<40 { await agent.refresh(); if !agent.grants.isEmpty { break }; try? await Task.sleep(for: .milliseconds(100)) }
        render(AgentAccessView(scrolls: false).environmentObject(agent), "panel.png")
        _ = await holding
    }

    agent.setEnabled(false)
    try? FileManager.default.removeItem(atPath: home)
    try? FileManager.default.removeItem(at: work)
    print(failures == 0 ? "\nAll integration tests passed." : "\n\(failures) integration test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { @MainActor in await runAll() }
// A real run loop (not just the main queue): SwiftUI's offscreen renderer needs one.
while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
