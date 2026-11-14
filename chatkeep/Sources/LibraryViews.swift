import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        Group {
            switch store.phase {
            case .setup: SetupView()
            case .locked: UnlockView()
            case .unlocked: LibraryView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.phase)
        .sheet(item: $browser.presenting) { sheet in
            switch sheet {
            case .importExport: ImportSheet()
            case .leakCheck: LeakCheckView()
            case .changePassword: ChangePasswordView()
            }
        }
    }
}

// MARK: - Helpers

enum Display {
    static func date(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "" }

    static func badgeColor(_ s: ChatSource) -> Color { s == .chatgpt ? .green : .orange }

    /// Bold, yellow-backed ranges (character offsets) inside `text`.
    static func highlighted(_ text: String, ranges: [Range<Int>]) -> AttributedString {
        var out = AttributedString(text)
        let count = text.count
        for r in ranges where r.lowerBound >= 0 && r.upperBound <= count && r.lowerBound < r.upperBound {
            let a = out.characters.index(out.startIndex, offsetBy: r.lowerBound)
            let b = out.characters.index(out.startIndex, offsetBy: r.upperBound)
            out[a..<b].backgroundColor = Color.yellow.opacity(0.45)
            out[a..<b].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }

    /// Highlights every occurrence of the search words in a message (capped, so a huge message stays quick).
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var out = AttributedString(text)
        var marked = 0
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex, marked < 300, let r = SearchIndex.find(term, in: text, from: from) {
                let lower = text.distance(from: text.startIndex, to: r.lowerBound)
                let upper = text.distance(from: text.startIndex, to: r.upperBound)
                let a = out.characters.index(out.startIndex, offsetBy: lower)
                let b = out.characters.index(out.startIndex, offsetBy: upper)
                out[a..<b].backgroundColor = Color.yellow.opacity(0.45)
                from = r.upperBound; marked += 1
            }
        }
        return out
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)          // never syncs to other devices
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))   // clipboard managers skip it
    }

    static func transcript(_ c: Conversation) -> String {
        c.messages.map { "\($0.role.label):\n\($0.text)" }.joined(separator: "\n\n")
    }
}

