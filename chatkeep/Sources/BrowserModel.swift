import Foundation
import Combine

/// What the library window is showing: the search box, filters, results and the open conversation.
@MainActor
final class BrowserModel: ObservableObject {
    enum When: String, CaseIterable, Identifiable {
        case any, week, month, year
        var id: String { rawValue }
        var label: String {
            switch self { case .any: return "Any time"; case .week: return "Past week"; case .month: return "Past month"; case .year: return "Past year" }
        }
        var from: Date? {
            let days: Double
            switch self { case .any: return nil; case .week: days = 7; case .month: days = 30; case .year: days = 365 }
            return Date().addingTimeInterval(-days * 86_400)
        }
    }

    enum Sheet: String, Identifiable {
        case importExport, leakCheck, changePassword
        var id: String { rawValue }
    }
    enum ImportState: Equatable {
        case idle, running, finished(ImportOutcome), failed(String)
    }

    let store: ArchiveStore
    @Published var presenting: Sheet?
    @Published private(set) var importState = ImportState.idle

    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var source: ChatSource? { didSet { if source != oldValue { scheduleSearch() } } }
    @Published var role: ChatRole? { didSet { if role != oldValue { scheduleSearch() } } }
    @Published var when = When.any { didSet { if when != oldValue { scheduleSearch() } } }
    @Published private(set) var results: SearchResults?
    @Published private(set) var searching = false
    @Published var selectedID: String?
    /// The message to scroll to and the words to highlight, set when opening a search hit.
    @Published private(set) var focusMessage: Int?
    @Published private(set) var highlightTerms: [String] = []

    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(store: ArchiveStore) {
        self.store = store
        // A new index (after import, delete or unlock) means results may have changed.
        store.$index.sink { [weak self] _ in self?.scheduleSearch() }.store(in: &cancellables)
        store.$phase.sink { [weak self] phase in
            guard let self, phase != .unlocked else { return }
            self.reset()                                    // locked: forget what was on screen
        }.store(in: &cancellables)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Conversations to list when not searching, after the source and date filters.
    var browsable: [Conversation] {
        let from = when.from
        return store.conversations.filter { c in
            if let source, c.source != source { return false }
            if let from, (c.lastActivity ?? .distantPast) < from { return false }
            return true
        }
    }

    // MARK: Importing

    func startImport(_ url: URL) {
        if case .running = importState { return }
        importState = .running
        presenting = .importExport
        Task { [weak self] in
            guard let self else { return }
            do { importState = .finished(try await store.importExport(from: url)) }
            catch { importState = .failed(error.localizedDescription) }
        }
    }

    func finishImport() {
        if case .running = importState { store.cancelImport(); return }
        importState = .idle
        presenting = nil
    }

    func reset() {
        searchTask?.cancel()
        query = ""; source = nil; role = nil; when = .any
        results = nil; searching = false; selectedID = nil; focusMessage = nil; highlightTerms = []
        presenting = nil
        if case .running = importState { importState = .idle }
    }

    func open(_ id: String, message: Int? = nil) {
        selectedID = id
        focusMessage = message
        highlightTerms = isSearching ? SearchIndex.terms(from: query) : []
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearching else { results = nil; searching = false; highlightTerms = []; return }
        let text = query
        let q = SearchQuery(text: text, source: source, role: role, from: when.from, to: nil)
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))                    // wait for typing to pause
            guard !Task.isCancelled, let self else { return }
            guard let index = self.store.index else {
                self.results = SearchResults(message: self.store.indexing ? "Building the search index…" : nil)
                self.searching = false
                return
            }
            let found = await Task.detached(priority: .userInitiated) { index.search(q) }.value
            guard !Task.isCancelled else { return }
            self.results = found
            self.searching = false
        }
    }
}
