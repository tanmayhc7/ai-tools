import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: PackModel

    var body: some View {
        Group {
            if model.loading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(model.loadProgress).foregroundStyle(.secondary)
                    Button("Cancel") { model.close() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.project != nil {
                HSplitView {
                    FileSidebar().frame(minWidth: 300, idealWidth: 380)
                    PackPanel().frame(minWidth: 460)
                }
            } else {
                DropZone()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.open(folder: url) }
            }
            return true
        }
        .alert("ContextPack", isPresented: Binding(get: { model.errorMessage != nil },
                                                   set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

func chooseFolder(_ completion: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open"
    panel.message = "Choose a project folder to pack into a prompt."
    if panel.runModal() == .OK, let url = panel.url { completion(url) }
}

struct DropZone: View {
    @EnvironmentObject private var model: PackModel
    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: Logo.image).resizable().interpolation(.high).frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Turn a project into one prompt").font(.title2.weight(.semibold))
                Text("Pick the files you want, and ContextPack bundles them into a single block of text for any AI.\nSecrets are removed automatically. .gitignore is respected.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Drop a project folder here").font(.headline)
                Button("Choose Folder…") { chooseFolder { model.open(folder: $0) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .frame(width: 420, height: 170)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(.quaternary))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Sidebar

struct FileSidebar: View {
    @EnvironmentObject private var model: PackModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project?.name ?? "").font(.headline)
                    Text(model.project?.usedGitIgnore == true ? "Following .gitignore" : "Default ignore list (not a git repo)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Select All") { model.selectAll() }
                    Button("Select None") { model.selectNone() }
                    Divider()
                    Button("Open Another Folder…") { chooseFolder { model.open(folder: $0) } }
                    Button("Close") { model.close() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            TextField("Filter files", text: $model.filter)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if model.filter.isEmpty {
                List(model.tree, children: \.children) { node in NodeRow(node: node) }
                    .listStyle(.sidebar)
            } else {
                List(model.filteredFiles) { f in
                    NodeRow(node: TreeNode(id: f.path, name: f.path, children: nil, file: f))
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct NodeRow: View {
    @EnvironmentObject private var model: PackModel
    let node: TreeNode

    var body: some View {
        let state = model.state(of: node)
        let file = node.file
        HStack(spacing: 6) {
            Button { model.toggle(node) } label: {
                Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                    .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(file.map { !$0.selectable } ?? false)

            Image(systemName: file == nil ? "folder.fill" : "doc.text")
                .foregroundStyle(file == nil ? Color.accentColor.opacity(0.8) : .secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(file.map { $0.selectable } ?? true ? .primary : .secondary)
            Spacer(minLength: 4)
            if let file {
                switch file.kind {
                case .sensitive:
                    Label("never included", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                        .font(.caption2).foregroundStyle(.red)
                        .help("Looks like a credential file, so ContextPack never reads it.")
                case .tooLarge:
                    Text("over 1 MB").font(.caption2).foregroundStyle(.secondary)
                default:
                    if file.secretCount > 0 {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                            .help("\(file.secretCount) secret\(file.secretCount == 1 ? "" : "s") will be replaced with [REDACTED]")
                    }
                    Text(file.tokens.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: Output panel

struct PackPanel: View {
    @EnvironmentObject private var model: PackModel
    private let windows: [(String, Int)] = [("32K", 32_000), ("128K", 128_000), ("200K", 200_000), ("1M", 1_000_000)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("≈ \(model.selectedTokens.formatted()) tokens").font(.title2.weight(.semibold)).monospacedDigit()
                        Text("\(model.selected.count) files selected").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Format", selection: $model.format) {
                        ForEach(Packer.Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                }

                HStack(spacing: 8) {
                    ForEach(windows, id: \.0) { name, size in
                        let fits = model.selectedTokens <= size
                        Label(name, systemImage: fits ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.caption).foregroundStyle(fits ? .green : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    Text("context windows").font(.caption).foregroundStyle(.secondary)
                }

                if let r = model.result, r.redactedSecrets > 0 {
                    Label("\(r.redactedSecrets) secret\(r.redactedSecrets == 1 ? "" : "s") replaced with [REDACTED]", systemImage: "checkmark.shield.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                notes

                HStack {
                    Button { model.copy() } label: {
                        Label(model.copied ? "Copied" : "Copy to Clipboard", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("Save As…") { model.save() }.controlSize(.large)
                    if model.packing { ProgressView().controlSize(.small).padding(.leading, 6) }
                }
                .disabled(model.result == nil || model.selected.isEmpty || model.packing)
            }
            .padding(20)
            Divider()
            Text("PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 10)
            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    private var preview: String {
        guard let text = model.result?.text, !text.isEmpty else { return "Select files to see the packed prompt." }
        let limit = 40_000
        return text.count > limit ? String(text.prefix(limit)) + "\n\n… (preview truncated. Copy or save to get everything)" : text
    }

    @ViewBuilder private var notes: some View {
        if let p = model.project {
            let sensitive = p.files.filter { $0.kind == .sensitive }.count
            VStack(alignment: .leading, spacing: 4) {
                if sensitive > 0 { note("\(sensitive) credential file\(sensitive == 1 ? "" : "s") (like .env) excluded", "lock.fill") }
                if p.skippedBinary > 0 { note("\(p.skippedBinary) binary files skipped", "photo") }
                if p.skippedSymlinks > 0 { note("\(p.skippedSymlinks) symlinks not followed", "link") }
                if p.truncated { note("Very large project: only the first \(Packer.maxFiles.formatted()) files were read", "exclamationmark.triangle") }
            }
        }
    }

    private func note(_ s: String, _ icon: String) -> some View {
        Label(s, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }
}
