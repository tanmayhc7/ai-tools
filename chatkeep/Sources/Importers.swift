import Foundation
import CryptoKit

/// Turns one conversation object from a ChatGPT or Claude export into a `Conversation`.
///
/// Neither export format is officially documented and both have changed over time, so everything
/// here is tolerant: unknown fields are ignored, missing fields have fallbacks, and an element that
/// can't be understood is skipped rather than aborting the import.
enum ChatImporters {
    // MARK: Detection

    static func source(of json: [String: Any]) -> ChatSource? {
        if json["mapping"] is [String: Any] { return .chatgpt }
        if json["chat_messages"] is [Any] { return .claude }
        if json["messages"] is [Any], json["uuid"] != nil || json["name"] != nil { return .claude }
        return nil
    }

    static func conversation(from json: [String: Any], limits: ImportLimits = ImportLimits()) -> Conversation? {
        switch source(of: json) {
        case .chatgpt: return ChatGPTImporter.conversation(from: json, limits: limits)
        case .claude: return ClaudeImporter.conversation(from: json, limits: limits)
        case nil: return nil
        }
    }

    // MARK: Shared helpers

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    static func date(_ any: Any?) -> Date? {
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return epoch(n.doubleValue) }
        guard let s = any as? String, !s.isEmpty else { return nil }
        if let d = Double(s) { return epoch(d) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func epoch(_ v: Double) -> Date? {
        guard v.isFinite, v > 0 else { return nil }
        let seconds = v > 1e12 ? v / 1000 : v                 // some exports use milliseconds
        guard seconds < 4_102_444_800 else { return nil }     // year 2100: anything later is garbage
        return Date(timeIntervalSince1970: seconds)
    }

    static func stableID(_ parts: String...) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return "gen-" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Caps a message and the running total for a conversation.
    static func capped(_ text: String, limits: ImportLimits, remaining: inout Int) -> String {
        var t = text
        if t.count > limits.maxCharactersPerMessage { t = String(t.prefix(limits.maxCharactersPerMessage)) + "\n[… cut off by ChatKeep: message too long]" }
        if t.count > remaining { t = String(t.prefix(max(0, remaining))) }
        remaining -= t.count
        return t
    }
}

// MARK: - ChatGPT

enum ChatGPTImporter {
    static func conversation(from json: [String: Any], limits: ImportLimits) -> Conversation? {
        guard let mapping = json["mapping"] as? [String: Any], mapping.count <= limits.maxMappingNodes else { return nil }

        let rawTitle = ChatImporters.string(json["title"]) ?? ""
        let title = TextCleaning.oneLine(rawTitle, maxLength: limits.maxTitleLength)
        let created = ChatImporters.date(json["create_time"])
        let id = ChatImporters.string(json["conversation_id"]) ?? ChatImporters.string(json["id"])
            ?? ChatImporters.stableID(rawTitle, String(created?.timeIntervalSince1970 ?? 0))

        var remaining = limits.maxCharactersPerConversation
        var messages: [ChatMessage] = []
        for nodeID in activePath(mapping: mapping, currentNode: ChatImporters.string(json["current_node"])) {
            guard messages.count < limits.maxMessagesPerConversation, remaining > 0,
                  let node = mapping[nodeID] as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  var parsed = parse(message) else { continue }
            parsed.text = ChatImporters.capped(parsed.text, limits: limits, remaining: &remaining)
            if parsed.text.isEmpty && parsed.note == nil { continue }
            messages.append(parsed)
        }
        guard !messages.isEmpty else { return nil }
        return Conversation(id: "chatgpt:\(id)", source: .chatgpt,
                            title: title.isEmpty ? fallbackTitle(messages) : title,
                            created: created, updated: ChatImporters.date(json["update_time"]), messages: messages)
    }

