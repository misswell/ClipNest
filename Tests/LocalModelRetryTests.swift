import XCTest
@testable import ClipNest

/// An engine that answers differently on each call, so a retry can be observed.
private actor SequencedLocalEngine: LocalTextGenerating {
    nonisolated let engineName = "Sequenced Engine"
    private var answers: [String]
    private(set) var callCount = 0

    init(answers: [String]) { self.answers = answers }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        callCount += 1
        guard !answers.isEmpty else { return answers.last ?? "" }
        return answers.removeFirst()
    }

    var calls: Int { callCount }
}

/// An engine that fails outright, to prove a hard failure is not retried.
private actor AlwaysFailingEngine: LocalTextGenerating {
    nonisolated let engineName = "Always Failing"
    private(set) var callCount = 0
    var error: any Error = LocalAIError.generationFailed("boom")

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        callCount += 1
        throw error
    }

    var calls: Int { callCount }
}

/// Roughly one real generation in thirty comes back as prose instead of the requested object.
/// These tests pin what happens then.
final class LocalModelRetryTests: XCTestCase {
    private func content() -> ClipboardContent {
        ClipboardContent(text: "# 标题\n\n正文提到 VNRecognizeTextRequest。")!
    }

    private let good = #"{"title":"标题","summary":"摘要","category":"","tags":["a"]}"#

    func testAGoodAnswerIsNotRetried() async throws {
        let engine = SequencedLocalEngine(answers: [good])
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "标题")
        let calls = await engine.calls
        XCTAssertEqual(calls, 1, "a parseable answer must not cost a second generation")
    }

    func testAProseAnswerIsRetriedOnceAndSucceeds() async throws {
        let engine = SequencedLocalEngine(answers: ["I could not do that.", good])
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "标题")
        let calls = await engine.calls
        XCTAssertEqual(calls, 2)
    }

    func testAThinkBlockOnlyAnswerIsRetried() async throws {
        let engine = SequencedLocalEngine(answers: ["<think>\n\n</think>", good])
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "标题")
    }

    func testTwoBadAnswersGiveUpAfterExactlyOneRetry() async throws {
        let engine = SequencedLocalEngine(answers: ["nope", "still nope"])
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        do {
            _ = try await provider.generate(from: content(),
                                            existingCategories: [],
                                            preferredLanguage: .automatic)
            XCTFail("an unreadable answer must surface, so the router can degrade to Local Lite")
        } catch {
            // The router turns this into Local Lite rather than the network (§11).
            XCTAssertTrue(error is LocalAIError)
        }
        let calls = await engine.calls
        XCTAssertEqual(calls, 2, "exactly one retry, never more")
    }

    /// A generation that fails for a real reason must not be repeated — the second attempt
    /// would fail identically and only delay the fallback to Local Lite.
    func testAHardGenerationFailureIsNotRetried() async throws {
        let engine = AlwaysFailingEngine()
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        do {
            _ = try await provider.generate(from: content(),
                                            existingCategories: [],
                                            preferredLanguage: .automatic)
            XCTFail("expected the failure to surface")
        } catch {
            XCTAssertTrue(error is LocalAIError)
        }
        let calls = await engine.calls
        XCTAssertEqual(calls, 1, "a thrown generation error must not be retried")
    }

    /// The retry must not be visible as a stall in the banner: the user should see the second
    /// attempt starting, not a frozen first one.
    func testProgressIsStillReportedDuringARetry() async throws {
        let engine = SequencedLocalEngine(answers: ["nope", good])
        let provider = QwenLocalProvider(engine: engine, profiles: [])
        let log = RetryProgressLog()
        _ = try await provider.generate(from: content(),
                                        existingCategories: [],
                                        preferredLanguage: .automatic,
                                        onProgress: { log.append($0) })
        XCTAssertEqual(log.all.last, .finishing)
    }
}

private final class RetryProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NoteGenerationProgress] = []
    func append(_ progress: NoteGenerationProgress) {
        lock.lock(); entries.append(progress); lock.unlock()
    }
    var all: [NoteGenerationProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}
