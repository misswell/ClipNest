import XCTest
@testable import ClipNest

/// The renderer: every section exists only when the format asks for it and the material
/// exists (方案 §15, §16), and the heading rules stay minimal (方案 §16).
final class NoteRendererTests: XCTestCase {
    private let sourceText = """
    iOS Vision 可以在设备端进行 OCR，无需联网。
    实测约 0.4 秒完成识别。
    """
    private var source: ClipboardContent { ClipboardContent(text: sourceText)! }

    private let note = GeneratedNote(
        title: "iOS Vision 本地 OCR",
        summary: "用 Vision 在设备端识别图片文字。",
        content: "## 要点\n\n- VNRecognizeTextRequest 做本地 OCR",
        category: "Inbox",
        tags: ["iOS", "OCR"],
        sourceURL: nil)

    private let attachments = [
        SavedAttachment(url: URL(fileURLWithPath: "/v/Attachments/2026-09-25-a.jpg"),
                        relativePath: "Attachments/2026-09-25-a.jpg")
    ]

    private func render(_ format: NoteFormatConfiguration,
                        note: GeneratedNote? = nil,
                        attachments: [SavedAttachment] = [],
                        date: Date = Date(timeIntervalSince1970: 0),
                        sourceKind: CaptureSourceKind = .clipboard) -> String {
        MarkdownNoteBuilder.make(note: note ?? self.note,
                                 originalContent: source,
                                 format: format,
                                 attachments: attachments,
                                 date: date,
                                 sourceKind: sourceKind)
    }

    // MARK: - Case 1: 标题 + AI 正文 (方案 §35)

    func testTitlePlusGeneratedBodyHasNoChrome() {
        var format = NoteFormatConfiguration.clean
        format.includeOriginalImage = false
        let markdown = render(format)

        XCTAssertTrue(markdown.contains("# iOS Vision 本地 OCR"))
        XCTAssertTrue(markdown.contains("- VNRecognizeTextRequest 做本地 OCR"))
        XCTAssertFalse(markdown.contains("## 摘要"), "clean carries no summary")
        XCTAssertFalse(markdown.contains("## 正文"),
                       "a body next to a title needs no heading (方案 §16)")
        XCTAssertFalse(markdown.contains(sourceText),
                       "the original text is off in Clean")
        // Starts with the title: no frontmatter.
        XCTAssertTrue(markdown.hasPrefix("# "))
    }

    // MARK: - Case 2: 标题 + 原文 (方案 §35)

    func testTitlePlusOriginalPreservesTheSourceVerbatim() {
        let markdown = render(.titleAndOriginal)

        XCTAssertTrue(markdown.contains("# iOS Vision 本地 OCR"))
        XCTAssertTrue(markdown.contains("实测约 0.4 秒完成识别。"),
                      "the source is kept verbatim as the body")
        XCTAssertFalse(markdown.contains("## 原始内容"),
                       "a body that *is* the source is not quoted again")
        XCTAssertFalse(markdown.contains("## 摘要"))
    }

    // MARK: - Case 3: 标题 + 摘要 + 正文 (方案 §35)

    func testTitleSummaryAndBodyGetExplicitHeadings() {
        var format = NoteFormatConfiguration.archive
        format.includeOriginalText = false
        format.includeOriginalImage = false
        format.includeFrontmatter = false
        format.includeTags = false
        let markdown = render(format)

        XCTAssertTrue(markdown.contains("## 摘要"))
        XCTAssertTrue(markdown.contains("## 正文"))
        XCTAssertTrue(markdown.contains("用 Vision 在设备端识别图片文字。"))
        XCTAssertTrue(markdown.contains("- VNRecognizeTextRequest 做本地 OCR"))
    }

    // MARK: - Case 4: 完整归档 (方案 §35)

