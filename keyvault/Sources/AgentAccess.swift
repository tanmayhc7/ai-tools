import SwiftUI
import AppKit

/// Turns the engine (socket + controller) on and off, and connects it to the real vault.
/// Off by default: until the user switches it on in Settings → Agent Access, no socket exists.
@MainActor
final class AgentAccess: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var statusMessage: String?
    @Published private(set) var grants: [AccessGrant] = []
    @Published private(set) var log: [AccessLogEntry] = []

    static let defaultsKey = "agentAccessEnabled"
    static var socketPath: String { VaultStore.directoryURL.appendingPathComponent("agent.sock").path }

    private unowned let store: VaultStore
    private let controller: AccessController
    private var server: AgentServer?

    init(store: VaultStore, approver: any Approving, config: AccessController.Config = .init()) {
        self.store = store
        controller = AccessController(host: StoreHost(store: store, approver: approver), config: config)
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)

        let controller = controller
        Task { [weak self] in await controller.setOnChange { Task { @MainActor in await self?.refresh() } } }

        // Locking (manual, idle, sleep, screen lock) drops every grant and closes any open dialog.
        store.onLock = { [weak self] in self?.revokeAll() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.stop() }
        }
        if enabled { start() }
    }

    // MARK: Switch

    func setEnabled(_ on: Bool) {
        if on {
            enabled = true
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            start()
        } else {
            server?.stop(); server = nil
            enabled = false
            statusMessage = nil
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            revokeAll()
        }
    }

    private func start() {
        do {
            try VaultStore.ensureDirectory(VaultStore.directoryURL)
            let s = AgentServer(path: Self.socketPath, controller: controller)
            try s.start()
            server = s
            statusMessage = nil
        } catch {
            // Fail closed: if the socket can't be created safely, the feature stays off.
            server = nil
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Grants and log

    func revokeAll() {
        let controller = controller
        Task { await controller.revokeAll(); await refresh() }
    }

    func revoke(_ grant: AccessGrant) {
        let controller = controller
        Task { await controller.revoke(grantID: grant.id); await refresh() }
    }

    func refresh() async {
        let snapshot = await controller.snapshot()
        grants = snapshot.grants
        log = snapshot.log
    }

    func revealClientInFinder() {
        let fm = FileManager.default
        let candidates = [Bundle.main.url(forResource: "keyvault_client", withExtension: "py")].compactMap { $0 }
        if let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            statusMessage = "keyvault_client.py wasn't found inside the app. It's in the agent/ folder of the source."
        }
    }
}

// MARK: - Connection to the vault

/// The engine's view of the app. Every call hops to the main actor, where `VaultStore` lives.
final class StoreHost: AgentHost, @unchecked Sendable {
    private weak var store: VaultStore?
    private let approver: any Approving
    /// How long a request waits for the user to unlock. (Variable so tests can shorten it.)
    nonisolated(unsafe) static var unlockWait: TimeInterval = 60

    init(store: VaultStore, approver: any Approving) {
        self.store = store
        self.approver = approver
    }

    func isUnlocked() async -> Bool {
        await MainActor.run { store?.phase == .unlocked }
    }

    func canUnlock() async -> Bool {
        await MainActor.run { store?.phase == .locked }
    }

    func requestUnlock(for requester: Requester) async -> Bool {
        let started = await MainActor.run { () -> Bool in
            guard let store, store.phase == .locked else { return false }
            store.unlockRequestNote = "\(requester.label) is asking for a key. Unlock to continue, or ignore this to refuse."
            Foreground.bringMainWindow()
            return true
        }
        guard started else { return false }

        let deadline = Date().addingTimeInterval(Self.unlockWait)
        var unlocked = false
        while Date() < deadline {
            if await isUnlocked() { unlocked = true; break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await MainActor.run { store?.unlockRequestNote = nil }
        return unlocked
    }

    func entries() async -> [HostEntry] {
        await MainActor.run {
            guard let store, store.phase == .unlocked else { return [] }
            return store.entries.map { HostEntry(id: $0.id, name: $0.name) }
        }
    }

    func secret(for id: UUID) async -> String? {
        await MainActor.run {
            guard let store, store.phase == .unlocked else { return nil }
            return store.entries.first { $0.id == id }?.secret
        }
    }

    func approve(_ request: ApprovalRequest) async -> Decision {
        await approver.ask(request)
    }

    func cancelPendingApprovals() async {
        await MainActor.run {
            approver.cancel()
            store?.unlockRequestNote = nil
        }
    }
}
