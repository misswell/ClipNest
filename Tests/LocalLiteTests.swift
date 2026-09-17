import Foundation
import XCTest
@testable import ClipNest

/// An embedding provider that always fails, so classification and search decide on their
/// lexical layer alone. Keeps the assertions independent of which system assets happen to
/// be installed on the machine running the tests.
final class UnavailableEmbeddingProvider: EmbeddingProviding {
    func vector(for text: String, language: String) -> [Float]? { nil }
    func dimension(for language: String) -> Int? { nil }
}

/// A hand-fed embedding provider, used to prove the adaptive weighting actually reacts to a
/// discriminative embedding model.
final class FixedVectorEmbeddingProvider: EmbeddingProviding {
    let fixed: [Float]
    init(_ fixed: [Float]) { self.fixed = fixed }
    func vector(for text: String, language: String) -> [Float]? { fixed }
    func dimension(for language: String) -> Int? { fixed.count }
}

// MARK: - Titles

final class LocalTitleTests: XCTestCase {
    func testUsesMarkdownH1First() {
        let title = LocalTitleExtractor.title(for: "# 使用 Vision 做 OCR\n\n正文内容在这里。")
        XCTAssertEqual(title, "使用 Vision 做 OCR")
    }

    func testFallsBackToH2WhenThereIsNoH1() {
        let title = LocalTitleExtractor.title(for: "## 数据库索引优化\n\n正文内容在这里。")
        XCTAssertEqual(title, "数据库索引优化")
    }

    func testFallsBackToTheFirstSubstantialSentence() {
        let title = LocalTitleExtractor.title(for: "这是一段没有任何标题的笔记，第一句话应该成为标题。后面还有别的内容。")
        XCTAssertTrue(title.hasPrefix("这是一段没有任何标题的笔记"))
    }

    func testNeverUsesABareURLAsATitle() {
        let title = LocalTitleExtractor.title(for: "https://example.com/a/very/long/path/to/an/article")
        XCTAssertEqual(title, LocalTitleExtractor.fallbackTitle)
    }

    func testStripsMarkdownDecoration() {
        let title = LocalTitleExtractor.title(for: "# **Swift** `actor` 并发 —— 深入理解")
        XCTAssertFalse(title.contains("*"))
        XCTAssertFalse(title.contains("`"))
        XCTAssertFalse(title.contains("#"))
    }

    func testCapsChineseTitlesAtThirtyCharacters() {
        let long = String(repeating: "中", count: 80)
        let title = LocalTitleExtractor.finalize("# " + long)
        XCTAssertLessThanOrEqual(title.count, LocalTitleExtractor.chineseMaximumLength)
    }

    func testCapsLatinTitlesAtEightyCharactersOnAWordBoundary() {
        let sentence = Array(repeating: "concurrency", count: 20).joined(separator: " ")
        let title = LocalTitleExtractor.finalize(sentence)
        XCTAssertLessThanOrEqual(title.count, LocalTitleExtractor.latinMaximumLength)
        XCTAssertFalse(title.hasSuffix("concurren"), "must not split a word")
        XCTAssertFalse(title.hasSuffix(" "))
    }

    func testTitleNeverContainsNewlines() {
        let title = LocalTitleExtractor.finalize("# 第一行\n第二行")
        XCTAssertFalse(title.contains("\n"))
    }

    func testUntitledFallbackForEmptyInput() {
        XCTAssertEqual(LocalTitleExtractor.title(for: "   \n  "), LocalTitleExtractor.fallbackTitle)
    }
}

// MARK: - Summaries

final class LocalSummaryTests: XCTestCase {
    private let article = """
    SwiftUI 的视图更新依赖状态驱动，因此理解 @State 的生命周期非常关键。
    在真实项目里，最常见的问题是子视图持有了本该由父视图管理的状态。
    Vision 框架提供了 VNRecognizeTextRequest 用于本地图片文字识别。
    使用 accurate 识别级别并开启语言纠正，可以得到比较稳定的中文识别结果。
    最后，记得把识别结果合并换行，避免每一行都变成独立段落。
    """

