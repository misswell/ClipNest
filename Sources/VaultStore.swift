import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import CoreServices   // FSEvents — live folder watching
#endif

enum VaultMoveDirection {
    case up
    case down
}

struct VaultDocumentMove: Equatable {
    let source: URL
    let destination: URL
}

/// Selection is intentionally separate from the file-tree publisher. Selecting a document is
/// a high-frequency UI action and must not invalidate the entire recursive explorer tree.
@MainActor
final class VaultSelection: ObservableObject {
    @Published var fileURL: URL?
}

/// Owns the currently-open Obsidian-compatible vault (a local folder), its file tree,
/// the selected file, and all file-system CRUD. Persists the vault via a security-scoped
/// bookmark so it re-opens on next launch.
@MainActor
final class VaultStore: ObservableObject {
    @Published var rootURL: URL?
    @Published var rootNode: FileNode?
    /// Monotonic identity for the current file-tree snapshot. It is intentionally not
    /// published: `rootNode` already publishes refreshes, while this cheap token lets the
    /// explorer skip equality work when only the selected document changes.
    private(set) var treeRevision: UInt64 = 0
    /// Compatibility access for non-UI services and tests. UI observers use `selection` so a
    /// selection change does not publish through this store and rebuild the whole file tree.
    let selection = VaultSelection()
    var selectedFileURL: URL? {
        get { selection.fileURL }
        set { selection.fileURL = newValue }
    }
    /// Home-screen data is rebuilt with the file tree, not while a document is being opened.
    @Published private(set) var homeSnapshot = VaultHomeSnapshot.empty

    /// Toggles wired to menu commands / toolbar on macOS.
    @Published var openVaultRequested = false
    @Published var newFileRequested = false