    /// ChatGPT stores a tree (edits and regenerations create branches). The conversation you saw is
    /// the chain from `current_node` back to the root. Visited-set and step cap stop loops.
    static func activePath(mapping: [String: Any], currentNode: String?) -> [String] {
        func chain(from leaf: String) -> [String] {
            var path: [String] = [], seen = Set<String>()
            var cursor: String? = leaf
            while let id = cursor, !seen.contains(id), seen.count <= mapping.count, let node = mapping[id] as? [String: Any] {
                seen.insert(id); path.append(id)
                cursor = ChatImporters.string(node["parent"])
            }
            return path.reversed()
        }
        if let current = currentNode, mapping[current] != nil { return chain(from: current) }

        // No usable current_node: take the latest leaf.
        func time(_ id: String) -> Double {
            ((mapping[id] as? [String: Any])?["message"] as? [String: Any]).flatMap { ChatImporters.date($0["create_time"])?.timeIntervalSince1970 } ?? 0
        }
        let leaves = mapping.keys.filter { id in
            let children = (mapping[id] as? [String: Any])?["children"] as? [Any]
            return children?.isEmpty ?? true
        }
        if let best = leaves.max(by: { time($0) < time($1) }) { return chain(from: best) }
        return mapping.keys.sorted { time($0) < time($1) }
    }

