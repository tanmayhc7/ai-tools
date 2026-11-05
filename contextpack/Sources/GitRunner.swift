import Foundation

// Shared helper (identical copy in leakguard/ and contextpack/).
// Runs /usr/bin/git safely against folders that may come from untrusted sources.

enum GitError: LocalizedError {
    case notInstalled, timedOut, failed(String), cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Git isn't available. Install Apple's Command Line Tools: xcode-select --install"
        case .timedOut:     return "Git took too long and was stopped."
        case .failed(let m): return "Git reported an error: \(m)"
        case .cancelled:    return "Cancelled."
        }
    }
}

enum GitRunner {
    static let gitPath = "/usr/bin/git"

    /// Config overrides that stop a malicious repo from running programs through git.
    /// Command-line -c settings take precedence over anything in the repo's own .git/config.
    /// fsmonitor hooks, pagers, credential helpers and network transports. (Callers also pass
    // --no-ext-diff / --no-textconv to diff-producing commands. Hooks never run for the
    // read-only commands these tools use.)
    private static let safetyConfig = [
        "-c", "core.fsmonitor=false",
        "-c", "core.pager=cat",
        "-c", "core.quotePath=false",      // print non-ASCII file names as-is
        "-c", "credential.helper=",
        "-c", "protocol.allow=never",
        // A repo can ask git to "verify" commit signatures with any program it names.
        "-c", "log.showSignature=false",
        "-c", "gpg.program=/usr/bin/false",
        "-c", "gpg.ssh.program=/usr/bin/false",
        "-c", "gpg.x509.program=/usr/bin/false",
        "-c", "core.untrackedCache=false",
    ]

    private static func makeProcess(_ args: [String], in dir: URL) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = safetyConfig + ["-C", dir.path] + args
        var env: [String: String] = [:]
        env["PATH"] = "/usr/bin:/bin"
        env["HOME"] = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"     // read-only: never take index locks
        env["LC_ALL"] = "C"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return p
    }

    static var isAvailable: Bool {
        // /usr/bin/git is a stub that pops an install dialog when the tools are missing,
        // so check for the real toolchain first.
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: gitPath)
            && (fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
                || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git"))
    }

    /// Runs git and returns stdout, capped in size and time.
    static func run(_ args: [String], in dir: URL, timeout: TimeInterval = 60,
                    maxBytes: Int = 64 * 1024 * 1024) throws -> Data {
        var out = Data()
        _ = try stream(args, in: dir, timeout: timeout) { chunk in
            out.append(chunk)
            return out.count <= maxBytes
        }
        return out
    }

    /// Streams stdout in chunks. Return false from `onChunk` to stop early.
    /// Throws on timeout, cancellation, or a non-zero exit.
    @discardableResult
    static func stream(_ args: [String], in dir: URL, timeout: TimeInterval,
                       isCancelled: @escaping () -> Bool = { false },
                       onChunk: (Data) -> Bool) throws -> Int32 {
        guard isAvailable else { throw GitError.notInstalled }
        let p = makeProcess(args, in: dir)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        try p.run()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }

        let state = TimeoutState()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if p.isRunning { state.timedOut = true; p.terminate() }
        }

        let handle = outPipe.fileHandleForReading
        var stoppedEarly = false
        while true {
            if isCancelled() { p.terminate(); stoppedEarly = true; break }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if !onChunk(chunk) { p.terminate(); stoppedEarly = true; break }
        }
        if stoppedEarly { try? handle.close() }
        p.waitUntilExit()
        _ = errDone.wait(timeout: .now() + 5)

        if state.timedOut { throw GitError.timedOut }
        if isCancelled() { throw GitError.cancelled }
        if !stoppedEarly && p.terminationStatus != 0 {
            let msg = String(decoding: errData.prefix(500), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(msg.isEmpty ? "exit code \(p.terminationStatus)" : msg)
        }
        return p.terminationStatus
    }

    /// Returns the repository root if `dir` is inside a git work tree.
    static func repoRoot(of dir: URL) -> URL? {
        guard isAvailable,
              let data = try? run(["rev-parse", "--show-toplevel"], in: dir, timeout: 10) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

private final class TimeoutState: @unchecked Sendable {
    var timedOut = false
}

/// Splits a byte stream into lines without loading the whole stream.
struct LineSplitter {
    private var buffer = Data()
    /// Lines longer than this are truncated (protects against minified one-line blobs).
    var maxLineBytes = 2 * 1024 * 1024

    mutating func feed(_ chunk: Data, _ onLine: (String) -> Void) {
        buffer.append(chunk)
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            onLine(String(decoding: buffer[start..<nl].prefix(maxLineBytes), as: UTF8.self))
            start = buffer.index(after: nl)
        }
        buffer.removeSubrange(buffer.startIndex..<start)   // one copy per chunk, not per line
        if buffer.count > maxLineBytes {
            onLine(String(decoding: buffer.prefix(maxLineBytes), as: UTF8.self))
            buffer.removeAll(keepingCapacity: true)
        }
    }

    mutating func finish(_ onLine: (String) -> Void) {
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        buffer.removeAll()
    }
}
