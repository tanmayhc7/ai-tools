import Foundation
import Darwin
import Security

/// What KeyVault can learn about the program on the other end of a connection.
/// Nothing here proves a script is "agentp": an unsigned interpreter looks the same whatever it
/// runs. It is shown to the user so *they* can judge, and is never trusted for access decisions
/// beyond "same process as before" (process ID + kernel start time).
struct Requester: Sendable, Equatable {
    enum Signature: Sendable, Equatable {
        case apple, developer, adHoc, unsigned, invalid, unknown

        var description: String {
            switch self {
            case .apple: return "Signed by Apple"
            case .developer: return "Signed by a developer"
            case .adHoc: return "Ad-hoc signed (identity can't be verified)"
            case .unsigned: return "Unsigned"
            case .invalid: return "Signature is invalid"
            case .unknown: return "Signature could not be checked"
            }
        }

        /// Anything that isn't verifiably tied to a known developer.
        var isUnverified: Bool { self != .apple && self != .developer }
    }

    let pid: Int32
    /// Kernel process start time (µs since 1970): with the pid, uniquely identifies a process.
    let startTime: UInt64
    let path: String
    let arguments: [String]
    let workingDirectory: String
    let parentPid: Int32
    let parentPath: String
    let signature: Signature

    var program: String { (path as NSString).lastPathComponent }

    /// The script (or module) an interpreter was asked to run, if it can be told.
    var script: String? {
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "-m", i + 1 < arguments.count { return "module " + arguments[i + 1] }
            if arg == "-c" { return "inline code" }
            if arg.hasPrefix("-") { i += 1; continue }
            return arg
        }
        return nil
    }

    /// Used for throttling: the same program running the same script, whatever its pid.
    var identityKey: String { path + "|" + (script ?? "") }

    /// Short single-line label for logs.
    var label: String {
        var s = AgentProtocol.sanitize(program, maxLength: 40)
        if let script { s += " · " + AgentProtocol.sanitize((script as NSString).lastPathComponent, maxLength: 40) }
        return s + " (pid \(pid))"
    }
}

enum ProcessInspector {
    /// Returns nil if the process no longer exists.
    static func inspect(pid: Int32) -> Requester? {
        guard let bsd = bsdInfo(pid) else { return nil }
        let path = executablePath(pid) ?? ""
        let (_, args) = processArguments(pid)
        let parent = bsd.pbi_ppid > 0 ? Int32(bsd.pbi_ppid) : 0
        return Requester(
            pid: pid,
            startTime: startTime(from: bsd),
            path: path,
            arguments: args,
            workingDirectory: workingDirectory(pid) ?? "",
            parentPid: parent,
            parentPath: parent > 0 ? (executablePath(parent) ?? "") : "",
            signature: path.isEmpty ? .unknown : signature(ofExecutableAt: path))
    }

    /// Cheap check used right before handing over a key: is this still the same process?
    static func startTime(of pid: Int32) -> UInt64? {
        bsdInfo(pid).map(startTime(from:))
    }

    // MARK: Pieces

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func startTime(from info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Parses the KERN_PROCARGS2 buffer: [argc:int32][exec path\0][padding \0…][argv[0]\0 … argv[argc-1]\0][env…].
    /// Only argv is read; the environment (which may hold secrets) is never touched.
    static func processArguments(_ pid: Int32) -> (execPath: String, argv: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8, size <= 4 * 1024 * 1024 else { return ("", []) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ("", []) }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    static func parseProcessArguments(_ buffer: [UInt8]) -> (execPath: String, argv: [String]) {
        guard buffer.count > 4 else { return ("", []) }
        let argc = Int(Int32(littleEndian: buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc >= 0, argc <= 4096 else { return ("", []) }
        var i = 4
        func readString() -> String? {
            guard i < buffer.count else { return nil }
            var j = i
            while j < buffer.count, buffer[j] != 0 { j += 1 }
            let s = String(decoding: buffer[i..<j], as: UTF8.self)
            i = min(j + 1, buffer.count)
            return s
        }
        let exec = readString() ?? ""
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var argv: [String] = []
        for _ in 0..<min(argc, 64) {
            guard let s = readString() else { break }
            argv.append(s)
        }
        return (exec, argv)
    }

    // MARK: Code signature

    static func signature(ofExecutableAt path: String) -> Requester.Signature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unknown }

        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }

        func satisfies(_ requirement: String) -> Bool {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
            return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        if satisfies("anchor apple") { return .apple }
        if satisfies("anchor apple generic") { return .developer }
        return .adHoc
    }
}
