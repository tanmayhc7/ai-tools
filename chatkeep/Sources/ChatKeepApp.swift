import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No core dumps: a crash must never write decrypted conversations to disk.
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
        // Refuse debugger attachment (ptrace isn't exported to Swift, so look it up: RTLD_DEFAULT = -2, PT_DENY_ATTACH = 31).
        typealias Ptrace = @convention(c) (CInt, pid_t, UnsafeMutableRawPointer?, CInt) -> CInt
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ptrace") {
            _ = unsafeBitCast(sym, to: Ptrace.self)(31, 0, nil, 0)
        }
        if !ArchiveStore.acquireInstanceLock() {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.chatkeep.app")
                .filter { $0 != NSRunningApplication.current }
            if let other = others.first { other.activate() } else {
                let alert = NSAlert()
                alert.messageText = "ChatKeep is already open"
                alert.informativeText = "Only one copy can run at a time, so changes can't overwrite each other."
                alert.runModal()
            }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Your conversations stay out of screenshots and screen recordings, including sheets.
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
struct ChatKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: ArchiveStore
    @StateObject private var browser: BrowserModel

    init() {
        let s = ArchiveStore()
        _store = StateObject(wrappedValue: s)
        _browser = StateObject(wrappedValue: BrowserModel(store: s))
    }

    var body: some Scene {
        Window("ChatKeep", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(browser)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Archive") {
                Button("Import an Export…") { browser.presenting = .importExport }
                    .keyboardShortcut("i", modifiers: .command).disabled(store.phase != .unlocked)
                Button("Check for Leaked Secrets…") { browser.presenting = .leakCheck }
                    .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(store.phase != .unlocked)
                Divider()
                Button("Lock Archive") { store.lock() }.keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
