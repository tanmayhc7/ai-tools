import Foundation

// MARK: Host interface

enum Decision: Sendable, Equatable {
    case deny
    case allowOnce
    case allow(seconds: Int)
    /// The dialog timed out. Not counted as a refusal.
    case timedOut
    /// The vault locked (or KeyVault quit) while the dialog was open.
    case cancelled
}

struct HostEntry: Sendable, Equatable {
    let id: UUID
    let name: String
}

struct ApprovalRequest: Sendable {
    /// The real entry's name, taken from the vault. Never text supplied by the requester.
    let entryName: String
    let requester: Requester
    /// Free text from the requester. Untrusted: sanitise before showing.
    let reason: String?
}

/// What the controller needs from the app. The real implementation talks to `VaultStore`;
/// tests supply a fake.
protocol AgentHost: AnyObject, Sendable {
    func isUnlocked() async -> Bool
    /// False when there is no vault yet, so asking the user to unlock would be pointless.
    func canUnlock() async -> Bool
    func requestUnlock(for requester: Requester) async -> Bool
    /// Every entry's id and name, or empty when locked. Matching is done by the controller.
    func entries() async -> [HostEntry]
    func secret(for id: UUID) async -> String?
    func approve(_ request: ApprovalRequest) async -> Decision
    func cancelPendingApprovals() async
}

// MARK: Records

struct AccessGrant: Identifiable, Sendable, Equatable {
    let id = UUID()
    let entryID: UUID
    let entryName: String
    let pid: Int32
    let startTime: UInt64
    let requesterLabel: String
    let expires: Date
}

struct AccessLogEntry: Identifiable, Sendable, Equatable {
    enum Outcome: String, Sendable {
        case allowedOnce, allowedWindow, allowedByGrant
        case denied, unknownKey, timedOut, cancelled
        case blocked, rateLimited, locked, badRequest, abandoned
        /// Every request paused after many refusals in a short time (defends against dialog fatigue).
        case paused

        /// True when the key was actually sent.
        var delivered: Bool { self == .allowedOnce || self == .allowedWindow || self == .allowedByGrant }
    }
    let id = UUID()
    let time: Date
    let requester: String
    /// What was asked for, sanitised and truncated.
    let keyName: String
    let outcome: Outcome

    var delivered: Bool { outcome.delivered }
}

// MARK: Controller

