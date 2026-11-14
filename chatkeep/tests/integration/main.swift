import Foundation
import AppKit
import SwiftUI
import CryptoKit

// Runs the real app model (ArchiveStore + BrowserModel + importer + search + leak scan) in a throwaway
// folder with throwaway settings, and photographs the real screens offscreen. It never touches the
// user's real archive, and no window is ever shown.

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
var failures = 0
func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)  [\(detail())]")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("ck-int-\(UUID().uuidString.prefix(8))")
try fm.createDirectory(at: work, withIntermediateDirectories: true)
let suite = "chatkeep.integration.\(UUID().uuidString.prefix(8))"
let defaults = UserDefaults(suiteName: suite)!
let renderDir = ProcessInfo.processInfo.environment["KV_RENDER_DIR"]

// MARK: Fixtures

func gpt(_ id: String, _ title: String, _ turns: [(String, String)], at time: Double) -> [String: Any] {
    var mapping: [String: Any] = ["root": ["id": "root", "parent": NSNull(), "children": ["n0"], "message": NSNull()] as [String: Any]]
    for (i, turn) in turns.enumerated() {
        mapping["n\(i)"] = ["id": "n\(i)", "parent": i == 0 ? "root" : "n\(i - 1)", "children": i + 1 < turns.count ? ["n\(i + 1)"] : [],
                            "message": ["author": ["role": turn.0], "create_time": time + Double(i) * 30,
                                        "content": ["content_type": "text", "parts": [turn.1]], "metadata": [:] as [String: Any]] as [String: Any]] as [String: Any]
    }
    return ["title": title, "conversation_id": id, "create_time": time, "update_time": time + Double(turns.count) * 30,
            "current_node": "n\(turns.count - 1)", "mapping": mapping]
}
func claude(_ id: String, _ title: String, _ turns: [(String, String)], at time: Double) -> [String: Any] {
    let f = ISO8601DateFormatter()
    return ["uuid": id, "name": title, "created_at": f.string(from: Date(timeIntervalSince1970: time)), "updated_at": f.string(from: Date(timeIntervalSince1970: time + 600)),
            "chat_messages": turns.enumerated().map { (i, t) in
                ["uuid": "m\(i)", "sender": t.0 == "user" ? "human" : "assistant", "text": t.1,
                 "created_at": f.string(from: Date(timeIntervalSince1970: time + Double(i) * 30)),
                 "content": [["type": "text", "text": t.1]]] as [String: Any] }]
}
let now = Date().timeIntervalSince1970
// Fake secrets assembled at runtime so this file never contains a literal key.
let leakedOpenAI = "sk-" + "proj-" + String(repeating: "Zk8q", count: 12)
let leakedAWS = "AK" + "IA" + "ZXCVBNMASDFGHJKL"
let vaultToken = "billing-service-token-" + "4d3c2b1a0f9e"
let conversations: [[String: Any]] = [
    gpt("g1", "Fixing my Python deploy script", [("user", "My deploy script keeps failing. Here's the config: AWS_ACCESS_KEY_ID=\(leakedAWS) and also OPENAI_API_KEY=\(leakedOpenAI)"),
        ("assistant", "Thanks. First, never paste live keys. Your deploy script fails because the environment variable isn't exported. Try `export OPENAI_API_KEY=\(leakedOpenAI)` in your shell."),
        ("user", "That worked! Also my corporate card 4111 1111 1111 1111 got declined on the cloud bill, any idea?")], at: now - 86_400 * 3),
    claude("c1", "Pasta carbonara tips", [("user", "How do I keep carbonara from scrambling?"), ("assistant", "Take the pan off the heat before adding the egg mixture, and add a splash of pasta water. The residual heat is enough to thicken it gently.")], at: now - 86_400 * 9),
    gpt("g2", "Quarterly budget email draft", [("user", "Draft an email to jane.doe@example.com about the Q3 budget overrun in marketing"), ("assistant", "Subject: Q3 marketing budget update\n\nHi Jane,\n\nI wanted to flag that marketing is running 12% over budget this quarter...")], at: now - 86_400 * 14),
    claude("c2", "Debugging the OAuth callback", [("user", "My callback gets a 400. Token is \(vaultToken), redirect uri is http://localhost:3000/callback"), ("assistant", "A 400 on the callback usually means the redirect URI doesn't exactly match what's registered. Check for a trailing slash.")], at: now - 86_400 * 20),
    gpt("g3", "Weekend trip to Lisbon", [("user", "Plan a 3 day trip to Lisbon with good food and not too much walking"), ("assistant", "Day 1: Alfama and a long lunch. Day 2: Belém and pastéis de nata. Day 3: LX Factory and the tram to Estrela.")], at: now - 86_400 * 40),
    claude("c3", "Explain Rust lifetimes simply", [("user", "Explain lifetimes like I'm a Python developer"), ("assistant", "A lifetime tells the compiler how long a reference stays valid, so it can prove you never use a value after it's gone. Think of it as the compiler checking dangling pointers at build time.")], at: now - 86_400 * 55),
    gpt("g4", "Résumé review", [("user", "Can you review my résumé summary? Café-style prose is not my strength."), ("assistant", "Lead with impact: replace 'responsible for' with a result and a number.")], at: now - 86_400 * 75),
    claude("c4", "日本語の勉強計画", [("user", "日本語を3ヶ月で勉強する計画を立ててください"), ("assistant", "毎日30分の会話練習と、週に一度の文法の復習をおすすめします。")], at: now - 86_400 * 100),
]

