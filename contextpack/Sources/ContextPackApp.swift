import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ContextPackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PackModel()

    var body: some Scene {
        Window("ContextPack", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum Logo {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()
}

/// Folder tree for the sidebar.
struct TreeNode: Identifiable, Hashable {
    let id: String          // relative path ("" for root)
    let name: String
    var children: [TreeNode]?
    let file: FileItem?
}

@MainActor
final class PackModel: ObservableObject {
    @Published private(set) var project: Project?
    @Published private(set) var tree: [TreeNode] = []
    @Published private(set) var loading = false
    @Published private(set) var loadProgress = ""
    @Published var selected: Set<String> = [] { didSet { schedulePack() } }
    @Published var format: Packer.Format = .xml {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format"); schedulePack() }
    }
    @Published var filter = ""
    @Published private(set) var result: PackResult?
    @Published private(set) var packing = false
    @Published private(set) var copied = false
    @Published var errorMessage: String?

    /// folder path → every selectable file under it (precomputed for tri-state checkboxes)
    private var descendants: [String: [String]] = [:]
    private var loadCancel: LoadCancellation?
    private var packTask: Task<Void, Never>?

    init() {
        if let raw = UserDefaults.standard.string(forKey: "format"), let f = Packer.Format(rawValue: raw) { format = f }
    }

    var selectedTokens: Int {
        project?.files.reduce(0) { selected.contains($1.path) ? $0 + $1.tokens : $0 } ?? 0
    }

    var filteredFiles: [FileItem] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return project?.files.filter { $0.path.lowercased().contains(q) } ?? []
    }

    func open(folder url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Please choose a folder, not a file."
            return
        }
        loadCancel?.cancel()
        let cancel = LoadCancellation()
        loadCancel = cancel
        loading = true
        loadProgress = "Listing files…"
        project = nil; result = nil; tree = []
        Task.detached(priority: .userInitiated) { [weak self] in
            var last = Date.distantPast
            let p = Packer.load(root: url, cancel: cancel) { done, total in
                guard Date().timeIntervalSince(last) > 0.1 else { return }
                last = Date()
                Task { @MainActor in self?.loadProgress = "Reading \(done) of \(total) files…" }
            }
            await self?.finishLoading(p, cancel: cancel)
        }
    }

    private func finishLoading(_ p: Project, cancel: LoadCancellation) {
        guard loadCancel === cancel else { return }
        project = p
        tree = Self.buildTree(p.files)
        descendants = Self.buildDescendants(p.files)
        selected = Set(p.files.filter(\.selectedByDefault).map(\.path))
        loading = false
    }

    func close() {
        loadCancel?.cancel()
        packTask?.cancel()
        project = nil; tree = []; result = nil; selected = []; loading = false
    }

    // MARK: Selection

    enum CheckState { case on, off, mixed }

    func state(of node: TreeNode) -> CheckState {
        if let f = node.file { return selected.contains(f.path) ? .on : .off }
        let files = descendants[node.id] ?? []
        let n = files.reduce(0) { selected.contains($1) ? $0 + 1 : $0 }
        return n == 0 ? .off : (n == files.count ? .on : .mixed)
    }

    func toggle(_ node: TreeNode) {
        if let f = node.file {
            guard f.selectable else { return }
            if selected.contains(f.path) { selected.remove(f.path) } else { selected.insert(f.path) }
            return
        }
        let files = descendants[node.id] ?? []
        if state(of: node) == .on { selected.subtract(files) } else { selected.formUnion(files) }
    }

    func selectAll() { selected = Set(project?.files.filter(\.selectable).map(\.path) ?? []) }
    func selectNone() { selected = [] }

    // MARK: Packing

    private func schedulePack() {
        packTask?.cancel()
        copied = false
        guard let project else { result = nil; return }
        let sel = selected, fmt = format
        packing = true
        packTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let r = await Task.detached(priority: .userInitiated) { Packer.pack(project, selected: sel, format: fmt) }.value
            if Task.isCancelled { return }
            result = r
            packing = false
        }
    }

    func copy() {
        guard let result else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(result.text, forType: .string)
        copied = true
    }

    func save() {
        guard let result, let project else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name)-context.\(format == .xml ? "xml" : "md")"
        panel.allowedContentTypes = [format == .xml ? .xml : UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(result.text.utf8).write(to: url, options: .atomic) }
        catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    // MARK: Tree building

    private static func buildTree(_ files: [FileItem]) -> [TreeNode] {
        final class Box { var dirs: [String: Box] = [:]; var files: [FileItem] = [] }
        let root = Box()
        for f in files {
            var node = root
            for part in f.path.split(separator: "/").dropLast().map(String.init) {
                let next = node.dirs[part] ?? Box()
                node.dirs[part] = next
                node = next
            }
            node.files.append(f)
        }
        func convert(_ box: Box, _ prefix: String) -> [TreeNode] {
            let dirs = box.dirs.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> TreeNode in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return TreeNode(id: path, name: name, children: convert(box.dirs[name]!, path), file: nil)
            }
            let files = box.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { TreeNode(id: $0.path, name: ($0.path as NSString).lastPathComponent, children: nil, file: $0) }
            return dirs + files
        }
        return convert(root, "")
    }

    private static func buildDescendants(_ files: [FileItem]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for f in files where f.selectable {
            let parts = f.path.split(separator: "/").dropLast()
            var prefix = ""
            for part in parts {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                map[prefix, default: []].append(f.path)
            }
        }
        return map
    }
}
