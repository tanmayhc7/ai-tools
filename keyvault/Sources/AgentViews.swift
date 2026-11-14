import SwiftUI
import AppKit

// MARK: - Settings → Agent Access

struct AgentAccessView: View {
    @EnvironmentObject private var agent: AgentAccess
    @Environment(\.dismiss) private var dismiss
    /// False only when rendering a picture of the panel (offscreen rendering can't draw scroll views).
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent Access").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            if scrolls { ScrollView { sections } } else { sections }
        }
        .frame(width: 580, height: scrolls ? 600 : nil)
        .task {
            while !Task.isCancelled {
                await agent.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 22) {
            switchSection
            if agent.enabled {
                grantsSection
                activitySection
            }
        }
        .padding(20)
    }

    // MARK: Switch

    private var switchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { agent.enabled }, set: { agent.setEnabled($0) })) {
                Text("Let programs request keys").font(.headline)
            }
            .toggleStyle(.switch)
            Text("Lets scripts and AI agents on this Mac ask for one key at a time. Each request opens a window showing which program is asking. Nothing is released unless you approve it, your master password is only ever typed into KeyVault, and the feature is off until you switch it on. Locking KeyVault cancels everything.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let message = agent.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if agent.enabled {
                HStack(spacing: 10) {
                    Button { agent.revealClientInFinder() } label: { Label("Show Python Client in Finder", systemImage: "doc.text") }
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(AgentAccess.socketPath, forType: .string)
                    } label: { Label("Copy Socket Path", systemImage: "doc.on.doc") }
                }
                .controlSize(.small)
                Text("Python: `from keyvault_client import get_key` then `get_key(\"Key name\")`. The key stays in that program's memory until it exits, so only approve programs you trust.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Active grants

    private var grantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIVE ACCESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !agent.grants.isEmpty { Button("Revoke All") { agent.revokeAll() }.controlSize(.small) }
            }
            if agent.grants.isEmpty {
                Text("None. Programs are asked every time.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(agent.grants) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: AgentProtocol.sanitize(grant.entryName, maxLength: 60)).font(.callout.weight(.semibold))
                        Text(verbatim: grant.requesterLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(grant.expires.timeIntervalSince(context.date)))
                        Text(String(format: "%d:%02d left", left / 60, left % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button("Revoke") { agent.revoke(grant) }.controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Activity log

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if agent.log.isEmpty {
                Text("No requests yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(agent.log.reversed().prefix(50)) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(entry.outcome)).foregroundStyle(color(entry.outcome)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: describe(entry.outcome)).font(.callout.weight(.semibold))
                            Spacer()
                            Text(entry.time, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: entry.keyName).font(.caption).lineLimit(1)
                        Text(verbatim: entry.requester).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func describe(_ o: AccessLogEntry.Outcome) -> String {
        switch o {
        case .allowedOnce: return "Allowed once"
        case .allowedWindow: return "Allowed for a while"
        case .allowedByGrant: return "Allowed (active access)"
        case .denied: return "Denied"
        case .unknownKey: return "No such key"
        case .timedOut: return "No answer"
        case .cancelled: return "Cancelled (vault locked)"
        case .blocked: return "Blocked (too many refusals)"
        case .rateLimited: return "Too many requests"
        case .locked: return "Vault was locked"
        case .badRequest: return "Malformed request"
        case .abandoned: return "Program went away"
        case .paused: return "Paused (many refusals in a row)"
        }
    }

    private func icon(_ o: AccessLogEntry.Outcome) -> String {
        o.delivered ? "checkmark.circle.fill" : (o == .denied || o == .unknownKey || o == .blocked || o == .paused ? "xmark.octagon.fill" : "minus.circle.fill")
    }

    private func color(_ o: AccessLogEntry.Outcome) -> Color {
        o.delivered ? .green : (o == .denied || o == .unknownKey || o == .blocked || o == .badRequest ? .red : .secondary)
    }
}
