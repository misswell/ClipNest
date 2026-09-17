import Foundation
import SQLite3

/// SQLite persistence for the local search index (spec §23).
///
/// No vector database is involved: embeddings are stored as `Float32` blobs in a plain
/// SQLite file next to their chunk metadata, and similarity is computed with Accelerate on
/// load. That is more than enough for a personal vault of a few thousand chunks, and it
/// keeps the app free of any server or extra dependency.
///
/// Keyword matching uses FTS5 with BM25 and per-column weights (spec §19). Because FTS5's
/// built-in tokenizer does not segment Chinese, every indexed column stores the *already
/// tokenized* term string produced by `LocalTextAnalyzer` (which emits CJK bi-grams); the
/// query side runs through the same tokenizer, so Chinese and mixed content match reliably.
final class SearchDatabase {
    /// BM25 column weights, in the order the columns appear in the FTS table (spec §19).
    static let columnWeights: [Double] = [
        4.0,   // title
        3.0,   // tags
        2.5,   // summary
        2.5,   // filename
        1.0,   // body
        0.8    // path
    ]

    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(pointer)
            throw SearchIndexError.databaseUnavailable(message)
        }
        handle = pointer
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try createSchema()
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    // MARK: - Schema

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS indexed_files (
            path TEXT PRIMARY KEY,
            modified_at REAL NOT NULL,
            size INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            indexed_at REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS chunks (
            chunk_id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            language TEXT NOT NULL DEFAULT '',
            embedding BLOB,
            modified_at REAL NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_path);")
        // Indexed columns hold tokenized terms; excerpt is for display only.
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
            chunk_id UNINDEXED,
            file_path UNINDEXED,
            title,
            tags,
            summary,
            filename,
            body,
            path,
            excerpt UNINDEXED,
            tokenize = 'unicode61'
        );
        """)
    }

    // MARK: - File bookkeeping

    func allFileStates() -> [String: IndexedFileState] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle,
                                 "SELECT path, modified_at, size, content_hash FROM indexed_files;",
                                 -1, &statement, nil) == SQLITE_OK else { return [:] }

        var output: [String: IndexedFileState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathText = sqlite3_column_text(statement, 0) else { continue }
            let state = IndexedFileState(path: String(cString: pathText),
                                          modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                          size: Int(sqlite3_column_int64(statement, 2)),
                                          contentHash: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "")
            output[state.path] = state
        }
        return output
    }

    func fileState(atPath path: String) -> IndexedFileState? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle,
                                 "SELECT modified_at, size, content_hash FROM indexed_files WHERE path = ?;",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, path, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return IndexedFileState(path: path,
                                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                size: Int(sqlite3_column_int64(statement, 1)),
                                contentHash: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "")
    }

    // MARK: - Writes

    /// Replaces every chunk of one file. Called inside `LocalSearchIndexer`'s actor, and
    /// wrapped in a transaction so a crash mid-index cannot leave half a note behind.
    func replaceChunks(forFileAt path: String, state: IndexedFileState, chunks: [IndexedChunk]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SearchIndexError.databaseUnavailable("no database") }
        try executeLocked(handle, "BEGIN IMMEDIATE;")
        do {
            try deleteChunksLocked(handle, path: path)
            for chunk in chunks {
                try insertChunkLocked(handle, path: path, chunk: chunk)
            }
            try upsertFileStateLocked(handle, state: state)
            try executeLocked(handle, "COMMIT;")
        } catch {
            try? executeLocked(handle, "ROLLBACK;")
            throw error
        }
    }

    /// Refreshes only the file bookkeeping — used when the modification date moved but the
    /// bytes are identical, so no chunk needs re-embedding.
    func updateFileState(_ state: IndexedFileState) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        try? upsertFileStateLocked(handle, state: state)
    }

    func deleteFile(atPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        try executeLocked(handle, "BEGIN IMMEDIATE;")
        do {
            try deleteChunksLocked(handle, path: path)
            try executeLocked(handle, "DELETE FROM indexed_files WHERE path = \(Self.quoted(path));")
            try executeLocked(handle, "COMMIT;")
        } catch {
            try? executeLocked(handle, "ROLLBACK;")
            throw error
        }
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        try executeLocked(handle, "DELETE FROM chunks;")
        try executeLocked(handle, "DELETE FROM indexed_files;")
        try executeLocked(handle, "DELETE FROM search_fts;")
    }

    private func deleteChunksLocked(_ handle: OpaquePointer, path: String) throws {
        try executeLocked(handle, "DELETE FROM chunks WHERE file_path = \(Self.quoted(path));")
        try executeLocked(handle, "DELETE FROM search_fts WHERE file_path = \(Self.quoted(path));")
    }

    private func upsertFileStateLocked(_ handle: OpaquePointer, state: IndexedFileState) throws {
        let sql = """
        INSERT INTO indexed_files (path, modified_at, size, content_hash, indexed_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            modified_at = excluded.modified_at,
            size = excluded.size,
            content_hash = excluded.content_hash,
            indexed_at = excluded.indexed_at;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_bind_text(statement, 1, state.path, -1, Self.transient)
        sqlite3_bind_double(statement, 2, state.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, Int64(state.size))
        sqlite3_bind_text(statement, 4, state.contentHash, -1, Self.transient)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func insertChunkLocked(_ handle: OpaquePointer, path: String, chunk: IndexedChunk) throws {
        let chunkSQL = """
        INSERT OR REPLACE INTO chunks
            (chunk_id, file_path, title, text, language, embedding, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, chunkSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_bind_text(statement, 1, chunk.id, -1, Self.transient)
        sqlite3_bind_text(statement, 2, path, -1, Self.transient)
        sqlite3_bind_text(statement, 3, chunk.title, -1, Self.transient)
        sqlite3_bind_text(statement, 4, chunk.text, -1, Self.transient)
        sqlite3_bind_text(statement, 5, chunk.language, -1, Self.transient)
        if chunk.embedding.isEmpty {
            sqlite3_bind_null(statement, 6)
        } else {
            let data = Self.encode(chunk.embedding)
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 6, buffer.baseAddress, Int32(data.count), Self.transient)
            }
        }
        sqlite3_bind_double(statement, 7, chunk.modifiedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }

        let ftsSQL = """
        INSERT INTO search_fts
            (chunk_id, file_path, title, tags, summary, filename, body, path, excerpt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var ftsStatement: OpaquePointer?
        defer { sqlite3_finalize(ftsStatement) }
        guard sqlite3_prepare_v2(handle, ftsSQL, -1, &ftsStatement, nil) == SQLITE_OK else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }
        let fields = chunk.ftsFields
        sqlite3_bind_text(ftsStatement, 1, chunk.id, -1, Self.transient)
        sqlite3_bind_text(ftsStatement, 2, path, -1, Self.transient)
        for (offset, value) in fields.enumerated() {
            sqlite3_bind_text(ftsStatement, Int32(offset + 3), value, -1, Self.transient)
        }
        sqlite3_bind_text(ftsStatement, 9, chunk.excerpt, -1, Self.transient)
        guard sqlite3_step(ftsStatement) == SQLITE_DONE else {
            throw SearchIndexError.databaseUnavailable(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - Reads

    /// Loads embeddings and metadata only — never note bodies (spec §39).
    func loadEmbeddings() -> [StoredEmbedding] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT chunk_id, file_path, title, modified_at, language, embedding
        FROM chunks WHERE embedding IS NOT NULL;
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }

        var output: [StoredEmbedding] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let pathText = sqlite3_column_text(statement, 1),
                  let blob = sqlite3_column_blob(statement, 5)
            else { continue }
            let byteCount = Int(sqlite3_column_bytes(statement, 5))
            let data = Data(bytes: blob, count: byteCount)
            output.append(StoredEmbedding(
                chunkID: String(cString: idText),
                filePath: String(cString: pathText),
                title: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                language: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                vector: Self.decode(data)
            ))
        }
        return output
    }

    /// BM25 keyword search. `query` is already a sanitized FTS5 expression.
    func keywordSearch(query: String, limit: Int) -> [KeywordMatch] {
        guard !query.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }

        let weights = Self.columnWeights.map { String($0) }.joined(separator: ", ")
        let sql = """
        SELECT chunk_id, file_path, title, excerpt, bm25(search_fts, \(weights))
        FROM search_fts
        WHERE search_fts MATCH ?
        ORDER BY bm25(search_fts, \(weights))
        LIMIT ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(statement, 1, query, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var output: [KeywordMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let chunkID = sqlite3_column_text(statement, 0),
                  let path = sqlite3_column_text(statement, 1)
            else { continue }
            // FTS5 bm25() is negative with "more negative is better"; flip it.
            let raw = sqlite3_column_double(statement, 4)
            output.append(KeywordMatch(
                chunkID: String(cString: chunkID),
                filePath: String(cString: path),
                title: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                excerpt: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                score: -raw,
                matchedTerms: []
            ))
        }
        return output
    }

    /// Title and modification date for a chunk, so a keyword row can be rendered without a
    /// second lookup into the note itself.
    func chunkMetadata(chunkID: String) -> (title: String, modifiedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle,
                                 "SELECT title, modified_at FROM chunks WHERE chunk_id = ?;",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, chunkID, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
    }

    /// Full text of one chunk, fetched only when a row is shown (spec §39).
    func chunkText(chunkID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT text FROM chunks WHERE chunk_id = ?;", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        sqlite3_bind_text(statement, 1, chunkID, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func chunkCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM chunks;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Primitives

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SearchIndexError.databaseUnavailable("no database") }
        try executeLocked(handle, sql)
    }

    private func executeLocked(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SearchIndexError.databaseUnavailable(message)
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let bound = raw.bindMemory(to: Float.self)
            return Array(bound.prefix(count))
        }
    }
}