    func testSummaryIsExtractiveAndNeverInventsText() {
        let summary = LocalSummarizer().summarize(article, title: "SwiftUI 与 Vision")
        XCTAssertFalse(summary.isEmpty)

        let sentences = LocalTextAnalyzer.sentences(in: article)
        // Every produced sentence must exist verbatim in the source.
        for fragment in summary.components(separatedBy: "。").filter({ !$0.isEmpty }) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(sentences.contains { $0.contains(trimmed) },
                          "summary invented text: \(trimmed)")
        }
    }

    func testSummaryKeepsAtMostThreeSentencesInOriginalOrder() {
        let long = (1...12).map { "这是第\($0)句用于测试摘要长度的中文句子，里面包含一些关键词。" }.joined()
        let summary = LocalSummarizer().summarize(long, title: "测试")
        let sentences = LocalTextAnalyzer.sentences(in: long)
        let chosen = sentences.filter { summary.contains($0) }
        XCTAssertLessThanOrEqual(chosen.count, 3)
        XCTAssertGreaterThanOrEqual(chosen.count, 1)

        let positions = chosen.compactMap { sentences.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted(), "summary must preserve document order")
    }

    func testShortInputYieldsASingleSentenceSummary() {
        let summary = LocalSummarizer().summarize("只有一句话的笔记。")
        XCTAssertEqual(summary, "只有一句话的笔记。")
    }

    func testSummaryIgnoresCodeBlocks() {
        let text = """
        # 标题

        ```swift
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        ```

        真正需要总结的是这一段说明文字，它解释了为什么要在本地做识别。
        """
        let summary = LocalSummarizer().summarize(text, title: "标题")
        XCTAssertFalse(summary.contains("VNRecognizeTextRequest()"))
    }
}

// MARK: - Tags

final class LocalTagTests: XCTestCase {
    func testProducesBetweenTwoAndSixTags() {
        let tags = LocalTagExtractor().tags(in: "使用 SwiftUI 和 Vision 做 OCR，VNRecognizeTextRequest 负责识别，CoreML 负责推理。",
                                            title: "SwiftUI 图片文字识别")
        XCTAssertGreaterThanOrEqual(tags.count, 2)
        XCTAssertLessThanOrEqual(tags.count, 6)
    }

    func testKeepsTechnicalTermsIntact() {
        let tags = LocalTagExtractor().tags(in: "SwiftUI React MySQL Spring Boot Claude Code OpenAI CoreML iCloud Obsidian Docker Kubernetes 都是常见技术词。",
                                            title: "技术栈")
        XCTAssertTrue(tags.contains { $0.caseInsensitiveCompare("SwiftUI") == .orderedSame },
                      "expected SwiftUI among \(tags)")
        // The whole point: SwiftUI must never be reported as "Swift" or "UI".
        XCTAssertFalse(tags.contains { $0.caseInsensitiveCompare("UI") == .orderedSame })
    }

    func testFiltersStopwordsNumbersAndPunctuation() {
        let tags = LocalTagExtractor().tags(in: "的 了 和 是 12345 ，。！ the and for",
                                            title: "标题")
        XCTAssertFalse(tags.contains("的"))
        XCTAssertFalse(tags.contains("the"))
        XCTAssertFalse(tags.contains("12345"))
    }

    func testTagsAreUnique() {
        let tags = LocalTagExtractor().tags(in: "Swift Swift swift SwiftUI SwiftUI SwiftUI",
                                            title: "Swift")
        let normalized = tags.map { $0.lowercased() }
        XCTAssertEqual(normalized.count, Set(normalized).count)
    }
}

// MARK: - Classification

