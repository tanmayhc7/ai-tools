import SwiftUI
import AppKit

final class ScanCancel: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
final class LeakModel: ObservableObject {
    enum Phase { case idle, scanning, done }

    @Published var phase = Phase.idle
    @Published var secrets = true
    @Published var financial = true
    @Published var emails = false
    @Published var ipAddresses = false
    @Published var aiReplies = true
    @Published var checkVault = false
    @Published private(set) var progress = ""
    @Published private(set) var groups: [LeakGroup] = []
    @Published private(set) var report: LeakReport?
    private var cancellation = ScanCancel()

    var optionsChosen: Bool { secrets || financial || emails || ipAddresses || checkVault }

    func run(conversations: [Conversation], vault: [VaultSecret]) {
        guard phase != .scanning else { return }
        var options = LeakOptions()
        options.secrets = secrets; options.financialAndID = financial; options.emails = emails
        options.ipAddresses = ipAddresses; options.includeAIReplies = aiReplies; options.vault = vault
        let cancel = ScanCancel()
        cancellation = cancel
        phase = .scanning; report = nil; groups = []; progress = "Starting…"
        let throttle = ProgressThrottle()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = LeakScanner.scan(conversations, options: options, isCancelled: { cancel.isCancelled }) { done, total in
                guard throttle.allow() else { return }
                Task { @MainActor in self?.progress = "Checked \(done.formatted()) of \(total.formatted()) conversations" }
            }
            let grouped = result.groups
            await self?.finish(result, grouped, cancel)         // the KeyVault keys in `options` are released here
        }
    }

    private func finish(_ r: LeakReport, _ g: [LeakGroup], _ cancel: ScanCancel) {
        guard cancellation === cancel else { return }
        report = r; groups = g; phase = .done
    }

    func cancel() { cancellation.cancel(); phase = .idle }
}

struct LeakCheckView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LeakModel()
    @Local private var askingVaultPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Leak Check").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Looks through everything you've imported for API keys, passwords and personal numbers you may have pasted into a chat. It runs on this Mac and shows only masked previews.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    options
                    switch model.phase {
                    case .idle: EmptyView()
                    case .scanning:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small); Text(model.progress).font(.callout).foregroundStyle(.secondary)
                            Spacer(); Button("Stop") { model.cancel() }
                        }
                    case .done: results
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 640)
        .sheet(isPresented: $askingVaultPassword) {
            VaultPasswordSheet { secrets in model.run(conversations: store.conversations, vault: secrets) }
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO LOOK FOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("API keys, tokens, private keys and database passwords", isOn: $model.secrets)
            Toggle("Card numbers, bank accounts (IBAN) and US social security numbers", isOn: $model.financial)
            Toggle("Email addresses", isOn: $model.emails)
            Toggle("IP addresses", isOn: $model.ipAddresses)
            Toggle("Also check the AI's replies (it may have repeated what you pasted)", isOn: $model.aiReplies)
            Toggle(isOn: $model.checkVault) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Find my exact KeyVault keys")
                    Text(VaultReader.exists ? "Asks for your KeyVault password. Catches keys in any format." : "No KeyVault vault found on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!VaultReader.exists)
            HStack {
                Spacer()
                Button(model.phase == .done ? "Scan Again" : "Scan \(store.conversations.count.formatted()) Conversations") {
                    if model.checkVault && VaultReader.exists { askingVaultPassword = true }
                    else { model.run(conversations: store.conversations, vault: []) }
                }
                .buttonStyle(.borderedProminent).disabled(!model.optionsChosen || model.phase == .scanning || store.conversations.isEmpty)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if let r = model.report {
            if model.groups.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(r.cancelled ? "Stopped. Nothing found so far." : "Nothing found").font(.headline)
                        Text("Checked \(r.scannedMessages.formatted()) messages in \(r.scannedConversations.formatted()) conversations.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                let chats = Set(model.groups.flatMap { $0.findings.map(\.conversationID) }).count
                Label("\(model.groups.count.formatted()) item\(model.groups.count == 1 ? "" : "s") found in \(chats.formatted()) conversation\(chats == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                if r.cancelled { Text("The scan was stopped early, so this list is incomplete.").font(.caption).foregroundStyle(.orange) }
                ForEach(model.groups.prefix(200)) { group in GroupRow(group: group, onOpen: { f in browser.open(f.conversationID, message: f.messageIndex); dismiss() }) }
                if model.groups.count > 200 { Text("…and \(model.groups.count - 200) more.").font(.caption).foregroundStyle(.secondary) }
                advice
            }
        }
    }

    private var advice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            tip("1", "Rotate any real key.", "Make a new one in the provider's dashboard and revoke the old one. Anything you pasted into a chat has left your control.")
            tip("2", "Deleting the chat doesn't undo it.", "Removing it from ChatGPT or Claude (or from this archive) won't recall what was already sent. Use Remove from Archive on a conversation to clear it from here.")
            tip("3", "Next time, keep keys out of prompts.", "Use Redact to swap secrets for placeholders first, or ContextPack, which removes them for you.")
        }
        .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tip(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.weight(.bold)).frame(width: 18, height: 18).background(.tint.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GroupRow: View {
    @EnvironmentObject private var store: ArchiveStore
    let group: LeakGroup
    let onOpen: (LeakFinding) -> Void
    @Local private var open = false

    private var icon: String {
        switch group.kind {
        case .vaultKey, .secret: return "key.fill"
        case .financial: return "creditcard.fill"
        case .email: return "envelope.fill"
        case .network: return "network"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(group.kind <= .secret ? .red : .orange).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: group.label).font(.callout.weight(.semibold))
                            if let n = group.vaultEntryName {
                                Text(verbatim: "In KeyVault: " + n).font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(.purple.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(verbatim: group.masked).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(group.findings.count)× in \(group.conversationCount) chat\(group.conversationCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if open {
                ForEach(group.findings.prefix(20)) { f in
                    HStack {
                        Text(verbatim: store.conversation(id: f.conversationID)?.title ?? "Conversation").font(.caption).lineLimit(1)
                        Text("· \(f.role.label)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { onOpen(f) }.controlSize(.small)
                    }
                    .padding(.leading, 32)
                }
                if group.findings.count > 20 { Text("…and \(group.findings.count - 20) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 32) }
            }
        }
        .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VaultPasswordSheet: View {
    let onUnlock: ([VaultSecret]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var password = ""
    @Local private var busy = false
    @Local private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check against your KeyVault").font(.title3.weight(.semibold))
            Text("Enter your KeyVault master password. Your keys are decrypted in memory for this scan only, and are never saved or shown. A wrong password counts toward KeyVault's own lockout.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("KeyVault master password", text: $password).textFieldStyle(.roundedBorder).onSubmit(unlock)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: unlock) { if busy { ProgressView().controlSize(.small) } else { Text("Unlock & Scan") } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(password.isEmpty || busy)
            }
        }
        .padding(22).frame(width: 420)
    }

    private func unlock() {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        let pw = password
        Task.detached(priority: .userInitiated) {
            let result = Result { try VaultReader.readSecrets(password: pw) }
            await MainActor.run {
                busy = false
                switch result {
                case .success(let secrets): password = ""; dismiss(); onUnlock(secrets)
                case .failure(let err): error = err.localizedDescription; password = ""
                }
            }
        }
    }
}
