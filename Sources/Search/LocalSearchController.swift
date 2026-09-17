import Foundation
import CryptoKit
import Combine

extension Notification.Name {
    /// Posted by `VaultStore` for each batch of external file-system changes, with the
    /// changed paths under `"paths"`.
    static let vaultFilesDidChange = Notification.Name("vaultFilesDidChange")
}

/// App-facing owner of the local search index: opens the SQLite file for the current vault,
/// drives the indexer actor, caches the in-memory vector layer, and answers queries.
///
/// It exists so no view has to know about `LocalSearchIndexer`, `SemanticSearchIndex` or
/// SQLite — the side bar just binds `query`, `mode` and `results`.
@MainActor
final class LocalSearchController: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var mode: VaultSearchMode = .smart {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var statistics: SearchIndexStatistics?
    @Published private(set) var indexedChunkCount = 0
    @Published private(set) var errorMessage: String?

    private var database: SearchDatabase?
    private var indexer: LocalSearchIndexer?
    private var semanticIndex = SemanticSearchIndex()
    private var semanticEnabled = AIConfigurationStore.loadLocalSemanticSearchEnabled()
    /// §25 keyword expansion. Best-effort: the literal query is always searched first.
    private var queryExpander = LocalQueryExpander()
    private var vaultRoot: URL?
    private var searchTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?
    private var didIndexThisSession = false
    private var fileChangeSubscription: AnyCancellable?
    /// Coalesces a burst of file-system events into one incremental pass.
    private var pendingChangedPaths: Set<String> = []
    private var incrementalWork: Task<Void, Never>?

    var isReady: Bool { database != nil }
    var hasIndex: Bool { indexedChunkCount > 0 }

    init() {
        fileChangeSubscription = NotificationCenter.default
            .publisher(for: .vaultFilesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let paths = notification.userInfo?["paths"] as? [String] else { return }
                self?.enqueueIncremental(paths: paths)
            }
    }

    // MARK: - Vault lifecycle

    /// Points the controller at a vault. Re-opening the same vault keeps the existing index.
    func attach(vaultRoot newRoot: URL?) {
        let standardized = newRoot?.standardizedFileURL
        guard standardized != vaultRoot else { return }
        searchTask?.cancel()
        indexingTask?.cancel()
        database?.close()
        database = nil
        indexer = nil
        semanticIndex = SemanticSearchIndex()
        results = []
        statistics = nil
        indexedChunkCount = 0
        errorMessage = nil
        didIndexThisSession = false
        vaultRoot = standardized

        guard let standardized else { return }
        do {
            let database = try SearchDatabase(url: Self.databaseURL(for: standardized))
            self.database = database
            let indexer = LocalSearchIndexer(vaultRoot: standardized,
                                            database: database,
                                            semanticSearchEnabled: semanticEnabled)
            self.indexer = indexer
            // Decoding every stored vector is real work; it happens on the indexer, never
            // on the main actor (spec §38/§39).
            Task { [weak self] in
                let loaded = await indexer.loadSemanticIndex()
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.indexer === indexer else { return }
                    self.semanticIndex = loaded
                    self.scheduleSearch()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSemanticSearchEnabled(_ enabled: Bool) {
        guard enabled != semanticEnabled else { return }
        semanticEnabled = enabled
        recreateIndexer()
        rebuild()
    }

    /// The indexer is immutable, so a settings change swaps it for a new one.
    private func recreateIndexer() {
        guard let vaultRoot, let database else { return }
        indexer = LocalSearchIndexer(vaultRoot: vaultRoot,
                                     database: database,
                                     semanticSearchEnabled: semanticEnabled)
    }

    /// Full incremental pass. Safe to call repeatedly — unchanged notes are skipped.
    func rebuild() {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        let database = self.database
        let expectedVault = vaultRoot
        indexingTask = Task { [weak self] in
            let stats = await indexer.indexVault()
            // Reading the vectors back is a full-table decode; keep it on the actor.
            let loaded = await indexer.loadSemanticIndex()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A vault switch during the pass invalidates everything it produced.
                guard expectedVault == self.vaultRoot else { return }
                self.statistics = stats
                self.isIndexing = false
                self.didIndexThisSession = true
                self.indexedChunkCount = database?.chunkCount() ?? 0
                self.semanticIndex = loaded
                self.scheduleSearch()
            }
        }
    }

    /// Indexes a single file after the vault's file watcher reports a change.
    func indexChangedFile(at url: URL) {
        guard let indexer else { return }
        Task { [weak self] in
            _ = await indexer.reindex(fileAt: url)
            let loaded = await indexer.loadSemanticIndex()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.indexedChunkCount = self.database?.chunkCount() ?? 0
                self.semanticIndex = loaded
                self.scheduleSearch()
            }
        }
    }

    func removeIndexedFile(at url: URL) {
        guard let indexer else { return }
        Task { [weak self] in
            await indexer.removeFile(at: url)
            let loaded = await indexer.loadSemanticIndex()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.indexedChunkCount = self.database?.chunkCount() ?? 0
                self.semanticIndex = loaded
                self.scheduleSearch()
            }
        }
    }

