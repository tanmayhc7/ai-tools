import Foundation
import NaturalLanguage

/// What kind of personal data a placeholder stands for.
enum Category: String, CaseIterable, Identifiable, Codable, Sendable {
    case secret, custom, email, card, iban, idNumber, ip, url, phone, address, person, organization, place

    var id: String { rawValue }

    var label: String {
        switch self {
        case .secret: return "API keys & passwords"
        case .custom: return "My custom terms"
        case .email: return "Email addresses"
        case .card: return "Card numbers"
        case .iban: return "Bank accounts (IBAN)"
        case .idNumber: return "ID numbers (SSN)"
        case .ip: return "IP addresses"
        case .url: return "Web links"
        case .phone: return "Phone numbers"
        case .address: return "Street addresses"
        case .person: return "People's names"
        case .organization: return "Organisations"
        case .place: return "Places"
        }
    }

    var prefix: String {
        switch self {
        case .secret: return "SECRET"
        case .custom: return "TERM"
        case .email: return "EMAIL"
        case .card: return "CARD"
        case .iban: return "IBAN"
        case .idNumber: return "ID"
        case .ip: return "IP"
        case .url: return "URL"
        case .phone: return "PHONE"
        case .address: return "ADDRESS"
        case .person: return "NAME"
        case .organization: return "ORG"
        case .place: return "PLACE"
        }
    }

    /// Links, organisations and places are often needed for context, so they start off.
    var enabledByDefault: Bool { ![.url, .organization, .place].contains(self) }

    /// Lower wins when two detections overlap.
    var priority: Int { Category.allCases.firstIndex(of: self)! }

    /// Category inferred from a placeholder key such as "EMAIL".
    init?(prefix: String) {
        guard let c = Category.allCases.first(where: { $0.prefix == prefix }) else { return nil }
        self = c
    }
}

struct Placeholder: Hashable, Identifiable, Sendable {
    /// e.g. "EMAIL_1"
    let key: String
    let category: Category
    let original: String
    var token: String { "[\(key)]" }
    var id: String { key }
}

/// Session-wide mapping. Reused across edits so a value keeps its placeholder, and so
/// restoring works even if the original text changed after it was sent to the AI.
struct RedactionMap: Sendable {
    private(set) var byKey: [String: Placeholder] = [:]
    private var keyByValue: [String: String] = [:]
    private var counters: [String: Int] = [:]

    var all: [Placeholder] {
        byKey.values.sorted {
            $0.category.priority != $1.category.priority ? $0.category.priority < $1.category.priority
                : (Int($0.key.split(separator: "_").last ?? "") ?? 0) < (Int($1.key.split(separator: "_").last ?? "") ?? 0)
        }
    }
    var isEmpty: Bool { byKey.isEmpty }

    static func normalize(_ value: String, _ category: Category) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch category {
        case .secret: return "secret|" + trimmed                                    // exact
        case .card, .iban, .phone, .idNumber:
            return category.rawValue + "|" + trimmed.filter { $0.isLetter || $0.isNumber }.uppercased()
        default: return category.rawValue + "|" + trimmed.lowercased()
        }
    }

    /// Returns the existing placeholder for this value or makes a new one whose token
    /// doesn't already occur in `text` (so restoring can't hit genuine text).
    mutating func placeholder(for value: String, category: Category, avoiding text: String) -> Placeholder {
        let norm = Self.normalize(value, category)
        if let key = keyByValue[norm], let p = byKey[key] { return p }
        var n = counters[category.prefix, default: 0]
        var key: String
        repeat {
            n += 1
            key = "\(category.prefix)_\(n)"
        } while byKey[key] != nil || text.range(of: key, options: .caseInsensitive) != nil
        counters[category.prefix] = n
        let p = Placeholder(key: key, category: category, original: value)
        byKey[key] = p
        keyByValue[norm] = key
        return p
    }
}

struct RedactionSettings: Sendable {
    var enabled: Set<Category> = Set(Category.allCases.filter(\.enabledByDefault))
    var customTerms: [String] = []
    /// Values the user chose to leave visible (normalised with RedactionMap.normalize).
    var keep: Set<String> = []
}

struct Detection: Sendable {
    let range: Range<String.Index>
    let category: Category
    var value: String
}

struct RedactionOutput: Sendable {
    let text: String
    /// Placeholders used in this text, with how many times each appears.
    let used: [(placeholder: Placeholder, count: Int)]
}

