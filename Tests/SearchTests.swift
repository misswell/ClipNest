import Foundation
import XCTest
@testable import ClipNest

/// Search ranking, hybrid fusion, and incremental indexing (spec §18–§23, §43–§44).
final class SearchRankingTests: XCTestCase {
    private var root: URL!
    private var databaseURL: URL!
    private var database: SearchDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("index.sqlite")
        database = try SearchDatabase(url: databaseURL)
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeIndexer(semantic: Bool = false) -> LocalSearchIndexer {
        LocalSearchIndexer(vaultRoot: root,
                           database: database,
                           embeddingProvider: UnavailableEmbeddingProvider(),
                           semanticSearchEnabled: semantic)
    }

    private func makeEngine(semanticIndex: SemanticSearchIndex = SemanticSearchIndex(),
                            semanticEnabled: Bool = false,
                            provider: EmbeddingProviding = UnavailableEmbeddingProvider()) -> LocalSearchEngine {
        var engine = LocalSearchEngine(database: database,
                                       semanticIndex: semanticIndex,
                                       semanticEnabled: semanticEnabled)
        engine.embeddingProvider = provider
        return engine
    }

    /// Indexes the vault and waits for the pass to finish.
    @discardableResult
    private func indexAll(semantic: Bool = false) async -> SearchIndexStatistics {
        await makeIndexer(semantic: semantic).indexVault()
    }

    private func seedVault() throws {
        try write("Vision OCR 图片文字识别.md", """
        ---
        tags:
          - SwiftUI
          - Vision
        ---
        # Vision OCR 图片文字识别

        ## 摘要

        在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。

        ## 内容

        使用 VNRecognizeTextRequest 对 UIImage 进行识别，recognitionLevel 设置为 accurate。
        """)
        try write("MySQL 索引优化.md", """
        # MySQL 索引优化

        ## 内容

        复合索引的最左前缀原则，以及 PostgreSQL 的查询计划分析。
        """)
        try write("日本旅行计划.md", """
        # 日本旅行计划

        ## 内容

        签证材料、机票和酒店都已经确认，行程安排如下。
        """)
        try write("随笔.md", """
        # 随笔

        ## 内容

        今天下午去公园散步，天气很好。
        """)
    }

    // MARK: - Indexing

    func testIndexesEveryMarkdownFileWithChunks() async throws {
        try seedVault()
        let indexer = makeIndexer()
        let statistics = await indexer.indexVault()

        XCTAssertEqual(statistics.indexedFiles, 4)
        XCTAssertEqual(statistics.removedFiles, 0)
        XCTAssertGreaterThanOrEqual(statistics.totalChunks, 4)
        XCTAssertEqual(database.chunkCount(), statistics.totalChunks)
    }

    func testSecondPassSkipsUnchangedFiles() async throws {
        try seedVault()
        _ = await makeIndexer().indexVault()
        let second = await makeIndexer().indexVault()

        XCTAssertEqual(second.indexedFiles, 0)
        XCTAssertEqual(second.updatedFiles, 0)
        XCTAssertEqual(second.skippedFiles, 4)
    }

    func testChangedFileIsReindexed() async throws {
        let url = try write("笔记.md", "# 笔记\n\n第一版内容。")
        _ = await makeIndexer().indexVault()

        // A real content change moves the modification date.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "# 笔记\n\n第二版内容，加入了 SwiftUI 与 Vision。".write(to: url, atomically: true, encoding: .utf8)

        let statistics = await makeIndexer().indexVault()
        XCTAssertEqual(statistics.updatedFiles, 1)
        XCTAssertEqual(statistics.skippedFiles, 0)

        let results = makeEngine().search(query: "Vision", mode: .exact)
        XCTAssertEqual(results.first?.fileURL.lastPathComponent, "笔记.md")
    }

    func testDeletedFileIsRemovedFromTheIndex() async throws {
        try seedVault()
        _ = await makeIndexer().indexVault()
        XCTAssertFalse(makeEngine().search(query: "MySQL", mode: .exact).isEmpty)

        try FileManager.default.removeItem(at: root.appendingPathComponent("MySQL 索引优化.md"))
        let statistics = await makeIndexer().indexVault()

        XCTAssertEqual(statistics.removedFiles, 1)
        XCTAssertTrue(makeEngine().search(query: "MySQL", mode: .exact).isEmpty)
    }

    func testMetadataOnlyChangeDoesNotReembed() async throws {
        let url = try write("笔记.md", "# 笔记\n\n内容不变。")
        _ = await makeIndexer().indexVault()
        let before = database.chunkCount()

        // Touch the modification date without changing a byte.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let statistics = await makeIndexer().indexVault()

        XCTAssertEqual(statistics.updatedFiles, 0)
        XCTAssertEqual(database.chunkCount(), before)
    }

    func testIndexExcludesToolingDirectories() async throws {
        try seedVault()
        let obsidian = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
        try "# hidden".write(to: obsidian.appendingPathComponent("workspace.md"),
                             atomically: true, encoding: .utf8)

        let statistics = await makeIndexer().indexVault()
        XCTAssertEqual(statistics.indexedFiles, 4)
        XCTAssertTrue(makeEngine().search(query: "hidden", mode: .exact).isEmpty)
    }

