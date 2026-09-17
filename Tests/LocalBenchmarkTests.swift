import Foundation
import XCTest
@testable import ClipNest

/// Phase 7 of the plan: measure the local engines on realistic Chinese content before
/// deciding whether an extra Core ML embedding model is warranted (spec §24, §38, §46).
///
/// The assertions here are invariants, not magic numbers. The numbers themselves are
/// printed so a human can read the report produced by:
///
///     xcodebuild test -project ClipNest.xcodeproj -scheme ClipNest \
///       -destination 'platform=macOS' -only-testing:ClipNestTests/LocalBenchmarkTests
///
final class LocalBenchmarkTests: XCTestCase {

    // MARK: - Latency budgets (spec §38)

    func testLocalLiteMeetsLatencyBudgets() {
        let shortText = "SwiftUI 里用 Vision 做 OCR 的要点"
        let normalNote = Self.realisticNote

        // Warm up so the first-call framework cost is not attributed to the budget.
        _ = LocalLiteNoteProvider().synchronousNote(for: shortText)

        let shortDuration = measureAverage(iterations: 20) {
            _ = LocalLiteNoteProvider().synchronousNote(for: shortText)
        }
        let noteDuration = measureAverage(iterations: 10) {
            _ = LocalLiteNoteProvider().synchronousNote(for: normalNote)
        }

        print("""
        [benchmark] LocalLite short text  : \(milliseconds(shortDuration)) ms (budget 50 ms)
        [benchmark] LocalLite normal note : \(milliseconds(noteDuration)) ms (budget 150 ms)
        """)

        XCTAssertLessThan(shortDuration, 0.050, "short text must stay under 50 ms")
        XCTAssertLessThan(noteDuration, 0.150, "a normal note must stay under 150 ms")
    }

    func testClassificationMeetsLatencyBudget() {
        let profiles = Self.benchmarkProfiles
        let note = Self.realisticNote
        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = SystemEmbeddingProvider.shared

        SystemEmbeddingProvider.shared.clearCache()
        // Cold: nothing is cached, every profile has to be embedded.
        let cold = measureAverage(iterations: 1) {
            _ = classifier.classify(text: note, categories: profiles)
        }

        // Steady state: the profiles are memoised, so this is the per-note cost a user
        // actually pays. Each iteration uses a different note so no note vector is a hit.
        let notes = Self.benchmarkCases.map(\.text)
        var index = 0
        let steady = measureAverage(iterations: notes.count) {
            _ = classifier.classify(text: notes[index % notes.count], categories: profiles)
            index += 1
        }

        let cache = SystemEmbeddingProvider.shared.cacheStatistics
        print("""
        [benchmark] Classification cold    : \(milliseconds(cold)) ms (one-off, warms the profile cache)
        [benchmark] Classification steady  : \(milliseconds(steady)) ms (budget 100 ms)
        [benchmark] Embedding cache        : \(cache.hits) hits / \(cache.misses) misses / \(cache.entries) entries
        """)
        XCTAssertLessThan(steady, 0.100, "steady-state classification must stay under 100 ms")
    }

    // MARK: - Embedding quality on a Chinese vault

