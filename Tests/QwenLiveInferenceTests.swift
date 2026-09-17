import Foundation
import XCTest
@testable import ClipNest

/// Live inference against the real `mlx-community/Qwen3-0.6B-4bit` weights.
///
/// The rest of the suite is hermetic: it drives `QwenLocalProvider` with a scripted engine so
/// it can assert on exact strings. This file is the opposite — it exercises the production
/// path end to end (installed manifest → `isInstalled()` → `LocalModelRuntime` load → real
/// MLX generation → `GeneratedNote`) and only asserts properties that must hold whatever the
/// model says.
///
/// It skips when the weights are not installed, so a checkout without them still runs green.
/// Populate them with the mirror fetch documented in `LOCAL_AI.md` §11.
final class QwenLiveInferenceTests: XCTestCase {
    private let store = LocalModelStore()

    /// A capture that looks like what Vision OCR hands over in practice.
    private let ocrText = """
    # Vision OCR 图片文字识别

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
    recognitionLevel 设置为 accurate，并打开 usesLanguageCorrection。
    中文需要把 recognitionLanguages 设置为 zh-Hans。
    实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别，全程不联网。
    """

    private var profiles: [CategoryProfile] {
        [CategoryProfile(name: "iOS开发", keywords: ["SwiftUI", "Vision", "Xcode"]),
         CategoryProfile(name: "数据库", keywords: ["MySQL", "索引", "SQL"]),
         CategoryProfile(name: "生活", keywords: ["旅行", "饮食"])]
    }

    /// Real MLX streaming, measured on the weights rather than on a scripted engine.
    ///
    /// The banner's whole value depends on the library actually producing intermediate frames
    /// during a real generation — something a scripted engine cannot prove. This pins both the
    /// frame count and the fact that a title becomes readable before the answer ends.
    func testTheRealModelStreamsEnoughFramesToShowProgress() async throws {
        try requireModel()
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let log = LiveProgressLog()
        let engine = try await MLXQwenEngine.load(modelDirectory: store.modelDirectory)
        let provider = QwenLocalProvider(engine: engine, profiles: profiles)

        let start = Date()
        let note = try await provider.generate(from: content,
                                               existingCategories: profiles.map(\.name),
                                               preferredLanguage: .simplifiedChinese,
                                               onProgress: { log.append($0) })
        let elapsed = Date().timeIntervalSince(start)

        let all = log.all
        let withPreview = all.compactMap { $0.preview }
        let titles = withPreview.compactMap(\.title).filter { !$0.isEmpty }
        print("""
        ===== LIVE STREAMING =====
        elapsed            : \(String(format: "%.2f", elapsed)) s
        callbacks          : \(all.count) (\(withPreview.count) with a preview)
        distinct titles    : \(Set(titles).count)
        final title        : \(note.title)
        ==========================
        """)

        XCTAssertGreaterThanOrEqual(withPreview.count, 2,
                                    "a real generation must yield more than one frame")
        XCTAssertFalse(titles.isEmpty, "a title must be readable before the end")
        // Every streamed title is a prefix of the final one: the preview never shows something
        // the finished note contradicts.
        for title in titles {
            XCTAssertTrue(note.title.hasPrefix(title),
                          "\(title) is not a prefix of \(note.title)")
        }
        XCTAssertEqual(all.last, .finishing)
    }

    private func requireModel() throws {
        try XCTSkipUnless(LocalModelRuntime.isRuntimeLinked,
                          "this build does not link the MLX runtime")
        try XCTSkipUnless(store.isInstalled(),
                          "Qwen3-0.6B-4bit is not installed at \(store.modelDirectory.path)")
    }

    /// The whole point: real weights in, a usable `GeneratedNote` out.
    func testRealModelProducesAUsableNote() async throws {
        try requireModel()
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let loadStart = Date()
        let engine = try await LocalModelRuntime.shared.engine(for: store.modelDirectory)
        let loadSeconds = Date().timeIntervalSince(loadStart)

        let provider = QwenLocalProvider(engine: engine, profiles: profiles)

        let generateStart = Date()
        let note = try await provider.generate(from: content,
                                               existingCategories: profiles.map(\.name),
                                               preferredLanguage: .simplifiedChinese)
        let generateSeconds = Date().timeIntervalSince(generateStart)

        // Reported rather than asserted: these are the numbers the report quotes.
        print("""
        ===== QWEN LIVE RESULT =====
        engineName      : \(engine.engineName)
        load (cold)     : \(String(format: "%.2f", loadSeconds)) s
        generate        : \(String(format: "%.2f", generateSeconds)) s
        title           : \(note.title)
        summary         : \(note.summary)
        category        : \(note.category.isEmpty ? "<none>" : note.category)
        tags            : \(note.tags.joined(separator: ", "))
        content         : \(note.content.prefix(400))
        ============================
        """)

        // Properties that must hold no matter what a 0.6B model decided to write.
        XCTAssertFalse(note.title.isEmpty, "a title is mandatory")
        XCTAssertFalse(note.summary.isEmpty, "a summary is mandatory")
        XCTAssertFalse(note.content.isEmpty, "a body is mandatory")
        XCTAssertGreaterThanOrEqual(note.tags.count, 1, "at least one tag is mandatory")
        XCTAssertEqual(note.sourceURL, content.sourceURL)

        // §20: the model may only choose an existing folder, never invent one.
        XCTAssertTrue(note.category.isEmpty || profiles.map(\.name).contains(note.category),
                      "the model returned a category outside the allowed list: \(note.category)")

        // §14/§22: the raw facts survive whatever the model rewrote.
        XCTAssertTrue(note.content.contains("VNRecognizeTextRequest"),
                      "the prompt requires code identifiers to be preserved")
    }

