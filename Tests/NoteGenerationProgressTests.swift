import XCTest
@testable import ClipNest

/// A streaming engine driven at whatever pace the test chooses, so the progress contract can be
/// asserted without a GPU.
private struct StreamingScriptedEngine: LocalTextStreaming {
    nonisolated let engineName = "Streaming Scripted"
    var fullAnswer: String
    /// Characters delivered per callback.
    var chunkSize: Int = 8

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        try await generate(prompt: prompt, maximumTokens: maximumTokens) { _ in }
    }

    func generate(prompt: String,
                  maximumTokens: Int,
                  onDelta: @Sendable (String) -> Void) async throws -> String {
        var delivered = ""
        var index = fullAnswer.startIndex
        while index < fullAnswer.endIndex {
            let end = fullAnswer.index(index, offsetBy: chunkSize,
                                       limitedBy: fullAnswer.endIndex) ?? fullAnswer.endIndex
            delivered += fullAnswer[index..<end]
            onDelta(delivered)
            index = end
        }
        return fullAnswer
    }
}

/// An engine that reports nothing it cannot: no streaming support at all.
private struct NonStreamingEngine: LocalTextGenerating {
    nonisolated let engineName = "Non-streaming"
    var answer: String
    func generate(prompt: String, maximumTokens: Int) async throws -> String { answer }
}

/// A collector that is safe to call from the background context the provider uses.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NoteGenerationProgress] = []
    func append(_ progress: NoteGenerationProgress) { lock.lock(); entries.append(progress); lock.unlock() }
    var all: [NoteGenerationProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class NoteGenerationProgressTests: XCTestCase {
    private let source = "# 标题\n\n正文里提到 VNRecognizeTextRequest 和 iPhone 15 Pro。"

    private func content() -> ClipboardContent { ClipboardContent(text: source)! }

    private let answer = """
    {"title":"图片文字识别","summary":"用 Vision 识别图片文字。","category":"iOS开发","tags":["Vision","OCR"]}
    """

    private func collect(from engine: any LocalTextGenerating) async throws -> [NoteGenerationProgress] {
        let log = ProgressLog()
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        _ = try await provider.generate(from: content(),
                                        existingCategories: ["iOS开发"],
                                        preferredLanguage: .automatic,
                                        onProgress: { log.append($0) })
        return log.all
    }

    // MARK: - Streaming

    func testProgressArrivesManyTimesDuringOneGeneration() async throws {
        let log = try await collect(from: StreamingScriptedEngine(fullAnswer: answer, chunkSize: 6))
        let generating = log.filter { $0.preview != nil }
        XCTAssertGreaterThan(generating.count, 3,
                             "a streamed answer must produce more than a single update")
    }

    /// The title appears before the rest of the answer does — that is what makes the wait feel
    /// like progress rather than a stall.
    func testTheTitleBecomesVisibleWhileTheAnswerIsStillArriving() async throws {
        let log = try await collect(from: StreamingScriptedEngine(fullAnswer: answer, chunkSize: 4))
        let titles = log.compactMap { $0.preview?.title }
        XCTAssertFalse(titles.isEmpty)
        // Some early frame must already carry a title while the full answer does not yet exist.
        let partial = log.filter { progress in
            guard let preview = progress.preview else { return false }
            return preview.title != nil && preview.charactersGenerated < answer.count
        }
        XCTAssertFalse(partial.isEmpty, "the title must land before the answer finishes")
    }

    func testThePreviewOnlyEverGrows() async throws {
        let log = try await collect(from: StreamingScriptedEngine(fullAnswer: answer, chunkSize: 5))
        let counts = log.compactMap { $0.preview?.charactersGenerated }
        XCTAssertEqual(counts, counts.sorted(), "the preview must never shrink")
    }

    func testThePreviewNeverContradictsTheFinalNote() async throws {
        let log = try await collect(from: StreamingScriptedEngine(fullAnswer: answer, chunkSize: 3))
        let final = try LocalGeneratedNoteDecoder.decode(answer)
        for title in log.compactMap({ $0.preview?.title }) {
            XCTAssertTrue(final.title.hasPrefix(title),
                          "\(title) is not a prefix of the final title \(final.title)")
        }
    }

    // MARK: - Phases

    func testTheLoadIsReportedAsItsOwnPhase() async throws {
        // `RuntimeBackedLocalEngine` is the only engine that prepares, and it needs a runtime;
        // here the contract is asserted on a stand-in so the phase ordering is pinned.
        let log = try await collect(from: PreparingScriptedEngine(answer: answer))
        XCTAssertEqual(log.first, .preparingEngine(engineName: "Preparing Scripted"))
        XCTAssertTrue(log.contains(.finishing), "the capture must report that it is wrapping up")
    }

    func testAnEngineThatCannotStreamStillReportsOnceAndThenFinishes() async throws {
        let log = try await collect(from: NonStreamingEngine(answer: answer))
        XCTAssertEqual(log.count, 2, "one generating update, then finishing")
        XCTAssertEqual(log.first?.preview?.title, "图片文字识别")
        XCTAssertEqual(log.last, .finishing)
    }

    func testPassingNoCallbackIsAllowed() async throws {
        let provider = QwenLocalProvider(engine: StreamingScriptedEngine(fullAnswer: answer),
                                         profiles: [])
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic,
                                               onProgress: nil)
        XCTAssertEqual(note.title, "图片文字识别")
    }

    // MARK: - The plain protocol

    func testTheNonReportingEntryPointStillWorks() async throws {
        let provider = QwenLocalProvider(engine: StreamingScriptedEngine(fullAnswer: answer),
                                         profiles: [])
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "图片文字识别")
        XCTAssertFalse(note.content.isEmpty)
    }

    // MARK: - Coordinator surface

    @MainActor
    func testThePreviewAccessorIsNilOutsideTheGeneratingPhase() {
        XCTAssertNil(NoteGenerationProgress.preparingEngine(engineName: "x").preview)
        XCTAssertNil(NoteGenerationProgress.finishing.preview)
        XCTAssertEqual(NoteGenerationProgress.generating(preview: NotePreview(title: "t")).preview?.title,
                       "t")
    }

    @MainActor
    func testAnEmptyPreviewIsRecognisable() {
        XCTAssertTrue(NotePreview().isEmpty)
        XCTAssertFalse(NotePreview(title: "t").isEmpty)
        XCTAssertFalse(NotePreview(tags: ["a"]).isEmpty)
        XCTAssertFalse(NotePreview(summary: "s").isEmpty)
        // A character count alone is not content: there is nothing to display yet.
        XCTAssertTrue(NotePreview(charactersGenerated: 5).isEmpty)
    }
}

/// A stand-in that exercises the prepare phase without a runtime.
private struct PreparingScriptedEngine: LocalTextStreaming, LocalTextPreparing {
    nonisolated let engineName = "Preparing Scripted"
    var answer: String

    var isPrepared: Bool { get async { false } }
    func prepare() async {}

    func generate(prompt: String, maximumTokens: Int) async throws -> String { answer }

    func generate(prompt: String,
                  maximumTokens: Int,
                  onDelta: @Sendable (String) -> Void) async throws -> String {
        onDelta(answer)
        return answer
    }
}
