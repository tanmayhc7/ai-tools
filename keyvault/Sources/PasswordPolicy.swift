import Foundation

/// Master-password rules. The vault file can be copied and attacked offline, where no
/// lockout applies — so the only real defence is a password that isn't in a cracking wordlist.
enum PasswordPolicy {
    static let minimumLength = 12
    static let minimumBits = 50.0

    /// Bases that cracking dictionaries try first, with digits/symbols appended.
    private static let common = [
        "password", "passwd", "qwerty", "qwertyuiop", "asdfgh", "zxcvbn", "letmein", "welcome",
        "admin", "administrator", "iloveyou", "monkey", "dragon", "football", "baseball", "soccer",
        "master", "sunshine", "princess", "shadow", "superman", "batman", "trustno1", "hello",
        "freedom", "whatever", "starwars", "login", "secret", "keyvault", "apikey", "changeme",
        "default", "abc123", "123456", "1234567890", "111111", "000000", "computer", "internet",
    ]

    private static func deLeet(_ s: String) -> String {
        let map: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s",
                                           "7": "t", "@": "a", "$": "s", "!": "i"]
        return String(s.lowercased().map { map[$0] ?? $0 })
    }

    /// True when the password is essentially a dictionary word plus a short suffix/prefix.
    static func isCommon(_ password: String) -> Bool {
        // Strip every dictionary word (repeats included); if little is left, it's guessable.
        let words = common.sorted { $0.count > $1.count }
        func remainder(_ s: String) -> String {
            words.reduce(s) { $0.replacingOccurrences(of: $1, with: "") }
        }
        let plain = password.lowercased()
        let leet = deLeet(password)
        let left = min(remainder(plain).count, remainder(leet).count)
        return left < password.count && left < 6
    }

    /// Rough entropy estimate in bits. Repeats and runs like "aaaa" or "1234" count once.
    static func estimatedBits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0.0
        if password.contains(where: \.isLowercase) { pool += 26 }
        if password.contains(where: \.isUppercase) { pool += 26 }
        if password.contains(where: \.isNumber) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }

        let scalars = password.unicodeScalars.map { Int($0.value) }
        var effective = 1
        for i in 1..<scalars.count {
            let d = scalars[i] - scalars[i - 1]
            if abs(d) > 1 { effective += 1 }
        }
        var bits = Double(effective) * log2(max(pool, 2))
        if isCommon(password) { bits = min(bits, 20) }
        return bits
    }

    /// 0 = too short … 4 = strong.
    static func score(_ password: String) -> Int {
        guard password.count >= minimumLength else { return 0 }
        let bits = estimatedBits(password)
        switch bits {
        case ..<minimumBits: return 1
        case ..<65: return 2
        case ..<85: return 3
        default: return 4
        }
    }

    /// Why this password can't be used, or nil if it's acceptable.
    static func problem(_ password: String) -> String? {
        if password.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if isCommon(password) { return "Too close to a common password — attackers try these first." }
        if estimatedBits(password) < minimumBits {
            return "Too predictable. Try a few random words, e.g. “maple orbit cactus lantern”."
        }
        return nil
    }
}