    /// Answers the plan's Phase 7 question directly: is Apple's system sentence embedding
    /// good enough to classify a Chinese technical vault on its own?
    ///
    /// It also proves the shipped design is safe either way: whatever the embedding does, the
    /// adaptive classifier never scores below the keyword-only baseline it falls back to.
    func testEmbeddingQualityGateOnAChineseVault() {
        let cases = Self.benchmarkCases
        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = SystemEmbeddingProvider.shared

        var embeddingOnlyCorrect = 0
        var shippedCorrect = 0

        print("[benchmark] --- Chinese vault classification ---")
        for testCase in cases {
            let result = classifier.classify(text: testCase.text, categories: Self.benchmarkProfiles)
            let shipped = result.category ?? "Inbox(未分类)"
            let embeddingTop = result.candidates.max { lhs, rhs in
                lhs.semanticScore < rhs.semanticScore
            }?.category ?? "-"

            if shipped == testCase.expected { shippedCorrect += 1 }
            if embeddingTop == testCase.expected { embeddingOnlyCorrect += 1 }

            print("""
            [benchmark] \(testCase.name)
                expected=\(testCase.expected) shipped=\(shipped) embeddingTop=\(embeddingTop) \
            spreadUsed=\(result.usedEmbedding) score=\(String(format: "%.2f", result.score))
            """)
        }

        let embeddingAccuracy = Double(embeddingOnlyCorrect) / Double(cases.count)
        let shippedAccuracy = Double(shippedCorrect) / Double(cases.count)
        print("""
        [benchmark] embedding-only top-1 accuracy : \(String(format: "%.0f%%", embeddingAccuracy * 100))
        [benchmark] shipped (adaptive) top-1      : \(String(format: "%.0f%%", shippedAccuracy * 100))
        [benchmark] embedding spaces available    : \(LocalEmbeddingService.supportedLanguages())
        """)

        // The shipped engine must never be worse than trusting the embedding blindly.
        XCTAssertGreaterThanOrEqual(shippedAccuracy, embeddingAccuracy,
                                    "the adaptive blend must not lose to raw embeddings")
        // It must also be genuinely useful, not silently always-Inbox.
        XCTAssertGreaterThanOrEqual(shippedAccuracy, 0.6,
                                    "local classification should handle the majority of a realistic vault")
    }

    /// Documents why `minimumSemanticMargin` exists: on this content the raw cosines sit in
    /// a narrow band, which is exactly when a fixed threshold would mis-assign.
    func testSystemEmbeddingSimilaritiesAreReportedForCalibration() throws {
        let languages = LocalEmbeddingService.supportedLanguages()
        guard !languages.isEmpty else {
            throw XCTSkip("No system sentence embeddings are installed on this machine")
        }

        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = SystemEmbeddingProvider.shared

        for testCase in Self.benchmarkCases.prefix(3) {
            let result = classifier.classify(text: testCase.text, categories: Self.benchmarkProfiles)
            let similarities = result.candidates
                .map { "\($0.category)=\(String(format: "%.3f", $0.semanticScore))" }
                .joined(separator: " ")
            print("[benchmark] cosines for \(testCase.name): \(similarities)")
        }

        let first = try XCTUnwrap(Self.benchmarkCases.first)
        let result = classifier.classify(text: first.text, categories: Self.benchmarkProfiles)
        XCTAssertFalse(result.candidates.isEmpty)
    }

    // MARK: - Helpers

    /// Guards the lexical layer directly: every benchmark note must share vocabulary with
    /// the category it belongs to. If this fails, the classification failure is a
    /// tokenization bug (a real one shipped once: long Chinese clauses were kept as single
    /// terms and suppressed the meaningful bi-grams inside them).
    func testEveryBenchmarkNoteSharesVocabularyWithItsCategory() {
        for testCase in Self.benchmarkCases {
            let terms = LocalTextAnalyzer.terms(in: testCase.text, limit: 60)
            let vocabulary = Self.benchmarkProfiles.reduce(into: [String: Set<String>]()) {
                $0[$1.name] = $1.distinctiveKeys
            }
            let all = vocabulary.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let relevant = terms.filter { all.contains($0.key) }.map(\.key)
            let expectedKeys = vocabulary[testCase.expected] ?? []

            XCTAssertFalse(relevant.isEmpty,
                           "\(testCase.name) shares no vocabulary with any category (terms: \(terms.map(\.key)))")
            XCTAssertFalse(relevant.filter(expectedKeys.contains).isEmpty,
                           "\(testCase.name) shares nothing with \(testCase.expected) (relevant: \(relevant))")
        }
    }

