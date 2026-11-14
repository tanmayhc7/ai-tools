import Foundation
import CryptoKit
import AppKit

struct ArchivePayload: Codable {
    var version = 1
    var conversations: [Conversation]
    /// Conversations the user removed. Re-importing an export won't bring them back.
    var deleted: [String]
}

struct ImportOutcome: Equatable, Sendable {
    var added = 0
    var updated = 0
    var unchanged = 0
    var skippedDeleted = 0
    var report = ImportReport()
}

final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
final class ArchiveStore: ObservableObject {
    enum Phase: Equatable { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var conversations: [Conversation] = [] {
        didSet { positions = Dictionary(conversations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    private var positions: [String: Int] = [:]
    func conversation(id: String) -> Conversation? { positions[id].map { conversations[$0] } }
    @Published private(set) var index: SearchIndex?
    @Published private(set) var indexing = false
    @Published private(set) var importProgress: String?
    @Published private(set) var unlockBlockedUntil: Date?
    @Published var autoLockMinutes: Int {
        didSet { defaults.set(autoLockMinutes, forKey: "ck.autoLockMinutes") }
    }

    let directory: URL
    private let defaults: UserDefaults
    private var key: SymmetricKey?
    private var salt = Data()
    private var iterations = VaultCrypto.defaultIterations
    private var deleted: Set<String> = []
    private var lockGeneration = 0
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var importCancellation: ImportCancellation?

    nonisolated static let backupsToKeep = 3
    /// An archive file larger than this is treated as damaged rather than read into memory.
    nonisolated static let maxArchiveBytes = 4 << 30

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatKeep", isDirectory: true)
    }
    var fileURL: URL { directory.appendingPathComponent("archive.chatkeep") }
    var backupsURL: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    init(directory: URL = ArchiveStore.defaultDirectory, defaults: UserDefaults = .standard, installSystemHooks: Bool = true) {
        self.directory = directory
        self.defaults = defaults
        autoLockMinutes = (defaults.object(forKey: "ck.autoLockMinutes") as? Int) ?? 5
        phase = FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive.chatkeep").path) ? .locked : .setup
        let until = defaults.double(forKey: "ck.unlockBlockedUntil")
        if until > Date().timeIntervalSince1970 { unlockBlockedUntil = Date(timeIntervalSince1970: until) }
        if installSystemHooks { installLockTriggers() }
    }

    // MARK: Single instance

    nonisolated(unsafe) private static var instanceLockFD: Int32 = -1

    /// Two running copies would overwrite each other's saves.
    nonisolated static func acquireInstanceLock(in directory: URL = defaultDirectory) -> Bool {
        try? ensureDirectory(directory)
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        instanceLockFD = fd
        return true
    }

    // MARK: Create, unlock, lock

    func create(password: String) async throws {
        guard phase == .setup else { return }
        let (newKey, newSalt, iters) = try await Self.newKey(for: password)
        try await Self.write(ArchivePayload(conversations: [], deleted: []), key: newKey, salt: newSalt, iterations: iters,
                             to: fileURL, backups: backupsURL)
        key = newKey; salt = newSalt; iterations = iters
        conversations = []; deleted = []
        lastActivity = Date()
        phase = .unlocked
        rebuildIndex()
    }

    func unlock(password: String) async throws {
        if let until = unlockBlockedUntil, until > Date() {
            throw VaultError.throttled(seconds: Int(until.timeIntervalSinceNow.rounded(.up)))
        }
        let generation = lockGeneration
        let url = fileURL
        let result: (SymmetricKey, Data, UInt32, ArchivePayload)
        do {
            result = try await Task.detached(priority: .userInitiated) { () throws -> (SymmetricKey, Data, UInt32, ArchivePayload) in
                let file = try Self.readCapped(url)
                let (header, _, _) = try ArchiveCrypto.parseHeader(file)
                let salt = try ArchiveCrypto.salt(of: header)
                let key = try VaultCrypto.deriveKey(password: password, salt: salt, iterations: header.iterations)
                let payload = try Self.decode(try ArchiveCrypto.open(file, key: key))
                return (key, salt, header.iterations, payload)
            }.value
        } catch VaultError.wrongPassword {
            registerFailedUnlock()
            throw VaultError.wrongPassword
        }
        guard generation == lockGeneration else { return }          // locked while we were deriving
        defaults.set(0, forKey: "ck.failedUnlocks")
        setBlockedUntil(nil)
        key = result.0; salt = result.1; iterations = result.2
        deleted = Set(result.3.deleted)
        conversations = Self.sorted(result.3.conversations)
        lastActivity = Date()
        phase = .unlocked
        rebuildIndex()
        if iterations < VaultCrypto.upgradeThreshold { Task { try? await upgradeKDF(password: password) } }
    }

    func lock() {
        lockGeneration += 1
        importCancellation?.cancel()
        key = nil
        conversations = []; deleted = []; index = nil
        importProgress = nil; indexing = false
        if phase == .unlocked { phase = .locked }
    }

    private func upgradeKDF(password: String) async throws {
        let generation = lockGeneration
        let (newKey, newSalt, iters) = try await Self.newKey(for: password)
        guard generation == lockGeneration, phase == .unlocked else { return }
        try await Self.write(ArchivePayload(conversations: conversations, deleted: Array(deleted)), key: newKey, salt: newSalt,
                             iterations: iters, to: fileURL, backups: backupsURL)
        guard generation == lockGeneration else { return }
        key = newKey; salt = newSalt; iterations = iters
        try? FileManager.default.removeItem(at: backupsURL)           // older backups are cheaper to attack
    }

    func changePassword(current: String, new: String) async throws {
        guard phase == .unlocked else { throw VaultError.locked }
        let url = fileURL
        try await Task.detached(priority: .userInitiated) {
            let file = try Self.readCapped(url)
            let (header, _, _) = try ArchiveCrypto.parseHeader(file)
            let k = try VaultCrypto.deriveKey(password: current, salt: try ArchiveCrypto.salt(of: header), iterations: header.iterations)
            _ = try ArchiveCrypto.open(file, key: k)                   // proves the current password
        }.value
        let (newKey, newSalt, iters) = try await Self.newKey(for: new)
        try await Self.write(ArchivePayload(conversations: conversations, deleted: Array(deleted)), key: newKey, salt: newSalt,
                             iterations: iters, to: fileURL, backups: nil)
        key = newKey; salt = newSalt; iterations = iters
        try? FileManager.default.removeItem(at: backupsURL)           // old backups still open with the old password
    }

    // MARK: Importing

    func cancelImport() { importCancellation?.cancel() }

    func importExport(from url: URL) async throws -> ImportOutcome {
        guard phase == .unlocked, key != nil else { throw VaultError.locked }
        let generation = lockGeneration
        let cancel = ImportCancellation()
        importCancellation = cancel
        importProgress = "Reading…"
        defer { importProgress = nil; importCancellation = nil }

        let (incoming, report) = await Task.detached(priority: .userInitiated) { [weak self] () -> ([Conversation], ImportReport) in
            var list: [Conversation] = []
            let throttle = ProgressThrottle()
            let report = ExportReader.read(url, isCancelled: { cancel.isCancelled }, progress: { message in
                guard throttle.allow() else { return }
                Task { @MainActor in self?.importProgress = message }
            }) { list.append($0) }
            return (list, report)
        }.value
        guard generation == lockGeneration else { throw VaultError.locked }

        var outcome = ImportOutcome(report: report)
        guard report.fatalError == nil, !report.cancelled else { return outcome }

        var byID: [String: Int] = [:]
        var merged = conversations
        for (i, c) in merged.enumerated() { byID[c.id] = i }
        for c in incoming {
            if deleted.contains(c.id) { outcome.skippedDeleted += 1; continue }
            if let i = byID[c.id] {
                if Self.isNewer(c, than: merged[i]) { merged[i] = c; outcome.updated += 1 } else { outcome.unchanged += 1 }
            } else {
                byID[c.id] = merged.count; merged.append(c); outcome.added += 1
            }
        }
        guard outcome.added + outcome.updated > 0 else { return outcome }

        importProgress = "Encrypting and saving…"
        let sortedList = Self.sorted(merged)
        guard let key else { throw VaultError.locked }
        try await Self.write(ArchivePayload(conversations: sortedList, deleted: Array(deleted)), key: key, salt: salt,
                             iterations: iterations, to: fileURL, backups: backupsURL)
        guard generation == lockGeneration else { throw VaultError.locked }
        conversations = sortedList
        rebuildIndex()
        return outcome
    }

    /// Same conversation seen again: keep the version that has more history or a later update.
    static func isNewer(_ incoming: Conversation, than existing: Conversation) -> Bool {
        if incoming.messages.count != existing.messages.count { return incoming.messages.count > existing.messages.count }
        guard let a = incoming.lastActivity, let b = existing.lastActivity else { return false }
        return a > b
    }

    static func sorted(_ list: [Conversation]) -> [Conversation] {
        list.sorted {
            switch ($0.lastActivity, $1.lastActivity) {
            case let (a?, b?): return a != b ? a > b : $0.id < $1.id
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }

    // MARK: Deleting

    func delete(ids: Set<String>) async throws {
        guard phase == .unlocked, let key, !ids.isEmpty else { return }
        let remaining = conversations.filter { !ids.contains($0.id) }
        let tombstones = deleted.union(ids)
        try await Self.write(ArchivePayload(conversations: remaining, deleted: Array(tombstones)), key: key, salt: salt,
                             iterations: iterations, to: fileURL, backups: backupsURL)
        conversations = remaining
        deleted = tombstones
        rebuildIndex()
    }

    // MARK: Index

    func rebuildIndex() {
        let snapshot = conversations
        let generation = lockGeneration
        indexing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = SearchIndex(conversations: snapshot)
            await self?.installIndex(built, generation: generation)
        }
    }

    private func installIndex(_ built: SearchIndex, generation: Int) {
        guard generation == lockGeneration else { return }       // locked or changed while indexing
        index = built
        indexing = false
    }

    // MARK: Backups

    var backupFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "chatkeep" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    var hasBackups: Bool { !backupFiles.isEmpty }

    /// Replaces the archive with a backup. It still needs the password it was made with.
    func restore(from url: URL) throws {
        let data = try Self.readCapped(url)
        _ = try ArchiveCrypto.parseHeader(data)
        try? Self.backupCurrent(file: fileURL, backups: backupsURL)
        try Self.ensureDirectory(directory)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        lock()
        phase = .locked
    }

    // MARK: Persistence (all heavy work off the main thread)

    private static func newKey(for password: String) async throws -> (SymmetricKey, Data, UInt32) {
        let salt = try VaultCrypto.randomBytes(16)
        return try await Task.detached(priority: .userInitiated) {
            let iters = VaultCrypto.calibratedIterations()
            return (try VaultCrypto.deriveKey(password: password, salt: salt, iterations: iters), salt, iters)
        }.value
    }

    nonisolated static func encode(_ payload: ArchivePayload) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let json = try encoder.encode(payload)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated static func decode(_ compressed: Data) throws -> ArchivePayload {
        guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { throw VaultError.corrupted }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(ArchivePayload.self, from: json), payload.version == 1 else { throw VaultError.corrupted }
        return payload
    }

    /// Encrypts and replaces the archive file. The result is decrypted again and checked before it
    /// replaces anything, so a good archive is never swapped for one that can't be read back.
    private static func write(_ payload: ArchivePayload, key: SymmetricKey, salt: Data, iterations: UInt32,
                              to url: URL, backups: URL?) async throws {
        try await Task.detached(priority: .userInitiated) {
            let plain = try encode(payload)
            let sealed = try ArchiveCrypto.seal(plain, key: key, salt: salt, iterations: iterations)
            guard try ArchiveCrypto.open(sealed, key: key).count == plain.count else { throw VaultError.corrupted }
            if let backups { try? backupCurrent(file: url, backups: backups) }
            try ensureDirectory(url.deletingLastPathComponent())
            try sealed.write(to: url, options: .atomic)               // temp file + rename: never half-written
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
    }

    nonisolated private static func backupCurrent(file: URL, backups: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        try ensureDirectory(backups)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let dest = backups.appendingPathComponent("archive-\(f.string(from: Date())).chatkeep")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: file, to: dest)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        let all = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "chatkeep" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(backupsToKeep) { try? fm.removeItem(at: old) }
    }

    nonisolated private static func readCapped(_ url: URL) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxArchiveBytes else { throw VaultError.corrupted }
        do { return try Data(contentsOf: url) } catch { throw VaultError.corrupted }
    }

    nonisolated static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    // MARK: Unlock throttling

    private func registerFailedUnlock() {
        let n = defaults.integer(forKey: "ck.failedUnlocks") + 1
        defaults.set(n, forKey: "ck.failedUnlocks")
        guard n >= 3 else { return }
        setBlockedUntil(Date().addingTimeInterval(min(5 * pow(2, Double(n - 3)), 300)))     // 5 s, 10 s, 20 s … 5 min
    }

    private func setBlockedUntil(_ date: Date?) {
        unlockBlockedUntil = date
        defaults.set(date?.timeIntervalSince1970 ?? 0, forKey: "ck.unlockBlockedUntil")
    }

    // MARK: Auto-lock

    private func installLockTriggers() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .unlocked, self.autoLockMinutes > 0 else { return }
                if Date().timeIntervalSince(self.lastActivity) > Double(self.autoLockMinutes * 60) { self.lock() }
            }
        }
        let lockNow: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.lock() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lockNow)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: lockNow)
    }
}

/// Lets a fast producer report progress at most five times a second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock(); private var last = Date.distantPast
    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(last) > 0.2 else { return false }
        last = Date(); return true
    }
}