/// Decides whether a request gets a key. Owns grants, throttling and the access log.
/// All state lives here, in the signed app's memory: a process running as the user can't reset
/// a counter without quitting KeyVault (which also locks the vault).
actor AccessController {
    struct Config: Sendable {
        var maxGrantSeconds = 3600
        var failuresBeforeBlock = 3
        var failureWindow: TimeInterval = 600
        var blockSeconds: TimeInterval = 300
        var maxBlockSeconds: TimeInterval = 3600
        var globalRequestsPerMinute = 30
        var maxPendingApprovals = 5
        var unlockPromptCooldown: TimeInterval = 30
        var maxLogEntries = 200
        /// Refusals from *any* programs within the window that pause every request: a program can
        /// dodge its own block by changing its name, but it can't make you click through endless dialogs.
        var denialsBeforePause = 5
        var denialPauseWindow: TimeInterval = 600
        var pauseSeconds: TimeInterval = 300
    }

    private let host: AgentHost
    private let config: Config
    private let clock: @Sendable () -> Date

    private var grants: [AccessGrant] = []
    private var log: [AccessLogEntry] = []
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var blockCount: [String: Int] = [:]
    private var recentRequests: [Date] = []
    private var lastUnlockPrompt: Date = .distantPast
    private var recentDenials: [Date] = []
    private var pausedUntil: Date = .distantPast
    /// Bumped by `revokeAll`; anything that started before can no longer hand out a key.
    private var epoch = 0

    private var pendingApprovals = 0
    private var approvalGateBusy = false
    private var approvalWaiters: [CheckedContinuation<Void, Never>] = []

    private var onChange: (@Sendable () -> Void)?

    init(host: AgentHost, config: Config = Config(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.config = config
        self.clock = clock
    }

    func setOnChange(_ callback: (@Sendable () -> Void)?) { onChange = callback }

    // MARK: Snapshot for the UI

    func snapshot() -> (grants: [AccessGrant], log: [AccessLogEntry]) {
        pruneGrants()
        return (grants, log)
    }

    // MARK: Revocation

    /// Locking the vault: drop every grant and dismiss any open dialog.
    func revokeAll() async {
        epoch += 1
        grants.removeAll()
        changed()
        await host.cancelPendingApprovals()
    }

    func revoke(grantID: UUID) {
        grants.removeAll { $0.id == grantID }
        changed()
    }

    // MARK: Handling a request

    /// Returns the bytes to send back, or nil if the requester went away and nothing should be sent.
    func handle(_ request: AgentProtocol.Request, from requester: Requester,
                peerStillValid: @Sendable () -> Bool) async -> Data? {
        let now = clock()
        let identity = requester.identityKey
        let askedFor = AgentProtocol.sanitize(request.key, maxLength: 60)
        func record(_ outcome: AccessLogEntry.Outcome) {
            appendLog(AccessLogEntry(time: clock(), requester: requester.label, keyName: askedFor, outcome: outcome))
        }
        func fail(_ code: AgentProtocol.ErrorCode, _ outcome: AccessLogEntry.Outcome) -> Data {
            record(outcome)
            return AgentProtocol.error(code)
        }

        pruneGrants()

        if pausedUntil > now { return fail(.rateLimited, .paused) }
        if let until = blockedUntil[identity], until > now { return fail(.rateLimited, .blocked) }
        recentRequests.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentRequests.count < config.globalRequestsPerMinute else { return fail(.rateLimited, .rateLimited) }
        recentRequests.append(now)

        // Locked: at most one unlock prompt per cooldown, and only if there is a vault to unlock.
        if !(await host.isUnlocked()) {
            guard await host.canUnlock(),
                  now.timeIntervalSince(lastUnlockPrompt) >= config.unlockPromptCooldown else {
                return fail(.locked, .locked)
            }
            lastUnlockPrompt = now
            guard await host.requestUnlock(for: requester), await host.isUnlocked() else {
                return fail(.locked, .locked)
            }
        }
        // The user may have unlocked while this request waited; that is a legitimate fresh start.
        // From here on, only a *lock* (which bumps the epoch) invalidates the request.
        let activeEpoch = epoch

        let matches = await host.entries().filter { AgentProtocol.names($0.name, match: request.key) }
        guard matches.count == 1, let entry = matches.first else {
            registerFailure(identity)
            return fail(.denied, matches.isEmpty ? .unknownKey : .denied)
        }

        /// Hands over the key if everything still holds. `delivered` is true only when the key was sent.
        func deliver(_ outcome: AccessLogEntry.Outcome) async -> (data: Data?, delivered: Bool) {
            guard epoch == activeEpoch else { return (fail(.locked, .cancelled), false) }
            guard peerStillValid() else { record(.abandoned); return (nil, false) }
            guard let secret = await host.secret(for: entry.id), epoch == activeEpoch else {
                return (fail(.locked, .locked), false)
            }
            record(outcome)
            return (AgentProtocol.ok(secret: secret), true)
        }

        if hasGrant(for: entry.id, requester: requester, now: now) {
            return await deliver(.allowedByGrant).data
        }

        // One dialog at a time; a small queue; anything beyond that is refused outright.
        guard pendingApprovals < config.maxPendingApprovals else { return fail(.rateLimited, .rateLimited) }
        pendingApprovals += 1
        await acquireApprovalGate()
        defer { releaseApprovalGate(); pendingApprovals -= 1 }

        // While queued, the vault may have locked or a sibling request may have been approved.
        guard epoch == activeEpoch, await host.isUnlocked() else { return fail(.locked, .cancelled) }
        if hasGrant(for: entry.id, requester: requester, now: clock()) { return await deliver(.allowedByGrant).data }
        guard peerStillValid() else { record(.abandoned); return nil }

        let decision = await host.approve(ApprovalRequest(entryName: entry.name, requester: requester, reason: request.reason))

        switch decision {
        case .deny:
            registerFailure(identity)
            registerDenial()
            return fail(.denied, .denied)
        case .timedOut:
            return fail(.timeout, .timedOut)
        case .cancelled:
            return fail(.locked, .cancelled)
        case .allowOnce:
            failures[identity] = nil
            return await deliver(.allowedOnce).data
        case .allow(let seconds):
            failures[identity] = nil
            let result = await deliver(.allowedWindow)
            // Only open the window once the key has actually been delivered.
            if result.delivered, epoch == activeEpoch {
                let lifetime = TimeInterval(max(1, min(seconds, config.maxGrantSeconds)))
                grants.append(AccessGrant(entryID: entry.id, entryName: entry.name, pid: requester.pid,
                                          startTime: requester.startTime, requesterLabel: requester.label,
                                          expires: clock().addingTimeInterval(lifetime)))
                changed()
            }
            return result.data
        }
    }

    /// A request that couldn't be parsed (or never finished arriving). Counts as a refusal so a
    /// program can't probe with garbage forever.
    func rejectMalformed(from requester: Requester) -> Data {
        registerFailure(requester.identityKey)
        appendLog(AccessLogEntry(time: clock(), requester: requester.label,
                                 keyName: "(malformed request)", outcome: .badRequest))
        return AgentProtocol.error(.badRequest)
    }

    // MARK: Grants

    private func hasGrant(for entryID: UUID, requester: Requester, now: Date) -> Bool {
        grants.contains {
            $0.entryID == entryID && $0.pid == requester.pid
                && $0.startTime == requester.startTime && $0.expires > now
        }
    }

    private func pruneGrants() {
        let now = clock()
        let before = grants.count
        grants.removeAll { $0.expires <= now }
        // A grant belongs to one process: when it exits (or its pid is reused), the grant goes too.
        grants.removeAll { ProcessInspector.startTime(of: $0.pid) != $0.startTime }
        if grants.count != before { changed() }
    }

    // MARK: Throttling

    private func registerFailure(_ identity: String) {
        let now = clock()
        var list = (failures[identity] ?? []).filter { now.timeIntervalSince($0) <= config.failureWindow }
        list.append(now)
        failures[identity] = list
        guard list.count >= config.failuresBeforeBlock else { return }
        let n = (blockCount[identity] ?? 0) + 1
        blockCount[identity] = n
        let duration = min(config.blockSeconds * pow(2, Double(n - 1)), config.maxBlockSeconds)
        blockedUntil[identity] = now.addingTimeInterval(duration)
        failures[identity] = nil
    }

    private func registerDenial() {
        let now = clock()
        recentDenials = recentDenials.filter { now.timeIntervalSince($0) <= config.denialPauseWindow } + [now]
        if recentDenials.count >= config.denialsBeforePause {
            pausedUntil = now.addingTimeInterval(config.pauseSeconds)
            recentDenials.removeAll()
        }
    }

    // MARK: Approval gate (one dialog at a time)

    private func acquireApprovalGate() async {
        if !approvalGateBusy { approvalGateBusy = true; return }
        await withCheckedContinuation { approvalWaiters.append($0) }
    }

    private func releaseApprovalGate() {
        if approvalWaiters.isEmpty { approvalGateBusy = false } else { approvalWaiters.removeFirst().resume() }
    }

    // MARK: Log

    private func appendLog(_ entry: AccessLogEntry) {
        log.append(entry)
        if log.count > config.maxLogEntries { log.removeFirst(log.count - config.maxLogEntries) }
        changed()
    }

    private func changed() { onChange?() }
}