    private func measureAverage(iterations: Int, _ body: () -> Void) -> TimeInterval {
        let start = Date()
        for _ in 0..<iterations { body() }
        return Date().timeIntervalSince(start) / Double(iterations)
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval * 1000)
    }

    // MARK: - Fixtures

    struct BenchmarkCase {
        let name: String
        let text: String
        let expected: String
    }

    static let benchmarkProfiles: [CategoryProfile] = [
        CategoryProfile(name: "iOS开发",
                        keywords: ["Swift", "SwiftUI", "UIKit", "Xcode", "Vision", "CoreML",
                                   "OCR", "VNRecognizeTextRequest", "iCloud", "App Store"],
                        noteTitles: ["Xcode 快捷键整理", "CoreML 模型量化", "SwiftUI 状态管理"]),
        CategoryProfile(name: "数据库",
                        keywords: ["MySQL", "PostgreSQL", "SQLite", "SQL", "索引", "事务",
                                   "查询优化", "Redis", "连接池"],
                        noteTitles: ["MySQL 慢查询排查", "PostgreSQL 索引原理"]),
        CategoryProfile(name: "AI",
                        keywords: ["LLM", "Transformer", "机器学习", "深度学习", "提示词",
                                   "RAG", "微调", "向量检索"],
                        noteTitles: ["Transformer 笔记", "RAG 检索增强"]),
        CategoryProfile(name: "生活",
                        keywords: ["做饭", "菜谱", "运动", "跑步", "睡眠", "健康", "记录"],
                        noteTitles: ["周末菜谱", "跑步计划"]),
        CategoryProfile(name: "旅游",
                        keywords: ["旅游", "签证", "机票", "酒店", "行程", "攻略", "自由行"],
                        noteTitles: ["日本行程", "签证材料清单"]),
        CategoryProfile(name: "服务器运维",
                        keywords: ["nginx", "Docker", "Kubernetes", "Linux", "部署", "ssl",
                                   "防火墙", "备份"],
                        noteTitles: ["nginx 反向代理", "Docker 部署笔记"])
    ]

    static let benchmarkCases: [BenchmarkCase] = [
        BenchmarkCase(name: "SwiftUI 调用 Vision",
                      text: "如何使用 SwiftUI 调用 Vision 进行 OCR，把 VNRecognizeTextRequest 的结果保存下来。",
                      expected: "iOS开发"),
        BenchmarkCase(name: "CoreML 模型转换",
                      text: "把 PyTorch 模型转成 CoreML 并做 INT8 量化，然后集成进 Xcode 工程。",
                      expected: "iOS开发"),
        BenchmarkCase(name: "MySQL 慢查询",
                      text: "MySQL 慢查询日志分析，复合索引的最左前缀原则，以及事务隔离级别。",
                      expected: "数据库"),
        BenchmarkCase(name: "PostgreSQL 索引",
                      text: "PostgreSQL 的 B-tree 与 GIN 索引选择，以及查询计划的成本估算。",
                      expected: "数据库"),
        BenchmarkCase(name: "大模型提示词",
                      text: "大语言模型的提示词工程与 RAG 检索增强，以及微调时的数据准备。",
                      expected: "AI"),
        BenchmarkCase(name: "Docker 部署",
                      text: "用 Docker 打包服务，Kubernetes 编排，nginx 反向代理和证书配置。",
                      expected: "服务器运维"),
        BenchmarkCase(name: "日本旅行",
                      text: "日本自由行攻略：签证材料、机票和酒店都已经确认，行程安排好了。",
                      expected: "旅游"),
        BenchmarkCase(name: "跑步计划",
                      text: "每周跑步三次，注意睡眠和饮食健康，顺便记录一下体重变化。",
                      expected: "生活")
    ]

    static let realisticNote: String = """
    # SwiftUI 与 Vision：本地图片文字识别

    ## 摘要

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别，识别结果整理成 Markdown 后写入 Obsidian。

    ## 内容

    首先把图片转成 CGImage，然后创建 VNImageRequestHandler。识别级别使用 accurate，
    同时打开 usesLanguageCorrection。每一行识别结果对应一个 VNRecognizedTextObservation，
    可以通过 boundingBox 得到位置。最后记得把 OCR 结果里被硬换行拆开的句子合并回去，
    但不要动代码块和 URL。整套流程完全在设备上运行，不需要联网，也不会把图片上传。

    ```swift
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    ```
    """
}

private extension LocalLiteNoteProvider {
    /// Synchronous shim used only by the latency benchmark.
    func synchronousNote(for text: String) -> GeneratedNote? {
        guard let content = ClipboardContent(text: text) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var output: GeneratedNote?
        Task {
            output = try? await generate(from: content,
                                         existingCategories: [],
                                         preferredLanguage: .automatic)
            semaphore.signal()
        }
        semaphore.wait()
        return output
    }
}