struct SourceBadge: View {
    let source: ChatSource
    var body: some View {
        Text(source.label).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Display.badgeColor(source).opacity(0.18), in: Capsule())
            .foregroundStyle(Display.badgeColor(source))
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            if let id = browser.selectedID, let c = store.conversation(id: id) {
                TranscriptView(conversation: c).id("\(c.id)#\(browser.focusMessage ?? -1)#\(browser.highlightTerms.joined(separator: ","))")
            } else if store.conversations.isEmpty {
                EmptyLibraryView()
            } else {
                ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("\(store.conversations.count.formatted()) conversations · encrypted on this Mac"))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { browser.presenting = .importExport } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import a ChatGPT or Claude export (⌘I)")
                Button { browser.presenting = .leakCheck } label: { Label("Leak Check", systemImage: "exclamationmark.shield") }
                    .help("Look for API keys and personal data you pasted into chats (⇧⌘L)")
                Menu {
                    Picker("Auto-lock After", selection: $store.autoLockMinutes) {
                        Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("Never").tag(0)
                    }
                    Button("Change Password…") { browser.presenting = .changePassword }
                    Divider()
                    Button("Show Archive File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                } label: { Label("Settings", systemImage: "gearshape") }
                Button { store.lock() } label: { Label("Lock", systemImage: "lock.fill") }.help("Lock (⌘L)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { browser.startImport(url) }
            }
            return true
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you've said to an AI", text: $browser.query).textFieldStyle(.plain)
                if browser.searching { ProgressView().controlSize(.small) }
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)

            HStack(spacing: 6) {
                Menu {
                    Picker("Service", selection: $browser.source) {
                        Text("All services").tag(ChatSource?.none)
                        ForEach(ChatSource.allCases) { Text($0.label).tag(ChatSource?.some($0)) }
                    }.pickerStyle(.inline)
                } label: { chip(browser.source?.label ?? "All services", active: browser.source != nil) }
                Menu {
                    Picker("Who", selection: $browser.role) {
                        Text("Anyone").tag(ChatRole?.none); Text("Me").tag(ChatRole?.some(.user)); Text("The AI").tag(ChatRole?.some(.assistant))
                    }.pickerStyle(.inline)
                } label: { chip(browser.role == nil ? "Anyone" : (browser.role == .user ? "Me" : "The AI"), active: browser.role != nil) }
                    .disabled(!browser.isSearching)
                Menu {
                    Picker("When", selection: $browser.when) { ForEach(BrowserModel.When.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
                } label: { chip(browser.when.label, active: browser.when != .any) }
                Spacer()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if browser.isSearching { SearchResultsList() } else { ConversationList() }

            Divider()
            HStack(spacing: 6) {
                let messages = store.conversations.reduce(0) { $0 + $1.messages.count }
                Text("\(store.conversations.count.formatted()) conversations · \(messages.formatted()) messages")
                Spacer()
                if store.indexing { ProgressView().controlSize(.mini); Text("Indexing…") }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func chip(_ text: String, active: Bool) -> some View {
        HStack(spacing: 3) { Text(text); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(active ? Color.accentColor : .primary)
    }
}

struct ConversationList: View {
    @EnvironmentObject private var browser: BrowserModel
    var body: some View {
        let items = browser.browsable
        List {
            ForEach(items) { c in
                Button { browser.open(c.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: c.title).font(.callout.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            SourceBadge(source: c.source)
                            Text(Display.date(c.lastActivity)).font(.caption).foregroundStyle(.secondary)
                            Text("· \(c.messages.count) messages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(browser.selectedID == c.id ? Color.accentColor.opacity(0.18) : Color.clear)
            }
        }
        .listStyle(.sidebar)
        .overlay { if items.isEmpty { ContentUnavailableView("Nothing here", systemImage: "tray", description: Text("No conversations match these filters.")) } }
    }
}

struct SearchResultsList: View {
    @EnvironmentObject private var browser: BrowserModel
    var body: some View {
        let results = browser.results
        List {
            if let r = results {
                if let m = r.message { Text(m).foregroundStyle(.secondary) }
                if !r.conversations.isEmpty {
                    Text("\(r.totalMatches.formatted())\(r.truncated ? "+" : "") matching messages in \(r.conversations.count.formatted()) conversations")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(r.conversations) { hit in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(verbatim: hit.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            SourceBadge(source: hit.source)
                        }
                        HStack(spacing: 6) {
                            Text(Display.date(hit.date)); Text("· \(hit.matchCount) match\(hit.matchCount == 1 ? "" : "es")")
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(hit.hits.enumerated()), id: \.offset) { _, h in
                            Button { browser.open(hit.conversationID, message: h.messageIndex) } label: {
                                Text(Display.highlighted(h.snippet, ranges: h.highlights)).font(.caption).lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(browser.selectedID == hit.conversationID ? Color.accentColor.opacity(0.18) : Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if let r = results, r.conversations.isEmpty, r.message == nil, !browser.searching {
                ContentUnavailableView.search(text: browser.query)
            }
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var browser: BrowserModel
    let conversation: Conversation
    @Local private var confirmDelete = false
    @Local private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.offset) { i, m in
                            MessageRow(message: m, terms: browser.highlightTerms, focused: browser.focusMessage == i).id(i)
                        }
                    }
                    .padding(24).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .onAppear {
                    guard let target = browser.focusMessage else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
        .confirmationDialog("Remove “\(conversation.title)” from your archive?", isPresented: $confirmDelete) {
            Button("Remove from Archive", role: .destructive) {
                Task {
                    do { try await store.delete(ids: [conversation.id]); browser.selectedID = nil }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("This only removes it from ChatKeep. The original is still on \(conversation.source.label)'s servers until you delete it there, and importing the same export won't bring it back here.")
        }
        .alert("Couldn't remove it", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: conversation.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    SourceBadge(source: conversation.source)
                    Text("\(conversation.messages.count) messages")
                    if let c = conversation.created { Text("· started \(Display.date(c))") }
                    if let u = conversation.updated { Text("· last active \(Display.date(u))") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Copy Conversation as Text") { Display.copy(Display.transcript(conversation)) }
                Divider()
                Button("Remove from Archive…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let terms: [String]
    let focused: Bool
    @Local private var expanded = false
    private static let previewLimit = 20_000

    var body: some View {
        let long = message.text.count > Self.previewLimit && !expanded
        let shown = long ? String(message.text.prefix(Self.previewLimit)) : message.text
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.role.label).font(.caption.weight(.bold)).foregroundStyle(message.role == .user ? Color.accentColor : .secondary)
                if let t = message.time { Text(t.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                if let note = message.note { Text(verbatim: "· " + note).font(.caption2).foregroundStyle(.secondary) }
            }
            if !shown.isEmpty {
                // Verbatim text only: no Markdown, links, HTML or images are ever interpreted from a transcript.
                Group {
                    if terms.isEmpty { Text(verbatim: TextCleaning.display(shown)) }
                    else { Text(Display.highlighted(TextCleaning.display(shown), terms: terms)) }
                }
                .font(message.role == .tool ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if long {
                Button("Show all \(message.text.count.formatted()) characters") { expanded = true }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .background(message.role == .user ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(focused ? 0.8 : 0), lineWidth: 2))
        .contextMenu { Button("Copy Message") { Display.copy(message.text) } }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var browser: BrowserModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("Import your first export").font(.title2.weight(.semibold))
            Text("Drop a ChatGPT or Claude export here, or choose it.").foregroundStyle(.secondary)
            Button("Choose Export…") { ImportPicker.choose { browser.startImport($0) } }.buttonStyle(.borderedProminent).controlSize(.large)
            VStack(alignment: .leading, spacing: 10) {
                Label("**ChatGPT:** Settings → Data controls → Export data. You'll get an email with a zip file.", systemImage: "1.circle")
                Label("**Claude:** Settings → Privacy → Export data. You'll get an email with a zip file.", systemImage: "2.circle")
                Label("Pick the zip as it is (no need to unzip it). It stays on this Mac and is stored encrypted.", systemImage: "lock.shield")
            }
            .font(.callout).frame(maxWidth: 460, alignment: .leading)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