struct RestoreOutput: Sendable {
    let text: String
    let restored: Int
    /// Placeholder-looking tokens in the AI reply that this session never created.
    let unknown: [String]
}

enum RedactionEngine {
    /// Inputs above this are rejected by the UI; the engine still works, just slowly.
    static let maxInputCharacters = 2_000_000

    // MARK: Patterns

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    private static let emailRE = re(#"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9\-]{1,63}(?:\.[A-Za-z0-9\-]{1,63}){0,8}\.[A-Za-z]{2,24}(?![A-Za-z0-9])"#)
    private static let cardRE = re(#"(?<![\d\-])(?:\d[ \-]?){12,18}\d(?![\d\-])"#)
    private static let ibanRE = re(#"(?<![A-Z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Z0-9])"#)
    private static let ssnRE = re(#"(?<![\d\-])(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}(?![\d\-])"#)
    private static let ipv4RE = re(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])"#)
    private static let ipv6FullRE = re(#"(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![0-9a-fA-F:])"#)
    private static let ipv6ShortRE = re(#"(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4}:){1,6}:(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,5})?(?![0-9a-fA-F:])"#)
    private static let notPersonalIPs: Set<String> = ["127.0.0.1", "0.0.0.0", "255.255.255.255", "::1"]

    private static func regexMatches(_ regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    // MARK: Validators

    static func luhnValid(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    static func ibanValid(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue { value = d }
            else if let a = ch.asciiValue, (65...90).contains(a) { value = Int(a) - 55 }
            else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    // MARK: Detection

    static func detect(_ text: String, settings: RedactionSettings) -> [Detection] {
        guard !text.isEmpty else { return [] }
        let on = settings.enabled
        var found: [Detection] = []
        func add(_ r: Range<String.Index>, _ c: Category) { found.append(Detection(range: r, category: c, value: String(text[r]))) }

        if on.contains(.secret) {
            for m in SecretRules.scan(text) { add(m.range, .secret) }
        }
        if on.contains(.custom) {
            for term in settings.customTerms.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where term.count >= 2 {
                for r in wholeWordRanges(of: term, in: text, caseInsensitive: true) { add(r, .custom) }
            }
        }
        if on.contains(.email) { regexMatches(emailRE, in: text).forEach { add($0, .email) } }
        if on.contains(.card) { regexMatches(cardRE, in: text).filter { luhnValid(String(text[$0])) }.forEach { add($0, .card) } }
        if on.contains(.iban) { regexMatches(ibanRE, in: text).filter { ibanValid(String(text[$0])) }.forEach { add($0, .iban) } }
        if on.contains(.idNumber) { regexMatches(ssnRE, in: text).forEach { add($0, .idNumber) } }
        if on.contains(.ip) {
            // Short-form IPv6 must have a digit and two groups, so "std::" or "a::b" aren't treated as addresses.
            let shortV6 = regexMatches(ipv6ShortRE, in: text).filter { r in
                let s = text[r]
                return s.contains(where: \.isNumber) && s.split(separator: ":").count >= 2
            }
            for r in regexMatches(ipv4RE, in: text) + regexMatches(ipv6FullRE, in: text) + shortV6
            where !notPersonalIPs.contains(String(text[r])) { add(r, .ip) }
        }

        let wantsDetector = on.contains(.url) || on.contains(.phone) || on.contains(.address)
        if wantsDetector {
            var types: NSTextCheckingResult.CheckingType = []
            if on.contains(.url) { types.insert(.link) }
            if on.contains(.phone) { types.insert(.phoneNumber) }
            if on.contains(.address) { types.insert(.address) }
            if let detector = try? NSDataDetector(types: types.rawValue) {
                for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(m.range, in: text) else { continue }
                    switch m.resultType {
                    case .link where m.url?.scheme != "mailto": add(r, .url)
                    case .phoneNumber where text[r].filter(\.isNumber).count >= 7: add(r, .phone)
                    case .address: add(r, .address)
                    default: break
                    }
                }
            }
        }

        let nameCategories: [NLTag: Category] = [.personalName: .person, .organizationName: .organization, .placeName: .place]
        if !on.isDisjoint(with: [.person, .organization, .place]) {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
                if let tag, let c = nameCategories[tag], on.contains(c), text[r].count >= 2 { add(r, c) }
                return true
            }
        }

        // Keep-list: values the user chose to leave visible.
        if !settings.keep.isEmpty {
            found.removeAll { settings.keep.contains(RedactionMap.normalize($0.value, $0.category)) }
        }

        var accepted = resolveOverlaps(found)

        // A name the tagger spotted once must be hidden everywhere it appears — and for
        // "Sarah Connor", so must a later "Connor" on its own.
        var extra: [Detection] = []
        let entityValues = Set(accepted.filter { [.person, .organization, .place, .custom].contains($0.category) }
            .map { "\($0.category.rawValue)|\($0.value)" })
        for entry in entityValues {
            let parts = entry.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let category = Category(rawValue: String(parts[0])) else { continue }
            let value = String(parts[1])
            var variants = [value]
            if category == .person {
                variants += value.split(whereSeparator: { $0.isWhitespace })
                    .map(String.init).filter { $0.count >= 3 && ($0.first?.isUppercase ?? false) }
            }
            for v in Set(variants) where !settings.keep.contains(RedactionMap.normalize(v, category)) {
                for r in wholeWordRanges(of: v, in: text, caseInsensitive: category == .custom) {
                    extra.append(Detection(range: r, category: category, value: String(text[r])))
                }
            }
        }
        if !extra.isEmpty { accepted = resolveOverlaps(accepted + extra) }
        return accepted
    }

    /// Higher-priority category wins; within a category, the longer match wins.
    private static func resolveOverlaps(_ detections: [Detection]) -> [Detection] {
        let sorted = detections.sorted {
            if $0.category.priority != $1.category.priority { return $0.category.priority < $1.category.priority }
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.range.lowerBound < $1.range.lowerBound
        }
        var taken: [Range<String.Index>] = []
        var out: [Detection] = []
        for d in sorted where !taken.contains(where: { $0.overlaps(d.range) }) {
            taken.append(d.range)
            out.append(d)
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Literal matches not glued to other letters/digits ("Ann" won't match "Annual").
    static func wholeWordRanges(of term: String, in text: String, caseInsensitive: Bool) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return [] }
        return regexMatches(regex, in: text)
    }

    // MARK: Redact

    static func redact(_ text: String, settings: RedactionSettings, map: inout RedactionMap) -> RedactionOutput {
        let detections = detect(text, settings: settings)
        guard !detections.isEmpty else { return RedactionOutput(text: text, used: []) }

        var out = ""
        out.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex
        var counts: [String: (Placeholder, Int)] = [:]
        var order: [String] = []
        for d in detections {
            let p = map.placeholder(for: d.value, category: d.category, avoiding: text)
            out += text[cursor..<d.range.lowerBound]
            out += p.token
            cursor = d.range.upperBound
            if counts[p.key] == nil { order.append(p.key); counts[p.key] = (p, 0) }
            counts[p.key]!.1 += 1
        }
        out += text[cursor...]
        return RedactionOutput(text: out, used: order.map { (counts[$0]!.0, counts[$0]!.1) })
    }

    // MARK: Restore

    /// Matches "[EMAIL_1]", "[ email_1 ]", markdown-escaped "\[EMAIL\_1\]" and bare "EMAIL_1".
    private static let tokenRE = re(#"\\?\[\s{0,3}([A-Za-z]{2,10})\\?_(\d{1,6})\s{0,3}\\?\]|(?<![A-Za-z0-9_])([A-Z]{2,10})_(\d{1,6})(?![A-Za-z0-9_])"#)

    /// One left-to-right pass, so a restored value is never itself expanded again.
    static func restore(_ text: String, map: RedactionMap) -> RestoreOutput {
        let ns = text as NSString
        var out = ""
        var last = 0
        var restored = 0
        var unknown: [String] = []
        for m in tokenRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let bracketed = m.range(at: 1).location != NSNotFound
            let prefix = ns.substring(with: m.range(at: bracketed ? 1 : 3)).uppercased()
            let number = ns.substring(with: m.range(at: bracketed ? 2 : 4))
            let key = "\(prefix)_\(Int(number) ?? -1)"
            guard Category(prefix: prefix) != nil else { continue }       // e.g. "[MAX_2]" in normal text
            if let p = map.byKey[key] {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += p.original
                last = m.range.location + m.range.length
                restored += 1
            } else if bracketed {
                unknown.append(ns.substring(with: m.range))
            }
        }
        out += ns.substring(from: last)
        return RestoreOutput(text: out, restored: restored, unknown: Array(Set(unknown)).sorted())
    }
}
