import Foundation
import XCTest
@testable import ClipNest

/// §25: the on-device model widens a search query with related keywords. Every test here has a
/// counterpart for the "no model / slow model / bad answer" path, because expansion must never
/// be able to break search.
final class LocalQueryExpanderTests: XCTestCase {
    private func expander(engine: (any LocalTextGenerating)?,
                          timeout: Duration = .milliseconds(50)) -> LocalQueryExpander {
        LocalQueryExpander(makeEngine: { engine }, timeout: timeout, cache: nil)
    }

    // MARK: - Parsing what a small model actually emits

    func testParsesChineseCommas() {
        XCTAssertEqual(LocalQueryExpander.parse("图片,文字识别，Vision、OCR", excluding: "图片识别"),
                       ["文字识别", "Vision", "OCR"])
    }

    func testParsesNewlinesAndBullets() {
        XCTAssertEqual(LocalQueryExpander.parse("- SwiftUI\n- 布局\n* 视图", excluding: "x"),
                       ["SwiftUI", "布局", "视图"])
    }

    func testParsesAJSONArray() {
        XCTAssertEqual(LocalQueryExpander.parse(#"["SwiftUI", "Vision", "OCR"]"#, excluding: "x"),
                       ["SwiftUI", "Vision", "OCR"])
    }

    /// A model that ignores "keywords only" and writes a sentence must not poison the query.
    func testDropsProseAndLabels() {
        let raw = "关键词：SwiftUI 是一个用于构建界面的框架，非常好用"
        let parsed = LocalQueryExpander.parse(raw, excluding: "x")
        XCTAssertFalse(parsed.contains { $0.contains("很好用") }, "got \(parsed)")
        XCTAssertTrue(parsed.allSatisfy { $0.split(separator: " ").count <= 3 }, "got \(parsed)")
    }

    func testExcludesTheUserOwnTermsAndStopwords() {
        let parsed = LocalQueryExpander.parse("Vision, the, 的, OCR", excluding: "Vision")
        XCTAssertFalse(parsed.contains("Vision"))
        XCTAssertFalse(parsed.contains("the"))
        XCTAssertFalse(parsed.contains("的"))
        XCTAssertTrue(parsed.contains("OCR"))
    }

    func testCapsTheKeywordCount() {
        XCTAssertLessThanOrEqual(LocalQueryExpander.parse("a,b,c,d,e,f,g,h", excluding: "x").count,
                                 LocalQueryExpander.maximumKeywords)
    }

    func testAnEmptyAnswerProducesNothing() {
        XCTAssertTrue(LocalQueryExpander.parse("", excluding: "x").isEmpty)
        XCTAssertTrue(LocalQueryExpander.parse("   \n  ", excluding: "x").isEmpty)
    }

    // MARK: - Degradation

    /// No model installed: the engine is never asked, and the caller keeps the raw query.
    func testNoModelMeansNoExpansionAndNoModelCall() async {
        let engine = RecordingLocalEngine(response: "SwiftUI, Vision")
        let expander = LocalQueryExpander(makeEngine: { nil }, cache: nil)
        let keywords = await expander.expand("图片识别")
        XCTAssertTrue(keywords.isEmpty)

        let asked = await engine.prompts
        XCTAssertTrue(asked.isEmpty)
    }

    /// A slow model must not hold the search field hostage.
    func testASlowModelIsAbandonedOnTimeout() async {
        let engine = SlowLocalEngine(delay: .milliseconds(400), response: "SwiftUI, Vision")
        let expander = expander(engine: engine, timeout: .milliseconds(30))

        let started = Date()
        let keywords = await expander.expand("图片识别")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(keywords.isEmpty, "a timed-out expansion must contribute nothing")
        XCTAssertLessThan(elapsed, 0.3, "the timeout must actually bound the wait")
    }

    func testTheModelAnswerIsUsedWhenItArrives() async {
        let engine = RecordingLocalEngine(response: "SwiftUI, Vision")
        let keywords = await expander(engine: engine).expand("图片识别")
        XCTAssertEqual(keywords, ["SwiftUI", "Vision"])
    }

    /// A one-character query would expand to half the vault.
    func testVeryShortQueriesAreNotExpanded() async {
        let engine = RecordingLocalEngine(response: "SwiftUI")
        let keywords = await expander(engine: engine).expand("图")
        XCTAssertTrue(keywords.isEmpty)
        let asked = await engine.prompts
        XCTAssertTrue(asked.isEmpty)
    }

    /// Typing re-issues the same query many times; each miss would cost a model run.
    func testTheCachePreventsASecondModelRun() async {
        let engine = CountingLocalEngine(response: "SwiftUI")
        let cache = LocalQueryExpansionCache()
        let expander = LocalQueryExpander(makeEngine: { engine },
                                          timeout: .milliseconds(50),
                                          cache: cache)

        _ = await expander.expand("图片识别")
        _ = await expander.expand("图片识别")
        _ = await expander.expand("图片识别")

        let runs = await engine.runs
        XCTAssertEqual(runs, 1)
    }

    /// The prompt must ask for keywords, be tiny, and disable reasoning (§20, §21).
    func testThePromptAsksForKeywordsOnly() {
        let prompt = LocalQueryExpander.prompt(for: "图片识别")
        XCTAssertTrue(prompt.contains("/no_think"))
        XCTAssertTrue(prompt.contains("图片识别"))
        XCTAssertTrue(prompt.contains("关键词"))
        XCTAssertLessThan(prompt.count, 200)
    }
}

/// Fails if the engine is asked anything — proves a path short-circuits early.
final class SlowLocalEngine: LocalTextGenerating, @unchecked Sendable {
    let engineName = "Slow Engine"
    private let delay: Duration
    private let response: String

