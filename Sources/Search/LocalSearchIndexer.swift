import Foundation
import CryptoKit

/// Outcome of one indexing pass, surfaced in Settings so a user can see that the local
/// index actually did something.
struct SearchIndexStatistics: Equatable, Sendable {
    var indexedFiles = 0
    var updatedFiles = 0
    var removedFiles = 0
    var skippedFiles = 0
    var skippedRemoteFiles = 0
    var totalChunks = 0
    var embeddedChunks = 0
    var duration: TimeInterval = 0

    static func + (lhs: SearchIndexStatistics, rhs: SearchIndexStatistics) -> SearchIndexStatistics {
        var result = lhs
        result.indexedFiles += rhs.indexedFiles
        result.updatedFiles += rhs.updatedFiles
        result.removedFiles += rhs.removedFiles
        result.skippedFiles += rhs.skippedFiles
        result.skippedRemoteFiles += rhs.skippedRemoteFiles
        result.totalChunks += rhs.totalChunks
        result.embeddedChunks += rhs.embeddedChunks
        result.duration += rhs.duration
        return result
    }
}

/// Serialises all vault scanning and index mutation (spec §40).
///
/// Being an actor is what keeps two foreground/background indexing passes from walking the
/// vault and rewriting SQLite at the same time, and it is also what keeps the non-thread-safe
/// `NLEmbedding` instances behind a single serial caller.
///
/// The pass is incremental (spec §22): a note is only re-chunked when its modification date
/// moved *and* its content hash changed, files that vanished lose their rows, and new files
/// are appended. iCloud placeholders are skipped rather than downloaded — indexing must never
/// pull an entire vault down.
actor LocalSearchIndexer {
    /// Files read and embedded per batch before yielding (spec §39).
    static let batchSize = 32

    private let vaultRoot: URL
    private let database: SearchDatabase
    private let embeddingProvider: EmbeddingProviding
    private let semanticSearchEnabled: Bool

    init(vaultRoot: URL,
         database: SearchDatabase,
         embeddingProvider: EmbeddingProviding = SystemEmbeddingProvider.shared,
         semanticSearchEnabled: Bool = true) {
        self.vaultRoot = vaultRoot
        self.database = database
        self.embeddingProvider = embeddingProvider
        self.semanticSearchEnabled = semanticSearchEnabled
    }

    // MARK: - Full pass

    func indexVault() async -> SearchIndexStatistics {
        let started = Date()
        var statistics = SearchIndexStatistics()

        let known = database.allFileStates()
        var seenPaths = Set<String>()
        var processedInBatch = 0

        for file in Self.markdownFiles(in: vaultRoot) {
            if Task.isCancelled { break }
            let path = file.standardizedFileURL.path
            seenPaths.insert(path)

            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0

            if let existing = known[path], existing.modifiedAt == modifiedAt, existing.size == size {
                statistics.skippedFiles += 1
                continue
            }
            // Do not drag iCloud placeholders down just to index them.
            if await !VaultFileAccess.shared.hasLocalContents(at: file) {
                statistics.skippedRemoteFiles += 1
                continue
            }

            let result = await index(fileAt: file, modifiedAt: modifiedAt, size: size)
            statistics = statistics + result

            processedInBatch += 1
            if processedInBatch >= Self.batchSize {
                processedInBatch = 0
                await Task.yield()
            }
        }

        // Files that disappeared from the vault lose their index rows.
        for path in known.keys where !seenPaths.contains(path) {
            try? database.deleteFile(atPath: path)
            statistics.removedFiles += 1
        }

        statistics.duration = Date().timeIntervalSince(started)
        return statistics
    }

    /// Incremental single-file updates, used by the vault's file-watch events.
    @discardableResult
    func reindex(fileAt url: URL) async -> SearchIndexStatistics {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0
        if let existing = database.fileState(atPath: url.standardizedFileURL.path),
           existing.modifiedAt == modifiedAt, existing.size == size {
            return SearchIndexStatistics(skippedFiles: 1)
        }
        return await index(fileAt: url, modifiedAt: modifiedAt, size: size)
    }

    func removeFile(at url: URL) {
        try? database.deleteFile(atPath: url.standardizedFileURL.path)
    }

    func clear() {
        try? database.removeAll()
    }

    func chunkCount() -> Int { database.chunkCount() }

    // MARK: - Search

    /// Reads the stored vectors back as a searchable index.
    ///
    /// This is a full-table decode, so it runs on the actor rather than on whoever happens to
    /// ask (spec §38, §39). Only metadata and vectors are read — never the note bodies.
    func loadSemanticIndex() -> SemanticSearchIndex {
        SemanticSearchIndex(embeddings: database.loadEmbeddings())
    }

    /// Runs a query on the indexer's executor.
    ///
    /// Search embeds the query (through `EmbeddingProviding`), and embedding work is
    /// serialized on this actor, so search must not be executed on the main actor either —
    /// the same contract that governs indexing (spec §40).
    func search(query: String,
                mode: VaultSearchMode,
                semanticIndex: SemanticSearchIndex,
                semanticEnabled: Bool,
                expandedTerms: [String] = [],
                limit: Int = 40) -> [SearchResult] {
        var engine = LocalSearchEngine(database: database,
                                       semanticIndex: semanticIndex,
                                       semanticEnabled: semanticEnabled)
        engine.embeddingProvider = embeddingProvider
        return engine.search(query: query,
                             mode: mode,
                             expandedTerms: expandedTerms,
                             limit: limit)
    }

    // MARK: - One file

    private func index(fileAt url: URL, modifiedAt: Date, size: Int) async -> SearchIndexStatistics {
        let path = url.standardizedFileURL.path
        guard let data = try? await VaultFileAccess.shared.readData(at: url),
              let text = String(data: data, encoding: .utf8)
        else { return SearchIndexStatistics() }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let state = IndexedFileState(path: path,
                                     modifiedAt: modifiedAt,
                                     size: size,
                                     contentHash: hash)

        // Modification date moved but the bytes did not (a touch, a sync, a metadata-only
        // save). Refresh the bookkeeping without re-embedding anything.
        if let existing = database.fileState(atPath: path), existing.contentHash == hash {
            database.updateFileState(state)
            var skipped = SearchIndexStatistics()
            skipped.skippedFiles = 1
            return skipped
        }

        let document = SearchDocument.parse(markdown: text, fileURL: url, modifiedAt: modifiedAt)
        let chunkTexts = SearchChunker.chunks(for: document.body.isEmpty ? text : document.body)
        let excerpt = Self.excerpt(from: document)

        var chunks: [IndexedChunk] = []
        chunks.reserveCapacity(chunkTexts.count)

        for (index, chunkText) in chunkTexts.enumerated() {
            if Task.isCancelled { break }
            let fields = KeywordSearchIndex.fields(for: document,
                                                  bodyText: chunkText,
                                                  vaultRoot: vaultRoot)
            var embedding: [Float] = []
            var language = ""
            if semanticSearchEnabled,
               let result = LocalEmbeddingService.embedding(for: chunkText, provider: embeddingProvider) {
                embedding = result.vector
                language = result.language
            }
            chunks.append(IndexedChunk(id: "\(path)#\(index)",
                                       title: document.title,
                                       text: chunkText,
                                       excerpt: excerpt,
                                       language: language,
                                       embedding: embedding,
                                       modifiedAt: modifiedAt,
                                       ftsFields: fields.ordered))
        }

        do {
            try database.replaceChunks(forFileAt: path, state: state, chunks: chunks)
        } catch {
            return SearchIndexStatistics()
        }

        var statistics = SearchIndexStatistics()
        statistics.indexedFiles = 1
        statistics.updatedFiles = 1
        statistics.totalChunks = chunks.count
        statistics.embeddedChunks = chunks.filter { !$0.embedding.isEmpty }.count
        return statistics
    }

    /// A bounded excerpt stored with the chunk so a result row can be rendered without
    /// touching the note body.
    private static func excerpt(from document: SearchDocument, limit: Int = 240) -> String {
        let source = document.summary.isEmpty ? document.body : document.summary
        let flattened = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > limit ? String(flattened.prefix(limit)) : flattened
    }

    // MARK: - Scanning

    /// Markdown files under the vault, excluding hidden folders and the trash. Uses the
    /// shared `FileNode` extension list so the index and the explorer agree on what a note is.
    static func markdownFiles(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var output: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if FileNode.indexingExcludedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard FileNode.editableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            output.append(url)
        }
        return output
    }
}
