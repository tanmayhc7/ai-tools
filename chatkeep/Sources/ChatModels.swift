import Foundation

enum ChatSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case chatgpt, claude
    var id: String { rawValue }
    var label: String { self == .chatgpt ? "ChatGPT" : "Claude" }
}

enum ChatRole: String, Codable, Sendable {
    case user, assistant, system, tool
    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "AI"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }
}

struct ChatMessage: Codable, Equatable, Sendable {
    var role: ChatRole
    var text: String
    var time: Date?
    /// Things that were in the message but aren't text: "2 images", "file: report.pdf".
    var note: String?
}

struct Conversation: Codable, Identifiable, Equatable, Sendable {
    /// "chatgpt:<original id>" or "claude:<original id>", so ids from different services can't collide.
    var id: String
    var source: ChatSource
    var title: String
    var created: Date?
    var updated: Date?
    var messages: [ChatMessage]

    var lastActivity: Date? { updated ?? messages.compactMap(\.time).max() ?? created }
    var characterCount: Int { messages.reduce(0) { $0 + $1.text.count } }
    var originalID: String { String(id.drop { $0 != ":" }.dropFirst()) }
}

/// Hard limits that keep a hostile or enormous export from exhausting memory.
struct ImportLimits: Sendable {
    var maxConversations = 500_000
    var maxMessagesPerConversation = 50_000
    var maxCharactersPerMessage = 500_000
    var maxCharactersPerConversation = 8_000_000
    var maxTitleLength = 300
    var maxMappingNodes = 200_000
    /// A single conversation larger than this (as JSON) is skipped and counted.
    var maxConversationBytes = 64 << 20
}

enum TextCleaning {
    /// Removes characters that carry no meaning in a transcript or that could be used to disguise
    /// text: NUL, and ChatGPT's private-use citation markers (U+E200…U+E201 spans).
    static func clean(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var text = s
        if text.unicodeScalars.contains(where: { $0.value == 0 }) { text = text.replacingOccurrences(of: "\u{0}", with: "") }
        if text.contains("\r") { text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        if text.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) }) {
            // Citation spans such as  cite turn0search1 : drop the whole span, then any stray marker.
            while let open = text.firstIndex(of: "\u{E200}"), let close = text[open...].firstIndex(of: "\u{E201}") {
                text.removeSubrange(open...close)
            }
            text.unicodeScalars.removeAll { (0xE000...0xF8FF).contains($0.value) }
        }
        return text
    }

    /// One line, no control or direction-override characters, truncated. For titles and names.
    static func oneLine(_ s: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for scalar in s.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !lastSpace { out.append(" "); lastSpace = true }
            case .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                out.append(scalar); lastSpace = false
            }
        }
        var result = String(out).trimmingCharacters(in: .whitespaces)
        if result.count > maxLength { result = String(result.prefix(maxLength - 1)) + "…" }
        return result
    }

    /// Message text for display: keeps newlines and tabs, drops other control characters and
    /// direction overrides (which can make text read differently from how it is stored).
    static func display(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if scalar == "\n" || scalar == "\t" { out.append(scalar) }
            case .format:
                // keep joiners that emoji and many scripts need; drop direction controls and invisibles
                if scalar.value == 0x200D || scalar.value == 0x200C || (0xFE00...0xFE0F).contains(scalar.value) { out.append(scalar) }
            case .surrogate, .unassigned:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}
