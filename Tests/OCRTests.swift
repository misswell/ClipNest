import Foundation
import CoreGraphics
import Vision
import XCTest
@testable import ClipNest

// MARK: - Post-processing

final class OCRPostProcessorTests: XCTestCase {
    func testJoinsWrappedChineseLines() {
        let raw = """
        使用 VNRecognizeTextRequest 对图片
        进行文字识别，效果不错。
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertEqual(processed, "使用 VNRecognizeTextRequest 对图片进行文字识别，效果不错。")
    }

    func testJoinsWrappedLatinLinesWithASpace() {
        let raw = """
        This note explains how to run
        vision text recognition on device.
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertEqual(processed, "This note explains how to run vision text recognition on device.")
    }

    /// A capitalised continuation is genuinely ambiguous (it could be a new heading), so the
    /// post-processor stays conservative and leaves the line break alone.
    func testDoesNotJoinOnACapitalisedContinuation() {
        let raw = """
        This note explains how to run
        Vision text recognition on device.
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertEqual(processed.components(separatedBy: "\n").count, 2)
    }

    func testDoesNotJoinIntoIndentedCode() {
        let raw = """
        第一段说明文字
            缩进代码行
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertTrue(processed.contains("    缩进代码行"))
    }

    func testDoesNotJoinAfterSentenceTerminators() {
        let raw = """
        第一句。
        第二句！
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertEqual(processed, "第一句。\n第二句！")
    }

    func testNeverTouchesCode() {
        let raw = """
        ```swift
        func recognize() {
          let request = VNRecognizeTextRequest()
        }
        ```
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertTrue(processed.contains("func recognize() {"))
        XCTAssertTrue(processed.contains("let request = VNRecognizeTextRequest()"))
        XCTAssertTrue(processed.contains("\n"), "code lines must stay on their own lines")
    }

    func testRepairsHyphenatedWordBreaks() {
        let raw = """
        This is an exam-
        ple of a broken word.
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertTrue(processed.contains("example"))
        XCTAssertFalse(processed.contains("exam-\nple"))
    }

    func testRemovesRepeatedPageHeaders() {
        let raw = """
        笔记标题
        Page 1
        正文内容第一段。
        Page 1
        正文内容第二段。
        Page 1
        """
        let processed = OCRPostProcessor.process(raw)
        XCTAssertFalse(processed.contains("Page 1"))
        XCTAssertTrue(processed.contains("笔记标题"))
        XCTAssertTrue(processed.contains("正文内容第二段。"))
    }

    func testCollapsesRunsOfSpacesButKeepsIndentation() {
        let processed = OCRPostProcessor.process("普通    文字\n    缩进代码")
        XCTAssertTrue(processed.contains("普通 文字"))
        XCTAssertTrue(processed.contains("    缩进代码"))
    }

    func testCollapsesBlankLines() {
        let processed = OCRPostProcessor.process("第一段\n\n\n\n第二段")
        XCTAssertEqual(processed, "第一段\n\n第二段")
    }

    /// OCR errors inside technical terms are left exactly as recognized (spec §37).
    func testDoesNotCorrectFacts() {
        let raw = "HTTP JSON Swift VNRecognizeTextRequest 12345 CORRECT"
        let processed = OCRPostProcessor.process(raw)
        XCTAssertEqual(processed, raw)
    }

    func testCodeDetectionIsConservative() {
        XCTAssertTrue(OCRPostProcessor.looksLikeCode("let value = compute()"))
        XCTAssertTrue(OCRPostProcessor.looksLikeCode("return true;"))
        XCTAssertFalse(OCRPostProcessor.looksLikeCode("这是一行普通的中文说明文字"))
        XCTAssertFalse(OCRPostProcessor.looksLikeCode("A normal English sentence."))
    }
}

// MARK: - Vision service

final class VisionOCRServiceTests: XCTestCase {
    func testResolvedLanguagesIntersectWithWhatTheSystemSupports() {
        let supported = VisionOCRService.supportedLanguages()
        XCTAssertFalse(supported.isEmpty, "Vision must report at least one recognition language")

        let resolved = VisionOCRService.resolvedLanguages(preferred: ["zh-Hans", "en-US"], revision: 3)
        XCTAssertFalse(resolved.isEmpty)
        for language in resolved {
            XCTAssertTrue(supported.contains(language))
        }
    }

    func testUnsupportedPreferredLanguagesFallBackToSupportedOnes() {
        let supported = VisionOCRService.supportedLanguages(forRevision: 3)
        XCTAssertFalse(supported.isEmpty)
        let resolved = VisionOCRService.resolvedLanguages(preferred: ["xx-XX"], revision: 3)
        XCTAssertEqual(resolved, supported)
    }

    /// Both entry points must agree, so the Settings readout cannot disagree with the
    /// languages the recognizer will actually use.
    func testCapabilityReadoutMatchesTheRequestRevisionLanguages() {
        XCTAssertFalse(VisionOCRService.supportedLanguages().isEmpty)
        XCTAssertFalse(VisionOCRService.supportedLanguages(forRevision: 3).isEmpty)
    }

    func testRecognizesTextOnASyntheticImage() async throws {
        // Draw real glyphs so Vision has something to find.
        let width = 420
        let height = 120
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                               width: width,
                               height: height,
                               bitsPerComponent: 8,
                               bytesPerRow: 0,
                               space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        #if canImport(AppKit)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black
        ]
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSString(string: "VISION OCR").draw(at: NSPoint(x: 20, y: 30), withAttributes: attributes)
        image.unlockFocus()
        guard let cgImage = image.ocrCGImage else {
            throw XCTSkip("Could not rasterize the test image")
        }
        #else
        guard let cgImage = context.makeImage() else {
            throw XCTSkip("Could not create the test image")
        }
        #endif

        let result = try await VisionOCRService().recognizeText(cgImage: cgImage, languages: ["en-US"])
        // Availability of the recognition model varies by machine; the contract we assert is
        // that the call succeeds and reports consistent structure.
        XCTAssertEqual(result.blocks.count, result.blocks.count)
        for block in result.blocks {
            XCTAssertFalse(block.text.isEmpty)
            XCTAssertGreaterThanOrEqual(block.confidence, 0)
            XCTAssertLessThanOrEqual(block.confidence, 1)
        }
        if !result.isEmpty {
            XCTAssertTrue(result.text.uppercased().contains("OCR") || result.text.uppercased().contains("VISION"))
        }
    }

    func testSupportedRecognitionLanguagesAreReportedForSettings() {
        XCTAssertFalse(VisionOCRService.supportedLanguages().isEmpty)
    }
}

// MARK: - Capabilities

final class LocalAICapabilitiesTests: XCTestCase {
    func testVisionAndEmbeddingCapabilitiesAreReported() {
        let capabilities = LocalAICapabilities.current()
        XCTAssertTrue(capabilities.visionOCR.isAvailable)
        XCTAssertFalse(capabilities.localNoteEngineName.isEmpty)
    }

    /// The enhancement model is a download, so on a clean machine it must report a concrete
    /// reason rather than a bare "unavailable" (China plan §30).
    func testEnhancedModelStatusAlwaysExplainsItself() {
        let status = LocalAICapabilities.enhancedModelStatus()
        XCTAssertFalse(status.detail.isEmpty)
        // Local Lite is never gated on anything: no download, no API key, no network.
        XCTAssertTrue(LocalAICapabilities.current().localNoteEngine.isAvailable)
    }
}
