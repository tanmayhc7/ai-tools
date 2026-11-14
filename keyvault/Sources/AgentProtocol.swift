import Foundation

/// Wire format for the local agent handoff. One request per connection:
///
///     → {"v":1,"op":"get","key":"OpenAI – production","reason":"agentp session"}\n
///     ← {"ok":true,"secret":"…"}\n          or   {"ok":false,"error":"denied"}\n
///
/// Everything in a request is attacker-controlled, so it is validated strictly and anything
/// shown to the user is sanitised first.
///
/// The client must keep its connection open until the reply arrives: if it hangs up (or shuts
/// down its sending side) before then, the request is dropped and no key is sent.
enum AgentProtocol {
    static let version = 1
    static let maxRequestBytes = 4096
    static let maxKeyNameLength = 256
    static let maxReasonLength = 200

    struct Request: Equatable, Sendable {
        let key: String
        let reason: String?
    }

    enum ParseError: Error, Equatable {
        case tooLarge, notJSON, wrongVersion, unsupportedOperation, badKey, badReason
    }

    enum ErrorCode: String, Sendable {
        /// The user said no, the key doesn't exist, or the name is ambiguous. Deliberately one
        /// code for all three so a caller can't probe which keys exist.
        case denied
        case locked
        case rateLimited = "rate_limited"
        case badRequest = "bad_request"
        case timeout
    }

    static func parse(_ line: Data) -> Result<Request, ParseError> {
        guard line.count <= maxRequestBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let dict = object as? [String: Any] else { return .failure(.notJSON) }
        guard let version = dict["v"] as? Int, version == Self.version else { return .failure(.wrongVersion) }
        guard let op = dict["op"] as? String, op == "get" else { return .failure(.unsupportedOperation) }

        guard let raw = dict["key"] as? String else { return .failure(.badKey) }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= maxKeyNameLength,
              !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .failure(.badKey)
        }

        var reason: String?
        if let r = dict["reason"] {
            guard let s = r as? String, s.count <= maxReasonLength * 4 else { return .failure(.badReason) }
            reason = s
        }
        return .success(Request(key: key, reason: reason))
    }

    // MARK: Matching

    /// Entry names match case-insensitively after Unicode normalisation, so "OpenAI – Prod" finds
    /// "openai – prod" however it was typed. Anything looser (prefixes, accents folded) could make
    /// two different keys answer to one name.
    static func names(_ entry: String, match requested: String) -> Bool {
        func canonical(_ s: String) -> String {
            s.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return canonical(entry) == canonical(requested)
    }

    // MARK: Responses

    static func ok(secret: String) -> Data {
        encode(["ok": true, "secret": secret])
    }

    static func error(_ code: ErrorCode) -> Data {
        encode(["ok": false, "error": code.rawValue])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Sanitising text for display

    /// Makes attacker-controlled text safe to show in an approval dialog: removes control
    /// characters (so it can't fake extra lines), invisible and bidirectional-override characters
    /// (so it can't reorder or hide text), collapses whitespace, and truncates.
    static func sanitize(_ text: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            case .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                out.append(scalar); lastWasSpace = false
            }
        }
        var result = String(out).trimmingCharacters(in: .whitespaces)
        if result.count > maxLength { result = String(result.prefix(maxLength - 1)) + "…" }
        return result
    }
}
