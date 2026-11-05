import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillFinishLaunching(_ notification: Notification) {
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)   // KeyVault keys may be in memory during a scan
        setrlimit(RLIMIT_CORE, &noCore)
    }
}

@main
struct LeakGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        Window("LeakGuard", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1000, height: 680)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum Logo {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()
}

@MainActor
final class ScanModel: ObservableObject {
    enum Phase { case idle, scanning, done }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var folder: URL?
    @Published private(set) var repoRoot: URL?
    @Published private(set) var hookStatus = HookInstaller.Status.notRepo
    @Published private(set) var progressText = ""
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var summary = ScanSummary()
    @Published var includeHistory = true
    @Published var checkVault = false
    @Published var errorMessage: String?

    private var cancellation: ScanCancellation?

    var vaultAvailable: Bool { VaultReader.exists }
    var gitAvailable: Bool { GitRunner.isAvailable }

    /// Files sorted with the most findings first; history and current findings together.
    var groupedFindings: [(file: String, items: [Finding])] {
        Dictionary(grouping: findings, by: \.file)
            .map { (file: $0.key, items: $0.value.sorted { ($0.source.isHistory ? 1 : 0, $0.line) < ($1.source.isHistory ? 1 : 0, $1.line) }) }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.file < $1.file }
    }

    var uniqueSecrets: Int { Set(findings.map(\.fingerprint)).count }
    var hasHistoryFindings: Bool { findings.contains { $0.source.isHistory } }

    func select(folder url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Please choose a folder, not a file."
            return
        }
        cancel()
        folder = url
        findings = []
        summary = ScanSummary()
        phase = .idle
        repoRoot = nil
        hookStatus = .notRepo
        Task.detached(priority: .userInitiated) {
            let root = GitRunner.repoRoot(of: url)
            let status = HookInstaller.status(repo: root)
            await MainActor.run {
                guard self.folder == url else { return }
                self.repoRoot = root
                self.hookStatus = status
            }
        }
    }

    func startScan(vault: [VaultSecret] = []) {
        guard let folder, phase != .scanning else { return }
        let cancel = ScanCancellation()
        cancellation = cancel
        phase = .scanning
        findings = []
        progressText = "Starting…"
        let history = includeHistory && gitAvailable

        Task.detached(priority: .userInitiated) { [weak self] in
            var lastUpdate = Date.distantPast
            let (found, summary) = Scanner.scan(root: folder, includeHistory: history, vault: vault,
                                                cancel: cancel) { text in
                guard Date().timeIntervalSince(lastUpdate) > 0.1 else { return }
                lastUpdate = Date()
                Task { @MainActor in self?.progressText = text }
            }
            // `vault` goes out of scope here; secrets are not kept after the scan.
            await self?.finish(found: found, summary: summary, cancel: cancel)
        }
    }

    private func finish(found: [Finding], summary: ScanSummary, cancel: ScanCancellation) {
        guard cancellation === cancel else { return }   // a newer scan or a cancel superseded this one
        findings = found
        self.summary = summary
        phase = .done
        cancellation = nil
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        if phase == .scanning { phase = .idle }
    }

    func reset() {
        cancel()
        folder = nil
        findings = []
        phase = .idle
    }

    func installHook() { hookAction { try HookInstaller.install(repo: $0) } }
    func removeHook() { hookAction { try HookInstaller.uninstall(repo: $0) } }

    private func hookAction(_ action: (URL) throws -> Void) {
        guard let repoRoot else { return }
        do { try action(repoRoot) } catch { errorMessage = error.localizedDescription }
        hookStatus = HookInstaller.status(repo: repoRoot)
    }
}
