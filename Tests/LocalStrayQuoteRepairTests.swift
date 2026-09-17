import XCTest
@testable import ClipNest

/// The exact malformation the real model produces, and the boundary of the repair that fixes it.
///
/// Measured on `Qwen3-0.6B-4bit` with the short prompt: 3 of 20 raw answers came back as
/// `...,"tags":[...,"accurate"]"}` — perfect JSON apart from one stray quote. Without a repair
/// the capture lost its on-device model over a single character.
final class LocalStrayQuoteRepairTests: XCTestCase {
    /// Verbatim from the device/macOS run that exposed it.
    private let observed = """
    ```json
    {"title":"Vision OCR 图片文字识别","summary":"在 SwiftUI 中使用 VNRecognizeTextRequest 对图片进行本地文字识别。","category":"iOS开发","tags":["VNRecognizeTextRequest","zh-Hans","accurate"]"}
    ```
    """

    func testDecodesTheExactlyObservedMalformation() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(observed)
        XCTAssertEqual(fields.title, "Vision OCR 图片文字识别")
        XCTAssertEqual(fields.category, "iOS开发")
        XCTAssertEqual(fields.tags, ["VNRecognizeTextRequest", "zh-Hans", "accurate"])
    }

    func testRepairsTheSameSlipWithoutAFence() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"{"title":"T","summary":"s","category":"","tags":["a"]"}"#)
        XCTAssertEqual(fields.title, "T")
        XCTAssertEqual(fields.tags, ["a"])
    }

    func testRepairsAStrayQuoteBeforeAClosingBracket() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"{"title":"T","summary":"s","category":"","tags":["a""]}"#)
        XCTAssertEqual(fields.tags, ["a"])
    }

    func testRepairsAStrayQuoteBeforeTheBraceWithWhitespace() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            "{\"title\":\"T\",\"summary\":\"s\",\"category\":\"\",\"tags\":[\"a\"]\"\n}")
        XCTAssertEqual(fields.title, "T")
    }

    // MARK: - The repair must not touch well-formed answers

    func testAWellFormedAnswerIsUnchangedByTheRepair() {
        let clean = #"{"title":"T","summary":"s","category":"","tags":["a","b"]}"#
        XCTAssertEqual(LocalGeneratedNoteDecoder.repairingStrayQuotes(clean), clean)
    }

    func testAnEmptyStringValueIsNotMistaken() {
        let clean = #"{"title":"","summary":"s","category":"","tags":["a"]}"#
        XCTAssertEqual(LocalGeneratedNoteDecoder.repairingStrayQuotes(clean), clean)
    }

    func testAStringEndingInABraceIsNotMistaken() {
        // The closing quote here is *inside* a string, so it is not a stray.
        let clean = #"{"title":"用 } 结尾","summary":"s","category":"","tags":["a"]}"#
        XCTAssertEqual(LocalGeneratedNoteDecoder.repairingStrayQuotes(clean), clean)
    }

    func testEscapedQuotesSurvive() throws {
        let raw = #"{"title":"他说 \"好\"","summary":"s","category":"","tags":["a"]}"#
        let fields = try LocalGeneratedNoteDecoder.decode(raw)
        XCTAssertEqual(fields.title, "他说 \"好\"")
    }

    /// The repair is a fallback, not a first choice: an answer that already parses must reach
    /// the caller untouched.
    func testRepairOnlyHappensAfterEveryHonestReadingFails() {
        let clean = #"{"title":"T","summary":"s","category":"","tags":["a"]}"#
        let candidates = LocalGeneratedNoteDecoder.jsonCandidates(from: clean)
        XCTAssertEqual(candidates.first, clean,
                       "the untouched answer must be the first thing tried")
    }
}
