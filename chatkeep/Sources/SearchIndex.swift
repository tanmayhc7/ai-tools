import Foundation
import SQLite3

struct SearchQuery: Equatable, Sendable {
    var text: String
    var source: ChatSource?
    var role: ChatRole?
    var from: Date?
    var to: Date?
    /// Maximum matching messages to collect.
    var limit = 400
}

struct SearchHit: Equatable, Sendable {
    let conversationID: String
    let messageIndex: Int
    /// A short excerpt around the first match.
    let snippet: String
    /// Character ranges inside `snippet` to emphasise.
    let highlights: [Range<Int>]
}

struct ConversationHit: Identifiable, Equatable, Sendable {
    var id: String { conversationID }
    let conversationID: String
    let title: String
    let source: ChatSource
    let date: Date?
    var matchCount: Int
    var hits: [SearchHit]            // the first few, for preview
}

struct SearchResults: Equatable, Sendable {
    var conversations: [ConversationHit] = []
    var totalMatches = 0
    var truncated = false
    var message: String?
}

/// Full-text search over the unlocked archive, held entirely in memory.
///
/// Nothing is ever written to disk: the SQLite database is `:memory:`, temporary storage is forced
/// to memory too, and all user input is passed as bound parameters (never spliced into SQL).
/// The trigram tokenizer gives substring matching ("api_k" finds "api_key"), case-insensitivity,
/// accent-insensitivity, and CJK support. Words shorter than 3 characters can't use the index and
/// are checked directly against the candidate messages instead.
final class SearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let conversations: [Conversation]
    private let positions: [String: Int]
    private(set) var indexedMessages = 0
    /// False if this SQLite lacks FTS5 trigram support: search then scans linearly (slower, same results).
    private(set) var usesFullTextIndex = false

    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let maxQueryLength = 500
    private static let maxTerms = 8

    init(conversations: [Conversation], isCancelled: () -> Bool = { false }) {
        self.conversations = conversations
        var map: [String: Int] = [:]
        for (i, c) in conversations.enumerated() { map[c.id] = i }
        positions = map

        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
        exec("PRAGMA temp_store=MEMORY; PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-200000;")
        usesFullTextIndex = exec("""
            CREATE VIRTUAL TABLE fts USING fts5(text, tokenize='trigram remove_diacritics 1');
            CREATE TABLE msgs(id INTEGER PRIMARY KEY, conv INTEGER NOT NULL, msg INTEGER NOT NULL,
                              src INTEGER NOT NULL, role INTEGER NOT NULL, t REAL NOT NULL);
            """)
        guard usesFullTextIndex else { return }

        var insertFTS: OpaquePointer?, insertMeta: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO fts(rowid, text) VALUES (?1, ?2)", -1, &insertFTS, nil)
        sqlite3_prepare_v2(db, "INSERT INTO msgs(id, conv, msg, src, role, t) VALUES (?1, ?2, ?3, ?4, ?5, ?6)", -1, &insertMeta, nil)
        defer { sqlite3_finalize(insertFTS); sqlite3_finalize(insertMeta) }

        exec("BEGIN")
        var rowID: Int64 = 0
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        outer: for (ci, c) in conversations.enumerated() {
            if ci % 200 == 0, isCancelled() { break outer }
            let fallbackTime = c.lastActivity?.timeIntervalSince1970 ?? 0
            for (mi, m) in c.messages.enumerated() where !m.text.isEmpty {
                rowID += 1
                sqlite3_reset(insertFTS)
                sqlite3_bind_int64(insertFTS, 1, rowID)
                sqlite3_bind_text(insertFTS, 2, m.text, -1, transient)
                sqlite3_step(insertFTS)

                sqlite3_reset(insertMeta)
                sqlite3_bind_int64(insertMeta, 1, rowID)
                sqlite3_bind_int(insertMeta, 2, Int32(ci)); sqlite3_bind_int(insertMeta, 3, Int32(mi))
                sqlite3_bind_int(insertMeta, 4, c.source == .chatgpt ? 0 : 1)
                sqlite3_bind_int(insertMeta, 5, Self.roleCode(m.role))
                sqlite3_bind_double(insertMeta, 6, m.time?.timeIntervalSince1970 ?? fallbackTime)
                sqlite3_step(insertMeta)
            }
        }
        exec("COMMIT")
        indexedMessages = Int(rowID)
        exec("CREATE INDEX msgs_src ON msgs(src); CREATE INDEX msgs_role ON msgs(role); CREATE INDEX msgs_t ON msgs(t);")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func roleCode(_ r: ChatRole) -> Int32 {
        switch r { case .user: return 0; case .assistant: return 1; case .system: return 2; case .tool: return 3 }
    }

    func conversation(id: String) -> Conversation? { positions[id].map { conversations[$0] } }

    // MARK: Query parsing

    /// Splits what the user typed into words and "quoted phrases". Everything is treated as plain
    /// text: search operators like AND, NEAR, *, ^ or parentheses have no special meaning.
    static func terms(from text: String) -> [String] {
        var terms: [String] = []
        var current = "", inQuote = false
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { terms.append(t) }
            current = ""
        }
        for ch in text.prefix(maxQueryLength) {
            if ch == "\"" { flush(); inQuote.toggle() }
            else if ch.isWhitespace && !inQuote { flush() }
            else { current.append(ch) }
        }
        flush()
        return Array(terms.prefix(maxTerms).map { String($0.prefix(120)) })
    }

    // MARK: Search

    func search(_ query: SearchQuery) -> SearchResults {
        let terms = Self.terms(from: query.text)
        guard !terms.isEmpty else { return SearchResults(message: nil) }

        lock.lock(); defer { lock.unlock() }
        let indexable = terms.filter { $0.unicodeScalars.count >= 3 }

        var candidates: [(conv: Int, msg: Int)] = []
        var truncated = false
        let cap = max(1, min(query.limit, 5000))

        if usesFullTextIndex, !indexable.isEmpty, let rows = ftsCandidates(indexable, query, limit: cap * 4) {
            candidates = rows.map { ($0.0, $0.1) }
            truncated = rows.count >= cap * 4
        } else {
            candidates = linearCandidates(query)
        }

        // Verify against the real text (covers short words and any tokenizer quirks) and build snippets.
        var order: [String] = []
        var groups: [String: ConversationHit] = [:]
        var total = 0
        for (ci, mi) in candidates {
            let conversation = conversations[ci]
            let message = conversation.messages[mi]
            guard let hit = Self.match(message.text, terms: terms, conversationID: conversation.id, messageIndex: mi) else { continue }
            total += 1
            if total > cap { truncated = true; break }
            if var g = groups[conversation.id] {
                g.matchCount += 1
                if g.hits.count < 3 { g.hits.append(hit) }
                groups[conversation.id] = g
            } else {
                order.append(conversation.id)
                groups[conversation.id] = ConversationHit(conversationID: conversation.id, title: conversation.title,
                                                          source: conversation.source, date: conversation.lastActivity,
                                                          matchCount: 1, hits: [hit])
            }
        }
        return SearchResults(conversations: order.compactMap { groups[$0] }, totalMatches: min(total, cap),
                             truncated: truncated, message: nil)
    }

    private func ftsCandidates(_ terms: [String], _ q: SearchQuery, limit: Int) -> [(Int, Int)]? {
        guard let db else { return nil }
        // Every word or phrase becomes one quoted string (embedded quotes doubled), so what the user
        // typed can never be read as search syntax.
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")

        enum Value { case int(Int32), double(Double) }
        var sql = "SELECT m.conv, m.msg FROM fts JOIN msgs m ON m.id = fts.rowid WHERE fts MATCH ?1"
        var values: [(position: Int32, value: Value)] = []
        var next: Int32 = 1
        func add(_ clause: String, _ value: Value) {
            next += 1
            sql += " AND " + clause.replacingOccurrences(of: "?", with: "?\(next)")
            values.append((next, value))
        }
        if let s = q.source { add("m.src = ?", .int(s == .chatgpt ? 0 : 1)) }
        if let r = q.role { add("m.role = ?", .int(Self.roleCode(r))) }
        if let f = q.from { add("m.t >= ?", .double(f.timeIntervalSince1970)) }
        if let t = q.to { add("m.t <= ?", .double(t.timeIntervalSince1970)) }
        next += 1
        sql += " ORDER BY rank LIMIT ?\(next)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        for (position, value) in values {
            switch value {
            case .int(let i): sqlite3_bind_int(stmt, position, i)
            case .double(let d): sqlite3_bind_double(stmt, position, d)
            }
        }
        sqlite3_bind_int(stmt, next, Int32(limit))

        var rows: [(Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append((Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int(stmt, 1)))) }
        return rows
    }

    private func linearCandidates(_ q: SearchQuery) -> [(Int, Int)] {
        var rows: [(Int, Int)] = []
        for (ci, c) in conversations.enumerated() {
            if let s = q.source, c.source != s { continue }
            let fallback = c.lastActivity
            for (mi, m) in c.messages.enumerated() where !m.text.isEmpty {
                if let r = q.role, m.role != r { continue }
                let t = m.time ?? fallback
                if let f = q.from, (t ?? .distantPast) < f { continue }
                if let to = q.to, (t ?? .distantFuture) > to { continue }
                rows.append((ci, mi))
            }
        }
        return rows
    }

    // MARK: Matching and snippets

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FFFF: return true
        default: return false
        }
    }

    /// Words of one or two letters ("AI", "go") would otherwise match inside countless longer words
    /// ("l-ai-t"), so they must stand alone. Languages written without spaces (Chinese, Japanese,
    /// Korean) have no word boundaries, so short terms there are matched as substrings.
    static func needsWholeWord(_ term: String) -> Bool {
        term.unicodeScalars.count < 3 && !term.unicodeScalars.contains(where: isCJK)
    }

    /// First occurrence of `term` at or after `start`, honouring the whole-word rule for short terms.
    static func find(_ term: String, in text: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let wholeWord = needsWholeWord(term)
        var from = start ?? text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: compareOptions, range: from..<text.endIndex) {
            if !wholeWord { return r }
            let beforeOK = r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
            let afterOK = r.upperBound == text.endIndex || !(text[r.upperBound].isLetter || text[r.upperBound].isNumber)
            if beforeOK && afterOK { return r }
            from = text.index(after: r.lowerBound)
        }
        return nil
    }

    static func match(_ text: String, terms: [String], conversationID: String, messageIndex: Int) -> SearchHit? {
        var firstRange: Range<String.Index>?
        for term in terms {
            guard let r = find(term, in: text) else { return nil }
            if firstRange == nil || r.lowerBound < firstRange!.lowerBound { firstRange = r }
        }
        guard let first = firstRange else { return nil }

        let before = 60, after = 90
        let start = text.index(first.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = TextCleaning.display(String(text[start..<end]))
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }

        var highlights: [Range<Int>] = []
        for term in terms {
            var from = excerpt.startIndex
            while from < excerpt.endIndex, let r = find(term, in: excerpt, from: from) {
                let lower = excerpt.distance(from: excerpt.startIndex, to: r.lowerBound)
                highlights.append(lower..<lower + excerpt.distance(from: r.lowerBound, to: r.upperBound))
                from = r.upperBound
                if highlights.count > 40 { break }
            }
        }
        return SearchHit(conversationID: conversationID, messageIndex: messageIndex, snippet: excerpt,
                         highlights: highlights.sorted { $0.lowerBound < $1.lowerBound })
    }
}
