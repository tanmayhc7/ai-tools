import Foundation
import CryptoKit

/// One key stored in KeyVault (same shape LeakGuard uses).
struct VaultSecret: Sendable {
    let name: String
    let secret: String
}

struct LeakOptions: Sendable {
    /// API keys, tokens, private keys, database passwords.
    var secrets = true
    /// Card numbers (checksum verified), bank accounts (IBAN, checksum verified), US social security numbers.
    var financialAndID = true
    var emails = false
    var ipAddresses = false
    var includeAIReplies = true
    /// Exact keys from the user's KeyVault. Kept only for the duration of one scan.
    var vault: [VaultSecret] = []
    static let minimumVaultSecretLength = 12
}

enum LeakKind: Int, Comparable, Sendable {
    case vaultKey = 0, secret, financial, email, network
    static func < (a: LeakKind, b: LeakKind) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .vaultKey: return "Your KeyVault key"
        case .secret: return "Key or password"
        case .financial: return "Card, bank or ID number"
        case .email: return "Email address"
        case .network: return "IP address"
        }
    }
}

struct LeakFinding: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: LeakKind
    let label: String                // e.g. "OpenAI API key"
    let conversationID: String
    let messageIndex: Int
    let role: ChatRole
    /// Only a masked preview is ever kept; the full value is never stored in a finding.
    let masked: String
    /// Short SHA-256 of the value, to recognise the same secret across messages and chats.
    let fingerprint: String
    var vaultEntryName: String?
}

struct LeakGroup: Identifiable, Sendable {
    var id: String { fingerprint }
    let fingerprint: String
    let kind: LeakKind
    let label: String
    let masked: String
    var vaultEntryName: String?
    var findings: [LeakFinding]
    var conversationCount: Int { Set(findings.map(\.conversationID)).count }
}

struct LeakReport: Sendable {
    var findings: [LeakFinding] = []
    var scannedMessages = 0
    var scannedConversations = 0
    var cancelled = false

    var groups: [LeakGroup] {
        var order: [String] = [], map: [String: LeakGroup] = [:]
        for f in findings {
            if map[f.fingerprint] == nil {
                order.append(f.fingerprint)
                map[f.fingerprint] = LeakGroup(fingerprint: f.fingerprint, kind: f.kind, label: f.label, masked: f.masked,
                                               vaultEntryName: f.vaultEntryName, findings: [f])
            } else {
                map[f.fingerprint]!.findings.append(f)
                if let n = f.vaultEntryName { map[f.fingerprint]!.vaultEntryName = n }
            }
        }
        return order.compactMap { map[$0] }.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind : $0.findings.count > $1.findings.count
        }
    }
}

enum LeakScanner {
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func scan(_ conversations: [Conversation], options: LeakOptions,
                     isCancelled: () -> Bool = { false },
                     progress: (Int, Int) -> Void = { _, _ in }) -> LeakReport {
        var report = LeakReport()
        var settings = RedactionSettings()
        let vault = options.vault.filter { $0.secret.count >= LeakOptions.minimumVaultSecretLength }

        for (ci, conversation) in conversations.enumerated() {
            if isCancelled() { report.cancelled = true; break }
            if ci % 50 == 0 { progress(ci, conversations.count) }
            report.scannedConversations += 1

            for (mi, message) in conversation.messages.enumerated() {
                guard !message.text.isEmpty else { continue }
                if message.role != .user && !options.includeAIReplies { continue }
                report.scannedMessages += 1
                var seen = Set<String>()
                var local: [LeakFinding] = []

                func add(_ kind: LeakKind, _ label: String, _ value: String, masked: String, vaultName: String? = nil) {
                    let fp = fingerprint(value)
                    guard seen.insert(fp).inserted else { return }       // once per message
                    local.append(LeakFinding(kind: kind, label: label, conversationID: conversation.id, messageIndex: mi,
                                             role: message.role, masked: masked, fingerprint: fp, vaultEntryName: vaultName))
                }

                if options.secrets {
                    for m in SecretRules.scan(message.text) { add(.secret, m.ruleName, m.value, masked: SecretRules.mask(m.value)) }
                }
                // Cheap byte-level checks first: most messages have no digits or no "@", so the pattern
                // matching for cards, IBANs, SSNs, emails and IPs can be skipped for them entirely.
                var digits = 0, hasAt = false, hasDot = false
                for b in message.text.utf8 { if b >= 0x30 && b <= 0x39 { digits += 1 } else if b == 0x40 { hasAt = true } else if b == 0x2E { hasDot = true } }
                var enabled = Set<Category>()
                if options.financialAndID && digits >= 8 { enabled.formUnion([.card, .iban, .idNumber]) }
                if options.emails && hasAt { enabled.insert(.email) }
                if options.ipAddresses && hasDot && digits >= 4 { enabled.insert(.ip) }
                settings.enabled = enabled
                if !enabled.isEmpty {
                    for d in RedactionEngine.detect(message.text, settings: settings) {
                        switch d.category {
                        case .card: add(.financial, "Card number", d.value, masked: "•••• " + d.value.filter(\.isNumber).suffix(4))
                        case .iban: add(.financial, "Bank account (IBAN)", d.value, masked: String(d.value.prefix(4)) + "••••" + d.value.suffix(4))
                        case .idNumber: add(.financial, "ID number (SSN)", d.value, masked: "•••-••-" + d.value.suffix(4))
                        case .email: add(.email, "Email address", d.value, masked: maskEmail(d.value))
                        case .ip: add(.network, "IP address", d.value, masked: d.value.split(separator: ".").prefix(2).joined(separator: ".") + ".•.•")
                        default: break
                        }
                    }
                }
                for entry in vault where message.text.contains(entry.secret) {
                    let fp = fingerprint(entry.secret)
                    if let i = local.firstIndex(where: { $0.fingerprint == fp }) { local[i].vaultEntryName = entry.name }
                    else { add(.vaultKey, "Key from your KeyVault", entry.secret, masked: SecretRules.mask(entry.secret), vaultName: entry.name) }
                }
                report.findings.append(contentsOf: local)
            }
        }
        progress(conversations.count, conversations.count)
        return report
    }

    private static func maskEmail(_ e: String) -> String {
        guard let at = e.lastIndex(of: "@") else { return SecretRules.mask(e) }
        return String(e[e.startIndex]) + "•••" + e[at...]
    }
}
