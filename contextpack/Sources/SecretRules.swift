import Foundation

// Shared secret-detection rules (identical copy in leakguard/, redact/ and contextpack/
// so each tool builds on its own). Keep the copies in sync.

struct SecretRule: Sendable {
    let id: String
    let name: String
    let regex: NSRegularExpression
    /// Capture group holding the secret itself (0 = whole match).
    let group: Int
    /// Generic rules only fire on random-looking values.
    let needsEntropy: Bool
}

struct SecretMatch: Hashable, Sendable {
    let ruleID: String
    let ruleName: String
    let range: Range<String.Index>
    let value: String
}

enum SecretRules {
    private static func rule(_ id: String, _ name: String, _ pattern: String,
                             group: Int = 0, entropy: Bool = false) -> SecretRule {
        // Patterns are compile-time constants covered by tests; a bad one is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        return SecretRule(id: id, name: name, regex: regex, group: group, needsEntropy: entropy)
    }

    /// Ordered: when two rules overlap, the earlier (more specific) one wins.
    /// Every repetition has an upper bound: unbounded `{n,}` / `*` let crafted input
    /// (e.g. "token" repeated a million times) take quadratic time.
    static let all: [SecretRule] = [
        // Matches the BEGIN line; scan() extends it to the matching END line (see privateKeyEnds).
        rule("private-key", "Private key", #"-----BEGIN [A-Z0-9 ]{0,20}PRIVATE KEY[A-Z ]{0,10}-----"#),
        rule("anthropic", "Anthropic API key", #"\bsk-ant-[A-Za-z0-9_\-]{32,250}"#),
        rule("openai", "OpenAI API key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{32,250}"#),
        rule("aws-access-key", "AWS access key ID", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("aws-secret", "AWS secret access key",
             #"(?i)aws.{0,20}?(?:secret|private).{0,20}?['"=:\s]{1,6}([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+])"#, group: 1),
        rule("github-token", "GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,255}\b"#),
        rule("github-pat", "GitHub fine-grained token", #"\bgithub_pat_[A-Za-z0-9_]{60,255}\b"#),
        rule("gitlab", "GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,100}\b"#),
        rule("slack-token", "Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,250}\b"#),
        rule("slack-webhook", "Slack webhook URL", #"https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,200}"#),
        rule("stripe", "Stripe live key", #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,250}\b"#),
        rule("google", "Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        rule("huggingface", "Hugging Face token", #"\bhf_[A-Za-z0-9]{30,100}\b"#),
        rule("groq", "Groq API key", #"\bgsk_[A-Za-z0-9]{40,100}\b"#),
        rule("replicate", "Replicate token", #"\br8_[A-Za-z0-9]{30,100}\b"#),
        rule("sendgrid", "SendGrid key", #"\bSG\.[A-Za-z0-9_\-]{16,100}\.[A-Za-z0-9_\-]{16,100}\b"#),
        rule("twilio", "Twilio API key", #"\bSK[0-9a-fA-F]{32}\b"#),
        rule("npm", "npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        rule("db-url", "Database password in URL",
             #"\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?)://[^:\s/@]{1,64}:([^@\s/]{3,128})@"#, group: 1),
        rule("generic", "Possible secret",
             #"(?i)(?:api[_\-]?key|apikey|secret|token|passwd|password|access[_\-]?key|client[_\-]?secret|auth[_\-]?key)[A-Za-z0-9_\-]{0,30}["']?\s{0,5}[:=]\s{0,5}["']([^"'\s]{16,200})["']"#,
             group: 1, entropy: true),
    ]

    /// Texts larger than this are scanned in overlapping windows, so one huge minified line
    /// can't make the regex engine run away.
    static let windowSize = 1_000_000

    /// Cheap pre-check: every rule needs one of these substrings (case-insensitive).
    private static let triggers = ["sk-", "akia", "asia", "aws", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
                                   "github_pat_", "glpat-", "xox", "hooks.slack", "_live_", "aiza", "hf_",
                                   "gsk_", "r8_", "sg.", "sk", "npm_", "://", "private key", "key",
                                   "secret", "token", "pass", "auth"]

    static func mightContainSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        return triggers.contains { lower.contains($0) }
    }

    static func scan(_ text: String) -> [SecretMatch] {
        guard !text.isEmpty, mightContainSecret(text) else { return [] }
        let ns = text as NSString
        var candidates: [(order: Int, match: SecretMatch, nsRange: NSRange)] = []

        var windows: [NSRange] = []
        if ns.length <= windowSize {
            windows = [NSRange(location: 0, length: ns.length)]
        } else {
            var start = 0
            while start < ns.length {
                windows.append(NSRange(location: start, length: min(windowSize, ns.length - start)))
                start += windowSize - 25_000   // overlap so keys on a boundary are still seen
            }
        }

        // All END markers in one linear pass; each BEGIN then finds its END by binary search.
        // (A lazy "BEGIN … END" regex re-scans forward from every BEGIN: quadratic on crafted input.)
        let ends: [NSRange] = text.contains("PRIVATE KEY") ? Self.privateKeyEnd.matches(
            in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) : []

        for (order, rule) in all.enumerated() {
            for window in windows {
                rule.regex.enumerateMatches(in: text, options: [], range: window) { result, _, _ in
                    guard let result else { return }
                    var r = result.range(at: rule.group)
                    if rule.id == "private-key", let end = Self.firstEnd(after: r, in: ends),
                       end.location - r.location <= Self.maxPrivateKeyLength {
                        r = NSRange(location: r.location, length: end.location + end.length - r.location)
                    }
                    guard r.location != NSNotFound, let range = Range(r, in: text) else { return }
                    let value = String(text[range])
                    if rule.needsEntropy && !looksRandom(value) { return }
                    candidates.append((order, SecretMatch(ruleID: rule.id, ruleName: rule.name,
                                                          range: range, value: value), r))
                }
            }
        }

        // Resolve overlaps: earlier rule wins, then longer match.
        candidates.sort { a, b in
            a.order != b.order ? a.order < b.order : a.nsRange.length > b.nsRange.length
        }
        var taken: [NSRange] = []
        var result: [SecretMatch] = []
        for c in candidates where !taken.contains(where: { NSIntersectionRange($0, c.nsRange).length > 0 }) {
            taken.append(c.nsRange)
            result.append(c.match)
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let privateKeyEnd = try! NSRegularExpression(
        pattern: #"-----END [A-Z0-9 ]{0,20}PRIVATE KEY[A-Z ]{0,10}-----"#)
    static let maxPrivateKeyLength = 20_000

    private static func firstEnd(after begin: NSRange, in ends: [NSRange]) -> NSRange? {
        let start = begin.location + begin.length
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid].location < start { lo = mid + 1 } else { hi = mid }
        }
        return lo < ends.count ? ends[lo] : nil
    }

    /// Replaces every detected secret. Returns the new text and what was removed.
    static func redact(_ text: String, with replacement: (SecretMatch) -> String) -> (String, [SecretMatch]) {
        let matches = scan(text)
        guard !matches.isEmpty else { return (text, []) }
        var out = text
        for m in matches.reversed() { out.replaceSubrange(m.range, with: replacement(m)) }
        return (out, matches)
    }

    /// "sk-proj-abc…wxyz" style preview that never shows the middle of a secret.
    static func mask(_ value: String) -> String {
        let firstLine = value.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? value
        if firstLine.hasPrefix("-----BEGIN") { return firstLine }
        guard value.count > 12 else { return String(repeating: "•", count: max(value.count, 4)) }
        return "\(value.prefix(4))••••••••\(value.suffix(4))"
    }

    private static let placeholderWords = ["your", "example", "placeholder", "changeme", "dummy", "sample",
                                           "xxxx", "****", "redacted", "<", ">", "${", "{{", "process.env", "os.environ"]

    /// Shannon entropy check for generic `key = "..."` matches, so config like
    /// password = "please-change-this" isn't flagged.
    static func looksRandom(_ value: String) -> Bool {
        let lower = value.lowercased()
        if placeholderWords.contains(where: { lower.contains($0) }) { return false }
        var counts: [Character: Int] = [:]
        for c in value { counts[c, default: 0] += 1 }
        let n = Double(value.count)
        let entropy = counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        return entropy >= 3.5 && hasDigit && hasLetter
    }
}