    init(delay: Duration, response: String) {
        self.delay = delay
        self.response = response
    }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        try? await Task.sleep(for: delay)
        return response
    }
}

actor CountingLocalEngine: LocalTextGenerating {
    nonisolated let engineName = "Counting Engine"
    private(set) var runs = 0
    private let response: String

    init(response: String) { self.response = response }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        runs += 1
        return response
    }
}

// MARK: - Expansion in the FTS expression

final class ExpandedSearchTests: XCTestCase {
    private var root: URL!
    private var database: SearchDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpandedSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try SearchDatabase(url: root.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ body: String) throws {
        try body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeEngine() -> LocalSearchEngine {
        var engine = LocalSearchEngine(database: database,
                                       semanticIndex: SemanticSearchIndex(),
                                       semanticEnabled: false)
        engine.embeddingProvider = UnavailableEmbeddingProvider()
        return engine
    }

    @discardableResult
    private func index() async -> SearchIndexStatistics {
        await LocalSearchIndexer(vaultRoot: root,
                                 database: database,
                                 embeddingProvider: UnavailableEmbeddingProvider(),
                                 semanticSearchEnabled: false).indexVault()
    }

    private func seed() throws {
        try write("MySQL 索引.md", """
        # MySQL 索引优化

        复合索引的最左前缀原则。
        """)
        try write("数据库设计.md", """
        # 数据库设计

        关系型数据库的表结构设计要点。
        """)
        try write("日本旅行.md", """
        # 日本旅行计划

        签证材料和机票。
        """)
    }

    /// The literal query is what the user asked for, so it must win.
    func testALiteralHitOutranksAnExpansionOnlyHit() async throws {
        try seed()
        await index()

        let plain = makeEngine().search(query: "MySQL", mode: .exact)
        XCTAssertEqual(plain.first?.title, "MySQL 索引优化")
        XCTAssertEqual(plain.count, 1, "without expansion only the literal note matches")

        let widened = makeEngine().search(query: "MySQL", mode: .exact,
                                          expandedTerms: ["数据库", "表结构"])
        XCTAssertEqual(widened.first?.title, "MySQL 索引优化",
                       "expansion must not displace the literal answer")
        XCTAssertTrue(widened.contains { $0.title == "数据库设计" },
                      "the expansion should surface the related note; got \(widened.map(\.title))")
        XCTAssertEqual(widened.first?.matchedQueryLiterally, true)
        XCTAssertTrue(widened.dropFirst().allSatisfy { !$0.matchedQueryLiterally },
                      "everything expansion added is a suggestion, not an answer")
    }

    func testExpansionAloneStillFindsSomething() async throws {
        try seed()
        await index()

        let widened = makeEngine().search(query: "MySQL", mode: .exact,
                                          expandedTerms: ["数据库"])
        let files = widened.map(\.title)
        XCTAssertTrue(files.contains { $0.contains("数据库设计") }, "got \(files)")
        XCTAssertFalse(files.contains { $0.contains("日本旅行") }, "unrelated notes must stay out")
    }

    /// Expansion must widen FTS, not replace it: passing no expansions is byte-for-byte the
    /// old behaviour.
    func testNoExpansionIsIdenticalToTheOriginalQuery() async throws {
        try seed()
        await index()

        let a = makeEngine().search(query: "MySQL", mode: .exact)
        let b = makeEngine().search(query: "MySQL", mode: .exact, expandedTerms: [])
        XCTAssertEqual(a.map(\.title), b.map(\.title))
    }

    /// Unanalyzable input must not be able to turn into an FTS syntax error.
    func testExpansionTermsAreQuotedLikeUserInput() async throws {
        try seed()
        await index()

        let widened = makeEngine().search(query: "MySQL", mode: .exact,
                                          expandedTerms: ["\"; DROP TABLE chunks; --", "数据库*"])
        XCTAssertEqual(widened.first?.title, "MySQL 索引优化")
        XCTAssertGreaterThan(database.chunkCount(), 0, "the index must survive hostile input")
    }

    func testExpansionTermsAreAnalysedIntoTheIndexVocabulary() {
        // A suggested Chinese phrase becomes the bi-grams the index actually stores.
        let terms = KeywordSearchIndex.expansionTerms(["数据库"], excluding: ["mysql"])
        XCTAssertFalse(terms.isEmpty)
        XCTAssertFalse(terms.contains("mysql"), "terms already in the query are not repeated")
        XCTAssertEqual(Set(terms).count, terms.count, "no term may be duplicated")
    }

    /// Regression: the system tokenizer yields bare CJK characters (`截图取字` →
    /// `截图 / 取 / 字`). `terms()` has a two-character floor on the indexing side, so such a
    /// character can never match the index — yet it used to make a note claim a literal
    /// match, because the highlight check does a plain substring test.
    func testBareCJKCharactersAreNotQueryTerms() {
        let terms = KeywordSearchIndex.queryTerms("截图取字")
        XCTAssertFalse(terms.contains("字"), "got \(terms)")
        XCTAssertFalse(terms.contains("取"), "got \(terms)")
        XCTAssertTrue(terms.contains("截图"))

        // A query that genuinely is one character still works, via the collapsed query.
        XCTAssertEqual(KeywordSearchIndex.queryTerms("图"), ["图"])

        XCTAssertFalse(KeywordSearchIndex.matchedTerms(in: "Vision 文字识别",
                                                       queryTerms: terms).contains("字"))
    }

    func testAMatchExpressionCanBeBuiltFromExpansionsAlone() {
        XCTAssertNil(KeywordSearchIndex.matchExpression(for: "的", expansions: []),
                     "a stopword-only query with no expansion has nothing to match")
        let expression = KeywordSearchIndex.matchExpression(for: "的", expansions: ["数据库"])
        XCTAssertNotNil(expression)
        XCTAssertTrue(expression!.contains("数据库"))
    }

    /// The stored note must be findable by the keywords the model suggested for a *different*
    /// query — this is the whole user-visible payoff.
    ///
    /// The query is chosen so its CJK bi-grams genuinely do not occur in the note: Chinese
    /// search tokenizes to bi-grams, so a query that shared even one (`文字`) would match
    /// literally and this would prove nothing.
    func testExpansionFindsANoteAcrossVocabulary() async throws {
        try write("OCR 笔记.md", """
        # Vision 文字识别

        使用 VNRecognizeTextRequest 做本地识别。
        """)
        await index()

        let literal = makeEngine().search(query: "截图取字", mode: .exact)
        XCTAssertTrue(literal.isEmpty, "no note contains that phrase")

        let widened = makeEngine().search(query: "截图取字", mode: .exact,
                                          expandedTerms: ["文字识别"])
        XCTAssertEqual(widened.first?.title, "Vision 文字识别")
        XCTAssertEqual(widened.first?.matchedQueryLiterally, false,
                       "this row is reachable only through the expansion")
    }
}