    /// Runs once per session, after the vault tree is available.
    func indexIfNeeded() {
        guard !didIndexThisSession, database != nil else { return }
        rebuild()
    }

    // MARK: - Incremental updates

    private func enqueueIncremental(paths: [String]) {
        guard database != nil else { return }
        pendingChangedPaths.formUnion(paths)
        incrementalWork?.cancel()
        incrementalWork = Task { [weak self] in
            // Let a burst of autosaves settle before touching the index.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.flushIncremental()
            }
        }
    }

    private func flushIncremental() {
        guard let indexer else { return }
        let paths = Array(pendingChangedPaths)
        pendingChangedPaths.removeAll()
        guard !paths.isEmpty else { return }

        Task { [weak self] in
            var changed = false
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard FileNode.editableExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if FileManager.default.fileExists(atPath: path) {
                    _ = await indexer.reindex(fileAt: url)
                } else {
                    await indexer.removeFile(at: url)
                }
                changed = true
            }
            guard changed else { return }
            let loaded = await indexer.loadSemanticIndex()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.indexedChunkCount = self.database?.chunkCount() ?? 0
                self.semanticIndex = loaded
                self.scheduleSearch()
            }
        }
    }

    // MARK: - Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        let mode = mode
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let indexer
        else {
            results = []
            return
        }
        let semanticIndex = semanticIndex
        let semanticEnabled = semanticEnabled
        searchTask = Task { [weak self] in
            // Coalesce keystrokes; a personal vault query is cheap but this keeps typing smooth.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            // Off the main actor: this embeds the query.
            let hits = await indexer.search(query: query,
                                            mode: mode,
                                            semanticIndex: semanticIndex,
                                            semanticEnabled: semanticEnabled)
            guard !Task.isCancelled, let self else { return }
            // A result whose file disappeared between indexing and now is dropped rather than
            // opened into an error.
            self.results = hits.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }

            // §25: widen the query with related keywords from the on-device model. This runs
            // *after* the literal results are already on screen, so a slow or absent model
            // costs nothing — the raw-query answer simply stands.
            guard AIConfigurationStore.loadLocalQueryExpansionEnabled() else { return }
            let expanded = await self.queryExpander.expand(query)
            guard !expanded.isEmpty, !Task.isCancelled else { return }
            // A newer keystroke owns the results now; this expansion is stale.
            guard self.query == query else { return }

            let widened = await indexer.search(query: query,
                                               mode: mode,
                                               semanticIndex: semanticIndex,
                                               semanticEnabled: semanticEnabled,
                                               expandedTerms: expanded)
            guard !Task.isCancelled, self.query == query else { return }
            self.results = widened.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        }
    }

    /// Exact (keyword-only) search, used by tests and by any caller that wants no semantics.
    func keywordResults(for query: String) -> [SearchResult] {
        guard let database else { return [] }
        let engine = LocalSearchEngine(database: database,
                                       semanticIndex: SemanticSearchIndex(),
                                       semanticEnabled: false)
        return engine.search(query: query, mode: .exact)
    }

    // MARK: - Storage location

    /// The index lives outside the vault so it never pollutes an Obsidian folder, and it is
    /// excluded from backups because it is fully rebuildable from disk.
    static func databaseURL(for vaultRoot: URL) -> URL {
        let digest = SHA256.hash(data: Data(vaultRoot.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent("ClipNest", isDirectory: true)
            .appendingPathComponent("SearchIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent("\(digest).sqlite")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
}