    @Published var showHiddenFiles = false {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: Keys.showHidden); refresh() }
    }

    /// Explorer sort direction (folders always group first). Persisted.
    @Published var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: Keys.sortAsc)
            guard !isInitializing else { return }
            // Choosing an alphabetical direction exits manual order mode. A later
            // explicit move creates a new manual order for the affected directory.
            childOrders.removeAll()
            persistChildOrders()
            refresh()
        }
    }

    /// The most recent filesystem move, used by the desktop tab bar to update open tabs.
    @Published var lastDocumentMove: VaultDocumentMove?

    /// Recently-opened vault folders, most-recent first (Obsidian-style vault switcher).
    @Published var recentVaults: [URL] = []

    /// Per-vault custom display names, keyed by folder path. Lets you rename a vault's
    /// shown name without touching the folder on disk.
    @Published private var displayNames: [String: String] = [:]

    private enum Keys {
        static let bookmark = "vault.bookmark"
        static let showHidden = "settings.showHidden"
        static let onboarded = "vault.onboarded"
        static let sortAsc = "settings.sortAscending"
        static let recents = "vault.recents"
        static let displayNames = "vault.displayNames"
        static let childOrders = "vault.childOrders"
    }

    private var accessing: URL?
    /// Manual child order keyed by directory path. Values are absolute standardized paths
    /// so a move can update both the source and destination order deterministically.
    private var childOrders: [String: [String]] = [:]
    /// Save requests are serialized off the main actor. A revision prevents an older
    /// debounced request from overwriting a newer edit when disk writes finish out of order.
    private let fileWriter = VaultFileWriteCoordinator()
    private var saveRevisions: [String: UInt64] = [:]
    private var isInitializing = true

    init() {
        showHiddenFiles = UserDefaults.standard.bool(forKey: Keys.showHidden)
        sortAscending = UserDefaults.standard.object(forKey: Keys.sortAsc) as? Bool ?? true
        recentVaults = (UserDefaults.standard.array(forKey: Keys.recents) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        displayNames = UserDefaults.standard.dictionary(forKey: Keys.displayNames) as? [String: String] ?? [:]
        if let rawOrders = UserDefaults.standard.dictionary(forKey: Keys.childOrders) {
            childOrders = rawOrders.reduce(into: [String: [String]]()) { result, entry in
                if let paths = entry.value as? [String] {
                    result[entry.key] = paths
                }
            }
        }
        isInitializing = false
    }

    // MARK: - Menu bridges
    func requestOpenVault() { openVaultRequested = true }
    func requestNewFile() { newFileRequested = true }

    // MARK: - Opening / restoring a vault
    func openVault(at url: URL) {
        stopAccessing()
        // Non-sandboxed build: a scoped call isn't required, but harmless if it succeeds.
        if url.startAccessingSecurityScopedResource() {
            accessing = url
        }
        rootURL = url
        saveBookmark(for: url)
        addRecent(url)
        refresh()
        startWatching(url)
    }

    /// Add a folder to the top of the recent-vaults list (deduped, capped).
    private func addRecent(_ url: URL) {
        var list = recentVaults.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentVaults = Array(list.prefix(10))
        UserDefaults.standard.set(recentVaults.map(\.path), forKey: Keys.recents)
    }

    func removeRecent(_ url: URL) {
        recentVaults.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        UserDefaults.standard.set(recentVaults.map(\.path), forKey: Keys.recents)
    }

    /// Copy the bundled sample vault into the app's Documents directory (writable, no
    /// security scope needed) and open it. Great for first-run and trying the app.
    func openSampleVault() {
        guard let bundled = Bundle.main.url(forResource: "SampleVault", withExtension: nil) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("Sample Vault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
        stopAccessing()
        rootURL = dest
        saveBookmark(for: dest)
        addRecent(dest)
        refresh()
        startWatching(dest)
        selectedFileURL = dest.appendingPathComponent("Welcome.md")
    }

    func restoreVaultIfNeeded() {
        guard rootURL == nil else { return }
        // First-ever launch with no saved vault: seed the sample vault for onboarding.
        if UserDefaults.standard.data(forKey: Keys.bookmark) == nil {
            if !UserDefaults.standard.bool(forKey: Keys.onboarded) {
                UserDefaults.standard.set(true, forKey: Keys.onboarded)
                openSampleVault()
            }
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return }
        var stale = false
        // Try a plain resolution first; fall back to a security-scoped one so bookmarks
        // saved by an earlier sandboxed build still resolve.
        var resolved: URL?
        for options in bookmarkResolutionOptionSets {
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: options,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                resolved = url
                break
            }
        }
        guard let url = resolved else { return }
        if url.startAccessingSecurityScopedResource() {
            accessing = url
        }
        rootURL = url
        if stale { saveBookmark(for: url) }
        addRecent(url)
        refresh()
        startWatching(url)
    }

    func closeVault() {
        stopWatching()
        stopAccessing()
        rootURL = nil
        treeRevision &+= 1
        rootNode = nil
        homeSnapshot = .empty
        selectedFileURL = nil
        UserDefaults.standard.removeObject(forKey: Keys.bookmark)
    }

    /// Resolution options to attempt, in order. Plain bookmarks work in this non-sandboxed
    /// build; the security-scoped variant is kept as a fallback for legacy bookmarks.
    private var bookmarkResolutionOptionSets: [URL.BookmarkResolutionOptions] {
        #if os(macOS)
        return [[], [.withSecurityScope]]
        #else
        return [[]]
        #endif
    }

    private func saveBookmark(for url: URL) {
        // Non-sandboxed macOS uses plain bookmarks (no security scope needed).
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
        }
    }

    private func stopAccessing() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
    }

    var vaultName: String {
        guard let rootURL else { return String(localized: "No Vault") }
        return displayNames[rootURL.path] ?? rootURL.lastPathComponent
    }

    /// The vault's real folder name on disk (ignores any custom display name).
    var vaultFolderName: String { rootURL?.lastPathComponent ?? String(localized: "No Vault") }

    /// Rename the *display* name of the current vault (does not move the folder).
    /// Pass an empty/whitespace string to clear the override and fall back to the folder name.
    func renameVault(to newName: String) {
        guard let rootURL else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == rootURL.lastPathComponent {
            displayNames[rootURL.path] = nil
        } else {
            displayNames[rootURL.path] = trimmed
        }
        UserDefaults.standard.set(displayNames, forKey: Keys.displayNames)
    }

    /// Display name for any vault URL (used by the recent-vaults list).
    func displayName(for url: URL) -> String {
        displayNames[url.path] ?? url.lastPathComponent
    }

    // MARK: - Tree building
    func refresh() {
        guard let rootURL else {
            treeRevision &+= 1
            rootNode = nil
            homeSnapshot = .empty
            return
        }
        let node = buildNode(at: rootURL, isRoot: true)
        treeRevision &+= 1
        rootNode = node
        homeSnapshot = makeHomeSnapshot(from: node)
    }

    // MARK: - Live folder watching (auto-sync)
    #if os(macOS)
    private var fsStream: FSEventStreamRef?
    private var autoRefreshWork: DispatchWorkItem?

    /// Watch the vault folder (recursively) for any on-disk change — files created,
    /// deleted, or renamed by agents, git, Finder, the terminal — and refresh the tree.
    private func startWatching(_ url: URL) {
        stopWatching()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<VaultStore>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in store.scheduleAutoRefresh() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,                      // coalesce bursts within 0.4s
            flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        fsStream = stream
    }

    private func stopWatching() {
        guard let stream = fsStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsStream = nil
    }

    /// Debounce rapid change bursts into a single refresh.
    func scheduleAutoRefresh() {
        autoRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        autoRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    #else
    private func startWatching(_ url: URL) {}
    private func stopWatching() {}
    #endif

    private func buildNode(at url: URL, isRoot: Bool = false) -> FileNode {
        let name = url.lastPathComponent
        var children: [FileNode]? = nil
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants])) ?? []
            let ranks = childOrderRanks(for: url)
            let kids = contents
                // Show every file type (only the hidden-files toggle filters dotfiles).
                // Non-editable files still open to a graceful "Unsupported File" view.
                .filter { showHiddenFiles || !$0.lastPathComponent.hasPrefix(".") }
                .map { buildNode(at: $0) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    if let lhsRank = ranks[canonicalPath(lhs.url)],
                       let rhsRank = ranks[canonicalPath(rhs.url)] {
                        return lhsRank < rhsRank
                    }
                    if ranks[canonicalPath(lhs.url)] != nil { return true }
                    if ranks[canonicalPath(rhs.url)] != nil { return false }
                    let order = lhs.name.localizedStandardCompare(rhs.name)
                    return sortAscending ? order == .orderedAscending : order == .orderedDescending
                }
            children = kids
        }
        return FileNode(url: url, name: name, isDirectory: isDir, children: children)
    }

    // MARK: - Reading / writing

    /// Reading failures surfaced in the editor UI instead of a silent empty document.
    enum VaultReadError: LocalizedError {
        case iCloudDownloadTimedOut
        case readFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .iCloudDownloadTimedOut:
                return String(localized: "The file has not finished downloading from iCloud (timed out). Check your connection and try again.")
            case .readFailed(let underlying):
                return underlying.localizedDescription
            }
        }
    }

    nonisolated static func readText(at url: URL) throws -> String {
        // A vault inside iCloud Drive (e.g. the Obsidian container) may expose dataless
        // placeholder files on iOS. Reading those fails outright, so request the download
        // and wait until the contents are current before reading.
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(30)
            var downloaded = false
            while Date() < deadline {
                if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
                   status == .current {
                    downloaded = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if !downloaded {
                throw VaultReadError.iCloudDownloadTimedOut
            }
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultReadError.readFailed(underlying: error)
        }
    }

    func loadText(_ url: URL) -> String {
        (try? Self.readText(at: url)) ?? ""
    }

    func save(_ text: String, to url: URL) {
        let key = url.standardizedFileURL.path
        let revision = (saveRevisions[key] ?? 0) + 1
        saveRevisions[key] = revision
        let writer = fileWriter
        Task.detached(priority: .utility) {
            await writer.write(Data(text.utf8), to: url, revision: revision)
        }
    }

    /// All directories in the current vault, in the same depth-first order as the tree.
    /// The root is included so a document can be moved back to the vault root.
    func vaultDirectories() -> [URL] {
        guard let rootNode else { return [] }
        var result = [rootNode.url]
        appendDirectories(from: rootNode, to: &result)
        return result
    }

    /// Move a document to another directory without overwriting an existing file.
    /// A name collision receives the same " 2", " 3" suffix convention as new files.
    @discardableResult
    func moveDocument(_ url: URL, to directory: URL) -> URL? {
        guard isInsideVault(url), isInsideVault(directory) else { return nil }
        let source = url.standardizedFileURL
        let destinationDirectory = directory.standardizedFileURL
        let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let destinationIsDirectory = (try? destinationDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !sourceIsDirectory, destinationIsDirectory else { return nil }

        let sourceParent = source.deletingLastPathComponent().standardizedFileURL
        guard sourceParent != destinationDirectory else { return nil }
        let destination = uniqueURL(in: destinationDirectory, name: source.lastPathComponent)

        do {
            try FileManager.default.moveItem(at: source, to: destination)
            updateOrderAfterMoving(source: source,
                                   destination: destination,
                                   sourceDirectory: sourceParent,
                                   destinationDirectory: destinationDirectory)
            if selectedFileURL?.standardizedFileURL == source {
                selectedFileURL = destination
            }
            lastDocumentMove = VaultDocumentMove(source: source, destination: destination)
            refresh()
            return destination
        } catch {
            return nil
        }
    }

    /// Move a document up or down among the documents in its current directory.
    /// Folders remain grouped above files, matching the existing Explorer behavior.
    @discardableResult
    func moveDocumentInOrder(_ url: URL, direction: VaultMoveDirection) -> Bool {
        let source = url.standardizedFileURL
        guard isInsideVault(source),
              let node = findNode(at: source, in: rootNode),
              !node.isDirectory else { return false }
        let directory = source.deletingLastPathComponent().standardizedFileURL
        var siblings = childNodes(in: directory)
        let documentIndexes = siblings.indices.filter { !siblings[$0].isDirectory }
        guard let currentPosition = documentIndexes.firstIndex(where: {
            canonicalPath(siblings[$0].url) == canonicalPath(source)
        }) else { return false }

        let targetPosition: Int
        switch direction {
        case .up:
            guard currentPosition > 0 else { return false }
            targetPosition = currentPosition - 1
        case .down:
            guard currentPosition + 1 < documentIndexes.count else { return false }
            targetPosition = currentPosition + 1
        }

        siblings.swapAt(documentIndexes[currentPosition], documentIndexes[targetPosition])
        childOrders[orderKey(for: directory)] = siblings.map { canonicalPath($0.url) }
        persistChildOrders()
        refresh()
        return true
    }

    func canMoveDocument(_ url: URL, direction: VaultMoveDirection) -> Bool {
        let source = url.standardizedFileURL
        guard isInsideVault(source),
              let node = findNode(at: source, in: rootNode),
              !node.isDirectory else { return false }
        let directory = source.deletingLastPathComponent().standardizedFileURL
        let documentCount = childNodes(in: directory).filter { !$0.isDirectory }.count
        guard let current = childNodes(in: directory)
            .filter({ !$0.isDirectory })
            .firstIndex(where: { canonicalPath($0.url) == canonicalPath(source) }) else {
            return false
        }
        switch direction {
        case .up: return current > 0
        case .down: return current + 1 < documentCount
        }
    }

    // MARK: - CRUD
    /// Directory new items should be created in, based on the current selection.
    func targetDirectory() -> URL? {
        guard let rootURL else { return nil }
        guard let sel = selectedFileURL else { return rootURL }
        let isDir = (try? sel.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDir ? sel : sel.deletingLastPathComponent()
    }

    @discardableResult
    func createFile(named rawName: String, in directory: URL? = nil) -> URL? {
        guard let dir = directory ?? targetDirectory() else { return nil }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        let url = uniqueURL(in: dir, name: name)
        FileManager.default.createFile(atPath: url.path, contents: Data("# \(url.deletingPathExtension().lastPathComponent)\n\n".utf8))
        refresh()
        selectedFileURL = url
        return url
    }

    @discardableResult
    func createFolder(named rawName: String, in directory: URL? = nil) -> URL? {
        guard let dir = directory ?? targetDirectory() else { return nil }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "New Folder" }
        let url = uniqueURL(in: dir, name: name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        refresh()
        return url
    }

    func delete(_ url: URL) {
        try? FileManager.default.trashOrRemove(url)
        removeChildOrderPaths(under: url)
        if selectedFileURL == url { selectedFileURL = nil }
        refresh()
    }

    @discardableResult
    func rename(_ url: URL, to rawName: String) -> URL? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDir && (name as NSString).pathExtension.isEmpty {
            let oldExt = url.pathExtension
            if !oldExt.isEmpty { name += "." + oldExt }
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            rewriteChildOrderPaths(from: url, to: dest)
            if selectedFileURL == url { selectedFileURL = dest }
            refresh()
            return dest
        } catch { return nil }
    }

    private func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(newName)
        }
        return candidate
    }

    // MARK: - Manual tree order
    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func orderKey(for directory: URL) -> String {
        canonicalPath(directory)
    }

    private func childOrderRanks(for directory: URL) -> [String: Int] {
        (childOrders[orderKey(for: directory)] ?? [])
            .enumerated()
            .reduce(into: [String: Int]()) { result, item in
                result[item.element] = item.offset
            }
    }

    private func persistChildOrders() {
        UserDefaults.standard.set(childOrders, forKey: Keys.childOrders)
    }

    private func updateOrderAfterMoving(source: URL,
                                         destination: URL,
                                         sourceDirectory: URL,
                                         destinationDirectory: URL) {
        var sourceOrder = childNodes(in: sourceDirectory).map { canonicalPath($0.url) }
        sourceOrder.removeAll { $0 == canonicalPath(source) }
        childOrders[orderKey(for: sourceDirectory)] = sourceOrder

        var destinationOrder = childNodes(in: destinationDirectory).map { canonicalPath($0.url) }
        destinationOrder.removeAll { $0 == canonicalPath(destination) }
        destinationOrder.append(canonicalPath(destination))
        childOrders[orderKey(for: destinationDirectory)] = destinationOrder
        persistChildOrders()
    }

    private func rewriteChildOrderPaths(from source: URL, to destination: URL) {
        let sourcePath = canonicalPath(source)
        let destinationPath = canonicalPath(destination)
        var rewritten: [String: [String]] = [:]
        for (directory, paths) in childOrders {
            let newDirectory = replacingPathPrefix(directory, from: sourcePath, to: destinationPath)
            rewritten[newDirectory] = paths.map {
                replacingPathPrefix($0, from: sourcePath, to: destinationPath)
            }
        }
        childOrders = rewritten
        persistChildOrders()
    }

    private func removeChildOrderPaths(under url: URL) {
        let target = canonicalPath(url)
        childOrders = childOrders.reduce(into: [String: [String]]()) { result, entry in
            guard !isPathInside(entry.key, target) else { return }
            result[entry.key] = entry.value.filter { !isPathInside($0, target) }
        }
        persistChildOrders()
    }

    private func replacingPathPrefix(_ path: String, from source: String, to destination: String) -> String {
        guard path == source || path.hasPrefix(source + "/") else { return path }
        return path == source ? destination : destination + String(path.dropFirst(source.count))
    }

    private func isPathInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    private func isInsideVault(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let root = canonicalPath(rootURL)
        return isPathInside(canonicalPath(url), root)
    }

    private func appendDirectories(from node: FileNode, to result: inout [URL]) {
        for child in node.children ?? [] where child.isDirectory {
            result.append(child.url)
            appendDirectories(from: child, to: &result)
        }
    }

    private func findNode(at url: URL, in node: FileNode?) -> FileNode? {
        guard let node else { return nil }
        if canonicalPath(node.url) == canonicalPath(url) { return node }
        for child in node.children ?? [] {
            if let found = findNode(at: url, in: child) { return found }
        }
        return nil
    }

    private func childNodes(in directory: URL) -> [FileNode] {
        guard let rootNode else { return [] }
        return findNode(at: directory, in: rootNode)?.children ?? []
    }

    // MARK: - Image resolution (Bear / Obsidian embeds)
    /// Resolve a markdown/Obsidian image reference to an on-disk URL.
    /// Handles `![[image.png]]`, `![alt](relative/path.png)`, optional `|size` suffix.
    func resolveImageURL(_ src: String, relativeTo fileURL: URL?) -> URL? {
        Self.resolveImageURL(src, relativeTo: fileURL, rootURL: rootURL)
    }

    /// Nonisolated image lookup for preview tasks. The direct candidates are cheap, while
    /// the filename fallback may enumerate a large vault; callers can safely run this
    /// helper in a detached utility task.
    nonisolated static func resolveImageURL(_ src: String,
                                            relativeTo fileURL: URL?,
                                            rootURL: URL?) -> URL? {
        var name = src
        if let bar = name.firstIndex(of: "|") { name = String(name[..<bar]) }   // Obsidian size hint
        name = name.removingPercentEncoding ?? name
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("http") else { return nil }

        let direct = [
            fileURL?.deletingLastPathComponent().appendingPathComponent(name),
            rootURL?.appendingPathComponent(name)
        ].compactMap { $0 }
        for c in direct where FileManager.default.fileExists(atPath: c.path) { return c }

        // Fall back to searching the whole vault by file name (Obsidian shortest-path behaviour).
        if let root = rootURL {
            let base = (name as NSString).lastPathComponent
            if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in en where u.lastPathComponent == base { return u }
            }
        }
        return nil
    }
}

private extension FileManager {
    /// Move to Trash where available (macOS / iOS 11+), else hard delete.
    func trashOrRemove(_ url: URL) throws {
        do {
            try trashItem(at: url, resultingItemURL: nil)
        } catch {
            try removeItem(at: url)
        }
    }
}

/// Performs potentially blocking atomic writes away from the UI executor and preserves the
/// order of edits for each document. The actor is intentionally scoped to one VaultStore so
/// tests and separate app sessions do not share mutable write state.
private actor VaultFileWriteCoordinator {
    private var latestRevision: [String: UInt64] = [:]

    func write(_ data: Data, to url: URL, revision: UInt64) {
        let key = url.standardizedFileURL.path
        guard revision >= (latestRevision[key] ?? 0) else { return }
        latestRevision[key] = revision
        try? data.write(to: url, options: .atomic)
    }
}
