import AppKit

enum Foreground {
    /// Brings KeyVault in front of everything so a request can't go unnoticed.
    /// A process with the "prohibited" activation policy (the headless test harness) has no windows
    /// to show and AppKit refuses to reorder them, so there is nothing to do there.
    @MainActor
    static func bring() {
        guard NSApp.activationPolicy() != .prohibited else { return }
        NSApp.unhide(nil)
        for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Same, and also raises the main window (used for the unlock banner).
    @MainActor
    static func bringMainWindow() {
        guard NSApp.activationPolicy() != .prohibited else { return }
        bring()
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}