func zipUp(_ name: String, files: [(String, Data)]) throws -> URL {
    let dir = work.appendingPathComponent("src-\(name)"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (n, d) in files { try d.write(to: dir.appendingPathComponent(n)) }
    let out = work.appendingPathComponent(name)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.arguments = ["-q", "-r", out.path, "."]; p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    return out
}
func json(_ objs: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: objs) }

func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
@MainActor func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
    return condition()
}

/// Draws a SwiftUI view into a PNG without ever putting a window on screen.
@MainActor func snapshot<V: View>(_ view: V, size: CGSize, _ name: String, dark: Bool = false) {
    guard let renderDir else { return }
    try? fm.createDirectory(atPath: renderDir, withIntermediateDirectories: true)
    // A window that is never shown has no background of its own and inherits the system appearance,
    // so give it a real window background and a fixed appearance for a faithful picture.
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = appearance
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: renderDir).appendingPathComponent(name)) }
}

@MainActor
func runAll() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let dir = work.appendingPathComponent("archive")
    let store = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
    let browser = BrowserModel(store: store)
    check(store.phase == .setup && !fm.fileExists(atPath: dir.path), "app: a fresh install starts at setup with nothing on disk")
    snapshot(SetupView().environmentObject(store), size: CGSize(width: 520, height: 640), "setup.png")

    do { try await store.create(password: "integration test passphrase 7") } catch { print("FATAL create: \(error)"); exit(2) }
    snapshot(EmptyLibraryView().environmentObject(browser), size: CGSize(width: 760, height: 560), "empty.png")

    // MARK: Import the way a person would: a real zip, with bulky unrelated files inside
    let zipURL: URL
    do {
        zipURL = try zipUp("export.zip", files: [("conversations.json", try json(conversations)), ("chat.html", Data("<html></html>".utf8)),
                                                 ("image.png", Data(repeating: 7, count: 1_500_000)), ("user.json", Data("{\"email\":\"me@example.com\"}".utf8))])
    } catch { print("FATAL zip: \(error)"); exit(2) }
    browser.startImport(zipURL)
    check(browser.presenting == .importExport && browser.importState == .running, "import: starting an import opens the progress sheet")
    browser.startImport(zipURL)         // a second request while one runs must be ignored
    let done = await waitUntil(30) { if case .finished = browser.importState { return true }; return false }
    var outcome = ImportOutcome()
    if case .finished(let o) = browser.importState { outcome = o }
    check(done && outcome.added == 8 && outcome.report.bySource[.chatgpt] == 4 && outcome.report.bySource[.claude] == 4, "import: 8 conversations (4 ChatGPT, 4 Claude) added from the zip", detail: "\(outcome)")
    snapshot(ImportSheet().environmentObject(store).environmentObject(browser), size: CGSize(width: 560, height: 300), "import-done.png")
    browser.finishImport()
    check(browser.presenting == nil && browser.importState == .idle, "import: closing the result sheet resets it")
    check(store.conversations.count == 8 && store.conversations.first?.title == "Fixing my Python deploy script", "library: newest conversation first")
    check(store.conversation(id: "claude:c4")?.title == "日本語の勉強計画", "library: lookup by id")

    browser.startImport(zipURL)
    _ = await waitUntil(30) { if case .finished = browser.importState { return true }; return false }
    if case .finished(let again) = browser.importState { check(again.added == 0 && again.unchanged == 8, "import: the same export again changes nothing") }
    browser.finishImport()

    browser.startImport(work.appendingPathComponent("not-there.zip"))
    _ = await waitUntil(10) { if case .finished = browser.importState { return true }; return false }
    if case .finished(let bad) = browser.importState { check(bad.report.fatalError != nil && store.conversations.count == 8, "import: a missing file is a clear message and changes nothing") }
    browser.finishImport()

    let indexed = await waitUntil(15) { store.index != nil && !store.indexing }
    check(indexed && (store.index?.indexedMessages ?? 0) == 17, "search: index built after the import (\(store.index?.indexedMessages ?? -1) messages)")

    // MARK: Browsing and searching through the real model
    check(browser.browsable.count == 8, "browse: 8 conversations, no filters")
    browser.source = .claude
    check(browser.browsable.count == 4 && browser.browsable.allSatisfy { $0.source == .claude }, "browse: service filter")
    browser.when = .month
    check(browser.browsable.map(\.id).sorted() == ["claude:c1", "claude:c2"], "browse: service + time filters combine (Claude, past month)", detail: "\(browser.browsable.map(\.id))")
    browser.source = nil; browser.when = .any

    browser.query = "carbonara"
    let found = await waitUntil(5) { browser.results?.conversations.count == 1 }
    check(found && browser.results?.conversations.first?.title == "Pasta carbonara tips", "search: typing finds the conversation (debounced)")
    browser.query = "CAFE"
    _ = await waitUntil(5) { browser.results?.conversations.first?.title == "Résumé review" }
    check(browser.results?.conversations.count == 1 && browser.results?.conversations.first?.title == "Résumé review", "search: accent-insensitive (\"CAFE\" finds \"Café\") through the real model")
    browser.query = "日本語"
    _ = await waitUntil(5) { browser.results?.conversations.first?.title == "日本語の勉強計画" }
    check(browser.results?.conversations.count == 1, "search: Japanese")
    browser.query = "localhost"
    _ = await waitUntil(5) { browser.results?.conversations.first?.title == "Debugging the OAuth callback" }
    check(browser.results?.conversations.count == 1, "search: \"localhost\" is found with no speaker filter")
    browser.role = .assistant
    _ = await waitUntil(5) { browser.results?.conversations.isEmpty == true }
    check(browser.results?.conversations.isEmpty == true, "search: speaker filter (\"localhost\" only appears in what I said, so The AI finds nothing)")
    browser.role = .user
    _ = await waitUntil(5) { browser.results?.conversations.count == 1 }
    check(browser.results?.conversations.count == 1, "search: …and Me finds it")
    browser.role = nil

    browser.query = "OPENAI_API"
    _ = await waitUntil(5) { browser.results?.conversations.first?.conversationID == "chatgpt:g1" }
    let hit = browser.results?.conversations.first
    snapshot(SidebarView().environmentObject(store).environmentObject(browser), size: CGSize(width: 380, height: 640), "search.png")
    browser.open(hit!.conversationID, message: hit!.hits.first!.messageIndex)
    check(browser.selectedID == "chatgpt:g1" && browser.focusMessage == hit!.hits.first!.messageIndex && !browser.highlightTerms.isEmpty, "search: opening a hit selects the conversation, the message and the words to highlight")
    snapshot(TranscriptView(conversation: store.conversation(id: "chatgpt:g1")!).environmentObject(store).environmentObject(browser),
             size: CGSize(width: 760, height: 560), "transcript.png")

    browser.query = ""
    check(browser.results == nil && !browser.isSearching && browser.highlightTerms.isEmpty, "search: clearing the box returns to browsing")
    browser.open("claude:c1")
    snapshot(LibraryView().environmentObject(store).environmentObject(browser), size: CGSize(width: 1120, height: 700), "library.png")
    snapshot(LibraryView().environmentObject(store).environmentObject(browser), size: CGSize(width: 1120, height: 700), "library-dark.png", dark: true)

    // MARK: Leak check through the real model
    let leak = LeakModel()
    leak.run(conversations: store.conversations, vault: [VaultSecret(name: "Billing service", secret: vaultToken)])
    let scanned = await waitUntil(15) { leak.phase == .done }
    let labels = leak.groups.map(\.label)
    check(scanned && leak.groups.count == 4, "leak check: 4 distinct items found (OpenAI key, AWS key, card, KeyVault token)", detail: "\(labels)")
    check(leak.groups.first?.vaultEntryName == "Billing service" && leak.groups.first?.kind == .vaultKey, "leak check: your own KeyVault key is listed first")
    check(leak.groups.first { $0.label.contains("OpenAI") }?.findings.count == 2, "leak check: the OpenAI key I pasted and the AI's repeat of it are one item seen twice")
    check(!leak.groups.contains { $0.label == "Email address" }, "leak check: emails aren't flagged unless asked")
    check(leak.groups.allSatisfy { !$0.masked.contains(leakedOpenAI) && !$0.masked.contains(leakedAWS) && !$0.masked.contains(vaultToken) }, "leak check: only masked previews are held")
    snapshot(LeakCheckView().environmentObject(store).environmentObject(browser), size: CGSize(width: 640, height: 640), "leak-options.png")

    // MARK: Delete, lock, unlock
    do { try await store.delete(ids: ["claude:c1"]) } catch { print("delete failed \(error)") }
    check(store.conversations.count == 7 && store.conversation(id: "claude:c1") == nil, "delete: conversation removed")
    browser.query = "carbonara"
    _ = await waitUntil(5) { browser.results != nil }
    _ = await waitUntil(8) { store.index != nil && !store.indexing }
    browser.query = "carbonara "; browser.query = "carbonara"
    _ = await waitUntil(5) { browser.results?.conversations.isEmpty == true }
    check(browser.results?.conversations.isEmpty == true, "delete: it's gone from search results too")

    browser.open("chatgpt:g1")
    browser.presenting = .leakCheck
    store.lock()
    check(store.phase == .locked && store.conversations.isEmpty && store.index == nil, "lock: conversations and index are cleared from memory")
    check(browser.query.isEmpty && browser.selectedID == nil && browser.results == nil && browser.presenting == nil && browser.highlightTerms.isEmpty,
          "lock: the screen state (search, open conversation, sheets) is wiped")
    snapshot(UnlockView().environmentObject(store), size: CGSize(width: 520, height: 520), "unlock.png")

    do { try await store.unlock(password: "integration test passphrase 7") } catch { print("FATAL unlock: \(error)"); exit(2) }
    check(store.phase == .unlocked && store.conversations.count == 7, "unlock: everything is back, including the deletion")
    let reindexed = await waitUntil(15) { store.index != nil && !store.indexing }
    browser.query = "lifetimes"
    let after = await waitUntil(5) { browser.results?.conversations.count == 1 }
    check(reindexed && after, "unlock: search works again right away")

    // MARK: On disk
    let bytes = try! Data(contentsOf: store.fileURL)
    check(bytes.range(of: Data("Pasta".utf8)) == nil && bytes.range(of: Data(leakedAWS.utf8)) == nil && bytes.range(of: Data("lifetimes".utf8)) == nil, "disk: no titles, messages or keys are readable in the archive file")
    let listing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    check(Set(listing).isSubset(of: ["archive.chatkeep", "Backups", ".lock"]), "disk: the archive folder holds only the archive, its backups and a lock file", detail: "\(listing)")

    defaults.removePersistentDomain(forName: suite)
    try? fm.removeItem(at: work)
    print(failures == 0 ? "\nAll app tests passed." : "\n\(failures) app test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { @MainActor in await runAll() }
while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
