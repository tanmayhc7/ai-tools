import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillFinishLaunching(_ notification: Notification) {
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The text being redacted is personal: keep every window out of screenshots and recordings.
        let hide: @Sendable (Notification) -> Void = { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.sharingType = .none }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: hide)
        }
        NSApp.windows.forEach { $0.sharingType = .none }
    }
}

@main
struct RedactApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RedactModel()

    var body: some Scene {
        Window("Redact", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class RedactModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable { case redact = "1. Redact", restore = "2. Restore"; var id: String { rawValue } }

    @Published var mode = Mode.redact
    @Published var input = "" { didSet { if input != oldValue { schedule() } } }
    @Published var reply = ""
    @Published private(set) var output = ""
    @Published private(set) var used: [(placeholder: Placeholder, count: Int)] = []
    @Published private(set) var working = false
    @Published private(set) var copiedRedacted = false
    @Published var errorMessage: String?
    @Published var settings = RedactionSettings() {
        didSet {
            UserDefaults.standard.set(settings.enabled.map(\.rawValue), forKey: "enabledCategories")
            schedule()
        }
    }

    /// Placeholders already handed to an AI (locked in on copy). Previews build on top of it,
    /// so typing doesn't burn placeholder numbers on half-written text.
    private var committedMap = RedactionMap()
    private(set) var previewMap = RedactionMap()
    private var task: Task<Void, Never>?

    init() {
        if let saved = UserDefaults.standard.array(forKey: "enabledCategories") as? [String] {
            settings.enabled = Set(saved.compactMap(Category.init(rawValue:)))
        }
        // Custom terms and kept values are deliberately NOT saved: they are sensitive themselves.
    }

    var tooLarge: Bool { input.count > RedactionEngine.maxInputCharacters }

    var restoreResult: RestoreOutput { RedactionEngine.restore(reply, map: previewMap) }

    private func schedule() {
        task?.cancel()
        copiedRedacted = false
        guard !tooLarge else { output = ""; used = []; return }
        let text = input, settings = settings, base = committedMap
        working = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(text.count > 50_000 ? 500 : 200))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (RedactionOutput, RedactionMap) in
                var map = base
                let out = RedactionEngine.redact(text, settings: settings, map: &map)
                return (out, map)
            }.value
            if Task.isCancelled { return }
            output = result.0.text
            used = result.0.used
            previewMap = result.1
            working = false
        }
    }

    func copyRedacted() {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(output, forType: .string)
        committedMap = previewMap
        copiedRedacted = true
    }

    func copyRestored() {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(restoreResult.text, forType: .string)
        // Restored text contains the real data again: keep it out of clipboard managers.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    func keepVisible(_ p: Placeholder) {
        settings.keep.insert(RedactionMap.normalize(p.original, p.category))
    }

    func hideAgain(_ normalized: String) { settings.keep.remove(normalized) }

    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !settings.customTerms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        settings.customTerms.append(t)
    }

    func clearAll() {
        task?.cancel()
        input = ""; reply = ""; output = ""; used = []
        committedMap = RedactionMap(); previewMap = RedactionMap()
        settings.keep = []
        copiedRedacted = false
        working = false
    }

    // MARK: Files

    static let maxFileBytes = 20 * 1024 * 1024

    func load(file url: URL) {
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= Self.maxFileBytes else { throw LoadError.tooLarge }
            let ext = url.pathExtension.lowercased()
            let text: String
            if ext == "pdf" {
                guard let doc = PDFDocument(url: url), let s = doc.string else { throw LoadError.unreadable }
                text = s
            } else if ext == "webarchive" {
                throw LoadError.unsupported
            } else if ["rtf", "rtfd", "doc", "docx", "odt"].contains(ext) {
                // HTML is deliberately NOT converted here: Apple's HTML importer uses WebKit, which
                // can fetch remote images/CSS and reveal that you opened the file. HTML is read as
                // plain text below instead (the markup is redacted along with everything else).
                text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            } else {
                let data = try Data(contentsOf: url)
                guard !data.prefix(8_000).contains(0) else { throw LoadError.binary }
                text = String(decoding: data, as: UTF8.self)
            }
            guard text.count <= RedactionEngine.maxInputCharacters else { throw LoadError.tooLarge }
            mode = .redact
            input = text
        } catch {
            errorMessage = (error as? LoadError)?.message ?? "Couldn't open that file: \(error.localizedDescription)"
        }
    }

    enum LoadError: Error {
        case tooLarge, binary, unreadable, unsupported
        var message: String {
            switch self {
            case .tooLarge: return "That file is too large. Redact works with up to 2 million characters at a time."
            case .binary: return "That doesn't look like a text document."
            case .unreadable: return "Couldn't read any text from that file."
            case .unsupported: return "Web archives aren't supported. Save the page as text or PDF first."
            }
        }
    }
}
