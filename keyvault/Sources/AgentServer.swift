import Foundation
import Darwin

enum AgentServerError: LocalizedError {
    case pathTooLong
    case pathOccupied(String)
    case alreadyRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .pathTooLong: return "The socket path is too long for macOS (limit 103 bytes)."
        case .pathOccupied(let p): return "Something that isn't a socket is at \(p). It was left alone."
        case .alreadyRunning: return "Another process is already answering on the agent socket."
        case .failed(let m): return "Couldn't start the agent socket: \(m)"
        }
    }
}

/// Listens on a Unix socket (never a network port) and passes each request to the controller.
///
/// Socket file mode 0600 inside a 0700 folder, same-user check on every connection, small
/// request size, short read deadline, and a cap on simultaneous connections.
final class AgentServer: @unchecked Sendable {
    struct Config: Sendable {
        var readTimeout: TimeInterval = 5
        var writeTimeout: TimeInterval = 5
        var maxConcurrent = 8
        var expectedUID: uid_t = geteuid()
    }

    let path: String
    private let controller: AccessController
    private let config: Config
    private let lock = NSLock()
    private var running = false
    private var active = 0
    private var listenFD: Int32 = -1
    private let stopped = DispatchSemaphore(value: 0)
    private let work = DispatchQueue(label: "keyvault.agent.connections", attributes: .concurrent)

    // Constants from <sys/un.h>, written out so they don't depend on the header being imported.
    private static let solLocal: Int32 = 0
    private static let localPeerCred: Int32 = 0x001
    private static let localPeerPid: Int32 = 0x002

    init(path: String, controller: AccessController, config: Config = Config()) {
        self.path = path
        self.controller = controller
        self.config = config
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: Start / stop

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        guard path.utf8.count < 104 else { throw AgentServerError.pathTooLong }

        var st = stat()
        if lstat(path, &st) == 0 {
            // Only ever remove a stale *socket*. A file, folder or symlink here is not ours to touch.
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw AgentServerError.pathOccupied(path) }
            if Self.canConnect(path) { throw AgentServerError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentServerError.failed(String(cString: strerror(errno))) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = Self.address(for: path)
        let oldMask = umask(0o177)               // the socket file is created owner-only from the start
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else {
            let message = String(cString: strerror(errno)); close(fd)
            throw AgentServerError.failed(message)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno)); close(fd); unlink(path)
            throw AgentServerError.failed(message)
        }

        listenFD = fd
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "keyvault.agent.accept"
        thread.start()
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        _ = stopped.wait(timeout: .now() + 2)     // the accept loop closes the socket and removes the file
    }

    // MARK: Accepting

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 250) > 0 else { continue }       // wakes 4×/s to notice stop()
            let client = accept(fd, nil, nil)
            if client >= 0 { accepted(client) }
        }
        close(fd)
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
        stopped.signal()
    }

    private func accepted(_ client: Int32) {
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        let tooMany = active >= config.maxConcurrent
        if !tooMany { active += 1 }
        lock.unlock()

        if tooMany {
            _ = Self.writeAll(client, AgentProtocol.error(.rateLimited), timeout: 1)
            close(client)
            return
        }
        work.async { [self] in serve(client) }
    }

    private func finish(_ fd: Int32) {
        close(fd)
        lock.lock(); active -= 1; lock.unlock()
    }

    // MARK: One connection

    private func serve(_ fd: Int32) {
        guard let peer = Self.peer(of: fd), peer.uid == config.expectedUID,
              let requester = ProcessInspector.inspect(pid: peer.pid) else {
            finish(fd); return                                  // another user, or the caller already left
        }

        let deadline = Date().addingTimeInterval(config.readTimeout)
        let line: Data
        switch Self.readLine(fd, maxBytes: AgentProtocol.maxRequestBytes, deadline: deadline) {
        case .closed:
            finish(fd); return
        case .tooLarge, .timedOut:
            reply(fd) { await self.controller.rejectMalformed(from: requester) }
            return
        case .line(let data):
            line = data
        }

        switch AgentProtocol.parse(line) {
        case .failure:
            reply(fd) { await self.controller.rejectMalformed(from: requester) }
        case .success(let request):
            let pid = requester.pid, start = requester.startTime
            reply(fd) {
                await self.controller.handle(request, from: requester) {
                    // Still the same process, and still connected? Otherwise the key must not be sent.
                    ProcessInspector.startTime(of: pid) == start && Self.isOpen(fd)
                }
            }
        }
    }

    /// Runs the (possibly slow, user-dependent) decision, then writes the answer and closes.
    private func reply(_ fd: Int32, _ decide: @escaping @Sendable () async -> Data?) {
        Task.detached { [self] in
            let response = await decide()
            work.async { [self] in
                if let response { _ = Self.writeAll(fd, response, timeout: config.writeTimeout) }
                finish(fd)
            }
        }
    }

    // MARK: Socket helpers

    static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = path.withCString { strncpy(dst, $0, 103) }
            }
        }
        return addr
    }

    private static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(for: path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private static func peer(of fd: Int32) -> (uid: uid_t, pid: Int32)? {
        var cred = xucred()
        var credLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, solLocal, localPeerCred, &cred, &credLength) == 0, cred.cr_version == 0 else { return nil }
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPid, &pid, &pidLength) == 0, pid > 0 else { return nil }
        return (cred.cr_uid, pid)
    }

    /// False once the other end has hung up. On macOS a half-closed connection (the client shut
    /// down its sending side) is indistinguishable from a closed one, and handing a key to a client
    /// that might have gone is the worse mistake, so the rule is: **keep the connection open until
    /// the answer arrives.** The bundled Python client does.
    static func isOpen(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) >= 0 else { return false }
        return p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0
    }

    enum ReadResult { case line(Data), tooLarge, timedOut, closed }

    static func readLine(_ fd: Int32, maxBytes: Int, deadline: Date) -> ReadResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) { return .line(buffer.prefix(upTo: nl)) }
            if buffer.count > maxBytes { return .tooLarge }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(remaining * 1000, 1000)))
            if ready < 0 { if errno == EINTR { continue }; return .closed }
            if ready == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return .closed }        // EOF before a complete line: the client is gone (or half-closed, which we treat the same)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .closed }
            buffer.append(chunk, count: n)
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            while offset < raw.count {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&p, 1, Int32(min(remaining * 1000, 1000)))
                if ready < 0 { if errno == EINTR { continue }; return false }
                if ready == 0 { continue }
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
                offset += n
            }
            return true
        }
    }
}
