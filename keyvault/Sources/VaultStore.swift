import Foundation
import CryptoKit
import AppKit

struct APIKeyEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var service: String
    var secret: String
    var notes: String
    var createdAt = Date()
    var updatedAt = Date()
}

private struct VaultContents: Codable {
    var entries: [APIKeyEntry]
}

@MainActor
final class VaultStore: ObservableObject {
    enum Phase: Equatable { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var entries: [APIKeyEntry] = []
    @Published private(set) var unlockBlockedUntil: Date?
    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "autoLockMinutes") }
    }

    private var key: SymmetricKey?
    private var salt = Data()
    private var iterations = VaultCrypto.defaultIterations
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var copiedChangeCount: Int?
    /// Bumped on every lock, so an unlock that was in flight when the Mac slept is discarded.
    private var lockGeneration = 0
    private var failedUnlocks: Int {
        get { UserDefaults.standard.integer(forKey: "failedUnlocks") }
        set { UserDefaults.standard.set(newValue, forKey: "failedUnlocks") }
    }

    static let clipboardClearSeconds = 30
    static let backupsToKeep = 10

    // MARK: Locations

    nonisolated static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyVault", isDirectory: true)
    }
    nonisolated static var vaultURL: URL { directoryURL.appendingPathComponent("vault.json") }
    nonisolated static var backupsURL: URL { directoryURL.appendingPathComponent("Backups", isDirectory: true) }

    init() {
        let saved = UserDefaults.standard.object(forKey: "autoLockMinutes") as? Int
        autoLockMinutes = saved ?? 5
        phase = FileManager.default.fileExists(atPath: Self.vaultURL.path) ? .locked : .setup
        let until = UserDefaults.standard.double(forKey: "unlockBlockedUntil")
        if until > Date().timeIntervalSince1970 { unlockBlockedUntil = Date(timeIntervalSince1970: until) }
        installLockTriggers()
    }

    // MARK: Single instance

    nonisolated(unsafe) private static var instanceLockFD: Int32 = -1

    /// Two running copies would each hold their own list and overwrite each other's saves.
    /// An exclusive advisory lock on a file in the vault folder prevents that.
    nonisolated static func acquireInstanceLock() -> Bool {
        try? ensureDirectory(directoryURL)
        let path = directoryURL.appendingPathComponent(".lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return true }   // can't lock: don't block the user
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        instanceLockFD = fd   // held open for the life of the process
        return true
    }

    // MARK: Lifecycle

    func createVault(password: String) async throws {
        let (newKey, newSalt, iters) = try await Self.newKey(for: password)
        try write(entries: [], key: newKey, salt: newSalt, iterations: iters)
        key = newKey; salt = newSalt; iterations = iters
        entries = []
        lastActivity = Date()
        phase = .unlocked
    }

    func unlock(password: String) async throws {
        if let until = unlockBlockedUntil, until > Date() {
            throw VaultError.throttled(seconds: Int(until.timeIntervalSinceNow.rounded(.up)))
        }
        let generation = lockGeneration
        let file = try readVaultFile()
        let fileSalt = try VaultCrypto.salt(of: file)
        let result: (SymmetricKey, Data)
        do {
            result = try await Task.detached(priority: .userInitiated) {
                do {
                    let k = try VaultCrypto.deriveKey(password: password, salt: fileSalt, iterations: file.iterations)
                    return (k, try VaultCrypto.open(file, key: k))
                } catch VaultError.wrongPassword where password.precomposedStringWithCanonicalMapping != password {
                    // Vaults created before NFC normalisation used the raw bytes.
                    let k = try VaultCrypto.deriveKey(password: password, salt: fileSalt,
                                                      iterations: file.iterations, normalize: false)
                    return (k, try VaultCrypto.open(file, key: k))
                }
            }.value
        } catch VaultError.wrongPassword {
            registerFailedUnlock()
            throw VaultError.wrongPassword
        }
        guard generation == lockGeneration else { return }   // locked while we were deriving
        let contents: VaultContents
        do { contents = try Self.decoder.decode(VaultContents.self, from: result.1) }
        catch { throw VaultError.corrupted }

        failedUnlocks = 0
        setBlockedUntil(nil)
        key = result.0; salt = fileSalt; iterations = file.iterations
        entries = contents.entries
        lastActivity = Date()
        phase = .unlocked
        if file.iterations < VaultCrypto.upgradeThreshold {
            Task { try? await upgradeKDF(password: password) }
        }
    }

    /// Vaults made with a weaker work factor are silently re-encrypted with a calibrated one
    /// the next time they're unlocked (we have the password in hand at that moment only).
    private func upgradeKDF(password: String) async throws {
        let generation = lockGeneration
        let (newKey, newSalt, iters) = try await Self.newKey(for: password)
        guard generation == lockGeneration, phase == .unlocked else { return }
        try write(entries: entries, key: newKey, salt: newSalt, iterations: iters)
        key = newKey; salt = newSalt; iterations = iters
        // Older backups are cheaper to attack; keep only one made with the new settings.
        try? FileManager.default.removeItem(at: Self.backupsURL)
        try? backupCurrentFile()
    }

    func lock() {
        lockGeneration += 1
        key = nil
        entries = []
        clearClipboardIfOurs()
        if phase == .unlocked { phase = .locked }
    }

    func changePassword(current: String, new: String) async throws {
        let file = try readVaultFile()
        let fileSalt = try VaultCrypto.salt(of: file)
        try await Task.detached(priority: .userInitiated) {
            do {
                let k = try VaultCrypto.deriveKey(password: current, salt: fileSalt, iterations: file.iterations)
                _ = try VaultCrypto.open(file, key: k)
            } catch VaultError.wrongPassword where current.precomposedStringWithCanonicalMapping != current {
                let k = try VaultCrypto.deriveKey(password: current, salt: fileSalt,
                                                  iterations: file.iterations, normalize: false)
                _ = try VaultCrypto.open(file, key: k)
            }
        }.value
        let (newKey, newSalt, iters) = try await Self.newKey(for: new)
        // Write first; only switch the in-memory key once the new file is safely on disk.
        try write(entries: entries, key: newKey, salt: newSalt, iterations: iters)
        key = newKey; salt = newSalt; iterations = iters
        // Old backups still open with the old password — replace them with one under the new password.
        try? FileManager.default.removeItem(at: Self.backupsURL)
        try? backupCurrentFile()
    }

    private static func newKey(for password: String) async throws -> (SymmetricKey, Data, UInt32) {
        let newSalt = try VaultCrypto.randomBytes(16)
        return try await Task.detached(priority: .userInitiated) {
            let iters = VaultCrypto.calibratedIterations()
            return (try VaultCrypto.deriveKey(password: password, salt: newSalt, iterations: iters), newSalt, iters)
        }.value
    }

    // MARK: Throttling

    private func registerFailedUnlock() {
        failedUnlocks += 1
        let n = failedUnlocks
        guard n >= 3 else { return }
        let delay = min(5 * pow(2, Double(n - 3)), 300)   // 5s, 10s, 20s … capped at 5 min
        setBlockedUntil(Date().addingTimeInterval(delay))
    }

    private func setBlockedUntil(_ date: Date?) {
        unlockBlockedUntil = date
        UserDefaults.standard.set(date?.timeIntervalSince1970 ?? 0, forKey: "unlockBlockedUntil")
    }

    // MARK: Entries

    func add(_ entry: APIKeyEntry) throws {
        try commit(entries + [entry])
    }

    func update(_ entry: APIKeyEntry) throws {
        var list = entries
        guard let i = list.firstIndex(where: { $0.id == entry.id }) else { return }
        var e = entry
        e.updatedAt = Date()
        list[i] = e
        try commit(list)
    }

    func delete(id: APIKeyEntry.ID) throws {
        try commit(entries.filter { $0.id != id })
    }

    /// Saves first, then updates the UI — so what you see is always what is on disk.
    private func commit(_ newEntries: [APIKeyEntry]) throws {
        guard let key else { throw VaultError.locked }
        try write(entries: newEntries, key: key, salt: salt, iterations: iterations)
        entries = newEntries
    }

    // MARK: Clipboard

    func copyToClipboard(_ secret: String) {
        let pb = NSPasteboard.general
        // .currentHostOnly keeps the key off Universal Clipboard (no syncing to other devices).
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(secret, forType: .string)
        // Convention honoured by clipboard managers: don't record this item.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        copiedChangeCount = count
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.clipboardClearSeconds)) { [weak self] in
            MainActor.assumeIsolated {
                if pb.changeCount == count { pb.clearContents() }
                if self?.copiedChangeCount == count { self?.copiedChangeCount = nil }
            }
        }
    }

    private func clearClipboardIfOurs() {
        let pb = NSPasteboard.general
        if let c = copiedChangeCount, pb.changeCount == c { pb.clearContents() }
        copiedChangeCount = nil
    }

    // MARK: Backups

    var backupFiles: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.backupsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var hasBackups: Bool { !backupFiles.isEmpty }

    /// Copies the current vault file into Backups/ (already encrypted) and keeps the newest few.
    private func backupCurrentFile() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.vaultURL.path) else { return }
        try Self.ensureDirectory(Self.backupsURL)
        let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
        let dest = Self.backupsURL.appendingPathComponent("vault-\(stamp).json")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: Self.vaultURL, to: dest)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        for old in backupFiles.dropFirst(Self.backupsToKeep) { try? fm.removeItem(at: old) }
    }

    /// Replaces the vault with a backup (after backing up the current one). Needs the
    /// password that was in use when that backup was made.
    func restore(from url: URL) throws {
        let data = try Self.readCapped(url)
        guard let file = try? JSONDecoder().decode(VaultFile.self, from: data),
              file.format == VaultCrypto.format else { throw VaultError.corrupted }
        _ = try VaultCrypto.salt(of: file)
        try? backupCurrentFile()
        try Self.ensureDirectory(Self.directoryURL)
        try data.write(to: Self.vaultURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.vaultURL.path)
        lock()
        phase = .locked
    }

    func export(to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.copyItem(at: Self.vaultURL, to: url)
    }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    private func readVaultFile() throws -> VaultFile {
        let data: Data
        do { data = try Self.readCapped(Self.vaultURL) } catch { throw VaultError.corrupted }
        guard let file = try? JSONDecoder().decode(VaultFile.self, from: data) else { throw VaultError.corrupted }
        return file
    }

    private func write(entries: [APIKeyEntry], key: SymmetricKey, salt: Data, iterations: UInt32) throws {
        let plaintext = try Self.encoder.encode(VaultContents(entries: entries))
        let file = try VaultCrypto.seal(plaintext, key: key, salt: salt, iterations: iterations)
        let out = JSONEncoder()
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try out.encode(file)

        // Self-check: never replace a good file with one we can't read back.
        let check = try JSONDecoder().decode(VaultFile.self, from: data)
        guard try VaultCrypto.open(check, key: key) == plaintext else { throw VaultError.corrupted }

        try? backupCurrentFile()
        try Self.ensureDirectory(Self.directoryURL)
        try data.write(to: Self.vaultURL, options: .atomic)   // temp file + rename: never half-written
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.vaultURL.path)
    }

    /// A planted multi-gigabyte "vault" must not exhaust memory.
    private static func readCapped(_ url: URL) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= 32 * 1024 * 1024 else { throw VaultError.corrupted }
        return try Data(contentsOf: url)
    }

    nonisolated private static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    // MARK: Auto-lock

    private func installLockTriggers() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                                                    .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .unlocked, self.autoLockMinutes > 0 else { return }
                if Date().timeIntervalSince(self.lastActivity) > Double(self.autoLockMinutes * 60) {
                    self.lock()
                }
            }
        }
        let lockNow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lockNow)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow)
        // Quitting within 30 s of a copy must not leave the key on the clipboard.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: lockNow)
    }
}

extension ISO8601DateFormatter {
    static let backupStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        return f
    }()
}
