import Foundation
import Darwin

/// What happened during an import, in words a person can act on.
struct ImportReport: Equatable, Sendable {
    var filesRead: [String] = []
    var bySource: [ChatSource: Int] = [:]
    var emptyOrUnrecognised = 0
    var oversized = 0
    var truncatedFiles: [String] = []
    var warnings: [String] = []
    var fatalError: String?
    var cancelled = false

    var total: Int { bySource.values.reduce(0, +) }
}

/// Reads a ChatGPT or Claude export given as a `.zip`, an unzipped folder, or a single JSON file.
enum ExportReader {
    static let expectedFiles = "conversations.json (ChatGPT may split it into conversations-000.json, conversations-001.json, …)"

    static func isConversationFile(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".json"), !n.hasPrefix("._") else { return false }
        if n == "conversations.json" { return true }
        guard n.hasPrefix("conversations-") || n.hasPrefix("conversations_") else { return false }
        return n.dropFirst("conversations-".count).dropLast(".json".count).allSatisfy { $0.isNumber }
    }

    static func read(_ url: URL, limits: ImportLimits = ImportLimits(),
                     isCancelled: @escaping () -> Bool = { false },
                     progress: @escaping (String) -> Void = { _ in },
                     onConversation: @escaping (Conversation) -> Void) -> ImportReport {
        var report = ImportReport()
        var count = 0

        /// One JSON document, delivered in chunks.
        func process(name: String, feeding: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) {
            var splitter = JSONStreamSplitter(maxElementBytes: limits.maxConversationBytes)
            var readThisFile = 0
            do {
                try feeding { chunk in
                    if isCancelled() { throw CancellationError() }
                    try splitter.feed(chunk) { element in
                        guard count < limits.maxConversations else { return }
                        handle(element, &report, &count, &readThisFile, limits, onConversation)
                    }
                }
            } catch is CancellationError {
                report.cancelled = true
            } catch let e as ZipError {
                // The data before the damage was already delivered; keep it and say what went wrong.
                report.warnings.append("\(name): \(e.localizedDescription) Everything readable before that point was imported.")
            } catch {
                report.warnings.append("\(name): \(error.localizedDescription)")
            }
            let summary = splitter.finish()
            report.oversized += summary.oversized
            if summary.truncated { report.truncatedFiles.append(name) }
            report.filesRead.append(name)
            if count >= limits.maxConversations { report.warnings.append("Stopped at \(limits.maxConversations) conversations.") }
            progress("\(name): \(readThisFile) conversations")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            report.fatalError = "That file or folder doesn't exist."
            return report
        }

        if isDirectory.boolValue {
            let files = conversationFiles(in: url)
            guard !files.isEmpty else { report.fatalError = "No conversation files found in that folder. Looking for \(expectedFiles)."; return report }
            for file in files where !report.cancelled {
                process(name: file.lastPathComponent) { sink in try streamFile(file.path, followSymlinks: false, sink: sink) }
            }
        } else if looksLikeZip(url) {
            do {
                let zip = try ZipArchive(path: url.path)
                let entries = zip.entries.filter { !$0.isDirectory && isConversationFile($0.baseName) }
                guard !entries.isEmpty else {
                    report.fatalError = "This zip doesn't contain conversation files. Looking for \(expectedFiles)."
                    return report
                }
                for entry in entries where !report.cancelled {
                    process(name: entry.baseName) { sink in try zip.stream(entry, isCancelled: isCancelled, sink: sink) }
                }
            } catch {
                report.fatalError = error.localizedDescription
            }
        } else {
            process(name: url.lastPathComponent) { sink in try streamFile(url.path, followSymlinks: true, sink: sink) }
        }

        if report.fatalError == nil, !report.cancelled, report.total == 0 {
            report.fatalError = report.warnings.isEmpty && report.truncatedFiles.isEmpty
                ? "No conversations were found. The file may be a different kind of export."
                : "No conversations could be read."
        }
        return report
    }

    // MARK: Elements

    private static func handle(_ element: Data, _ report: inout ImportReport, _ count: inout Int, _ readThisFile: inout Int,
                               _ limits: ImportLimits, _ emit: (Conversation) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: element) else { report.emptyOrUnrecognised += 1; return }
        var candidates: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            // A wrapper such as {"conversations": [...]} (seen in some third-party exports).
            if let inner = dict["conversations"] as? [Any], ChatImporters.source(of: dict) == nil {
                candidates = inner.compactMap { $0 as? [String: Any] }
            } else { candidates = [dict] }
        }
        guard !candidates.isEmpty else { report.emptyOrUnrecognised += 1; return }
        for json in candidates {
            guard count < limits.maxConversations else { return }
            if let conversation = ChatImporters.conversation(from: json, limits: limits) {
                report.bySource[conversation.source, default: 0] += 1
                count += 1; readThisFile += 1
                emit(conversation)
            } else {
                report.emptyOrUnrecognised += 1
            }
        }
    }

    // MARK: Files

    private static func looksLikeZip(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// `conversations*.json` anywhere within three levels, never following symlinks.
    static func conversationFiles(in folder: URL) -> [URL] {
        var found: [URL] = []
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        while let rel = walker.nextObject() as? String {
            let attrs = walker.fileAttributes ?? [:]
            let type = attrs[.type] as? FileAttributeType
            if type == .typeDirectory { if walker.level > 3 { walker.skipDescendants() }; continue }
            guard type == .typeRegular, isConversationFile((rel as NSString).lastPathComponent) else { continue }
            found.append(folder.appendingPathComponent(rel))
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Reads a file in 4 MB pieces. A file found inside a folder is opened with O_NOFOLLOW so a
    /// symlink dropped into an unzipped export can't redirect the read elsewhere.
    static func streamFile(_ path: String, followSymlinks: Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw ZipError.unreadable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ZipError.unreadable("not a regular file") }
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw ZipError.unreadable(String(cString: strerror(errno))) }
            if n == 0 { return }
            try buffer.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
    }
}
