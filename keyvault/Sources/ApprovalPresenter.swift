import SwiftUI
import AppKit

// MARK: - Approval window content

struct ApprovalView: View {
    let request: ApprovalRequest
    let deadline: Date
    let windowMinutes: Int
    let onDecide: (Decision) -> Void
    /// The Allow buttons stay disabled briefly, so a click meant for something else (or a click
    /// lured onto this spot by another app's window) can't approve anything.
    static let armDelay: TimeInterval = 1.0
    private var shownAt: Date { deadline.addingTimeInterval(-ApprovalPresenter.timeout) }

    private var r: Requester { request.requester }
    private func clean(_ s: String, _ n: Int) -> String { AgentProtocol.sanitize(s, maxLength: n) }

    /// A short, readable account of what is running (the script, or the first few arguments).
    private var running: String {
        if let script = r.script { return clean(script, 160) }
        let args = r.arguments.dropFirst().prefix(4).joined(separator: " ")
        return args.isEmpty ? "(no arguments)" : clean(args, 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: Logo.image).resizable().interpolation(.high).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "A program wants this key").font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: clean(request.entryName, 80)).font(.title3.weight(.semibold)).lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                row("Program", clean(r.program, 60), strong: true, badge: r.signature)
                row("Location", clean(r.path, 200), mono: true)
                row("Running", running, mono: true)
                row("In folder", clean(r.workingDirectory, 200), mono: true)
                row("Started by", r.parentPath.isEmpty ? "unknown" : clean((r.parentPath as NSString).lastPathComponent, 60))
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if let reason = request.reason.map({ clean($0, AgentProtocol.maxReasonLength) }), !reason.isEmpty {
                // Labelled as the program's own words: it can say anything.
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "The program says:").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "“\(reason)”").font(.callout).italic()
                }
            }

            if r.signature.isUnverified {
                Label {
                    Text(verbatim: "KeyVault can't tell which script or app this is. Only allow it if you just started it yourself.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text(verbatim: "Refuses automatically in \(left)s").font(.caption).foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let armed = context.date.timeIntervalSince(shownAt) >= Self.armDelay
                HStack {
                    Spacer()
                    // Deny is the default button (Return) and the only one that can take keyboard
                    // focus, so stray typing never approves anything.
                    Button("Allow for \(windowMinutes) Minutes") { onDecide(.allow(seconds: windowMinutes * 60)) }
                        .disabled(!armed).focusable(false)
                    Button("Allow Once") { onDecide(.allowOnce) }
                        .disabled(!armed).focusable(false)
                    Button("Deny") { onDecide(.deny) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, strong: Bool = false, mono: Bool = false,
                     badge: Requester.Signature? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: value)
                    .font(mono ? .system(.caption, design: .monospaced) : (strong ? .callout.weight(.semibold) : .callout))
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                if let badge {
                    Text(verbatim: badge.description).font(.caption2.weight(.medium))
                        .foregroundStyle(badge.isUnverified ? Color.orange : Color.green)
                }
            }
            Spacer(minLength: 0)
        }
    }
}


// MARK: - The approval window

/// The part of the dialog the rest of the app depends on, so tests can stand in for the real window.
@MainActor
protocol Approving: AnyObject {
    func ask(_ request: ApprovalRequest) async -> Decision
    func cancel()
}

@MainActor
final class ApprovalPresenter: NSObject, NSWindowDelegate, Approving {
    /// Seconds before the window refuses on its own. (Variable so tests can shorten it.)
    static var timeout: TimeInterval = 60
    static let windowMinutes = 10

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Decision, Never>?
    private var timeoutTask: Task<Void, Never>?

    func ask(_ request: ApprovalRequest) async -> Decision {
        if continuation != nil { resolve(.cancelled) }     // the controller shows one at a time; belt and braces
        return await withCheckedContinuation { (cont: CheckedContinuation<Decision, Never>) in
            continuation = cont
            let deadline = Date().addingTimeInterval(Self.timeout)
            let view = ApprovalView(request: request, deadline: deadline, windowMinutes: Self.windowMinutes) { [weak self] decision in
                self?.resolve(decision)
            }
            let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
            panel.styleMask = [.titled, .closable]
            panel.title = "KeyVault: key request"
            panel.isFloatingPanel = true          // must come first: it resets the level to "floating"
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.delegate = self
            panel.center()
            self.panel = panel

            Foreground.bring()
            // A headless process (the test harness) builds the window but never puts it on screen.
            if NSApp.activationPolicy() != .prohibited { panel.makeKeyAndOrderFront(nil) }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                if !Task.isCancelled { self?.resolve(.timedOut) }
            }
        }
    }

    /// Dismiss any open window without a decision (the vault locked).
    func cancel() { resolve(.cancelled) }

    private func resolve(_ decision: Decision) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
        cont.resume(returning: decision)
    }

    /// The red close button is a refusal.
    func windowWillClose(_ notification: Notification) {
        if continuation != nil { resolve(.deny) }
    }
}
