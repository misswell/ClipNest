import XCTest
@testable import ClipNest

/// The shipping default: the model writes the title, summary, tags and category, and the body
/// is the user's own cleaned text.
///
/// This is the behaviour that replaces asking for a body the fact guard then threw away — five
/// times in six, measured on the device. The tests below pin both halves of that: the model is
/// no longer asked for a body, and a body it returns anyway is ignored rather than trusted.
final class LocalBodyStyleTests: XCTestCase {
    private let source = """
    # Vision OCR 图片文字识别

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
    实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别，全程不联网。
    """

    private func content() -> ClipboardContent { ClipboardContent(text: source)! }

    private func provider(_ response: String,
                          bodyStyle: LocalBodyStyle) -> (QwenLocalProvider,
                                                         RecordingLocalEngine) {
        let engine = RecordingLocalEngine(response: response)
        return (QwenLocalProvider(engine: engine,
                                  profiles: [],
                                  promptBuilder: LocalPromptBuilder(bodyStyle: bodyStyle)),
                engine)
    }

    // MARK: - The prompt

    func testTheDefaultAsksForFourFieldsAndRulesOutABody() {
        let prompt = LocalPromptBuilder().prompt(for: content(),
                                                 existingCategories: ["iOS开发"],
                                                 preferredLanguage: .automatic)
        for field in ["title", "summary", "category", "tags"] {
            XCTAssertTrue(prompt.contains(field), "the fast prompt must still ask for \(field)")
        }
        XCTAssertTrue(prompt.contains("不要输出 content 字段"),
                      "the prompt must say a body is not wanted, or the model writes one anyway")
    }

    func testTheDefaultPromptDoesNotAskForABodyRule() {
        let prompt = LocalPromptBuilder().prompt(for: content(),
                                                 existingCategories: [],
                                                 preferredLanguage: .automatic)
        XCTAssertFalse(prompt.contains("content：把原文完整整理成 Markdown"),
                       "the body-writing rule must be gone, not merely unused")
    }

    // MARK: - The token budget

    func testTheFastPathUsesASmallerTokenBudget() {
        XCTAssertEqual(LocalPromptBuilder(bodyStyle: .sourceVerbatim).maximumTokens,
                       LocalPromptBuilder.maximumShortAnswerTokens)
        XCTAssertEqual(LocalPromptBuilder(bodyStyle: .modelRewrite).maximumTokens,
                       LocalPromptBuilder.maximumTokens)
        XCTAssertLessThan(LocalPromptBuilder.maximumShortAnswerTokens,
                          LocalPromptBuilder.maximumTokens)
    }

    func testTheBudgetActuallyReachesTheEngine() async throws {
        let (provider, engine) = provider(#"{"title":"T","summary":"s","category":"","tags":["a"]}"#,
                                          bodyStyle: .sourceVerbatim)
        _ = try await provider.generate(from: content(),
                                        existingCategories: [],
                                        preferredLanguage: .automatic)
        let cap = await engine.tokenCaps.first
        XCTAssertEqual(cap, LocalPromptBuilder.maximumShortAnswerTokens)
    }

    // MARK: - The body

    func testTheBodyIsTheCleanedSourceNotTheModelsOwnText() async throws {
        // The model volunteers a body anyway. It must be ignored: trusting it would put the
        // capture back on the slow path it just left, and risk the fact loss the guard exists
        // to catch.
        let (provider, _) = provider(
            #"{"title":"T","summary":"s","content":"模型自己写的正文","category":"","tags":["a"]}"#,
            bodyStyle: .sourceVerbatim)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.content, MarkdownContentCleaner.clean(source))
        XCTAssertFalse(note.content.contains("模型自己写的正文"))
    }

    func testTheFastPathStillFillsEveryField() async throws {
        let (provider, _) = provider(
            #"{"title":"Vision OCR 图片文字识别","summary":"用 Vision 做本地图片文字识别。","category":"iOS开发","tags":["Vision","SwiftUI"]}"#,
            bodyStyle: .sourceVerbatim)
        let note = try await provider.generate(from: content(),
                                               existingCategories: ["iOS开发", "数据库"],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "Vision OCR 图片文字识别")
        XCTAssertEqual(note.summary, "用 Vision 做本地图片文字识别。")
        XCTAssertEqual(note.category, "iOS开发")
        XCTAssertEqual(note.tags, ["Vision", "SwiftUI"])
        XCTAssertEqual(note.content, MarkdownContentCleaner.clean(source))
    }

    /// The two styles must agree on everything except the body — that is the whole claim behind
    /// making the fast path the default.
    func testBothStylesProduceTheSameFieldsForTheSameAnswer() async throws {
        let answer = #"{"title":"标题","summary":"摘要","category":"iOS开发","tags":["Vision"]}"#
        let (fast, _) = provider(answer, bodyStyle: .sourceVerbatim)
        let (slow, _) = provider(answer, bodyStyle: .modelRewrite)

        let fastNote = try await fast.generate(from: content(),
                                               existingCategories: ["iOS开发"],
                                               preferredLanguage: .automatic)
        let slowNote = try await slow.generate(from: content(),
                                               existingCategories: ["iOS开发"],
                                               preferredLanguage: .automatic)

        XCTAssertEqual(fastNote.title, slowNote.title)
        XCTAssertEqual(fastNote.summary, slowNote.summary)
        XCTAssertEqual(fastNote.category, slowNote.category)
        XCTAssertEqual(fastNote.tags, slowNote.tags)
        XCTAssertEqual(fastNote.sourceURL, slowNote.sourceURL)
        // The body is the only difference, and the fast path's is the source.
        XCTAssertEqual(fastNote.content, MarkdownContentCleaner.clean(source))
    }

    /// A model that returns only the four fields must not be treated as a broken answer.
    func testAnAnswerWithNoBodyIsNotAFailure() async throws {
        let (provider, _) = provider(
            #"{"title":"T","summary":"s","category":"","tags":["a"]}"#,
            bodyStyle: .sourceVerbatim)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertEqual(note.content, MarkdownContentCleaner.clean(source))
    }
}

/// The compact-width toolbar collapses Edit and Preview into one button, so the icon has to name
/// the mode you get by tapping — not the mode you are in.
final class EditorModeToggleTests: XCTestCase {
    func testWhileReadingTheToggleOffersEditing() {
        XCTAssertEqual(EditorMode.toggleTarget(from: .preview), .edit)
    }

    func testWhileEditingTheToggleOffersReading() {
        XCTAssertEqual(EditorMode.toggleTarget(from: .edit), .preview)
    }

    /// The two glyphs must differ, or the button would look inert as it flips.
    func testTheTwoStatesUseDifferentGlyphs() {
        XCTAssertNotEqual(EditorMode.edit.systemImage, EditorMode.preview.systemImage)
    }

    /// `pencil`, not `square.and.pencil`: the latter's ink sits low and to the right, which made
    /// the button look off-centre next to the eye.
    func testTheEditGlyphIsTheOpticallyCentredOne() {
        XCTAssertEqual(EditorMode.edit.systemImage, "pencil")
    }

    /// Split only exists on wide layouts, where the toggle is not used; it must still resolve.
    func testSplitFallsBackToPreview() {
        XCTAssertEqual(EditorMode.toggleTarget(from: .split), .preview)
    }
}
