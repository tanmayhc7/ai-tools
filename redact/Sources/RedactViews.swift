import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: RedactModel

    var body: some View {
        HSplitView {
            Group {
                switch model.mode {
                case .redact: RedactPane()
                case .restore: RestorePane()
                }
            }
            .frame(minWidth: 640)
            SettingsSidebar().frame(minWidth: 260, idealWidth: 290, maxWidth: 340)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(RedactModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openFile() } label: { Label("Open File…", systemImage: "doc.badge.plus") }
                    .help("Open a text, Word, RTF or PDF file")
                Button(role: .destructive) { model.clearAll() } label: { Label("Clear All", systemImage: "trash") }
                    .help("Forget all text and placeholders")
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.load(file: url) }
            }
            return true
        }
        .alert("Redact", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a document to redact"
        if panel.runModal() == .OK, let url = panel.url { model.load(file: url) }
    }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct Editor: View {
    @Binding var text: String
    var placeholder: String
    var editable = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: editable ? $text : .constant(text))
                .font(.system(.body))
                .scrollContentBackground(.hidden)
                .padding(8)
                .autocorrectionDisabled()
            if text.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(.background)
    }
}

struct RedactPane: View {
    @EnvironmentObject private var model: RedactModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PaneHeader(title: "Original", subtitle: "Paste text, or drop a document here") {
                    Text("\(model.input.count.formatted()) chars").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Editor(text: $model.input, placeholder: "Paste the text you want to send to an AI…")
                if model.tooLarge {
                    Label("Too long. Split it into parts under 2 million characters.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
            }
            .frame(minWidth: 300)

            VStack(spacing: 0) {
                PaneHeader(title: "Redacted", subtitle: "Safe to paste into any AI") {
                    if model.working { ProgressView().controlSize(.small) }
                    Button {
                        model.copyRedacted()
                    } label: {
                        Label(model.copiedRedacted ? "Copied" : "Copy", systemImage: model.copiedRedacted ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.output.isEmpty || model.working)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                Divider()
                Editor(text: .constant(model.output), placeholder: "The redacted version appears here.", editable: false)
                if model.copiedRedacted {
                    Label("Copied. When the AI replies, paste its answer into **2. Restore**.", systemImage: "arrow.right.circle")
                        .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.tint.opacity(0.12))
                }
            }
            .frame(minWidth: 300)
        }
    }
}

struct RestorePane: View {
    @EnvironmentObject private var model: RedactModel
    @Local private var copied = false

    var body: some View {
        let result = model.restoreResult
        HSplitView {
            VStack(spacing: 0) {
                PaneHeader(title: "AI reply", subtitle: "Paste the answer that contains placeholders") { EmptyView() }
                Divider()
                Editor(text: $model.reply, placeholder: "Paste the AI's reply here…")
            }
            .frame(minWidth: 300)

            VStack(spacing: 0) {
                PaneHeader(title: "Restored", subtitle: "\(result.restored) placeholder\(result.restored == 1 ? "" : "s") filled back in") {
                    Button {
                        model.copyRestored(); copied = true
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.reply.isEmpty)
                }
                Divider()
                Editor(text: .constant(result.text), placeholder: "Your real names, emails and numbers are put back here. This never leaves your Mac.",
                       editable: false)
                if model.previewMap.isEmpty {
                    note("Nothing to restore yet. Redact some text first, in this same session.", "info.circle", .secondary)
                } else if !result.unknown.isEmpty {
                    note("Not from this session, left as-is: \(result.unknown.joined(separator: ", "))", "exclamationmark.triangle", .orange)
                }
            }
            .frame(minWidth: 300)
        }
        .onChange(of: model.reply) { copied = false }
    }

    private func note(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsSidebar: View {
    @EnvironmentObject private var model: RedactModel
    @Local private var newTerm = ""

    var body: some View {
        List {
            Section("Hidden in this text") {
                if model.used.isEmpty {
                    Text("Nothing detected yet.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.used, id: \.placeholder.key) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.placeholder.token).font(.callout.monospaced().weight(.semibold))
                            Text(item.placeholder.category == .secret ? SecretRules.mask(item.placeholder.original) : item.placeholder.original)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if item.count > 1 { Text("×\(item.count)").font(.caption).foregroundStyle(.secondary) }
                        Button { model.keepVisible(item.placeholder) } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless).help("Don't hide this one")
                    }
                }
                if !model.settings.keep.isEmpty {
                    DisclosureGroup("Left visible (\(model.settings.keep.count))") {
                        ForEach(Array(model.settings.keep).sorted(), id: \.self) { k in
                            HStack {
                                Text(k.split(separator: "|", maxSplits: 1).last.map(String.init) ?? k)
                                    .font(.caption).lineLimit(1)
                                Spacer()
                                Button { model.hideAgain(k) } label: { Image(systemName: "eye.slash") }
                                    .buttonStyle(.borderless).help("Hide it again")
                            }
                        }
                    }
                    .font(.callout)
                }
            }

            Section("Always hide these words") {
                HStack {
                    TextField("e.g. Project Falcon", text: $newTerm).onSubmit(add)
                        .autocorrectionDisabled()
                    Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).count < 2)
                }
                ForEach(model.settings.customTerms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button { model.settings.customTerms.removeAll { $0 == term } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                Text("Names are found by Apple's on-device language model and can be missed in short fragments. Add anything that must never leak here. These words are not saved when you quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What to detect") {
                ForEach(Category.allCases.filter { $0 != .custom }) { c in
                    Toggle(c.label, isOn: Binding(
                        get: { model.settings.enabled.contains(c) },
                        set: { on in if on { model.settings.enabled.insert(c) } else { model.settings.enabled.remove(c) } }))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func add() { model.addTerm(newTerm); newTerm = "" }
}