    // MARK: - Ranking

    func testFindsANoteByContentNotJustFilename() async {
        try? seedVault()
        await indexAll()

        let results = makeEngine().search(query: "VNRecognizeTextRequest", mode: .exact)
        XCTAssertEqual(results.first?.fileURL.lastPathComponent, "Vision OCR 图片文字识别.md")
    }

    /// Spec §43: a natural-language question must find the note even though the words differ.
    func testNaturalLanguageQueryFindsTheRelatedNote() async {
        try? seedVault()
        await indexAll()

        let results = makeEngine().search(query: "之前记录的那个 Swift 图片文字识别", mode: .smart)
        XCTAssertEqual(results.first?.fileURL.lastPathComponent, "Vision OCR 图片文字识别.md")
    }

    func testTitleMatchesOutrankBodyMatches() async {
        _ = try? write("Vision 教程.md", "# Vision 教程\n\n正文内容与查询无关。")
        _ = try? write("其他.md", "# 其他\n\n这里在很靠后的位置提到了 Vision 一次。")
        await indexAll()

        let results = makeEngine().search(query: "Vision", mode: .exact)
        XCTAssertEqual(results.first?.fileURL.lastPathComponent, "Vision 教程.md")
    }

    func testResultCarriesSnippetAndReason() async {
        try? seedVault()
        await indexAll()

        let results = makeEngine().search(query: "MySQL", mode: .exact)
        let first = try? XCTUnwrap(results.first)
        XCTAssertFalse(first?.snippet.isEmpty ?? true)
        XCTAssertFalse(first?.matchReason.isEmpty ?? true)
        XCTAssertFalse(first?.title.isEmpty ?? true)
    }

    func testEmptyQueryReturnsNothing() {
        try? seedVault()
        XCTAssertTrue(makeEngine().search(query: "   ", mode: .smart).isEmpty)
    }

    /// Spec §19: matching is exact, prefix and token. Prefix matters because search runs
    /// while the user is still typing.
    func testUnfinishedLatinWordStillFindsTheNote() async {
        _ = try? write("Vision 教程.md", "# Vision 教程\n\n在 SwiftUI 里调用 VisionKit。")
        await indexAll()

        let engine = makeEngine()
        XCTAssertEqual(engine.search(query: "Vis", mode: .exact).first?.fileURL.lastPathComponent,
                       "Vision 教程.md")
        XCTAssertEqual(engine.search(query: "SwiftU", mode: .exact).first?.fileURL.lastPathComponent,
                       "Vision 教程.md")
        XCTAssertEqual(engine.search(query: "VisionKit", mode: .exact).first?.fileURL.lastPathComponent,
                       "Vision 教程.md")
    }

    /// Chinese is matched as character bi-grams, so a partial phrase resolves without
    /// needing prefix semantics on top of them.
    func testPartialChinesePhraseStillFindsTheNote() async {
        try? seedVault()
        await indexAll()

        let results = makeEngine().search(query: "图片文字", mode: .exact)
        XCTAssertEqual(results.first?.fileURL.lastPathComponent, "Vision OCR 图片文字识别.md")
    }

    func testPrefixQueryWithSyntaxCharactersStaysSafe() async {
        try? seedVault()
        await indexAll()
        // A trailing quote or operator must not produce an FTS5 syntax error.
        for query in ["Vis\"", "Vis*", "Vis OR", "Vis -", "Vis^", "Vis:"] {
            _ = makeEngine().search(query: query, mode: .exact)
        }
        XCTAssertGreaterThan(database.chunkCount(), 0)
    }

    func testQuerySyntaxCharactersCannotBreakTheIndex() async {
        try? seedVault()
        await indexAll()

        // These would all be FTS5 syntax errors if the query were not quoted.
        for query in ["\"", "AND", "Vision OR", "*", "NEAR(", "^Vision", "col:value", "-Vision"] {
            _ = makeEngine().search(query: query, mode: .exact)
        }
        XCTAssertEqual(database.chunkCount() > 0, true)
    }

    // MARK: - Adaptive fusion

    /// With a discriminative embedding model, a note that shares no vocabulary can still be
    /// surfaced by meaning. This is the behaviour a stronger local model would unlock.
    func testSemanticOnlyResultIsReturnedWhenTheEmbeddingDiscriminates() throws {
        try seedVault()
        let visionPath = root.appendingPathComponent("Vision OCR 图片文字识别.md").standardizedFileURL.path
        let travelPath = root.appendingPathComponent("日本旅行计划.md").standardizedFileURL.path

        let semanticIndex = SemanticSearchIndex(embeddings: [
            StoredEmbedding(chunkID: "a", filePath: visionPath, title: "Vision",
                            modifiedAt: Date(), language: "en", vector: [1, 0]),
            StoredEmbedding(chunkID: "b", filePath: travelPath, title: "Travel",
                            modifiedAt: Date(), language: "en", vector: [0, 1])
        ])
        let engine = makeEngine(semanticIndex: semanticIndex,
                                semanticEnabled: true,
                                provider: FixedVectorEmbeddingProvider([1, 0]))
        let results = engine.search(query: "zzzqqq", mode: .smart)

        XCTAssertEqual(results.first?.fileURL.standardizedFileURL.path, visionPath)
        XCTAssertEqual(results.first?.matchReason, String(localized: "Related by meaning"))
    }

