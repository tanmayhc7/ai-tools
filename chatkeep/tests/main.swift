import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
var failures = 0
func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)  [\(detail())]")
    if !ok { failures += 1 }
}
func pause(_ s: Double) { usleep(UInt32(s * 1_000_000)) }

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("ck-tests-\(UUID().uuidString.prefix(8))")
try fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

@discardableResult
func run(_ exe: String, _ args: [String], in dir: URL? = nil) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if let dir { p.currentDirectoryURL = dir }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - JSON stream splitter

func split(_ s: String, chunk: Int = 7, max: Int = 1 << 20) throws -> (items: [String], summary: JSONStreamSplitter.Summary) {
    let r = try JSONStreamSplitter.elements(of: Data(s.utf8), maxElementBytes: max, chunkSize: chunk)
    return (r.items.map { String(decoding: $0, as: UTF8.self) }, r.summary)
}
do {
    let r = try split(#"[{"a":1},{"b":[1,2,{"c":"}"}]},  {"s":"quote \" and \\ brace }"}]"#)
    check(r.items == [#"{"a":1}"#, #"{"b":[1,2,{"c":"}"}]}"#, #"{"s":"quote \" and \\ brace }"}"#] && !r.summary.truncated,
          "splitter: objects with braces, quotes and escapes inside strings (tiny chunks)", detail: "\(r.items)")
    check(try split("\u{FEFF}[ ]").items.isEmpty, "splitter: BOM and empty list")
    check(try split("[1, \"x\", null, {\"k\":1}, true]").items == [#""x""#, #"{"k":1}"#], "splitter: scalars skipped, strings and objects kept")
    check(try split("{\"a\":1}\n{\"a\":2}\n{\"a\":3}").items.count == 3, "splitter: JSON Lines / bare objects")
    check(try split("[{\"a\":1},{\"b\":").summary.truncated, "splitter: truncated file is reported")
    check(try split("[{\"a\":1},{\"b\":2}").summary.truncated, "splitter: missing closing bracket is reported")
    let t = try split("[{\"a\":1},{\"b\":2}")
    check(t.items.count == 1 || t.items.count == 2, "splitter: complete elements before the cut are still delivered (\(t.items.count))")
    var threw = false
    do { _ = try split("hello world") } catch { threw = true }
    check(threw, "splitter: non-JSON rejected")
    let big = try split("[{\"x\":\"" + String(repeating: "a", count: 5000) + "\"},{\"y\":1}]", chunk: 100, max: 1000)
    check(big.summary.oversized == 1 && big.items == [#"{"y":1}"#], "splitter: oversized element skipped, not buffered")
    check(try split("[{\"a\":\"é日本語😀\"}]", chunk: 1).items == [#"{"a":"é日本語😀"}"#], "splitter: multi-byte characters split across chunks")
    // deep nesting must not recurse or crash
    let deep = "[" + String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000) + "]"
    check(try split(deep, chunk: 4096, max: 1 << 20).summary.elements == 1, "splitter: 200,000 levels of nesting handled without recursion")
    // property test: random documents round-trip
    func randomJSON(_ depth: Int) -> Any {
        switch Int.random(in: 0..<(depth > 3 ? 4 : 6)) {
        case 0: return Int.random(in: -1000...1000)
        case 1: return ["", "plain", "br}ace{", "q\"uote", "back\\slash", "é日本語😀", "line\nbreak", "]["].randomElement()!
        case 2: return Bool.random()
        case 3: return NSNull()
        case 4: return (0..<Int.random(in: 0...4)).map { _ in randomJSON(depth + 1) }
        default: return Dictionary(uniqueKeysWithValues: (0..<Int.random(in: 0...4)).map { ("k\($0)\(["}", "\"", "x"].randomElement()!)", randomJSON(depth + 1)) })
        }
    }
    var propertyOK = true
    for _ in 0..<300 {
        let docs: [Any] = (0..<Int.random(in: 0...6)).map { _ in ["id": Int.random(in: 0...9), "v": randomJSON(0)] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: docs, options: Bool.random() ? [.prettyPrinted] : [])
        let got = try JSONStreamSplitter.elements(of: data, chunkSize: Int.random(in: 1...64))
        let parsed = try got.items.map { try JSONSerialization.jsonObject(with: $0) as! NSDictionary }
        if parsed != docs.map({ $0 as! NSDictionary }) || got.summary.truncated { propertyOK = false; break }
    }
    check(propertyOK, "splitter: 300 random documents split and parsed back identically at random chunk sizes")
}

// MARK: - ZIP reader (real zip files made by /usr/bin/zip and Python)

func makeZip(_ name: String, files: [(String, Data)], extra: [String] = []) throws -> URL {
    let dir = work.appendingPathComponent("zipsrc-\(UUID().uuidString.prefix(6))")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (n, d) in files {
        let url = dir.appendingPathComponent(n)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url)
    }
    let out = work.appendingPathComponent(name)
    try? fm.removeItem(at: out)
    let r = run("/usr/bin/zip", ["-q", "-r"] + extra + [out.path, "."], in: dir)
    if r.status != 0 { print("zip failed: \(r.out)") }
    return out
}
func pyZip(_ name: String, _ code: String) throws -> URL {
    let out = work.appendingPathComponent(name)
    let script = work.appendingPathComponent("mk_\(UUID().uuidString.prefix(6)).py")
    try ("import zipfile, sys\nout = sys.argv[1]\n" + code).write(to: script, atomically: true, encoding: .utf8)
    let r = run("/usr/bin/python3", ["-I", script.path, out.path])
    if r.status != 0 { print("python zip failed: \(r.out)") }
    return out
}

if fm.isExecutableFile(atPath: "/usr/bin/zip") && fm.isExecutableFile(atPath: "/usr/bin/python3") {
    let json = Data((#"[{"id":"1","title":"é日本"}]"#).utf8)
    let payload = Data(String(repeating: "Lorem ipsum dolor sit amet. ", count: 50_000).utf8)

    let z = try makeZip("basic.zip", files: [("conversations.json", json), ("deep/dir/notes.txt", payload), ("empty.txt", Data())])
    let a = try ZipArchive(path: z.path)
    let names = Set(a.entries.map(\.name))
    check(names.contains("conversations.json") && names.contains("deep/dir/notes.txt") && names.contains("empty.txt"), "zip: lists entries", detail: "\(names)")
    check(try a.read(a.entries.first { $0.name == "conversations.json" }!) == json, "zip: deflated entry round-trips")
    check(try a.read(a.entries.first { $0.name == "deep/dir/notes.txt" }!) == payload, "zip: large compressible entry round-trips")
    check(try a.read(a.entries.first { $0.name == "empty.txt" }!).isEmpty, "zip: empty entry")

    let stored = try makeZip("stored.zip", files: [("conversations.json", json)], extra: ["-0"])
    let sa = try ZipArchive(path: stored.path)
    let storedBytes = try sa.read(sa.entries[0])
    check(sa.entries.first?.method == 0 && storedBytes == json, "zip: stored (uncompressed) entry")

    let z64 = try pyZip("zip64.zip", """
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        with z.open('conversations.json', 'w', force_zip64=True) as f: f.write(b'[{"id":"z64"}]')
        z.writestr('other.txt', 'x')
    """)
    let a64 = try ZipArchive(path: z64.path)
    check((try? a64.read(a64.entries.first { $0.name == "conversations.json" }!)) == Data(#"[{"id":"z64"}]"#.utf8), "zip: ZIP64 entry")

    let comment = try pyZip("comment.zip", """
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('conversations.json', '[1]')
        z.comment = b'PK\\x05\\x06 fake signature in a comment ' * 20
    """)
    check((try? ZipArchive(path: comment.path).entries.count) == 1, "zip: long comment containing a fake end-of-directory marker")

    // Hostile archives
    let slip = try pyZip("slip.zip", """
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr('../../../../tmp/ck-evil/conversations.json', '[{"id":"slip"}]')
        z.writestr('/etc/passwd', 'x')
    """)
    let sl = try ZipArchive(path: slip.path)
    check(sl.entries.contains { $0.baseName == "conversations.json" } && !fm.fileExists(atPath: "/tmp/ck-evil"), "zip: path-traversal names are only labels, nothing is ever written")

    let enc = try pyZip("enc.zip", """
    import struct
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr('conversations.json', '[1]')
    data = bytearray(open(out, 'rb').read())
    # set the 'encrypted' flag in both the local header and the central directory
    data[6] |= 1
    i = data.rfind(b'PK\\x01\\x02'); data[i + 8] |= 1
    open(out, 'wb').write(data)
    """)
    var encErr: ZipError?
    do { let e = try ZipArchive(path: enc.path); _ = try e.read(e.entries[0]) } catch let e as ZipError { encErr = e }
    check({ if case .encrypted = encErr { return true }; return false }(), "zip: password-protected entry gives a clear error", detail: "\(String(describing: encErr))")

    let trunc = work.appendingPathComponent("trunc.zip")
    try Data(contentsOf: z).prefix(60).write(to: trunc)
    var truncErr: Error?
    do { _ = try ZipArchive(path: trunc.path) } catch { truncErr = error }
    check(truncErr != nil, "zip: truncated download is rejected", detail: "\(String(describing: truncErr))")
    let notZip = work.appendingPathComponent("not.zip"); try Data("hello, this is not a zip".utf8).write(to: notZip)
    var notZipErr: ZipError?
    do { _ = try ZipArchive(path: notZip.path) } catch let e as ZipError { notZipErr = e }
    check(notZipErr == .notAZip, "zip: random file rejected as not a zip", detail: "\(String(describing: notZipErr))")
    check((try? ZipArchive(path: work.appendingPathComponent("missing.zip").path)) == nil && (try? ZipArchive(path: work.path)) == nil, "zip: missing file and directory rejected")

    // Corruption: flip one byte in the middle of an entry's compressed data
    for target in ["conversations.json", "deep/dir/notes.txt"] {
        var bytes = try Data(contentsOf: z)
        let e = a.entries.first { $0.name == target }!
        let h = Int(e.localHeaderOffset)
        let nameLen = Int(bytes[h + 26]) | Int(bytes[h + 27]) << 8, extraLen = Int(bytes[h + 28]) | Int(bytes[h + 29]) << 8
        let dataStart = h + 30 + nameLen + extraLen
        bytes[dataStart + Int(e.compressedSize) / 2] ^= 0xFF
        let corruptURL = work.appendingPathComponent("corrupt-\(target.count).zip"); try bytes.write(to: corruptURL)
        var corruptErr: Error?
        do { let c = try ZipArchive(path: corruptURL.path); try c.stream(c.entries.first { $0.name == target }!) { _ in } } catch { corruptErr = error }
        check(corruptErr != nil, "zip: a flipped byte inside “\(target)” is caught (decompression or checksum)", detail: "\(String(describing: corruptErr))")
    }

    // Decompression bomb: tiny on disk, enormous when expanded
    let bomb = try pyZip("bomb.zip", """
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        with z.open('conversations.json', 'w', force_zip64=True) as f:
            chunk = b'0' * (1 << 20)
            for _ in range(600): f.write(chunk)     # 600 MB of zeros, a few hundred KB zipped
    """)
    let ba = try ZipArchive(path: bomb.path)
    let bombEntry = ba.entries[0]
    check(bombEntry.compressedSize < 2_000_000 && bombEntry.uncompressedSize == 600 << 20, "zip: test bomb really is tiny on disk", detail: "\(bombEntry.compressedSize) -> \(bombEntry.uncompressedSize)")
    var bombErr: Error?
    var bombOut = 0
    do { try ba.stream(bombEntry, maxOutput: 100 << 20) { bombOut += $0.count } } catch { bombErr = error }
    check({ if case .tooLarge = bombErr as? ZipError { return true }; return false }() && bombOut <= (101 << 20), "zip: decompression bomb stopped at the limit (\(bombOut >> 20) MB produced)", detail: "\(String(describing: bombErr))")
    let t0 = Date(); var processed = 0
    try ba.stream(bombEntry, maxOutput: 1 << 30) { processed += $0.count }
    check(processed == 600 << 20 && Date().timeIntervalSince(t0) < 20, "zip: 600 MB streamed through a 1 MB buffer in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
} else {
    print("SKIP  zip tests (zip or python3 missing)")
}


// MARK: - Importers

func node(_ id: String, parent: String?, children: [String], message: [String: Any]?) -> [String: Any] {
    ["id": id, "parent": parent as Any? ?? NSNull(), "children": children, "message": message as Any? ?? NSNull()]
}
func gptMessage(_ role: String, _ content: [String: Any], time: Double? = nil, metadata: [String: Any] = [:]) -> [String: Any] {
    var m: [String: Any] = ["author": ["role": role], "content": content, "metadata": metadata]
    if let time { m["create_time"] = time }
    return m
}
func text(_ parts: [Any]) -> [String: Any] { ["content_type": "text", "parts": parts] }

let chatgptConversation: [String: Any] = [
    "title": "Trip planning",
    "create_time": 1_700_000_000.25, "update_time": 1_700_000_900.5,
    "conversation_id": "conv-1", "current_node": "a3",
    "mapping": [
        "root": node("root", parent: nil, children: ["sys"], message: nil),
        "sys": node("sys", parent: "root", children: ["u1"], message: gptMessage("system", text([""]), metadata: ["is_visually_hidden_from_conversation": true])),
        "u1": node("u1", parent: "sys", children: ["a1", "a1b"], message: gptMessage("user", text(["Hello there"]), time: 1_700_000_001)),
        "a1": node("a1", parent: "u1", children: [], message: gptMessage("assistant", text(["OLD regenerated answer"]), time: 1_700_000_002)),
        "a1b": node("a1b", parent: "u1", children: ["u2"], message: gptMessage("assistant", text(["Hi! How can I help?"]), time: 1_700_000_003)),
        "u2": node("u2", parent: "a1b", children: ["a2"], message: gptMessage("user", ["content_type": "multimodal_text", "parts": ["look at this", ["content_type": "image_asset_pointer", "asset_pointer": "file-service://x"]]], time: 1_700_000_004,
                                                                         metadata: ["attachments": [["name": "map.png"]]])),
        "a2": node("a2", parent: "u2", children: ["t1"], message: gptMessage("assistant", ["content_type": "code", "language": "python", "text": "print(1)"], time: 1_700_000_005)),
        "t1": node("t1", parent: "a2", children: ["a3"], message: gptMessage("tool", ["content_type": "execution_output", "text": "1"], time: 1_700_000_006)),
        "a3": node("a3", parent: "t1", children: [], message: gptMessage("assistant", text(["Answer\u{E200}cite\u{E202}turn0search1\u{E201} done."]), time: 1_700_000_007)),
    ] as [String: Any],
]
do {
    let c = ChatImporters.conversation(from: chatgptConversation)
    check(c?.id == "chatgpt:conv-1" && c?.source == .chatgpt && c?.title == "Trip planning", "chatgpt: id, source, title")
    check(c?.created == Date(timeIntervalSince1970: 1_700_000_000.25) && c?.updated == Date(timeIntervalSince1970: 1_700_000_900.5), "chatgpt: dates")
    let texts = c?.messages.map { "\($0.role.rawValue):\($0.text)" }
    check(texts == ["user:Hello there", "assistant:Hi! How can I help?", "user:look at this", "assistant:print(1)", "tool:1", "assistant:Answer done."],
          "chatgpt: follows the active branch only; hidden system message, old regeneration and citation markers dropped", detail: "\(texts ?? [])")
    check(c?.messages[2].note == "1 image · file: map.png", "chatgpt: image and attachment noted", detail: "\(c?.messages[2].note ?? "nil")")
}
do {
    var noCurrent = chatgptConversation; noCurrent["current_node"] = NSNull()
    let c = ChatImporters.conversation(from: noCurrent)
    check(c?.messages.last?.text == "Answer done." && c?.messages.count == 6, "chatgpt: no current_node → latest branch")
    var badCurrent = chatgptConversation; badCurrent["current_node"] = "does-not-exist"
    check(ChatImporters.conversation(from: badCurrent)?.messages.count == 6, "chatgpt: dangling current_node → latest branch")

    // parent cycle must terminate
    let cyc: [String: Any] = ["title": "loop", "current_node": "a", "conversation_id": "cyc", "mapping": [
        "a": node("a", parent: "b", children: [], message: gptMessage("user", text(["one"]), time: 1)),
        "b": node("b", parent: "a", children: ["a"], message: gptMessage("assistant", text(["two"]), time: 2))] as [String: Any]]
    let t0 = Date()
    check(ChatImporters.conversation(from: cyc)?.messages.count == 2 && Date().timeIntervalSince(t0) < 2, "chatgpt: parent cycle doesn't hang")

    check(ChatImporters.conversation(from: ["title": "empty", "mapping": ["r": node("r", parent: nil, children: [], message: nil)] as [String: Any]]) == nil, "chatgpt: conversation with no messages is skipped")
    let weird: [String: Any] = ["title": 12345, "create_time": "1700000000", "id": 99, "mapping": ["x": node("x", parent: nil, children: [], message:
        gptMessage("user", text([5, ["text": "dict part"], "string part", NSNull()]), time: 1_700_000_000_000))] as [String: Any], "current_node": "x"]
    let w = ChatImporters.conversation(from: weird)
    check(w?.id == "chatgpt:99" && w?.title == "12345" && w?.messages[0].text == "dict part\nstring part",
          "chatgpt: wrong types tolerated (numeric id/title, string and ms timestamps, junk parts)", detail: "\(String(describing: w?.title)) | \(String(describing: w?.messages.first?.text))")
    check(w?.created == Date(timeIntervalSince1970: 1_700_000_000), "chatgpt: string epoch seconds parsed")
    let noID = ChatImporters.conversation(from: ["title": "No id", "create_time": 5.0, "mapping": ["x": node("x", parent: nil, children: [], message: gptMessage("user", text(["hi"])))] as [String: Any], "current_node": "x"])
    let noID2 = ChatImporters.conversation(from: ["title": "No id", "create_time": 5.0, "mapping": ["x": node("x", parent: nil, children: [], message: gptMessage("user", text(["hi"])))] as [String: Any], "current_node": "x"])
    check(noID?.id.hasPrefix("chatgpt:gen-") == true && noID?.id == noID2?.id, "chatgpt: missing id gets a stable generated one (re-imports dedupe)")
    let hidden = ChatImporters.conversation(from: ["title": "t", "conversation_id": "h", "current_node": "b", "mapping": [
        "a": node("a", parent: nil, children: ["b"], message: gptMessage("assistant", ["content_type": "thoughts", "thoughts": [["content": "secret reasoning"]]])),
        "b": node("b", parent: "a", children: [], message: gptMessage("user", ["content_type": "user_editable_context", "user_profile": "I am Bob"])),
        "c": node("c", parent: "b", children: [], message: gptMessage("user", text(["visible"])))] as [String: Any]])
    check(hidden == nil, "chatgpt: hidden reasoning and saved-profile text are not imported")
    let huge = ChatImporters.conversation(from: ["title": "big", "conversation_id": "big", "current_node": "x", "mapping": ["x": node("x", parent: nil, children: [], message: gptMessage("user", text([String(repeating: "a", count: 900_000)])))] as [String: Any]])
    check((huge?.messages[0].text.count ?? 0) <= 500_100 && huge?.messages[0].text.hasSuffix("message too long]") == true, "chatgpt: a 900,000-character message is capped")
    var limits = ImportLimits(); limits.maxMappingNodes = 3
    check(ChatImporters.conversation(from: chatgptConversation, limits: limits) == nil, "chatgpt: absurd node count is refused")
    let titled = ChatImporters.conversation(from: ["title": "Line1\nFAKE\u{202E}gnp", "conversation_id": "t", "current_node": "x", "mapping": ["x": node("x", parent: nil, children: [], message: gptMessage("user", text(["hi"])))] as [String: Any]])
    check(titled?.title == "Line1 FAKEgnp", "chatgpt: titles are one line, without direction overrides", detail: titled?.title ?? "nil")
}

let claudeConversation: [String: Any] = [
    "uuid": "c-1", "name": "Recipe ideas", "created_at": "2025-03-01T10:00:00.123456Z", "updated_at": "2025-03-01T10:05:00Z",
    "chat_messages": [
        ["uuid": "m1", "sender": "human", "created_at": "2025-03-01T10:00:00Z",
         "content": [["type": "text", "text": "Make me a pasta recipe"]],
         "text": "Make me a pasta recipe",
         "attachments": [["file_name": "pantry.txt", "extracted_content": "flour, eggs, tomatoes"]], "files": [["file_name": "photo.jpg"]]],
        ["uuid": "m2", "sender": "assistant", "created_at": "2025-03-01T10:00:05Z",
         "content": [["type": "thinking", "thinking": "private chain of thought"], ["type": "text", "text": "Here you go."],
                     ["type": "tool_use", "name": "web_search", "input": ["q": "pasta"]],
                     ["type": "tool_result", "content": [["type": "text", "text": "result text"]]]]],
        ["uuid": "m3", "sender": "robot", "text": "unknown sender is skipped"],
    ] as [Any],
]
do {
    let c = ChatImporters.conversation(from: claudeConversation)
    check(c?.id == "claude:c-1" && c?.source == .claude && c?.title == "Recipe ideas", "claude: id, source, title")
    check(c?.messages.count == 2, "claude: unknown sender skipped", detail: "\(c?.messages.count ?? -1)")
    check(c?.messages[0].text == "Make me a pasta recipe\n[attachment: pantry.txt]\nflour, eggs, tomatoes", "claude: attachment text is included so it can be searched and scanned", detail: c?.messages[0].text ?? "nil")
    check(c?.messages[0].note == "file: pantry.txt · file: photo.jpg" && c?.messages[0].role == .user, "claude: files noted, human → user")
    check(c?.messages[1].text == "Here you go.\n[tool result] result text" && !(c?.messages[1].text.contains("chain of thought") ?? true) && c?.messages[1].note == "tool: web_search", "claude: thinking blocks dropped, tool use and results handled", detail: c?.messages[1].text ?? "nil")
    check(c?.created == ISO8601DateFormatter.fractional.date(from: "2025-03-01T10:00:00.123456Z") && c?.updated != nil, "claude: ISO dates with and without fractions")

    let legacy = ChatImporters.conversation(from: ["uuid": "l", "name": "", "chat_messages": [["sender": "human", "text": "What is a monad?"], ["sender": "assistant", "text": "A burrito."]] as [Any]])
    check(legacy?.messages.count == 2 && legacy?.title == "What is a monad?", "claude: older text-only messages; empty name → title from first question")
    let variant = ChatImporters.conversation(from: ["uuid": "v", "name": "Variant", "messages": [["role": "user", "text": "hi"], ["role": "assistant", "text": "hello"]] as [Any]])
    check(variant?.source == .claude && variant?.messages.map(\.role) == [.user, .assistant], "claude: privacy-export variant (messages / role keys)")
    check(ChatImporters.conversation(from: ["uuid": "e", "name": "x", "chat_messages": [] as [Any]]) == nil, "claude: empty conversation skipped")
    check(ChatImporters.conversation(from: ["random": "object"]) == nil && ChatImporters.conversation(from: [:]) == nil, "detect: unrecognised objects are skipped")
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}

// MARK: - Export reader (zip, folder, single file)

func jsonData(_ objects: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: objects) }
func collect(_ url: URL, limits: ImportLimits = ImportLimits(), cancelAfter: Int? = nil) -> (ImportReport, [Conversation]) {
    var got: [Conversation] = []
    let report = ExportReader.read(url, limits: limits, isCancelled: { if let n = cancelAfter { return got.count >= n }; return false }) { got.append($0) }
    return (report, got)
}
func gptConv(_ id: String, _ title: String) -> [String: Any] {
    var c = chatgptConversation; c["conversation_id"] = id; c["title"] = title; return c
}
func claudeConv(_ id: String) -> [String: Any] { var c = claudeConversation; c["uuid"] = id; return c }

if fm.isExecutableFile(atPath: "/usr/bin/zip") {
    // ChatGPT-style zip: split shards plus bulky unrelated files
    let randomBlob = Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) })
    let gptZip = try makeZip("chatgpt-export.zip", files: [
        ("conversations-000.json", try jsonData([gptConv("g1", "One"), gptConv("g2", "Two")])),
        ("conversations-001.json", try jsonData([gptConv("g3", "Three")])),
        ("chat.html", Data("<html>big</html>".utf8)), ("user.json", Data("{\"email\":\"x@y.z\"}".utf8)),
        ("dalle-generations/file-abc.png", randomBlob), ("export/ignored/conversations.txt", Data("nope".utf8)),
    ])
    var (r, got) = collect(gptZip)
    check(r.fatalError == nil && got.count == 3 && r.bySource[.chatgpt] == 3 && r.filesRead.count == 2, "reader: ChatGPT zip with split shards (3 conversations from 2 files)", detail: "\(r)")
    check(Set(got.map(\.title)) == ["One", "Two", "Three"], "reader: conversations from every shard")

    let claudeZip = try makeZip("claude-export.zip", files: [
        ("conversations.json", try jsonData([claudeConv("k1"), claudeConv("k2")])),
        ("projects.json", Data("[{\"uuid\":\"p\",\"name\":\"proj\"}]".utf8)), ("users.json", Data("[{\"email_address\":\"a@b.c\"}]".utf8)),
    ])
    (r, got) = collect(claudeZip)
    check(got.count == 2 && r.bySource[.claude] == 2 && r.filesRead == ["conversations.json"], "reader: Claude zip (projects.json and users.json are not read)", detail: "\(r)")

    let noConv = try makeZip("nothing.zip", files: [("hello.txt", Data("hi".utf8))])
    (r, got) = collect(noConv)
    check(r.fatalError?.contains("conversations.json") == true && got.isEmpty, "reader: zip without conversations explains what to look for", detail: r.fatalError ?? "nil")
}

do {   // folders and single files
    let folder = work.appendingPathComponent("unzipped"); try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try jsonData([gptConv("f1", "F1")]).write(to: folder.appendingPathComponent("conversations.json"))
    try jsonData([claudeConv("f2")]).write(to: folder.appendingPathComponent("sub/conversations.json"))
    let outside = work.appendingPathComponent("outside-secret.json"); try jsonData([gptConv("evil", "SHOULD NOT BE READ")]).write(to: outside)
    try fm.createSymbolicLink(at: folder.appendingPathComponent("conversations-007.json"), withDestinationURL: outside)
    let (r, got) = collect(folder)
    check(Set(got.map(\.id)) == ["chatgpt:f1", "claude:f2"] && r.bySource[.chatgpt] == 1 && r.bySource[.claude] == 1, "reader: folder with ChatGPT and Claude files; a symlink to outside is never read", detail: "\(got.map(\.id))")

    let single = work.appendingPathComponent("single.json"); try jsonData([gptConv("s1", "Single")]).write(to: single)
    check(collect(single).1.map(\.id) == ["chatgpt:s1"], "reader: a single JSON file")

    let wrapper = work.appendingPathComponent("wrapper.json")
    try JSONSerialization.data(withJSONObject: ["conversations": [gptConv("w1", "W"), claudeConv("w2")]]).write(to: wrapper)
    check(Set(collect(wrapper).1.map(\.id)) == ["chatgpt:w1", "claude:w2"], "reader: {\"conversations\": [...]} wrapper")

    let jsonl = work.appendingPathComponent("lines.json")
    try (try String(decoding: JSONSerialization.data(withJSONObject: gptConv("j1", "J")), as: UTF8.self) + "\n" + String(decoding: JSONSerialization.data(withJSONObject: claudeConv("j2")), as: UTF8.self)).write(to: jsonl, atomically: true, encoding: .utf8)
    check(Set(collect(jsonl).1.map(\.id)) == ["chatgpt:j1", "claude:j2"], "reader: JSON Lines")

    // Damaged inputs
    let whole = try jsonData([gptConv("t1", "T1"), gptConv("t2", "T2"), gptConv("t3", "T3")])
    let cut = work.appendingPathComponent("cut.json"); try whole.prefix(whole.count - 400).write(to: cut)
    let (cr, cg) = collect(cut)
    check(cg.count == 2 && cr.truncatedFiles == ["cut.json"] && cr.fatalError == nil, "reader: file cut off mid-way keeps the 2 complete conversations and says it was cut off", detail: "\(cg.count) \(cr.truncatedFiles)")
    let junk = work.appendingPathComponent("junk.json")
    try Data(("[1,2,\"x\",{\"a\":1},{\"mapping\":5}," + String(decoding: try JSONSerialization.data(withJSONObject: gptConv("ok", "OK")), as: UTF8.self) + ",null]").utf8).write(to: junk)
    let (jr, jg) = collect(junk)
    check(jg.map(\.id) == ["chatgpt:ok"] && jr.emptyOrUnrecognised >= 2, "reader: junk elements are skipped, the valid conversation survives", detail: "\(jr)")
    let emptyFile = work.appendingPathComponent("empty.json"); try Data().write(to: emptyFile)
    check(collect(emptyFile).0.fatalError != nil, "reader: empty file → clear message")
    let text = work.appendingPathComponent("notjson.json"); try Data("this is not json at all".utf8).write(to: text)
    check(collect(text).0.fatalError != nil, "reader: text file → clear message")
    check(collect(work.appendingPathComponent("nope")).0.fatalError == "That file or folder doesn't exist.", "reader: missing path")
    check(collect(work.appendingPathComponent("unzipped/sub")).0.total == 1, "reader: a subfolder works too")

    var tiny = ImportLimits(); tiny.maxConversationBytes = 500
    let (tr, tg) = collect(single, limits: tiny)
    check(tg.isEmpty && tr.oversized == 1, "reader: a conversation over the size limit is skipped and counted", detail: "\(tr)")
    var few = ImportLimits(); few.maxConversations = 2
    check(collect(folder, limits: few).1.count <= 2, "reader: conversation count limit")
    let (xr, xg) = collect(folder, cancelAfter: 1)
    check(xg.count == 1 && xr.cancelled, "reader: cancelling stops the import")
}

if fm.isExecutableFile(atPath: "/usr/bin/zip") {
    // A stored entry with one character changed: the JSON is still valid, but the checksum is not.
    let src = try jsonData([gptConv("c1", "Checksum")])
    let zip = try makeZip("flip.zip", files: [("conversations.json", src)], extra: ["-0"])
    var bytes = try Data(contentsOf: zip)
    let marker = Array("Checksum".utf8)
    if let at = bytes.firstRange(of: Data(marker))?.lowerBound { bytes[at] = UInt8(ascii: "X") }
    let flipped = work.appendingPathComponent("flipped.zip"); try bytes.write(to: flipped)
    let (fr, fg) = collect(flipped)
    check(fg.count == 1 && fr.warnings.contains { $0.lowercased().contains("checksum") }, "reader: a damaged zip entry still imports what was readable, with a warning naming the checksum", detail: "\(fr.warnings)")
}

// Scale: a few thousand conversations
do {
    var blob: [[String: Any]] = []
    for i in 0..<3000 {
        var c = gptConv("scale-\(i)", "Conversation \(i)")
        c["current_node"] = "a3"
        blob.append(c)
    }
    let big = work.appendingPathComponent("big.json"); try jsonData(blob).write(to: big)
    let size = (try fm.attributesOfItem(atPath: big.path)[.size] as? Int) ?? 0
    let t0 = Date()
    let (r, g) = collect(big)
    let dt = Date().timeIntervalSince(t0)
    check(g.count == 3000 && r.fatalError == nil && dt < 30, "reader: 3,000 conversations (\(size >> 20) MB) imported in \(String(format: "%.1f", dt))s")
}


// MARK: - Encrypted archive format

import CryptoKit

let testSalt = try VaultCrypto.randomBytes(16)
let testKey = try VaultCrypto.deriveKey(password: "correct horse battery staple", salt: testSalt, iterations: 600_000)
let otherKey = try VaultCrypto.deriveKey(password: "a different password entirely", salt: testSalt, iterations: 600_000)
func randomBytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

for n in [0, 1, 1023, 1024, 1025, 2048, 5000] {
    let plain = randomBytes(n)
    let sealed = try ArchiveCrypto.seal(plain, key: testKey, salt: testSalt, iterations: 600_000, chunkSize: 1024)
    check((try? ArchiveCrypto.open(sealed, key: testKey)) == plain, "archive: \(n)-byte payload round-trips (1 KB chunks)")
}
do {
    let plain = randomBytes(5000)
    let sealed = try ArchiveCrypto.seal(plain, key: testKey, salt: testSalt, iterations: 600_000, chunkSize: 1024)
    var wrong: Error?
    do { _ = try ArchiveCrypto.open(sealed, key: otherKey) } catch { wrong = error }
    check((wrong as? VaultError).map { if case .wrongPassword = $0 { return true }; return false } == true, "archive: wrong password is reported as a wrong password")
    check(try ArchiveCrypto.seal(plain, key: testKey, salt: testSalt, iterations: 600_000, chunkSize: 1024) != sealed, "archive: fresh nonces, so saving twice never gives the same bytes")
    check(sealed.range(of: plain.prefix(64)) == nil, "archive: the plaintext does not appear in the sealed bytes")

    // Tampering with every part of the file
    var allCaught = true, firstFlip = 0
    let header = try ArchiveCrypto.parseHeader(sealed)
    for position in stride(from: header.bodyOffset, to: sealed.count, by: 97) {
        var t = sealed; t[position] ^= 0x01
        if (try? ArchiveCrypto.open(t, key: testKey)) != nil { allCaught = false; firstFlip = position; break }
    }
    check(allCaught, "archive: flipping any byte of the body is detected (sampled every 97th byte)", detail: "undetected flip at \(firstFlip)")

    var chunkBoundaries: [Int] = []
    var cursor = header.bodyOffset
    while cursor < sealed.count { chunkBoundaries.append(cursor); let len = sealed[cursor..<cursor + 4].reduce(0) { ($0 << 8) | Int($1) }; cursor += 4 + len }
    check(chunkBoundaries.count == header.header.chunks && header.header.chunks == 5, "archive: test file has 5 chunks")
    func chunk(_ i: Int) -> Data { sealed[chunkBoundaries[i]..<(i + 1 < chunkBoundaries.count ? chunkBoundaries[i + 1] : sealed.count)] }
    let head = sealed[0..<header.bodyOffset]

    check((try? ArchiveCrypto.open(sealed.prefix(chunkBoundaries[4]), key: testKey)) == nil, "archive: dropping the last chunk is detected")
    check((try? ArchiveCrypto.open(sealed.prefix(chunkBoundaries[2]), key: testKey)) == nil, "archive: dropping several chunks is detected")
    check((try? ArchiveCrypto.open(sealed + Data([0]), key: testKey)) == nil, "archive: a trailing byte is detected")
    check((try? ArchiveCrypto.open(sealed + chunk(4), key: testKey)) == nil, "archive: appending a copied chunk is detected")
    check((try? ArchiveCrypto.open(Data(head) + chunk(0) + chunk(0) + chunk(2) + chunk(3) + chunk(4), key: testKey)) == nil, "archive: duplicating a chunk in place of another is detected")
    check((try? ArchiveCrypto.open(Data(head) + chunk(0) + chunk(2) + chunk(1) + chunk(3) + chunk(4), key: testKey)) == nil, "archive: swapping two chunks is detected")
    check((try? ArchiveCrypto.open(Data(head) + chunk(1) + chunk(0) + chunk(2) + chunk(3) + chunk(4), key: testKey)) == nil, "archive: swapping the first chunks is detected")
    check((try? ArchiveCrypto.open(Data(), key: testKey)) == nil && (try? ArchiveCrypto.open(Data("CKA1\n".utf8), key: testKey)) == nil
          && (try? ArchiveCrypto.open(Data("not an archive at all".utf8), key: testKey)) == nil, "archive: empty, header-less and foreign files are refused")

    func editHeader(_ transform: (String) -> String) -> Data {
        let text = String(decoding: head.dropFirst(5).dropLast(), as: UTF8.self)
        return Data("CKA1\n".utf8) + Data(transform(text).utf8) + Data("\n".utf8) + sealed[header.bodyOffset...]
    }
    check((try? ArchiveCrypto.open(editHeader { $0.replacingOccurrences(of: "\"iterations\":600000", with: "\"iterations\":1000") }, key: testKey)) == nil, "archive: lowering the iteration count in the header is refused")
    check((try? ArchiveCrypto.open(editHeader { $0.replacingOccurrences(of: "\"chunks\":5", with: "\"chunks\":4") }, key: testKey)) == nil, "archive: changing the chunk count in the header is detected")
    check((try? ArchiveCrypto.open(editHeader { $0.replacingOccurrences(of: "\"plainLength\":5000", with: "\"plainLength\":4999") }, key: testKey)) == nil, "archive: changing the length in the header is detected")
    check((try? ArchiveCrypto.open(editHeader { $0.replacingOccurrences(of: "\"cipher\":\"AES-256-GCM\"", with: "\"cipher\":\"none\"") }, key: testKey)) == nil, "archive: swapping the cipher name is refused")
    check((try? ArchiveCrypto.open(editHeader { $0.replacingOccurrences(of: "\"iterations\":600000", with: "\"iterations\":4000000000") }, key: testKey)) == nil, "archive: an absurd iteration count is refused without hanging")
    check((try? ArchiveCrypto.parseHeader(Data("CKA1\n".utf8) + Data(repeating: 0x41, count: 10_000))) == nil, "archive: a header with no end is refused")
}

// MARK: - Search

func conv(_ id: String, _ source: ChatSource, _ title: String, _ messages: [(ChatRole, String)], at time: TimeInterval = 1_700_000_000) -> Conversation {
    Conversation(id: "\(source.rawValue):\(id)", source: source, title: title, created: Date(timeIntervalSince1970: time),
                 updated: Date(timeIntervalSince1970: time + 100),
                 messages: messages.enumerated().map { ChatMessage(role: $1.0, text: $1.1, time: Date(timeIntervalSince1970: time + Double($0))) })
}
let corpus: [Conversation] = [
    conv("1", .chatgpt, "Config help", [(.user, "Where do I put my api_key for the service?"), (.assistant, "Store the API_KEY in an environment variable, not in code.")], at: 1_700_000_000),
    conv("2", .claude, "Recipes", [(.user, "Give me a café au lait recipe"), (.assistant, "Warm the milk, brew strong coffee, combine.")], at: 1_710_000_000),
    conv("3", .claude, "日本語", [(.user, "日本語のテキストを検索する方法"), (.assistant, "全文検索を使います")], at: 1_720_000_000),
    conv("4", .chatgpt, "Short words", [(.user, "Is AI going to replace me? Please answer no."), (.assistant, "No, AI will not replace you.")], at: 1_730_000_000),
    conv("5", .chatgpt, "Phrases", [(.user, "the quick brown fox jumps over the lazy dog"), (.assistant, "quick fox? brown dog?")], at: 1_740_000_000),
]
let index = SearchIndex(conversations: corpus)
func ids(_ q: String, _ tweak: (inout SearchQuery) -> Void = { _ in }) -> [String] {
    var query = SearchQuery(text: q); tweak(&query)
    return index.search(query).conversations.map { $0.conversationID.split(separator: ":").last.map(String.init)! }.sorted()
}
check(index.usesFullTextIndex && index.indexedMessages == 10, "search: full-text index available and holds all 10 messages", detail: "fts=\(index.usesFullTextIndex) n=\(index.indexedMessages)")
check(ids("api_k") == ["1"], "search: substring (\"api_k\" finds api_key)")
check(ids("API_KEY") == ["1"] && ids("api_key") == ["1"], "search: case-insensitive")
check(ids("cafe") == ["2"] && ids("CAFÉ") == ["2"], "search: accent-insensitive in both directions")
check(ids("日本語") == ["3"] && ids("検索") == ["3"], "search: Japanese text, including 2-character words")
check(ids("quick brown") == ["5"] && ids("brown quick") == ["5"], "search: several words must all appear, in any order")
check(ids("\"quick brown\"") == ["5"] && ids("\"brown quick\"") == [], "search: quoted phrase must appear exactly in that order")
check(ids("AI") == ["4"] && ids("ai replace") == ["4"], "search: words under 3 letters still work, as whole words (\"AI\" is not found inside \"lait\")", detail: "\(ids("AI"))")
check(ids("is") == ["4"], "search: \"is\" finds the word \"Is\", nothing else", detail: "\(ids("is"))")
check(ids("fox ai") == [], "search: terms from different conversations don't combine")
check(ids("zzzzzz") == [] && ids("") == [] && ids("   ") == [], "search: no match, empty and blank queries")
check(ids("milk", { $0.source = .chatgpt }) == [] && ids("milk", { $0.source = .claude }) == ["2"], "search: source filter")
check(ids("replace", { $0.role = .assistant }) == ["4"] && ids("Please", { $0.role = .assistant }) == [] && ids("Please", { $0.role = .user }) == ["4"], "search: speaker filter")
check(ids("the", { $0.from = Date(timeIntervalSince1970: 1_735_000_000) }) == ["5"] && ids("the", { $0.to = Date(timeIntervalSince1970: 1_705_000_000) }) == ["1"], "search: date filters")
let hit = index.search(SearchQuery(text: "environment variable")).conversations.first?.hits.first
check(hit != nil && hit!.highlights.count >= 2 && hit!.highlights.allSatisfy { r in
    let chars = Array(hit!.snippet); let piece = String(chars[r.lowerBound..<r.upperBound]).lowercased(); return piece == "environment" || piece == "variable" },
      "search: highlight ranges line up with the matched words in the snippet", detail: "\(String(describing: hit))")

// Queries that would be operators or injection in a naive implementation
let hostileQueries = ["AND", "OR", "NOT", "NEAR(a b)", "a OR b", "-x", "^api", "api*", "\"", "\"\"\"", "(", ")", ":", "text:api", "*", "'; DROP TABLE fts;--", "\" OR 1=1 --",
                      "api\u{0}key", "\u{202E}api", String(repeating: "api ", count: 500), String(repeating: "a", count: 100_000), "💥💥💥💥", "a b c d e f g h i j k l m n o p"]
var hostileOK = true, hostileFailure = ""
for q in hostileQueries {
    let r = index.search(SearchQuery(text: q))
    if r.conversations.count > 5 { hostileOK = false; hostileFailure = q.prefix(30).description }
}
check(hostileOK, "search: 23 hostile queries (operators, quotes, SQL, NUL, 100 KB) are plain text: no crash, no error", detail: hostileFailure)
let operatorIndex = SearchIndex(conversations: [conv("and1", .claude, "T1", [(.user, "salt and pepper")]), conv("and2", .claude, "T2", [(.user, "just pepper")])])
func operatorIDs(_ q: String) -> [String] { operatorIndex.search(SearchQuery(text: q)).conversations.map(\.conversationID).sorted() }
check(operatorIDs("AND") == ["claude:and1"], "search: \"AND\" is just the letters a-n-d: it finds \"salt and pepper\" and nothing else", detail: "\(operatorIDs("AND"))")
check(operatorIDs("salt OR pepper") == [] && operatorIDs("salt AND pepper") == ["claude:and1"] && operatorIDs("pepper NOT salt") == [], "search: OR / AND / NOT between words are ordinary words that must all be present")
check(ids("a OR b") == [] && ids("api*") == [] && ids("NEAR(api key)") == [] && ids("-api") == [] && ids("^api") == [], "search: OR, *, NEAR, - and ^ are ordinary characters")
let afterHostile = index.search(SearchQuery(text: "api"))
check(afterHostile.conversations.count == 1 && afterHostile.totalMatches == 2 && afterHostile.message == nil, "search: still working after the hostile queries")

// Scale and "nothing touches the disk"
do {
    let before = Set((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
    let beforeCwd = Set((try? fm.contentsOfDirectory(atPath: fm.currentDirectoryPath)) ?? [])
    var many: [Conversation] = []
    let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
    for i in 0..<4000 {
        many.append(conv("big\(i)", i % 2 == 0 ? .chatgpt : .claude, "Chat \(i)",
                         (0..<20).map { (m: Int) -> (ChatRole, String) in (m % 2 == 0 ? .user : .assistant, "message \(m) of chat \(i) mentions \(words[(i + m) % 10]) and \(words[(i * 3 + m) % 10]) with filler text to make it longer " + String(repeating: "lorem ipsum ", count: 12)) }))
    }
    many.append(conv("needle", .claude, "Needle", [(.user, "the unique-needle-token-7391 appears once")]))
    let t0 = Date()
    let big = SearchIndex(conversations: many)
    let buildTime = Date().timeIntervalSince(t0)
    let t1 = Date()
    let found = big.search(SearchQuery(text: "unique-needle-token-7391"))
    let common = big.search(SearchQuery(text: "alpha charlie"))
    let queryTime = Date().timeIntervalSince(t1)
    check(found.conversations.count == 1 && found.conversations[0].title == "Needle", "search: a single needle among 80,000 messages is found")
    check(common.truncated && common.totalMatches > 0, "search: a very common query is capped and flagged as truncated")
    check(buildTime < 40, "search: 80,000 messages (\(String(format: "%.0f", Double(many.reduce(0) { $0 + $1.characterCount }) / 1_048_576)) MB of text) indexed in \(String(format: "%.1f", buildTime))s")
    check(queryTime < 2, "search: both queries answered in \(String(format: "%.0f", queryTime * 1000)) ms")
    let after = Set((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
    let afterCwd = Set((try? fm.contentsOfDirectory(atPath: fm.currentDirectoryPath)) ?? [])
    check(after.subtracting(before).filter { !$0.hasPrefix("ck-tests-") }.isEmpty && afterCwd == beforeCwd, "search: building and querying the index writes no files anywhere (temp folder and working folder unchanged)", detail: "\(after.subtracting(before))")
}

// MARK: - Leak scan

func fakeKey(_ prefix: String, _ body: String, _ n: Int) -> String { prefix + String(repeating: body, count: n) }
let openaiKey = fakeKey("sk-" + "proj-", "Ab3x", 12)
let awsKey = "AK" + "IA" + "QWERTYUIOPASDFGH"
let cardNumber = "4111 1111 1111 1111"
let vaultOnly = "internal-service-token-" + "9f8e7d6c5b4a"
let leakCorpus: [Conversation] = [
    conv("l1", .chatgpt, "Debugging", [(.user, "my key is \(openaiKey) and it fails"), (.assistant, "Don't share \(openaiKey) publicly; rotate it."), (.user, "ok. my card is \(cardNumber) lol")]),
    conv("l2", .claude, "More debugging", [(.user, "again: \(openaiKey) and aws \(awsKey)"), (.user, "email me at jane.doe@example.com from 10.20.30.40"), (.user, "token: \(vaultOnly)")]),
    conv("l3", .chatgpt, "Clean chat", [(.user, "How do I make bread?"), (.assistant, "Mix flour, water, salt and yeast. Order 4111 1111 1111 1112 is not a card number.")]),
]
do {
    var options = LeakOptions()
    let r = LeakScanner.scan(leakCorpus, options: options)
    let groups = r.groups
    let kinds = groups.map { $0.label }
    check(r.scannedConversations == 3 && r.scannedMessages == 8, "leak scan: counts conversations and messages", detail: "\(r.scannedConversations) \(r.scannedMessages)")
    let openai = groups.first { $0.label.contains("OpenAI") }
    check(openai?.findings.count == 3 && openai?.conversationCount == 2, "leak scan: one key seen 3 times in 2 chats is one group", detail: "\(kinds)")
    check(groups.contains { $0.label.contains("AWS") } && groups.contains { $0.label == "Card number" }, "leak scan: AWS key and a valid card number found")
    check(!groups.contains { $0.label == "Email address" } && !groups.contains { $0.label == "IP address" }, "leak scan: emails and IP addresses are off by default")
    check(!r.findings.contains { $0.conversationID == "chatgpt:l3" }, "leak scan: invalid card number and ordinary chat produce nothing")
    check(r.findings.allSatisfy { !$0.masked.contains(openaiKey) && !$0.masked.contains(awsKey) && !$0.masked.contains("4111 1111") }, "leak scan: findings keep only masked previews")
    check(groups.first?.kind == .secret, "leak scan: keys sort ahead of other kinds")

    options.emails = true; options.ipAddresses = true
    let more = LeakScanner.scan(leakCorpus, options: options).groups.map(\.label)
    check(more.contains("Email address") && more.contains("IP address"), "leak scan: emails and IP addresses when switched on")

    options = LeakOptions(); options.includeAIReplies = false
    check(LeakScanner.scan(leakCorpus, options: options).groups.first { $0.label.contains("OpenAI") }?.findings.count == 2, "leak scan: can skip AI replies")
    options = LeakOptions(); options.secrets = false; options.financialAndID = false
    check(LeakScanner.scan(leakCorpus, options: options).findings.isEmpty, "leak scan: every category can be switched off")

    options = LeakOptions(); options.vault = [VaultSecret(name: "Internal", secret: vaultOnly), VaultSecret(name: "OpenAI prod", secret: openaiKey), VaultSecret(name: "Tiny", secret: "short")]
    let withVault = LeakScanner.scan(leakCorpus, options: options).groups
    check(withVault.first { $0.kind == .vaultKey }?.vaultEntryName == "Internal", "leak scan: your own key in an unrecognisable format is found by exact match")
    check(withVault.first { $0.label.contains("OpenAI") }?.vaultEntryName == "OpenAI prod" && withVault.filter { $0.label.contains("OpenAI") || $0.vaultEntryName == "OpenAI prod" }.count == 1, "leak scan: a recognised key that is also in KeyVault is tagged, not duplicated")
    check(!withVault.contains { $0.vaultEntryName == "Tiny" }, "leak scan: very short KeyVault entries are ignored (they'd match ordinary words)")
    check(withVault.first?.kind == .vaultKey, "leak scan: your own KeyVault keys sort first")

    var stopAt = 0
    let cancelled = LeakScanner.scan(Array(repeating: leakCorpus, count: 200).flatMap { $0 }, options: LeakOptions(), isCancelled: { stopAt += 1; return stopAt > 5 })
    check(cancelled.cancelled && cancelled.scannedConversations < 600, "leak scan: can be cancelled")
    check(LeakScanner.fingerprint(openaiKey) == LeakScanner.fingerprint(openaiKey) && LeakScanner.fingerprint(openaiKey) != LeakScanner.fingerprint(awsKey), "leak scan: fingerprints are stable and distinct")
    let t = Date()
    let large = LeakScanner.scan((0..<4000).map { conv("p\($0)", .chatgpt, "c", [(.user, "just an ordinary message about cooking pasta number \($0) " + String(repeating: "lorem ipsum ", count: 40))]) }, options: LeakOptions())
    check(large.findings.isEmpty && Date().timeIntervalSince(t) < 15, "leak scan: 4,000 ordinary conversations scanned clean in \(String(format: "%.1f", Date().timeIntervalSince(t)))s (no false positives)")
}

// MARK: - Archive store (real files in a throwaway folder)

@MainActor func tempStore(_ name: String) -> (store: ArchiveStore, dir: URL, defaults: UserDefaults, suite: String) {
    let dir = work.appendingPathComponent("store-\(name)")
    let suite = "chatkeep.tests.\(name).\(UUID().uuidString.prefix(6))"
    let d = UserDefaults(suiteName: suite)!
    return (ArchiveStore(directory: dir, defaults: d, installSystemHooks: false), dir, d, suite)
}
func exportFolder(_ name: String, _ convs: [[String: Any]]) throws -> URL {
    let folder = work.appendingPathComponent("export-\(name)"); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try jsonData(convs).write(to: folder.appendingPathComponent("conversations.json"))
    return folder
}
let pw = "correct horse battery staple"

do {
    let (store, dir, defaults, suite) = tempStore("main")
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    check(store.phase == .setup, "store: starts in setup when there is no archive")
    try await store.create(password: pw)
    var st = stat(); lstat(store.fileURL.path, &st); var dst = stat(); lstat(dir.path, &dst)
    check(store.phase == .unlocked && (st.st_mode & 0o777) == 0o600 && (dst.st_mode & 0o777) == 0o700, "store: created, file 0600 in a 0700 folder")

    let exportA = try exportFolder("a", [gptConv("s1", "Secret project plans"), gptConv("s2", "Holiday ideas"), claudeConv("s3")])
    var outcome = try await store.importExport(from: exportA)
    check(outcome.added == 3 && outcome.updated == 0 && store.conversations.count == 3, "store: first import adds 3 conversations", detail: "\(outcome)")
    outcome = try await store.importExport(from: exportA)
    check(outcome.added == 0 && outcome.unchanged == 3, "store: importing the same export again changes nothing")
    var grown = gptConv("s1", "Secret project plans")
    var mapping = grown["mapping"] as! [String: Any]
    mapping["a4"] = node("a4", parent: "a3", children: [], message: gptMessage("assistant", text(["A newer reply"]), time: 1_700_000_100)); grown["mapping"] = mapping
    mapping["a3"] = node("a3", parent: "t1", children: ["a4"], message: gptMessage("assistant", text(["Answer done."]), time: 1_700_000_007)); grown["mapping"] = mapping
    grown["current_node"] = "a4"
    outcome = try await store.importExport(from: try exportFolder("grown", [grown]))
    check(outcome.updated == 1 && outcome.added == 0 && store.conversations.first { $0.id == "chatgpt:s1" }?.messages.last?.text == "A newer reply", "store: a conversation that gained messages is updated")
    let older = try await store.importExport(from: exportA)
    check(older.updated == 0 && older.unchanged == 3, "store: an older export never overwrites newer history")

    // On disk: encrypted, no plaintext
    let onDisk = try Data(contentsOf: store.fileURL)
    check(onDisk.range(of: Data("Secret project plans".utf8)) == nil && onDisk.range(of: Data("Hello there".utf8)) == nil && onDisk.range(of: Data("Recipe".utf8)) == nil,
          "store: titles and message text do not appear anywhere in the archive file")
    check(!(try fm.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".json") || $0.hasSuffix(".tmp") }), "store: no stray plaintext or temp files next to the archive", detail: "\((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])")

    // Lock and unlock
    store.lock()
    check(store.phase == .locked && store.conversations.isEmpty && store.index == nil, "store: locking clears conversations and the search index from memory")
    var lockedErr: Error?
    do { _ = try await store.importExport(from: exportA) } catch { lockedErr = error }
    check(lockedErr != nil, "store: importing while locked is refused")

    let again = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
    check(again.phase == .locked, "store: a fresh launch finds the archive and starts locked")
    var wrongErr: Error?
    do { try await again.unlock(password: "not the password!!") } catch { wrongErr = error }
    check(wrongErr != nil && again.phase == .locked, "store: wrong password is refused")
    try await again.unlock(password: pw)
    check(again.phase == .unlocked && again.conversations.count == 3, "store: right password restores everything across launches")
    try await Task.sleep(for: .seconds(2))
    check(again.index?.indexedMessages ?? 0 > 10 && again.index?.search(SearchQuery(text: "A newer reply")).conversations.count == 1, "store: search index is rebuilt after unlocking", detail: "\(again.index?.indexedMessages ?? -1)")

    // Throttle
    let (t1, _, _, tsuite) = tempStore("throttle"); defer { UserDefaults().removePersistentDomain(forName: tsuite) }
    try await t1.create(password: pw); t1.lock()
    for _ in 0..<3 { _ = try? await t1.unlock(password: "wrong wrong wrong") }
    var throttled = false
    do { try await t1.unlock(password: pw) } catch VaultError.throttled { throttled = true } catch {}
    check(throttled && t1.unlockBlockedUntil != nil, "store: 3 wrong passwords lock out even the right one for a while")

    // Delete and tombstones
    try await again.delete(ids: ["chatgpt:s2"])
    check(again.conversations.count == 2 && !again.conversations.contains { $0.id == "chatgpt:s2" }, "store: delete removes a conversation")
    let reimport = try await again.importExport(from: exportA)
    check(reimport.skippedDeleted == 1 && !again.conversations.contains { $0.id == "chatgpt:s2" }, "store: re-importing an export doesn't bring a deleted conversation back")
    again.lock()
    let third = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
    try await third.unlock(password: pw)
    check(third.conversations.count == 2, "store: deletions survive a restart")

    // Backups
    for i in 0..<5 { _ = try await third.importExport(from: try exportFolder("b\(i)", [gptConv("extra\(i)", "Extra \(i)")])); try await Task.sleep(for: .milliseconds(1100)) }
    let backups = third.backupFiles
    var bst = stat(); if let b = backups.first { lstat(b.path, &bst) }
    check(backups.count == 3 && (bst.st_mode & 0o777) == 0o600, "store: only the 3 newest encrypted backups are kept, each 0600", detail: "\(backups.count)")

    // Change password
    try await third.changePassword(current: pw, new: "an entirely new passphrase 2026")
    third.lock()
    let fourth = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
    var oldErr: Error?
    do { try await fourth.unlock(password: pw) } catch { oldErr = error }
    check(oldErr != nil, "store: the old password stops working after a change")
    try await fourth.unlock(password: "an entirely new passphrase 2026")
    check(fourth.conversations.count == 7 && fourth.backupFiles.isEmpty, "store: new password opens everything; backups made under the old password are removed")
    var badChange: Error?
    do { try await fourth.changePassword(current: "wrong current password", new: "whatever passphrase here 1") } catch { badChange = error }
    check(badChange != nil, "store: changing the password needs the current one")

    // A failed import must change nothing
    let hashBefore = SHA256.hash(data: try Data(contentsOf: fourth.fileURL))
    let nothing = work.appendingPathComponent("nothing-here"); try fm.createDirectory(at: nothing, withIntermediateDirectories: true)
    let failed = try await fourth.importExport(from: nothing)
    let hashAfter = SHA256.hash(data: try Data(contentsOf: fourth.fileURL))
    check(failed.report.fatalError != nil && failed.added == 0 && hashAfter == hashBefore, "store: an import that finds nothing leaves the archive file untouched")
    let missingOutcome = try await fourth.importExport(from: work.appendingPathComponent("missing-export"))
    check(missingOutcome.report.fatalError != nil, "store: a missing export is a clear message, not a crash")
}

do {   // damaged archive files
    let (store, dir, defaults, suite) = tempStore("damage"); defer { UserDefaults().removePersistentDomain(forName: suite) }
    try await store.create(password: pw)
    _ = try await store.importExport(from: try exportFolder("d", [gptConv("d1", "Damage test")]))
    store.lock()
    let good = try Data(contentsOf: store.fileURL)
    func attempt(_ bytes: Data, _ label: String, expectWrongPassword: Bool = false) async {
        try? bytes.write(to: store.fileURL)
        let s = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
        var err: Error?
        do { try await s.unlock(password: pw) } catch { err = error }
        check(err != nil && s.phase == .locked && s.conversations.isEmpty, "store: \(label) is refused, with nothing loaded", detail: "\(String(describing: err))")
        defaults.removeObject(forKey: "ck.failedUnlocks"); defaults.removeObject(forKey: "ck.unlockBlockedUntil")
    }
    var flipped = good; flipped[flipped.count - 5] ^= 0x01
    await attempt(flipped, "an archive with a flipped byte")
    await attempt(good.prefix(good.count - 50), "a truncated archive")
    await attempt(good + Data([1, 2, 3]), "an archive with trailing bytes")
    await attempt(Data("{\"entries\":[]}".utf8), "a KeyVault file or other JSON in its place")
    await attempt(Data(), "an empty file")
    await attempt(randomBytes(5000), "random bytes")
    try good.write(to: store.fileURL)
    let recovered = ArchiveStore(directory: dir, defaults: defaults, installSystemHooks: false)
    try await recovered.unlock(password: pw)
    check(recovered.conversations.count == 1, "store: the original file still opens, so damage tests changed nothing")

    // restore from a backup
    _ = try await recovered.importExport(from: try exportFolder("d2", [gptConv("d2", "Second")]))
    try await Task.sleep(for: .milliseconds(1100))
    _ = try await recovered.importExport(from: try exportFolder("d3", [gptConv("d3", "Third")]))
    let backup = recovered.backupFiles.first!          // newest backup: taken just before the last import (2 conversations)
    try recovered.restore(from: backup)
    check(recovered.phase == .locked, "store: restoring a backup locks the archive")
    try await recovered.unlock(password: pw)
    check(recovered.conversations.count == 2, "store: restored archive holds the state before the last import (\(recovered.conversations.count) of 3 conversations)")
    var restoreErr: Error?
    do { try recovered.restore(from: work.appendingPathComponent("conversations-nope.json")) } catch { restoreErr = error }
    do { let junk = work.appendingPathComponent("junk.chatkeep"); try Data("junk".utf8).write(to: junk); try recovered.restore(from: junk) } catch { restoreErr = error }
    check(restoreErr != nil, "store: restoring from a junk file is refused")
}

do {   // locking while an import is running
    let (store, _, _, suite) = tempStore("race"); defer { UserDefaults().removePersistentDomain(forName: suite) }
    try await store.create(password: pw)
    var blob: [[String: Any]] = []
    for i in 0..<2000 { blob.append(gptConv("race\(i)", "Race \(i)")) }
    let before = try Data(contentsOf: store.fileURL)
    let folder = try exportFolder("race", blob)
    let task = Task { try await store.importExport(from: folder) }
    try await Task.sleep(for: .milliseconds(30))
    store.lock()
    var raceErr: Error?
    do { _ = try await task.value } catch { raceErr = error }
    let after = try Data(contentsOf: store.fileURL)
    check(store.phase == .locked && store.conversations.isEmpty && (raceErr != nil || after != before), "store: locking mid-import never leaves the vault open or half-written")
    let reopened = ArchiveStore(directory: store.directory, defaults: UserDefaults(suiteName: suite)!, installSystemHooks: false)
    try await reopened.unlock(password: pw)
    check(reopened.conversations.count == 0 || reopened.conversations.count == 2000, "store: after a lock mid-import the archive is either unchanged or fully updated (\(reopened.conversations.count))")
}

print(failures == 0 ? "\nAll chatkeep tests passed." : "\n\(failures) chatkeep test(s) failed.")
exit(failures == 0 ? 0 : 1)
