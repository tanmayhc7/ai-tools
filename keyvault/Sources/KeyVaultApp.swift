import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No core dumps: a crash must never write decrypted keys to disk.
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
        // Refuse debugger attachment (lldb/gdb) so another process can't read decrypted keys.
        // ptrace isn't exported to Swift, so look it up (RTLD_DEFAULT = -2; PT_DENY_ATTACH = 31).
        typealias Ptrace = @convention(c) (CInt, pid_t, UnsafeMutableRawPointer?, CInt) -> CInt
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ptrace") {
            _ = unsafeBitCast(sym, to: Ptrace.self)(31, 0, nil, 0)
        }

        if !VaultStore.acquireInstanceLock() {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.keyvault.app")
                .filter { $0 != NSRunningApplication.current }
            if let other = others.first {
                other.activate()
            } else {
                let alert = NSAlert()
                alert.messageText = "KeyVault is already open"
                alert.informativeText = "Only one copy can run at a time, so edits can't overwrite each other."
                alert.runModal()
            }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep vault contents out of screenshots and screen recordings — including sheets
        // and any window created later.
        let hide: @Sendable (Notification) -> Void = { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.sharingType = .none }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: hide)
        }
        NSApp.windows.forEach { $0.sharingType = .none }
    }
}

@main
struct KeyVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = VaultStore()

    var body: some Scene {
        Window("KeyVault", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 500)
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Vault") {
                Button("Lock Vault") { store.lock() }
                    .keyboardShortcut("l", modifiers: [.command])
            }
        }
    }
}

enum Logo {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()
}