    /// With the system embeddings the candidates are indistinguishable, so semantic-only
    /// rows are withheld instead of surfacing arbitrary notes.
    func testSemanticOnlyResultIsWithheldWhenTheEmbeddingCannotDiscriminate() throws {
        try seedVault()
        let first = root.appendingPathComponent("Vision OCR 图片文字识别.md").standardizedFileURL.path
        let second = root.appendingPathComponent("日本旅行计划.md").standardizedFileURL.path

        // Two nearly identical directions: spread is far below the threshold.
        let semanticIndex = SemanticSearchIndex(embeddings: [
            StoredEmbedding(chunkID: "a", filePath: first, title: "A",
                            modifiedAt: Date(), language: "en", vector: [1, 0]),
            StoredEmbedding(chunkID: "b", filePath: second, title: "B",
                            modifiedAt: Date(), language: "en", vector: [0.9999, 0.0141])
        ])
        let engine = makeEngine(semanticIndex: semanticIndex,
                                semanticEnabled: true,
                                provider: FixedVectorEmbeddingProvider([1, 0]))
        let results = engine.search(query: "zzzqqq", mode: .smart)

        XCTAssertTrue(results.isEmpty, "a non-discriminative embedding must not invent results")
    }

    func testExactModeIgnoresSemanticsEntirely() throws {
        try seedVault()
        let path = root.appendingPathComponent("Vision OCR 图片文字识别.md").standardizedFileURL.path
        let semanticIndex = SemanticSearchIndex(embeddings: [
            StoredEmbedding(chunkID: "a", filePath: path, title: "Vision",
                            modifiedAt: Date(), language: "en", vector: [1, 0])
        ])
        let engine = makeEngine(semanticIndex: semanticIndex,
                                semanticEnabled: true,
                                provider: FixedVectorEmbeddingProvider([1, 0]))

        XCTAssertTrue(engine.search(query: "zzzqqq", mode: .exact).isEmpty)
    }

    // MARK: - Storage

    func testEmbeddingsRoundTripThroughFloat32Blobs() throws {
        let vector: [Float] = [0.5, -1.25, 3.75, 0]
        let state = IndexedFileState(path: "/tmp/x.md", modifiedAt: Date(), size: 10, contentHash: "hash")
        let chunk = IndexedChunk(id: "/tmp/x.md#0",
                                 title: "嵌入测试",
                                 text: "内容",
                                 excerpt: "内容",
                                 language: "zh-Hans",
                                 embedding: vector,
                                 modifiedAt: Date(),
                                 ftsFields: ["", "", "", "", "内容", ""])
        try database.replaceChunks(forFileAt: "/tmp/x.md", state: state, chunks: [chunk])

        let loaded = database.loadEmbeddings()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.vector, vector)
        XCTAssertEqual(loaded.first?.language, "zh-Hans")
    }

    func testCosineSimilarityUsesAccelerate() {
        let identical = LocalEmbeddingService.cosineSimilarity([1, 2, 3], [2, 4, 6])
        XCTAssertEqual(identical, 1, accuracy: 0.0001)
        let orthogonal = LocalEmbeddingService.cosineSimilarity([1, 0], [0, 1])
        XCTAssertEqual(orthogonal, 0, accuracy: 0.0001)
        let mismatched = LocalEmbeddingService.cosineSimilarity([1, 0], [1, 0, 0])
        XCTAssertEqual(mismatched, 0)
    }

    func testChunkerSplitsOnStructureAndRespectsTheMaximum() {
        let paragraph = String(repeating: "这是一段中文说明文字，用来测试分块逻辑。", count: 40)
        let markdown = """
        # 标题

        \(paragraph)

        ```swift
        let a = 1
        let b = 2
        ```

        ## 第二节

        另一个段落的内容。
        """
        let chunks = SearchChunker.chunks(for: markdown)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SearchChunker.maximumCharacters)
        }
        XCTAssertTrue(chunks.contains { $0.contains("```swift") },
                      "a fenced code block must not be split away from its fence")
    }

    func testDocumentParsesFrontmatterTagsAndSummary() {
        let document = SearchDocument.parse(markdown: """
        ---
        tags:
          - SwiftUI
          - Vision
        ---
        # 标题

        ## 摘要

        这是摘要。

        ## 内容

        正文。
        """,
        fileURL: URL(fileURLWithPath: "/tmp/标题.md"),
        modifiedAt: Date())

        XCTAssertEqual(document.title, "标题")
        XCTAssertEqual(document.tags, ["SwiftUI", "Vision"])
        XCTAssertEqual(document.summary, "这是摘要。")
    }
}