final class LocalClassificationTests: XCTestCase {
    private let profiles = [
        CategoryProfile(name: "iOS开发",
                        keywords: ["Swift", "SwiftUI", "Xcode", "Vision", "CoreML", "OCR",
                                   "VNRecognizeTextRequest", "图片文字识别"],
                        noteTitles: ["Xcode 快捷键", "CoreML 模型量化"]),
        CategoryProfile(name: "数据库",
                        keywords: ["MySQL", "PostgreSQL", "SQL", "索引", "事务"],
                        noteTitles: ["MySQL 慢查询", "PostgreSQL 索引原理"]),
        CategoryProfile(name: "AI",
                        keywords: ["LLM", "Transformer", "机器学习", "提示词"],
                        noteTitles: ["Transformer 笔记"]),
        CategoryProfile(name: "生活", keywords: ["做饭", "运动", "睡眠"], noteTitles: ["周末菜谱"]),
        CategoryProfile(name: "旅游", keywords: ["签证", "机票", "酒店", "行程"], noteTitles: ["日本行程"])
    ]

    private func classifier() -> LocalSemanticClassifier {
        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = UnavailableEmbeddingProvider()
        return classifier
    }

    func testClassifiesTechnicalNoteIntoTheMatchingCategory() {
        let result = classifier().classify(
            text: "如何使用 SwiftUI 调用 Vision 进行 OCR，把 VNRecognizeTextRequest 的结果保存下来。",
            categories: profiles)
        XCTAssertEqual(result.category, "iOS开发")
        XCTAssertGreaterThanOrEqual(result.score, LocalSemanticClassifier.Thresholds.default.candidate)
    }

    func testLeavesUnrelatedContentUnclassifiedInsteadOfGuessing() {
        let result = classifier().classify(
            text: "今天下午去公园散步，顺便买了一本小说，天气很好。",
            categories: profiles)
        // No category may be forced: an unclassified note belongs in Inbox.
        XCTAssertNil(result.category)
        XCTAssertEqual(result.score < LocalSemanticClassifier.Thresholds.default.candidate, true)
    }

