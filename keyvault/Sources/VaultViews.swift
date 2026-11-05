import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum EditorTarget: Identifiable {
    case new
    case edit(APIKeyEntry)
    var id: String {
        switch self { case .new: return "new"; case .edit(let e): return e.id.uuidString }
    }
}

struct VaultView: View {
    @EnvironmentObject private var store: VaultStore
    @Local private var selection: APIKeyEntry.ID?
    @Local private var search = ""
    @Local private var editing: EditorTarget?
    @Local private var changingPassword = false
    @Local private var errorMessage: String?

    private var filtered: [APIKeyEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.entries
            .filter { q.isEmpty || $0.name.lowercased().contains(q)
                || $0.service.lowercased().contains(q) || $0.notes.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { entry in
                EntryRow(entry: entry).tag(entry.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search keys")
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("No keys yet", systemImage: "key",
                                           description: Text("Click + to add your first API key."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selection, let entry = store.entries.first(where: { $0.id == id }) {
                EntryDetailView(entry: entry,
                                onEdit: { editing = .edit(entry) },
                                onDelete: { run { try store.delete(id: entry.id); selection = nil } })
                    .id(entry.id)
            } else {
                ContentUnavailableView("Select a key", systemImage: "key.horizontal",
                                       description: Text("\(store.entries.count) key\(store.entries.count == 1 ? "" : "s") stored · encrypted with AES-256-GCM"))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editing = .new } label: { Label("Add Key", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Add an API key (⌘N)")
                Menu {
                    Button("Change Master Password…") { changingPassword = true }
                    Picker("Auto-lock After", selection: $store.autoLockMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                    Divider()
                    Button("Export Encrypted Backup…") { exportBackup() }
                    Button("Show Vault File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([VaultStore.vaultURL])
                    }
                } label: { Label("Settings", systemImage: "gearshape") }
                Button { store.lock() } label: { Label("Lock", systemImage: "lock.fill") }
                    .help("Lock vault (⌘L)")
            }
        }
        .sheet(item: $editing) { target in
            EntryEditor(target: target) { entry in
                run {
                    switch target {
                    case .new: try store.add(entry); selection = entry.id
                    case .edit: try store.update(entry)
                    }
                }
            }
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                             set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "Export Encrypted Backup"
        panel.message = "The file stays encrypted. You'll need your current master password to open it."
        panel.nameFieldStringValue = "KeyVault-backup-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try store.export(to: url) }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 30

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct EntryRow: View {
    let entry: APIKeyEntry
    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: entry.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                if !entry.service.isEmpty {
                    Text(entry.service).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct EntryDetailView: View {
    let entry: APIKeyEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var store: VaultStore
    @Local private var revealed = false
    @Local private var copiedAt: Date?
    @Local private var confirmDelete = false

    private var masked: String {
        let tail = entry.secret.count > 12 ? String(entry.secret.suffix(4)) : ""
        return String(repeating: "•", count: 20) + tail
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Avatar(name: entry.name, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.title.weight(.semibold)).textSelection(.enabled)
                        if !entry.service.isEmpty {
                            Text(entry.service).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                }

                section("API Key") {
                    Text(revealed ? entry.secret : masked)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 8) {
                        Button { revealed.toggle() } label: {
                            Label(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye")
                        }
                        Button {
                            store.copyToClipboard(entry.secret)
                            copiedAt = Date()
                        } label: {
                            Label(copiedAt == nil ? "Copy" : "Copied", systemImage: copiedAt == nil ? "doc.on.doc" : "checkmark")
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        if copiedAt != nil {
                            Text("Clipboard clears in \(VaultStore.clipboardClearSeconds)s")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !entry.notes.isEmpty {
                    section("Notes") {
                        Text(entry.notes).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                section("Details") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Created").foregroundStyle(.secondary)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        GridRow {
                            Text("Modified").foregroundStyle(.secondary)
                            Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.callout)
                }

                HStack {
                    Button("Edit", action: onEdit)
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(VaultStore.clipboardClearSeconds))
            copiedAt = nil
        }
        .confirmationDialog("Delete “\(entry.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("This permanently removes the key from your vault.")
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct EntryEditor: View {
    let target: EditorTarget
    let onSave: (APIKeyEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @Local private var name: String
    @Local private var service: String
    @Local private var secret: String
    @Local private var notes: String
    @Local private var showSecret = false

    init(target: EditorTarget, onSave: @escaping (APIKeyEntry) -> Void) {
        self.target = target
        self.onSave = onSave
        var existing: APIKeyEntry?
        if case .edit(let e) = target { existing = e }
        _name = Local(wrappedValue: existing?.name ?? "")
        _service = Local(wrappedValue: existing?.service ?? "")
        _secret = Local(wrappedValue: existing?.secret ?? "")
        _notes = Local(wrappedValue: existing?.notes ?? "")
    }

    private var isNew: Bool { if case .new = target { return true }; return false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSecret: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add API Key" : "Edit API Key")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. OpenAI – production"))
                TextField("Service", text: $service, prompt: Text("e.g. api.openai.com"))
                HStack {
                    Group {
                        if showSecret {
                            TextField("API key", text: $secret, prompt: Text("Paste key"))
                        } else {
                            SecureField("API key", text: $secret, prompt: Text("Paste key"))
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    Button { showSecret.toggle() } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showSecret ? "Hide key" : "Show key")
                }
                TextField("Notes", text: $notes, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedSecret.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    private func save() {
        var entry: APIKeyEntry
        if case .edit(let e) = target { entry = e } else {
            entry = APIKeyEntry(name: "", service: "", secret: "", notes: "")
        }
        entry.name = trimmedName
        entry.service = service.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.secret = trimmedSecret
        entry.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(entry)
        dismiss()
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Local private var current = ""
    @Local private var new = ""
    @Local private var confirm = ""
    @Local private var busy = false
    @Local private var error: String?

    private var valid: Bool { !current.isEmpty && PasswordPolicy.problem(new) == nil && new == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Master Password").font(.title3.weight(.semibold))
            Text("Your vault is re-encrypted with a key derived from the new password and a fresh salt.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Current password", text: $current)
            SecureField("New password (12+ characters)", text: $new)
            SecureField("Confirm new password", text: $confirm)
            StrengthMeter(password: new)
            if !new.isEmpty, let p = PasswordPolicy.problem(new) {
                Text(p).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: change) {
                    if busy { ProgressView().controlSize(.small) } else { Text("Change Password") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || busy)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 400)
    }

    private func change() {
        busy = true; error = nil
        Task {
            do {
                try await store.changePassword(current: current, new: new)
                dismiss()
            } catch VaultError.wrongPassword {
                error = "Current password is incorrect."
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
