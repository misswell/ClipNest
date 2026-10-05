import Foundation
import Combine

@MainActor
final class VaultKnowledgeIndex: ObservableObject {
    @Published private(set) var notes: [URL: NoteKnowledge] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var bookmarks: [String] = []
    @Published private(set) var revision = 0
    private var files: [URL: NoteKnowledge] = [:]
    private(set) var root: URL?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var generation = 0
    private var hasRequestedIndex = false
    private var stamps: [URL: String] = [:]
    private var lookup: NoteLinkResolver?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .vaultFilesDidChange, object: nil, queue: .main) { [weak self] notification in
            let paths = notification.userInfo?["paths"] as? [String] ?? []
            Task { @MainActor [weak self] in
                guard let self, self.hasRequestedIndex, let root = self.root,
                      paths.contains(where: { $0.hasPrefix(root.path + "/") }) else { return }
                for path in paths { self.stamps.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL) }
                self.refresh()
            }
        }
    }

    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(_ root: URL?) {
        let normalized = root?.standardizedFileURL
        guard self.root != normalized else { return }
        generation += 1
        task?.cancel()
        self.root = normalized
        notes = [:]
        files = [:]
        revision += 1
        stamps = [:]
        lookup = nil
        errors = []
        isLoading = false
        hasRequestedIndex = false
        bookmarks = normalized.flatMap { UserDefaults.standard.stringArray(forKey: bookmarkKey($0)) } ?? []
    }

    func refresh() {
        guard let root else { return }
        hasRequestedIndex = true
        generation += 1
        let request = generation
        task?.cancel()
        isLoading = true
        let previousNotes = notes
        let previousStamps = stamps
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let catalog = await Task.detached(priority: .utility) {
                VaultNoteCatalog.files(in: root).map { url in
                    (url, try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]))
                }
            }.value
            var notes: [URL: NoteKnowledge] = [:]
            var errors: [String] = []
            var stamps: [URL: String] = [:]
            var otherFiles: [URL: NoteKnowledge] = [:]
            for (url, metadata) in catalog {
                guard !Task.isCancelled else { return }
                if !FileNode.markdownExtensions.contains(url.pathExtension.lowercased()) {
                    otherFiles[url] = NoteKnowledge(url: url, links: [], headings: [], tags: [], aliases: [], properties: [:],
                        words: 0, characters: 0, excerpt: "", searchText: "", values: [:],
                        created: metadata?.creationDate, modified: metadata?.contentModificationDate, fileSize: metadata?.fileSize ?? 0)
                    continue
                }
                do {
                    guard let values = metadata else { throw CocoaError(.fileReadUnknown) }
                    guard (values.fileSize ?? 0) < 2_000_000 else {
                        errors.append(url.lastPathComponent + ": " + String(localized: "Note exceeds the 2 MB index limit"))
                        continue
                    }
                    let stamp = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
                    stamps[url] = stamp
                    if previousStamps[url] == stamp, let cached = previousNotes[url] { notes[url] = cached; continue }
                    // Do not download a whole iCloud vault just to show tags or backlinks.
                    guard await VaultFileAccess.shared.hasLocalContents(at: url) else {
                        errors.append(url.lastPathComponent + ": " + String(localized: "Not downloaded"))
                        continue
                    }
                    let text = try await VaultFileAccess.shared.readText(at: url)
                    let note = await Task.detached(priority: .utility) { MarkdownKnowledge.analyze(text, url: url) }.value
                    notes[url] = note
                } catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            guard let self, self.generation == request, self.root == root, !Task.isCancelled else { return }
            self.notes = notes
            self.files = notes.merging(otherFiles) { existing, _ in existing }
            self.lookup = NoteLinkResolver(root: root, files: Array(self.files.keys), aliases: self.aliases)
            self.revision += 1
            self.stamps = stamps
            self.errors = errors
            self.isLoading = false
        }
    }

    func ensureLoaded() { if !hasRequestedIndex { refresh() } }

    func waitUntilLoaded() async {
        ensureLoaded()
        while isLoading, let task, !Task.isCancelled {
            await task.value
        }
    }

    var sortedNotes: [NoteKnowledge] { notes.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending } }
    var sortedFiles: [NoteKnowledge] { files.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending } }
    var aliases: [String: [URL]] {
        var result: [String: [URL]] = [:]
        for note in notes.values {
            for alias in note.aliases { result[alias.lowercased(), default: []].append(note.url) }
        }
        return result
    }

    func resolve(_ target: String, from document: URL) -> URL? {
        lookup?.resolve(target, from: document)
    }

    func backlinks(to url: URL) -> [NoteKnowledge] {
        sortedNotes.filter { note in
            note.url != url && note.links.contains { resolve($0.target, from: note.url) == url }
        }
    }

    func unlinkedMentions(to url: URL) -> [NoteKnowledge] {
        let names = [url.deletingPathExtension().lastPathComponent] + (notes[url]?.aliases ?? [])
        let incoming = Set(backlinks(to: url).map(\.url))
        return sortedNotes.filter { note in
            note.url != url && !incoming.contains(note.url) && names.contains {
                !$0.isEmpty && note.searchText.localizedCaseInsensitiveContains($0)
            }
        }
    }

    func localGraph(for url: URL) -> [NoteKnowledge] {
        let outgoing = Set((notes[url]?.links ?? []).compactMap { resolve($0.target, from: url) })
        let incoming = Set(backlinks(to: url).map(\.url))
        return sortedNotes.filter { $0.url == url || outgoing.contains($0.url) || incoming.contains($0.url) }
    }

    func isBookmarked(_ url: URL) -> Bool {
        guard let root else { return false }
        return bookmarks.contains(MarkdownKnowledge.relativePath(url, to: root))
    }

    func toggleBookmark(_ url: URL) {
        guard let root, url.standardizedFileURL.path.hasPrefix(root.path + "/") else { return }
        let path = MarkdownKnowledge.relativePath(url, to: root)
        if bookmarks.contains(path) { bookmarks.removeAll { $0 == path } }
        else { bookmarks.append(path) }
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey(root))
    }

    func relocateBookmarks(_ move: VaultDocumentMove) {
        guard let root else { return }
        bookmarks = bookmarks.map { MarkdownKnowledge.relativePath(move.relocated(root.appendingPathComponent($0)), to: root) }
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey(root))
    }

    private func bookmarkKey(_ root: URL) -> String { "knowledge.bookmarks." + root.path }
}