    func testReturnsEmptyResultWhenThereAreNoCategories() {
        let result = classifier().classify(text: "任何内容", categories: [])
        XCTAssertNil(result.category)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testScoresAreRankedBestFirst() {
        let result = classifier().classify(
            text: "MySQL 的索引在事务里如何生效，以及 PostgreSQL 的查询优化。",
            categories: profiles)
        XCTAssertEqual(result.category, "数据库")
        XCTAssertEqual(result.candidates.first?.category, "数据库")
        let scores = result.candidates.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    /// The embedding only receives its 0.7 vote when it can actually separate candidates.
    func testEmbeddingIsGivenNoVoteWhenItCannotDiscriminate() {
        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = FixedVectorEmbeddingProvider([1, 0, 0, 0])
        let result = classifier.classify(text: "SwiftUI Vision OCR",
                                         categories: profiles)
        XCTAssertFalse(result.usedEmbedding)
    }

    func testEmbeddingDecidesWhenItIsDiscriminative() {
        // Two clear clusters on two axes. The note shares no vocabulary with either
        // category, so only a *working* embedding can classify it — which is the whole
        // point of spec §14.
        final class DirectionalEmbeddingProvider: EmbeddingProviding {
            func vector(for text: String, language: String) -> [Float]? {
                let lowered = text.lowercased()
                let graphics = ["swiftui", "vision", "ocr", "vr", "渲染", "识别"]
                let travel = ["签证", "机票", "酒店", "行程", "旅游"]
                if graphics.contains(where: { lowered.contains($0) }) { return [1, 0.2] }
                if travel.contains(where: { lowered.contains($0) }) { return [0.2, 1] }
                return [0.5, 0.5]
            }
            func dimension(for language: String) -> Int? { 2 }
        }

        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = DirectionalEmbeddingProvider()

        let categories = [
            CategoryProfile(name: "图形渲染", keywords: ["VR", "渲染"], noteTitles: []),
            CategoryProfile(name: "旅游", keywords: ["签证", "机票", "酒店", "行程"], noteTitles: [])
        ]
        let result = classifier.classify(text: "SwiftUI Vision OCR", categories: categories)

        XCTAssertTrue(result.usedEmbedding)
        XCTAssertEqual(result.category, "图形渲染")
        // Proof that no keyword overlap was involved.
        XCTAssertEqual(result.candidates.first { $0.category == "图形渲染" }?.keywordScore, 0)
    }

    /// Spec §16 defines three bands and is emphatic that the middle one must not be forced:
    /// 千万不要低置信度强行分类，宁可 Inbox 也不要错放.
    ///
    /// The denominator of a keyword score is the vocabulary of *all* profiles, so a note that
    /// mentions terms from two categories can never score 1.0 for either — which is exactly
    /// how an ambiguous note ends up below the assignment bar.
    func testThreeConfidenceBands() {
        let categories = [
            CategoryProfile(name: "Alpha组", keywords: ["Alpha", "Bravo"], noteTitles: []),
            CategoryProfile(name: "Charlie组", keywords: ["Charlie"], noteTitles: [])
        ]

        // Every relevant term belongs to one category → coverage 1.0 → assign.
        let strong = classifier().classify(text: "Alpha Bravo", categories: categories)
        XCTAssertEqual(strong.category, "Alpha组")
        XCTAssertNil(strong.suggestedCategory)
        XCTAssertGreaterThanOrEqual(strong.score, LocalSemanticClassifier.Thresholds.default.autoAssign)

        // Two of three, the third belonging elsewhere → 0.67 → plausible, never assigned.
        let moderate = classifier().classify(text: "Alpha Bravo Charlie", categories: categories)
        XCTAssertNil(moderate.category, "a moderate match must not be force-assigned")
        XCTAssertEqual(moderate.suggestedCategory, "Alpha组")
        XCTAssertEqual(moderate.score, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(moderate.score, LocalSemanticClassifier.Thresholds.default.candidate)
        XCTAssertLessThan(moderate.score, LocalSemanticClassifier.Thresholds.default.autoAssign)

        // Split evenly → 0.5 → below the candidate floor → nothing at all.
        let weak = classifier().classify(text: "Alpha Charlie", categories: categories)
        XCTAssertNil(weak.category)
        XCTAssertNil(weak.suggestedCategory)
        XCTAssertLessThan(weak.score, LocalSemanticClassifier.Thresholds.default.candidate)
    }

    /// A semantic-only match caps out at `semanticWeight` (0.7) and so can never reach the
    /// 0.72 bar; an unambiguous embedding winner therefore has its own route to assignment.
    /// This is where a stronger model (spec §24) earns its keep.
    func testUnambiguousSemanticWinnerIsAssignedWithoutLexicalSupport() {
        /// Points a note at one category's axis based on a marker word that appears in no
        /// profile vocabulary, so the lexical layer contributes exactly zero.
        final class KeyedVectorProvider: EmbeddingProviding {
            func vector(for text: String, language: String) -> [Float]? {
                if text.contains("zzz") || text.contains("无意义") { return [1, 0] }
                if text.contains("qqq") { return [0, 1] }
                return nil
            }
            func dimension(for language: String) -> Int? { 2 }
        }

        var classifier = LocalSemanticClassifier()
        classifier.embeddingProvider = KeyedVectorProvider()
        let categories = [
            CategoryProfile(name: "甲", keywords: ["zzz"], noteTitles: []),
            CategoryProfile(name: "乙", keywords: ["qqq"], noteTitles: [])
        ]
        let result = classifier.classify(text: "无意义的句子", categories: categories)

        XCTAssertTrue(result.usedEmbedding)
        XCTAssertEqual(result.candidates.first { $0.category == "甲" }?.keywordScore, 0)
        XCTAssertEqual(result.score, 0.7, accuracy: 0.001)
        XCTAssertLessThan(result.score, LocalSemanticClassifier.Thresholds.default.autoAssign)
        XCTAssertEqual(result.category, "甲", "an unambiguous semantic winner must still be usable")
    }

    func testNoAssignmentWithoutLexicalOrSemanticEvidence() {
        let categories = [
            CategoryProfile(name: "甲", keywords: ["zzz"], noteTitles: []),
            CategoryProfile(name: "乙", keywords: ["qqq"], noteTitles: [])
        ]
        let result = classifier().classify(text: "完全无关的词汇", categories: categories)
        XCTAssertNil(result.category)
        XCTAssertNil(result.suggestedCategory)
    }

    /// The thresholds are the knob a real-vault benchmark turns (spec §16), so verify they
    /// actually change the decision in both directions.
    func testThresholdsAreTunable() {
        // Evidence is split evenly between two categories: deliberately ambiguous.
        let ambiguous = "SwiftUI 与 MySQL 都有各自的生态"

        XCTAssertNil(classifier().classify(text: ambiguous, categories: profiles).category,
                     "the default thresholds must refuse an ambiguous note")

        var lenient = classifier()
        lenient.thresholds = .init(autoAssign: 0.4, candidate: 0.4, minimumSemanticMargin: 0.02)
        XCTAssertNotNil(lenient.classify(text: ambiguous, categories: profiles).category,
                        "lowering the floor must let the same evidence through")
    }
}

// MARK: - Local Lite end to end

final class LocalLiteProviderTests: XCTestCase {
    func testLocalLiteNeverRewritesTheBody() async throws {
        let original = """
        # Vision OCR 笔记

        使用 VNRecognizeTextRequest 识别图片文字。

        ```swift
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        ```

        参见 https://developer.apple.com/documentation/vision 的文档。
        """
        let provider = LocalLiteNoteProvider()
        let note = try await provider.generate(from: ClipboardContent(text: original)!,
                                              existingCategories: [],
                                              preferredLanguage: .automatic)

        XCTAssertTrue(note.content.contains("VNRecognizeTextRequest"))
        XCTAssertTrue(note.content.contains("recognitionLevel = .accurate"))
        XCTAssertTrue(note.content.contains("https://developer.apple.com/documentation/vision"))
        XCTAssertEqual(note.title, "Vision OCR 笔记")
    }

    /// Local Lite is not an LLM: it must never fail on odd input, and it must never invent
    /// content it cannot extract.
    func testLocalLiteHandlesContentWithoutProseGracefully() async throws {
        let provider = LocalLiteNoteProvider()
        let note = try await provider.generate(from: ClipboardContent(text: "12345 67890")!,
                                              existingCategories: [],
                                              preferredLanguage: .automatic)
        XCTAssertFalse(note.title.isEmpty)
        XCTAssertTrue(note.content.contains("12345"))
    }

    func testLocalLiteAssignsAnExistingCategoryAndFallsBackWhenUnsure() async throws {
        let provider = LocalLiteNoteProvider(profiles: [
            CategoryProfile(name: "iOS开发", keywords: ["SwiftUI", "Vision", "OCR"], noteTitles: []),
            CategoryProfile(name: "旅游", keywords: ["签证", "机票"], noteTitles: [])
        ], classifier: {
            var classifier = LocalSemanticClassifier()
            classifier.embeddingProvider = UnavailableEmbeddingProvider()
            return classifier
        }())

        let matching = try await provider.generate(
            from: ClipboardContent(text: "SwiftUI 里用 Vision 做 OCR 的完整步骤")!,
            existingCategories: ["iOS开发", "旅游"],
            preferredLanguage: .automatic)
        XCTAssertEqual(matching.category, "iOS开发")

        let unrelated = try await provider.generate(
            from: ClipboardContent(text: "今天下午去公园散步，天气很好。")!,
            existingCategories: ["iOS开发", "旅游"],
            preferredLanguage: .automatic)
        XCTAssertEqual(unrelated.category, "", "an unsure classification must stay empty for the Inbox fallback")
    }
}