    /// The same call twice on a warm runtime must not pay the load cost again (§26).
    func testTheSecondCaptureReusesTheLoadedModel() async throws {
        try requireModel()
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))
        let provider = QwenLocalProvider(
            engine: try await LocalModelRuntime.shared.engine(for: store.modelDirectory),
            profiles: profiles)

        _ = try await provider.generate(from: content,
                                       existingCategories: profiles.map(\.name),
                                       preferredLanguage: .simplifiedChinese)

        let secondStart = Date()
        _ = try await provider.generate(from: content,
                                       existingCategories: profiles.map(\.name),
                                       preferredLanguage: .simplifiedChinese)
        let secondSeconds = Date().timeIntervalSince(secondStart)

        // Roughly a generation, not a generation plus a 350 MB load.
        XCTAssertLessThan(secondSeconds, 60, "a warm run should not include a cold model load")
    }

    /// §25: the same engine backs search query expansion, so it has to answer that prompt too.
    func testTheModelExpandsASearchQuery() async throws {
        try requireModel()
        let engine = try await LocalModelRuntime.shared.engine(for: store.modelDirectory)
        let expander = LocalQueryExpander(makeEngine: { engine },
                                          timeout: .seconds(60),
                                          cache: nil)

        let keywords = await expander.expand("图片文字识别")
        print("===== QWEN QUERY EXPANSION: \(keywords.joined(separator: ", ")) =====")

        // A 0.6B model may legitimately return nothing useful; what must never happen is a
        // crash, a hang past the timeout, or an unvalidated blob reaching FTS.
        for keyword in keywords {
            XCTAssertLessThanOrEqual(keyword.count, 24)
            XCTAssertLessThanOrEqual(keyword.split(separator: " ").count, 3)
            XCTAssertFalse(keyword.contains("："))
        }
    }

    /// A real model answering a real prompt is the only way to know whether the tolerant
    /// decoder (§22) is actually needed, and whether 768 tokens is enough room.
    func testTheModelAnswersWithParseableJSON() async throws {
        try requireModel()
        let engine = try await LocalModelRuntime.shared.engine(for: store.modelDirectory)
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let prompt = LocalPromptBuilder().prompt(for: content,
                                                 existingCategories: profiles.map(\.name),
                                                 preferredLanguage: .simplifiedChinese)
        // One retry, mirroring the provider. Measured on these weights: about 3% of raw
        // generations come back as prose instead of an object, so a test that demands a
        // parseable answer from a single stochastic sample is flaky by construction — and it
        // was, failing roughly one run in ten. The retry is what the shipped path does, so
        // asserting after a retry asserts the behaviour the app actually guarantees.
        var raw = try await engine.generate(prompt: prompt,
                                            maximumTokens: LocalPromptBuilder.maximumTokens)
        var fields = try? LocalGeneratedNoteDecoder.decode(raw)
        if fields == nil {
            raw = try await engine.generate(prompt: prompt,
                                            maximumTokens: LocalPromptBuilder.maximumTokens)
            fields = try? LocalGeneratedNoteDecoder.decode(raw)
        }

        print("""
        ===== QWEN RAW OUTPUT (\(raw.count) chars) =====
        \(raw)
        ===============================================
        """)

        XCTAssertFalse(raw.isEmpty, "the model returned nothing at all")

        // Whether or not the raw text is clean, the tolerant decoder must get fields out of
        // it — that is the §22 guarantee that a formatting slip cannot lose the note.
        let decoded = try XCTUnwrap(fields, "two consecutive generations were unparseable")
        XCTAssertFalse(decoded.title.isEmpty)
    }
}


/// Thread-safe collector for progress callbacks, which arrive off the main actor.
final class LiveProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NoteGenerationProgress] = []
    func append(_ progress: NoteGenerationProgress) {
        lock.lock(); entries.append(progress); lock.unlock()
    }
    var all: [NoteGenerationProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}
