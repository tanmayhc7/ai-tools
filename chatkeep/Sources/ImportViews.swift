import SwiftUI
import AppKit

enum ImportPicker {
    static func choose(_ completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the zip file you downloaded from ChatGPT or Claude (or the folder you unzipped it to)."
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch browser.importState {
            case .idle:
                idle
            case .running:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Importing…").font(.title3.weight(.semibold))
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: store.importProgress ?? "Working…").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Text("Large exports can take a minute. Everything is read and encrypted on this Mac.").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Cancel") { browser.finishImport() } }
                }
            case .finished(let outcome):
                result(outcome)
            case .failed(let message):
                Text("Import didn't finish").font(.title3.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Close") { browser.finishImport() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(browser.importState == .running)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import an export").font(.title3.weight(.semibold))
            Text("Choose the zip you downloaded from ChatGPT or Claude. You can import again later: conversations you already have are updated, never duplicated, and ones you removed stay removed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { browser.finishImport() }.keyboardShortcut(.cancelAction)
                Button("Choose Export…") { ImportPicker.choose { browser.startImport($0) } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func result(_ o: ImportOutcome) -> some View {
        let r = o.report
        Text(r.fatalError != nil ? "Nothing imported" : (r.cancelled ? "Import cancelled" : "Import complete")).font(.title3.weight(.semibold))
        if let fatal = r.fatalError {
            Text(fatal).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if r.cancelled {
            Text("Nothing was changed.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                line("plus.circle.fill", .green, "\(o.added.formatted()) new conversation\(o.added == 1 ? "" : "s")")
                if o.updated > 0 { line("arrow.triangle.2.circlepath", .blue, "\(o.updated.formatted()) updated with newer messages") }
                if o.unchanged > 0 { line("equal.circle", .secondary, "\(o.unchanged.formatted()) already in your archive") }
                if o.skippedDeleted > 0 { line("trash", .secondary, "\(o.skippedDeleted.formatted()) skipped because you removed them earlier") }
                ForEach(ChatSource.allCases) { s in
                    if let n = r.bySource[s] { Text("\(s.label): \(n.formatted()) found").font(.caption).foregroundStyle(.secondary).padding(.leading, 26) }
                }
            }
            if !r.truncatedFiles.isEmpty {
                warning("\(r.truncatedFiles.joined(separator: ", ")) was cut off, so only the conversations before the cut were imported. Download the export again if you need the rest.")
            }
            if r.oversized > 0 { warning("\(r.oversized) conversation\(r.oversized == 1 ? " was" : "s were") too large to import.") }
            if r.emptyOrUnrecognised > 0 { Text("\(r.emptyOrUnrecognised.formatted()) entries were empty or in a format ChatKeep doesn't recognise, and were skipped.").font(.caption).foregroundStyle(.secondary) }
            ForEach(r.warnings, id: \.self) { warning($0) }
        }
        HStack { Spacer(); Button("Done") { browser.finishImport() }.keyboardShortcut(.defaultAction) }
    }

    private func line(_ icon: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(color) }.font(.callout)
    }

    private func warning(_ text: String) -> some View {
        Label { Text(verbatim: text).font(.caption).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