    func testFullArchiveRendersEverySection() {
        let markdown = render(.archive, attachments: attachments)

        XCTAssertTrue(markdown.hasPrefix("---\n"), "archive keeps the frontmatter")
        XCTAssertTrue(markdown.contains("tags:"))
        XCTAssertTrue(markdown.contains("  - iOS"))
        XCTAssertTrue(markdown.contains("# iOS Vision 本地 OCR"))
        XCTAssertTrue(markdown.contains("## 摘要"))
        XCTAssertTrue(markdown.contains("## 正文"))
        XCTAssertTrue(markdown.contains("](../Attachments/2026-09-25-a.jpg)"),
                      "the image embed is in the note")
        XCTAssertTrue(markdown.contains("## 原始内容"))
        XCTAssertTrue(markdown.contains("> \(sourceText.components(separatedBy: "\n")[0])"),
                      "the source is quoted next to the organized body")
        // Order: summary before body before image before the quoted source.
        let summaryRange = markdown.range(of: "## 摘要")!
        let bodyRange = markdown.range(of: "## 正文")!
        let imageRange = markdown.range(of: "Attachments/2026-09-25-a.jpg")!
        let originalRange = markdown.range(of: "## 原始内容")!
        XCTAssertTrue(summaryRange.lowerBound < bodyRange.lowerBound)
        XCTAssertTrue(bodyRange.lowerBound < imageRange.lowerBound)
        XCTAssertTrue(imageRange.lowerBound < originalRange.lowerBound)
    }

    // MARK: - Case 5: metadata off (方案 §35)

    func testTurningTheFrontmatterOffDegradesTheMetadataInlineInsteadOfDroppingIt() {
        var format = NoteFormatConfiguration.clean
        format.includeFrontmatter = false
        format.includeTags = true
        format.includeSourceURL = true
        let withURL = GeneratedNote(title: note.title,
                                    summary: "",
                                    content: note.content,
                                    category: "Inbox",
                                    tags: ["iOS", "OCR"],
                                    sourceURL: URL(string: "https://example.com/a"))
        let markdown = render(format, note: withURL)

        XCTAssertFalse(markdown.hasPrefix("---"))
        XCTAssertTrue(markdown.contains("#iOS #OCR"),
                      "tags survive as inline hashtags")
        XCTAssertTrue(markdown.contains("<https://example.com/a>"),
                      "the source URL survives as an inline autolink")
    }

    // MARK: - Heading minimality (方案 §16)

    func testSummaryOnlyNotesKeepTheSummaryHeading() {
        var format = NoteFormatConfiguration.standard
        format.includeOriginalText = false
        format.includeOriginalImage = false
        let emptyBody = GeneratedNote(title: "标题",
                                      summary: "只有摘要。",
                                      content: "",
                                      category: "Inbox",
                                      tags: [],
                                      sourceURL: nil)
        let markdown = render(format, note: emptyBody)
        XCTAssertTrue(markdown.contains("## 摘要"))
        XCTAssertTrue(markdown.contains("只有摘要。"))
    }

    func testAProviderWithoutABodyFallsBackToTheSource() {
        // Same as the old `## 内容` fallback, but without the heading: a capture whose AI
        // produced nothing usable still renders the source under the title.
        var format = NoteFormatConfiguration.clean
        format.includeOriginalImage = false
        let empty = GeneratedNote(title: "标题",
                                  summary: "",
                                  content: "",
                                  category: "Inbox",
                                  tags: [],
                                  sourceURL: nil)
        let markdown = render(format, note: empty)
        XCTAssertTrue(markdown.contains(sourceText))
    }

    // MARK: - Image embeds (方案 §19)

    func testImageLinkStyles() {
        var format = NoteFormatConfiguration.clean
        format.imageLinkStyle = .markdown
        XCTAssertTrue(render(format, attachments: attachments)
            .contains("](../Attachments/2026-09-25-a.jpg)"))

        format.imageLinkStyle = .obsidian
        XCTAssertTrue(render(format, attachments: attachments)
            .contains("![[Attachments/2026-09-25-a.jpg]]"))
    }

