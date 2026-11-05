import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel
    @Local private var askVaultPassword = false

    var body: some View {
        Group {
            if model.folder == nil {
                DropZone()
            } else {
                VStack(spacing: 0) {
                    HeaderBar(onScan: scan)
                    Divider()
                    switch model.phase {
                    case .idle:     ReadyView(onScan: scan)
                    case .scanning: ScanningView()
                    case .done:     ResultsView()
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadFolder(from: providers) { model.select(folder: $0) }
        }
        .sheet(isPresented: $askVaultPassword) {
            VaultPasswordSheet { secrets in model.startScan(vault: secrets) }
        }
        .alert("LeakGuard", isPresented: Binding(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private func scan() {
        if model.checkVault && model.vaultAvailable { askVaultPassword = true } else { model.startScan() }
    }
}

// MARK: Folder selection

func chooseFolder(_ completion: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Scan"
    panel.message = "Choose a project folder or git repository to scan for leaked secrets."
    if panel.runModal() == .OK, let url = panel.url { completion(url) }
}

func loadFolder(from providers: [NSItemProvider], _ completion: @escaping (URL) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
        return false
    }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async { completion(url) }
    }
    return true
}

struct DropZone: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: Logo.image).resizable().interpolation(.high).frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Find leaked API keys").font(.title2.weight(.semibold))
                Text("Scans a project's files and its entire git history for API keys, tokens and private keys.\nEverything stays on this Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Drop a project folder here").font(.headline)
                Button("Choose Folder…") { chooseFolder { model.select(folder: $0) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(width: 420, height: 170)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(.quaternary))
            if !model.gitAvailable {
                Label("Git isn't installed, so history scanning is off. Run: xcode-select --install",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Header

struct HeaderBar: View {
    @EnvironmentObject private var model: ScanModel
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.repoRoot == nil ? "folder.fill" : "point.3.connected.trianglepath.dotted")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder?.lastPathComponent ?? "").font(.headline)
                Text(model.folder?.path(percentEncoded: false) ?? "").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("Git history", isOn: $model.includeHistory)
                .disabled(model.repoRoot == nil || !model.gitAvailable || model.phase == .scanning)
                .help(model.repoRoot == nil ? "This folder isn't a git repository" : "Also scan every past commit")
            Toggle("My KeyVault keys", isOn: $model.checkVault)
                .disabled(!model.vaultAvailable || model.phase == .scanning)
                .help(model.vaultAvailable ? "Also look for the exact keys stored in your KeyVault" : "No KeyVault vault found on this Mac")
            Button("Change…") { chooseFolder { model.select(folder: $0) } }
                .disabled(model.phase == .scanning)
            if model.phase == .scanning {
                Button("Stop", role: .cancel) { model.cancel() }
            } else {
                Button(model.phase == .done ? "Scan Again" : "Scan", action: onScan)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct ReadyView: View {
    @EnvironmentObject private var model: ScanModel
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Ready to scan").font(.title3.weight(.semibold))
            Text(model.repoRoot != nil && model.includeHistory
                 ? "Current files and every commit in the repository's history will be checked."
                 : "All text files in this folder will be checked.")
                .foregroundStyle(.secondary)
            Button("Scan Now", action: onScan).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningView: View {
    @EnvironmentObject private var model: ScanModel
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning…").font(.title3.weight(.semibold))
            Text(model.progressText).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Results

struct ResultsView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        HSplitView {
            List {
                if model.findings.isEmpty {
                    CleanBanner()
                } else {
                    ForEach(model.groupedFindings, id: \.file) { group in
                        Section {
                            ForEach(group.items) { FindingRow(finding: $0) }
                        } header: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(group.file).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer()
                                Text("\(group.items.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 460)

            SidePanel().frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
    }
}

struct CleanBanner: View {
    @EnvironmentObject private var model: ScanModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(model.summary.cancelled ? "Scan stopped. Nothing found so far." : "No secrets found")
                .font(.title3.weight(.semibold))
            Text("Checked \(model.summary.filesScanned) files"
                 + (model.summary.commitsScanned > 0 ? " and \(model.summary.commitsScanned) commits." : "."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.source.isHistory ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.source.isHistory ? .orange : .red)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(finding.ruleName).font(.callout.weight(.semibold))
                    if let name = finding.vaultEntryName {
                        Text("In KeyVault: \(name)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.purple.opacity(0.18), in: Capsule())
                    }
                }
                Text(finding.masked).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Line \(finding.line) · \(finding.source.label)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy Location") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(finding.file):\(finding.line)", forType: .string)
            }
            if case .history(let commit, _) = finding.source {
                Button("Copy Commit ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit, forType: .string)
                }
            }
        }
    }
}

struct SidePanel: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryBox
                if !model.findings.isEmpty { adviceBox }
                hookBox
            }
            .padding(18)
        }
        .background(.background.secondary)
    }

    private var summaryBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUMMARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !model.findings.isEmpty {
                Text("\(model.uniqueSecrets) secret\(model.uniqueSecrets == 1 ? "" : "s") in \(Set(model.findings.map(\.file)).count) file\(Set(model.findings.map(\.file)).count == 1 ? "" : "s")")
                    .font(.title3.weight(.semibold)).foregroundStyle(.red)
            }
            stat("Files scanned", model.summary.filesScanned)
            if model.summary.commitsScanned > 0 { stat("Commits scanned", model.summary.commitsScanned) }
            if model.summary.skippedBinary > 0 { stat("Binary files skipped", model.summary.skippedBinary) }
            if model.summary.skippedLarge > 0 { stat("Files over 5 MB skipped", model.summary.skippedLarge) }
            if model.summary.skippedSymlinks > 0 { stat("Symlinks not followed", model.summary.skippedSymlinks) }
            if model.summary.skippedUnreadable > 0 { stat("Unreadable files", model.summary.skippedUnreadable) }
            if let err = model.summary.historyError {
                Label("History not fully scanned: \(err)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.summary.truncated {
                Label("Stopped after \(Scanner.maxFindings) findings.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text("\(n)").monospacedDigit() }.font(.callout)
    }

    private var adviceBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            advice("1", "Rotate the key first.", "Create a new key in the provider's dashboard and revoke the old one. Assume a leaked key is already compromised.")
            advice("2", "Move it out of the code.", "Read it from an environment variable or a git-ignored .env file.")
            if model.hasHistoryFindings {
                advice("3", "History keeps old keys.", "Deleting a file doesn't remove it from past commits. After rotating, rewrite history with git filter-repo if the repo is shared.")
            }
        }
    }

    private func advice(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.weight(.bold)).frame(width: 18, height: 18)
                .background(.tint.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var hookBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVENT FUTURE LEAKS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch model.hookStatus {
            case .notRepo:
                Text("Open a git repository to install a pre-commit check.").font(.caption).foregroundStyle(.secondary)
            case .notInstalled:
                Text("Install a git hook that blocks any commit adding an API key.").font(.caption).foregroundStyle(.secondary)
                Button("Install Pre-commit Hook") { model.installHook() }
            case .installed:
                Label("Pre-commit hook installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Button("Remove Hook") { model.removeHook() }
            case .otherHookPresent:
                Text("This repo already has a pre-commit hook. LeakGuard won't overwrite it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: KeyVault

struct VaultPasswordSheet: View {
    let onUnlock: ([VaultSecret]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var password = ""
    @Local private var busy = false
    @Local private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check against your KeyVault").font(.title3.weight(.semibold))
            Text("Enter your KeyVault master password. Your keys are decrypted in memory for this scan only, and are never saved or shown.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Master password", text: $password).textFieldStyle(.roundedBorder).onSubmit(unlock)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: unlock) {
                    if busy { ProgressView().controlSize(.small) } else { Text("Unlock & Scan") }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || busy)
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
                case .success(let secrets):
                    password = ""
                    dismiss()
                    onUnlock(secrets)
                case .failure(let err):
                    error = err.localizedDescription
                    password = ""
                }
            }
        }
    }
}
