import XCTest
@testable import ClipNest

/// `LocalPartialJSON` runs on every streamed frame while the user watches, so it has to be
/// right on half-finished input — the state it is *designed* for and the state a normal JSON
/// parser rejects.
final class LocalPartialJSONTests: XCTestCase {
    // MARK: - Complete values

    func testReadsACompleteString() {
        let raw = #"{"title":"Vision OCR 图片文字识别","summary":"在 SwiftUI 里"}"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: raw), "Vision OCR 图片文字识别")
        XCTAssertEqual(LocalPartialJSON.string("summary", in: raw), "在 SwiftUI 里")
    }

    func testToleratesWhitespaceAroundTheColon() {
        let raw = #"{ "title" : "间隔" , "summary" : "ok" }"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: raw), "间隔")
    }

    /// The key case: the object is not closed and the value is still being written.
    func testReadsAValueThatIsStillStreaming() {
        let raw = #"{"title":"正在生成的标"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: raw), "正在生成的标")
    }

    func testReturnsNilBeforeTheKeyArrives() {
        XCTAssertNil(LocalPartialJSON.string("summary", in: #"{"title":"#))
        XCTAssertNil(LocalPartialJSON.string("title", in: ""))
    }

    /// A key seen but with no value yet must not render an empty preview box.
    func testReturnsNilWhenTheValueHasNotStarted() {
        XCTAssertNil(LocalPartialJSON.string("title", in: #"{"title":"#))
        XCTAssertNil(LocalPartialJSON.string("title", in: #"{"title":""#))
    }

    // MARK: - Key matching

    /// `"subtitle"` must not satisfy a lookup for `"title"`.
    func testDoesNotMatchALongerKeyThatEndsWithTheSameWord() {
        let raw = #"{"subtitle":"错误来源","title":"正确标题"}"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: raw), "正确标题")
    }

    func testIgnoresAKeyNameThatAppearsInsideAValue() {
        let raw = #"{"title":"讲 \"summary\" 这个词","summary":"真正的摘要"}"#
        XCTAssertEqual(LocalPartialJSON.string("summary", in: raw), "真正的摘要")
    }

    // MARK: - Escapes

    func testDecodesEscapes() {
        let raw = #"{"title":"第一行\n第二行\t制表 \\ 反斜杠 \" 引号"}"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: raw),
                       "第一行\n第二行\t制表 \\ 反斜杠 \" 引号")
    }

    /// A `\u` whose digits have not all arrived must not emit a broken character.
    func testHoldsBackAnIncompleteUnicodeEscape() {
        XCTAssertEqual(LocalPartialJSON.string("title", in: #"{"title":"前缀\u4e2"#), "前缀")
        XCTAssertEqual(LocalPartialJSON.string("title", in: #"{"title":"前缀\u4e2d"#), "前缀中")
    }

    func testDecodesASurrogatePairOnlyOnceItIsComplete() {
        // U+1F600, written as a JSON surrogate pair.
        let complete = #"{"title":"笑脸\uD83D\uDE00结束"}"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: complete), "笑脸😀结束")
        // High surrogate alone: emit what is safe, drop the incomplete emoji.
        let half = #"{"title":"笑脸\uD83D"#
        XCTAssertEqual(LocalPartialJSON.string("title", in: half), "笑脸")
    }

    func testDoesNotEmitALiteralBackslashAtTheEndOfTheStream() {
        XCTAssertEqual(LocalPartialJSON.string("title", in: #"{"title":"结尾\"#), "结尾")
    }

    // MARK: - Arrays

    func testReadsOnlyCompleteArrayElements() {
        let raw = #"{"tags":["OCR","Vision","图片"]}"#
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: raw), ["OCR", "Vision", "图片"])
    }

    /// A tag still being typed must not appear and then change.
    func testSkipsTheArrayElementThatIsStillArriving() {
        let raw = #"{"tags":["OCR","Vis"#
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: raw), ["OCR"])
    }

    func testReturnsNoTagsBeforeTheArrayOpens() {
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: #"{"title":"x","tags"#), [])
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: #"{"tags":"not-an-array"}"#), [])
    }

    func testHonoursTheTagLimit() {
        let raw = #"{"tags":["a","b","c","d","e","f","g"]}"#
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: raw, limit: 3), ["a", "b", "c"])
    }

    func testHandlesSpacesInsideTheArray() {
        let raw = #"{"tags": [ "OCR" , "Vision" ] }"#
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: raw), ["OCR", "Vision"])
    }

    // MARK: - Realistic stream

    /// Simulates the actual framing: the answer arrives a few characters at a time and the
    /// preview must never show something the final parse would contradict.
    func testReplayingAStreamNeverShowsAValueTheFinalParseRejects() {
        let answer = #"{"title":"数据库索引优化","summary":"MySQL 最左前缀原则。","category":"数据库","tags":["MySQL","索引"]}"#
        let final = try? LocalGeneratedNoteDecoder.decode(answer)
        let expectedTitle = final?.title

        var delivered = ""
        var seenTitles: [String] = []
        for character in answer {
            delivered.append(character)
            if let title = LocalPartialJSON.string("title", in: delivered) {
                seenTitles.append(title)
            }
        }

        XCTAssertEqual(seenTitles.last, expectedTitle)
        // The preview is always a prefix of the final value, so the text only ever grows.
        for seen in seenTitles {
            XCTAssertTrue(expectedTitle?.hasPrefix(seen) ?? false,
                          "\(seen) is not a prefix of \(expectedTitle ?? "nil")")
        }
        XCTAssertEqual(LocalPartialJSON.strings("tags", in: delivered), ["MySQL", "索引"])
    }
}