    static func parse(_ message: [String: Any]) -> ChatMessage? {
        let metadata = message["metadata"] as? [String: Any]
        if (metadata?["is_visually_hidden_from_conversation"] as? Bool) == true { return nil }
        let roleName = ((message["author"] as? [String: Any])?["role"] as? String) ?? "assistant"
        guard let role = ChatRole(rawValue: roleName) else { return nil }
        guard let content = message["content"] as? [String: Any] else { return nil }

        var (text, note) = extract(content)
        if let attachments = metadata?["attachments"] as? [[String: Any]], !attachments.isEmpty {
            let names = attachments.compactMap { ChatImporters.string($0["name"]) }.map { TextCleaning.oneLine($0, maxLength: 80) }
            if !names.isEmpty { note = [note, "file: " + names.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ") }
        }
        text = TextCleaning.clean(text)
        if role == .system && text.isEmpty { return nil }
        return ChatMessage(role: role, text: text, time: ChatImporters.date(message["create_time"]), note: note)
    }

    private static func extract(_ content: [String: Any]) -> (text: String, note: String?) {
        let type = content["content_type"] as? String
        switch type {
        case "code", "execution_output", "system_error":
            return (ChatImporters.string(content["text"]) ?? "", nil)
        case "thoughts", "reasoning_recap", "user_editable_context", "model_editable_context",
             "tether_browsing_display", "tether_quote", "sonic_webpage":
            return ("", nil)        // hidden reasoning, saved memory/profile text, and browsing noise
        default:
            var texts: [String] = [], images = 0, audio = 0
            for part in (content["parts"] as? [Any]) ?? [] {
                if let s = part as? String { texts.append(s) }
                else if let d = part as? [String: Any] {
                    switch d["content_type"] as? String {
                    case "image_asset_pointer": images += 1
                    case "audio_transcription": if let t = ChatImporters.string(d["text"]) { texts.append(t) }
                    case "audio_asset_pointer", "real_time_user_audio_video_asset_pointer": audio += 1
                    default: if let t = ChatImporters.string(d["text"]) { texts.append(t) }
                    }
                }
            }
            if texts.isEmpty, let t = ChatImporters.string(content["text"]) { texts.append(t) }
            var notes: [String] = []
            if images > 0 { notes.append(images == 1 ? "1 image" : "\(images) images") }
            if audio > 0 { notes.append("audio") }
            return (texts.joined(separator: "\n"), notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
    }

    private static func fallbackTitle(_ messages: [ChatMessage]) -> String {
        let first = messages.first { $0.role == .user && !$0.text.isEmpty }?.text ?? ""
        let line = TextCleaning.oneLine(first, maxLength: 60)
        return line.isEmpty ? "Untitled" : line
    }
}

// MARK: - Claude

enum ClaudeImporter {
    static func conversation(from json: [String: Any], limits: ImportLimits) -> Conversation? {
        guard let rawMessages = (json["chat_messages"] as? [Any]) ?? (json["messages"] as? [Any]) else { return nil }
        let rawTitle = ChatImporters.string(json["name"]) ?? ChatImporters.string(json["title"]) ?? ""
        let created = ChatImporters.date(json["created_at"])
        let id = ChatImporters.string(json["uuid"]) ?? ChatImporters.string(json["id"])
            ?? ChatImporters.stableID(rawTitle, String(created?.timeIntervalSince1970 ?? 0))

        var remaining = limits.maxCharactersPerConversation
        var messages: [ChatMessage] = []
        for case let raw as [String: Any] in rawMessages {
            guard messages.count < limits.maxMessagesPerConversation, remaining > 0, var m = parse(raw) else { continue }
            m.text = ChatImporters.capped(m.text, limits: limits, remaining: &remaining)
            if m.text.isEmpty && m.note == nil { continue }
            messages.append(m)
        }
        guard !messages.isEmpty else { return nil }

        var title = TextCleaning.oneLine(rawTitle, maxLength: limits.maxTitleLength)
        if title.isEmpty {
            title = TextCleaning.oneLine(messages.first { $0.role == .user && !$0.text.isEmpty }?.text ?? "", maxLength: 60)
            if title.isEmpty { title = "Untitled" }
        }
        return Conversation(id: "claude:\(id)", source: .claude, title: title, created: created,
                            updated: ChatImporters.date(json["updated_at"]), messages: messages)
    }

    static func parse(_ message: [String: Any]) -> ChatMessage? {
        let sender = ((ChatImporters.string(message["sender"]) ?? ChatImporters.string(message["role"])) ?? "").lowercased()
        let role: ChatRole
        switch sender {
        case "human", "user": role = .user
        case "assistant", "claude", "ai": role = .assistant
        case "system": role = .system
        default: return nil
        }

        var notes: [String] = []
        var parts: [String] = []

        if let blocks = message["content"] as? [Any], !blocks.isEmpty {
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text", nil:
                    if let t = ChatImporters.string(block["text"]) { parts.append(t) }
                case "thinking":
                    continue                                    // the model's private reasoning isn't part of the chat
                case "tool_use":
                    if let n = ChatImporters.string(block["name"]) { notes.append("tool: \(TextCleaning.oneLine(n, maxLength: 40))") }
                case "tool_result":
                    if let t = toolResultText(block["content"]), !t.isEmpty { parts.append("[tool result] " + String(t.prefix(20_000))) }
                default:
                    if let t = ChatImporters.string(block["text"]) { parts.append(t) }
                }
            }
        }
        if parts.isEmpty, let t = ChatImporters.string(message["text"]) { parts.append(t) }

        // Attached documents: their extracted text was sent to the model, so it belongs in search and scans.
        for case let a as [String: Any] in (message["attachments"] as? [Any]) ?? [] {
            let name = TextCleaning.oneLine(ChatImporters.string(a["file_name"]) ?? "attachment", maxLength: 80)
            notes.append("file: \(name)")
            if let extracted = ChatImporters.string(a["extracted_content"]), !extracted.isEmpty {
                parts.append("[attachment: \(name)]\n" + extracted)
            }
        }
        for case let f as [String: Any] in (message["files"] as? [Any]) ?? [] {
            if let n = ChatImporters.string(f["file_name"]) { notes.append("file: " + TextCleaning.oneLine(n, maxLength: 80)) }
        }

        let text = TextCleaning.clean(parts.joined(separator: "\n"))
        return ChatMessage(role: role, text: text,
                           time: ChatImporters.date(message["created_at"]),
                           note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    private static func toolResultText(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        guard let blocks = any as? [Any] else { return nil }
        return blocks.compactMap { ($0 as? [String: Any]).flatMap { ChatImporters.string($0["text"]) } }.joined(separator: "\n")
    }
}