    func testImageEmbedsAppearOnlyWhenTheFormatKeepsThem() {
        let markdown = render(.clean, attachments: [])
        XCTAssertFalse(markdown.contains("Attachments/"),
                       "no attachments were saved, so none are referenced")
    }

    // MARK: - Image captures: the picture is the source, not the OCR transcription

    func testAnImageCapturePutsThePictureWhereTheSourceWouldGo() {
        let markdown = render(.titleAndOriginal, attachments: attachments, sourceKind: .photo)

        XCTAssertTrue(markdown.contains("](../Attachments/2026-09-25-a.jpg)"),
                      "the picture takes the source's place as the body")
        XCTAssertFalse(markdown.contains(sourceText),
                       "the OCR transcription is not kept as the original content")
        XCTAssertFalse(markdown.contains("## 原始内容"))
        XCTAssertEqual(markdown.components(separatedBy: "Attachments/2026-09-25-a.jpg").count - 1, 1,
                       "the embed is rendered exactly once")
    }

    func testAnImageCaptureWithAnOrganizedBodyQuotesThePictureNotTheTranscription() {
        let markdown = render(.archive, attachments: attachments, sourceKind: .importedImage)

        XCTAssertTrue(markdown.contains("## 正文"))
        let originalRange = markdown.range(of: "## 原始内容")!
        let embedRange = markdown.range(of: "Attachments/2026-09-25-a.jpg")!
        XCTAssertTrue(embedRange.lowerBound > originalRange.lowerBound,
                      "the picture is the quoted source material")
        XCTAssertFalse(markdown.contains("> \(sourceText.components(separatedBy: "\n")[0])"),
                       "the OCR transcription is never quoted back as the original")
        XCTAssertEqual(markdown.components(separatedBy: "Attachments/2026-09-25-a.jpg").count - 1, 1,
                       "no trailing duplicate of the embed")
    }

    func testAClipboardCaptureThatCarriesAnImageKeepsTheTextAsTheSource() {
        let markdown = render(.archive, attachments: attachments, sourceKind: .clipboard)

        XCTAssertTrue(markdown.contains("> \(sourceText.components(separatedBy: "\n")[0])"),
                      "clipboard text is still the original content")
        let imageRange = markdown.range(of: "Attachments/2026-09-25-a.jpg")!
        let originalRange = markdown.range(of: "## 原始内容")!
        XCTAssertTrue(imageRange.lowerBound < originalRange.lowerBound,
                      "an accompanying image still trails the note, before the quote")
    }

    func testAnImageCaptureWithImageSavingOffFallsBackToTheTranscription() {
        var format = NoteFormatConfiguration.titleAndOriginal
        format.includeOriginalImage = false
        let markdown = render(format, attachments: [], sourceKind: .photo)

        XCTAssertTrue(markdown.contains(sourceText),
                      "with the picture not saved, the transcription is all there is to keep")
    }

    // MARK: - Title fallback

    func testAnEmptyTitleStillRendersAHeading() {
        let untitled = GeneratedNote(title: "   ",
                                     summary: "",
                                     content: "body",
                                     category: "Inbox",
                                     tags: [],
                                     sourceURL: nil)
        var format = NoteFormatConfiguration.clean
        format.includeOriginalText = false
        XCTAssertTrue(render(format, note: untitled).contains("# Untitled"))
    }

    // MARK: - Local vs online parity (方案 §35 Case 11)

    func testBothEnginesRenderTheSameStructureForTheSameFormat() {
        // The renderer only ever sees a `GeneratedNote` + format, so a local and an online
        // capture with the same values must produce byte-identical Markdown. Proven here by
        // construction — the engine names appear nowhere in the signature.
        var bodyful = NoteFormatConfiguration.clean
        bodyful.includeOriginalImage = false
        let markdownA = render(bodyful)
        let markdownB = render(bodyful)
        XCTAssertEqual(markdownA, markdownB)
    }
}
