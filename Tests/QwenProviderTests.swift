import XCTest
@testable import ClipNest

/// Records what the engine was actually asked to do, so the prompt and the token cap can be
/// asserted without any MLX involvement.
actor RecordingLocalEngine: LocalTextGenerating {
    nonisolated let engineName = "Recording Engine"
    private(set) var prompts: [String] = []
    private(set) var tokenCaps: [Int] = []
    private var response: String
    private var error: (any Error)?
    private(set) var loadCount = 0

    init(response: String = "{}", error: (any Error)? = nil) {
        self.response = response
        self.error = error
    }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        prompts.append(prompt)
        tokenCaps.append(maximumTokens)
        if let error { throw error }
        return response
    }
}

/// Counts loads so the runtime's caching behaviour is observable.
actor CountingEngineFactory {
    private(set) var loads = 0
    private let engine: any LocalTextGenerating

    init(engine: any LocalTextGenerating) { self.engine = engine }

    func make(directory: URL) async throws -> any LocalTextGenerating {
        loads += 1
        return engine
    }

    var loadCount: Int { loads }
}

// MARK: - Tolerant JSON reading (§22)

final class LocalGeneratedNoteDecoderTests: XCTestCase {
    func testReadsCleanJSON() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"{"title":"标题","summary":"摘要","content":"正文","category":"工作","tags":["a","b"]}"#)
        XCTAssertEqual(fields.title, "标题")
        XCTAssertEqual(fields.summary, "摘要")
        XCTAssertEqual(fields.content, "正文")
        XCTAssertEqual(fields.category, "工作")
        XCTAssertEqual(fields.tags, ["a", "b"])
    }

    func testReadsJSONWrappedInAMarkdownFence() throws {
        let fields = try LocalGeneratedNoteDecoder.decode("""
        ```json
        {"title":"Fenced","summary":"s","content":"c","category":"","tags":["x"]}
        ```
        """)
        XCTAssertEqual(fields.title, "Fenced")
        XCTAssertEqual(fields.tags, ["x"])
    }

    func testReadsJSONSurroundedByChatter() throws {
        let fields = try LocalGeneratedNoteDecoder.decode("""
        Sure! Here is the JSON you asked for:
        {"title":"Chatty","summary":"s","content":"c","category":"","tags":[]}
        Let me know if you want changes.
        """)
        XCTAssertEqual(fields.title, "Chatty")
    }

    /// Qwen3 emits a reasoning block by default; §21 asks for it off, and even when it leaks
    /// through it must not become part of the note.
    func testStripsAReasoningBlock() throws {
        let fields = try LocalGeneratedNoteDecoder.decode("""
         thinkingThe user wants a title. I should keep it short.<｜end▁of▁thinking｜>
        {"title":"Thinker","summary":"s","content":"c","category":"","tags":[]}
        """)
        XCTAssertEqual(fields.title, "Thinker")
    }

    /// The model hit the token cap mid-reasoning: there is no answer, so this must fail rather
    /// than produce a note built from chain-of-thought text.
    func testUnterminatedReasoningBlockYieldsNoNote() {
        let raw = "Thinking Process:\nThe user is asking about OCR. I should start by  thinking"
        XCTAssertThrowsError(try LocalGeneratedNoteDecoder.decode(raw))
    }

    func testABraceInsideAStringDoesNotEndTheObject() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"prefix {"title":"a}b{c","summary":"","content":"","category":"","tags":[]} suffix"#)
        XCTAssertEqual(fields.title, "a}b{c")
    }

    func testEscapedQuotesAreHandled() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"{"title":"say \"hi\"","summary":"","content":"","category":"","tags":[]}"#)
        XCTAssertEqual(fields.title, "say \"hi\"")
    }

    func testChineseKeysAreAccepted() throws {
        let fields = try LocalGeneratedNoteDecoder.decode(
            #"{"标题":"中文键","摘要":"摘要","正文":"正文","分类":"工作","标签":["a","b"]}"#)
        XCTAssertEqual(fields.title, "中文键")
        XCTAssertEqual(fields.content, "正文")
        XCTAssertEqual(fields.tags, ["a", "b"])
    }

    func testTagsFromACommaSeparatedString() {
        XCTAssertEqual(LocalGeneratedNoteDecoder.tags(from: "SwiftUI, Vision、OCR"), ["SwiftUI", "Vision", "OCR"])
        XCTAssertEqual(LocalGeneratedNoteDecoder.tags(from: "[\"SwiftUI\", \"Vision\"]"), ["SwiftUI", "Vision"])
    }

    func testTagsAreDeduplicatedCaseInsensitivelyAndCapped() {
        let tags = LocalGeneratedNoteDecoder.tags(from: ["a", "A", "b", "c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(tags, ["a", "b", "c", "d", "e", "f"])
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try LocalGeneratedNoteDecoder.decode("no json at all"))
        XCTAssertThrowsError(try LocalGeneratedNoteDecoder.decode("[1,2,3]"))
    }

    /// A body that is legitimately a code listing must not be mistaken for a wrapper fence.
    func testALegitimateCodeBlockBodyIsNotUnwrapped() {
        let body = """
        ```swift
        let x = 1
        ```
        """
        XCTAssertEqual(LocalGeneratedNoteDecoder.strippingOuterMarkdownFence(body), body)
    }

    func testAMarkdownWrapperFenceIsUnwrapped() {
        let body = """
        ```markdown
        ## 标题

        正文
        ```
        """
        XCTAssertEqual(LocalGeneratedNoteDecoder.strippingOuterMarkdownFence(body), "## 标题\n\n正文")
    }
}

// MARK: - Prompt (§20, §21)

final class LocalPromptBuilderTests: XCTestCase {
    private func prompt(categories: [String] = ["iOS开发", "数据库"],
                        language: PreferredLanguage = .automatic,
                        bodyStyle: LocalBodyStyle = .default) -> String {
        LocalPromptBuilder(bodyStyle: bodyStyle)
            .prompt(for: ClipboardContent(text: "使用 Vision 做 OCR 识别图片文字")!,
                    existingCategories: categories,
                    preferredLanguage: language)
    }

    func testThePromptIsShort() {
        // A 0.6B model degrades with long instructions, so the prompt must stay terse.
        XCTAssertLessThan(prompt().count, 700)
    }

    func testThePromptAsksForJSONAndNamesTheFields() {
        let text = prompt(bodyStyle: .modelRewrite)
        for field in ["title", "summary", "content", "category", "tags"] {
            XCTAssertTrue(text.contains(field), "the prompt must name \(field)")
        }
        XCTAssertTrue(text.contains("JSON"))
    }

    /// §21: reasoning tokens would triple latency on a phone for no benefit.
    ///
    /// The mechanism is deliberately *not* `/no_think`. That was the first attempt and it was
    /// measured not to work on the real weights — the model still emitted a ` thinking` block.
    /// Qwen3's chat template honours `enable_thinking`, which `MLXQwenEngine` passes through.
    func testThinkingIsDisabledThroughTheChatTemplateNotThePrompt() {
        XCTAssertEqual(LocalPromptBuilder.chatTemplateContext["enable_thinking"], false)
        XCTAssertFalse(prompt().contains("/no_think"),
                       "the in-prompt switch is ineffective on this model and must not come back")
    }

    func testThePromptCarriesTheClosedCategoryList() {
        let text = prompt(categories: ["iOS开发", "数据库"])
        XCTAssertTrue(text.contains("iOS开发"))
        XCTAssertTrue(text.contains("数据库"))
    }

    func testThePromptAsksForTheRequestedOutputLanguage() {
        XCTAssertTrue(prompt(language: .english).lowercased().contains("english"))
        XCTAssertTrue(prompt(language: .simplifiedChinese).contains("简体中文"))
    }

    func testThePromptForbidsInventionAndProtectsFacts() {
        // Both styles must forbid invention.
        XCTAssertTrue(prompt(bodyStyle: .sourceVerbatim).contains("禁止编造"))
        XCTAssertTrue(prompt(bodyStyle: .modelRewrite).contains("禁止编造"))
        // Protecting URLs and numbers is only meaningful when the model writes a body; the
        // fast path uses the user's own text and has nothing to protect.
        XCTAssertTrue(prompt(bodyStyle: .modelRewrite).contains("URL"))
    }

    /// The prompt is truncated, but the *saved note* still uses the whole source, so a long
    /// capture costs a little fidelity in the rewrite and nothing in the raw text.
    func testLongInputIsTrimmedOnALineBoundary() {
        let long = (1...300).map { "第\($0)行内容说明文字" }.joined(separator: "\n")
        let condensed = LocalPromptBuilder.condensed(long, limit: 200)
        XCTAssertLessThanOrEqual(condensed.count, 200)
        XCTAssertTrue(long.hasPrefix(condensed))
    }
}

// MARK: - Qwen provider (§15, §20, §22)

final class QwenProviderTests: XCTestCase {
    private let source = """
    # SwiftUI 调用 Vision 做 OCR

    在 SwiftUI 里使用 VNRecognizeTextRequest 识别图片文字，识别级别使用 accurate。
    记得打开 usesLanguageCorrection，中文用 zh-Hans。
    """

    private func content() -> ClipboardContent { ClipboardContent(text: source)! }

    /// Builds a provider for the body-handling tests, which are all about what happens to the
    /// *model's* body — so they pin `.modelRewrite` rather than following the shipping default.
    /// The default's own behaviour is covered by `LocalBodyStyleTests`.
    private func provider(_ response: String,
                          profiles: [CategoryProfile] = [],
                          bodyStyle: LocalBodyStyle = .modelRewrite) -> (QwenLocalProvider,
                                                                         RecordingLocalEngine) {
        let engine = RecordingLocalEngine(response: response)
        return (QwenLocalProvider(engine: engine,
                                  profiles: profiles,
                                  promptBuilder: LocalPromptBuilder(bodyStyle: bodyStyle)),
                engine)
    }

    func testProducesANoteFromAWellFormedAnswer() async throws {
        // The body is faithful, so every fact survives and the model's own text is kept.
        let (provider, _) = provider("""
        {"title":"Vision OCR 识别","summary":"用 Vision 做图片文字识别。","content":"## 要点\\n\\n- VNRecognizeTextRequest 识别图片文字，级别用 accurate\\n- 打开 usesLanguageCorrection，中文用 zh-Hans\\n- 在 SwiftUI 里调用 Vision","category":"","tags":["SwiftUI","OCR"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)

        XCTAssertEqual(note.title, "Vision OCR 识别")
        XCTAssertEqual(note.summary, "用 Vision 做图片文字识别。")
        XCTAssertEqual(note.tags, ["SwiftUI", "OCR"])
        // This body is faithfully reorganised, so the model's own text is kept.
        XCTAssertEqual(note.content, "## 要点\n\n- VNRecognizeTextRequest 识别图片文字，级别用 accurate\n- 打开 usesLanguageCorrection，中文用 zh-Hans\n- 在 SwiftUI 里调用 Vision")
    }

    /// The body must not be replaced when the model did a faithful job: reorganising is the
    /// whole point of the 350 MB download.
    func testAFaithfulBodyIsKeptVerbatim() async throws {
        let body = """
        ## 要点

        - 在 SwiftUI 里用 VNRecognizeTextRequest 识别图片文字
        - recognitionLevel 用 accurate，打开 usesLanguageCorrection
        - 中文设置 zh-Hans
        """
        let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
        let (provider, _) = provider("""
        {"title":"Vision OCR","summary":"s","content":"\(escaped)","category":"","tags":["OCR"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.content, body)
    }

    /// Measured on the real weights: the model sometimes returns well-formed JSON whose body
    /// has quietly dropped the facts — one sample lost `iPhone 15 Pro` and `0.4 秒`. That is
    /// data loss, not reorganisation, so the cleaned source is used instead (§20, §22).
    func testABodyThatDropsFactsFallsBackToTheSource() async throws {
        let (provider, _) = provider("""
        {"title":"Vision OCR","summary":"s","content":"在 SwiftUI 里识别图片文字。","category":"","tags":["OCR"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)

        XCTAssertNotEqual(note.content, "在 SwiftUI 里识别图片文字。")
        for fact in ["VNRecognizeTextRequest", "accurate", "usesLanguageCorrection", "zh-Hans"] {
            XCTAssertTrue(note.content.contains(fact),
                          "the fallback body must preserve \(fact); got \(note.content)")
        }
    }

    /// §22: an empty field is repaired from the source rather than discarding the whole answer.
    func testAMissingTitleIsTakenFromTheSource() async throws {
        let (provider, _) = provider(#"{"title":"","summary":"s","content":"c","category":"","tags":["a"]}"#)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertTrue(note.title.contains("Vision"), "got \(note.title)")
    }

    func testAMissingBodyFallsBackToTheCleanedSourceText() async throws {
        let (provider, _) = provider(#"{"title":"T","summary":"s","content":"","category":"","tags":["a"]}"#)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertTrue(note.content.contains("VNRecognizeTextRequest"))
    }

    func testAMissingSummaryIsGeneratedLocally() async throws {
        let (provider, _) = provider(#"{"title":"T","summary":"","content":"c","category":"","tags":["a"]}"#)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertFalse(note.summary.isEmpty)
    }

    func testAMissingTagListIsExtractedLocally() async throws {
        let (provider, _) = provider(#"{"title":"T","summary":"s","content":"c","category":"","tags":[]}"#)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertGreaterThanOrEqual(note.tags.count, 2)
    }

    /// §20: the model may only *choose* from the given categories. A folder name it invented
    /// must never reach the vault.
    func testAnInventedCategoryIsDiscarded() async throws {
        let (provider, _) = provider("""
        {"title":"T","summary":"s","content":"c","category":"完全编造的目录","tags":["a"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: ["iOS开发", "数据库"],
                                               preferredLanguage: .automatic)
        XCTAssertNotEqual(note.category, "完全编造的目录")
        XCTAssertTrue(note.category.isEmpty || ["iOS开发", "数据库"].contains(note.category))
    }

    func testAChosenCategoryIsUsedWhenItMatchesTheList() async throws {
        let (provider, _) = provider("""
        {"title":"T","summary":"s","content":"c","category":"iOS开发","tags":["a"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: ["iOS开发", "数据库"],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.category, "iOS开发")
    }

    func testACategoryMatchIsCaseInsensitive() async throws {
        let (provider, _) = provider("""
        {"title":"T","summary":"s","content":"c","category":"ios开发","tags":["a"]}
        """)
        let note = try await provider.generate(from: content(),
                                               existingCategories: ["iOS开发"],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.category, "iOS开发", "the canonical folder name must be kept")
    }

    /// A model that echoes its own JSON into `content` has produced no body at all.
    func testABodyThatIsJustTheEchoedJSONIsReplacedByTheSource() async throws {
        let echoed = #"{"title":"T","summary":"s","content":"{\"title\":\"T\"}","category":"","tags":["a"]}"#
        let (provider, _) = provider(echoed)
        let note = try await provider.generate(from: content(),
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertTrue(note.content.contains("VNRecognizeTextRequest"))
    }

    func testTheSourceURLIsPreserved() async throws {
        let withURL = ClipboardContent(text: "看看 https://example.com/a 这篇文章")!
        let (provider, _) = provider(#"{"title":"T","summary":"s","content":"c","category":"","tags":["a"]}"#)
        let note = try await provider.generate(from: withURL,
                                               existingCategories: [],
                                               preferredLanguage: .automatic)
        XCTAssertEqual(note.sourceURL, withURL.sourceURL)
    }

    /// A blank capture can never reach the model because it can never be constructed: the
    /// content type normalises and rejects empty text at the boundary. The provider keeps its
    /// own `emptyInput` guard as defence in depth, but this is the guarantee that matters.
    func testBlankInputCanNeverBeConstructed() {
        XCTAssertNil(ClipboardContent(text: "   "))
        XCTAssertNil(ClipboardContent(text: "\n\n\t"))
        XCTAssertNil(ClipboardContent(text: "\r\n"))
        XCTAssertNotNil(ClipboardContent(text: " a "))
    }

    /// Whitespace-only framing is trimmed before the model is asked anything.
    func testWhitespaceIsTrimmedBeforeGeneration() async throws {
        let (provider, engine) = provider(#"{"title":"T","summary":"s","content":"c","category":"","tags":["a"]}"#)
        _ = try await provider.generate(from: ClipboardContent(text: "\n\n  正文内容  \n\n")!,
                                        existingCategories: [],
                                        preferredLanguage: .automatic)
        let recorded = await engine.prompts
        let prompt = try XCTUnwrap(recorded.first)
        XCTAssertTrue(prompt.contains("正文内容"))
    }

    func testTheEngineIsGivenTheTokenCapAndAShortPrompt() async throws {
        let (provider, engine) = provider(#"{"title":"T","summary":"s","content":"c","category":"","tags":["a"]}"#)
        _ = try await provider.generate(from: content(),
                                        existingCategories: [],
                                        preferredLanguage: .automatic)

        let cap = await engine.tokenCaps.first
        let recorded = await engine.prompts
        XCTAssertEqual(cap, LocalPromptBuilder.maximumTokens)
        let prompt = try XCTUnwrap(recorded.first)
        XCTAssertTrue(prompt.contains("VNRecognizeTextRequest"), "the source must reach the model")
        XCTAssertLessThan(prompt.count, 1000)
    }

    /// §22: an unreadable answer is a generation failure, never a lost capture.
    func testUnreadableOutputBecomesAGenerationFailure() async {
        let (provider, _) = provider("I could not do that.")
        do {
            _ = try await provider.generate(from: content(),
                                            existingCategories: [],
                                            preferredLanguage: .automatic)
            XCTFail("unparseable output must not look like success")
        } catch let error as LocalAIError {
            guard case .generationFailed = error else {
                return XCTFail("expected .generationFailed, got \(error)")
            }
        } catch {
            XCTFail("expected a LocalAIError, got \(error)")
        }
    }

    func testAThrownEngineErrorIsSurfacedAsALocalFailure() async {
        struct Cuda: LocalizedError { var errorDescription: String? { "out of memory" } }
        let engine = RecordingLocalEngine(error: Cuda())
        let provider = QwenLocalProvider(engine: engine)
        do {
            _ = try await provider.generate(from: content(),
                                            existingCategories: [],
                                            preferredLanguage: .automatic)
            XCTFail("expected the engine error to surface")
        } catch let error as LocalAIError {
            guard case .generationFailed = error else {
                return XCTFail("expected .generationFailed, got \(error)")
            }
        } catch {
            XCTFail("expected a LocalAIError, got \(error)")
        }
    }

    func testCancellationPropagatesRatherThanDegrading() async {
        let engine = RecordingLocalEngine(error: CancellationError())
        let provider = QwenLocalProvider(engine: engine)
        do {
            _ = try await provider.generate(from: content(),
                                            existingCategories: [],
                                            preferredLanguage: .automatic)
            XCTFail("cancellation must not be swallowed")
        } catch is CancellationError {
            // Expected: a user who cancelled must not get a Local Lite note instead.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}

// MARK: - Fallback through the router (§11, §22, §33)

final class LocalModelFallbackTests: XCTestCase {
    private let source = "# Vision OCR\n\n使用 VNRecognizeTextRequest 识别图片文字。"

    /// The whole point of the seam: a broken model is a *local* problem and the user still
    /// gets a saved note.
    func testABrokenModelStillProducesANoteViaLocalLite() async throws {
        let counter = ProviderCallCounter()
        let broken = QwenLocalProvider(engine: RecordingLocalEngine(response: "not json"))
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: broken,
            localLiteProviderFactory: { profiles in LocalLiteNoteProvider(profiles: profiles) },
            onlineProviderFactory: { _ in
                counter.increment()
                return LabelledProvider(label: "online")
            }
        )

        let note = try await router.generate(from: ClipboardContent(text: source)!,
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertFalse(note.title.isEmpty)
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertGreaterThanOrEqual(note.tags.count, 1)
        XCTAssertEqual(counter.value, 0, "local mode must not reach the network on a model failure")
    }

    /// A healthy model is used, and the result still travels the one `GeneratedNote` path.
    func testAWorkingModelIsPreferredOverLocalLite() async throws {
        let working = QwenLocalProvider(engine: RecordingLocalEngine(response: """
        {"title":"来自本地模型","summary":"s","content":"c","category":"","tags":["a","b"]}
        """))
        var liteCalls = 0
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: AIConfiguration.default,
            localModelProvider: working,
            localLiteProviderFactory: { _ in
                liteCalls += 1
                return LabelledProvider(label: "lite")
            },
            onlineProviderFactory: { _ in LabelledProvider(label: "online") }
        )

        let note = try await router.generate(from: ClipboardContent(text: source)!,
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "来自本地模型")
        XCTAssertEqual(liteCalls, 0, "Local Lite must not run when the model succeeded")
    }
}

// MARK: - Runtime lifecycle (§26)

final class LocalModelRuntimeTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Runtime-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTheModelIsLoadedOnFirstUseOnly() async throws {
        let engine = RecordingLocalEngine()
        let factory = CountingEngineFactory(engine: engine)
        let runtime = LocalModelRuntime(engineFactory: { try await factory.make(directory: $0) })
        let url = try directory("reuse")

        _ = try await runtime.engine(for: url)
        _ = try await runtime.engine(for: url)
        _ = try await runtime.engine(for: url)

        let loads = await factory.loadCount
        XCTAssertEqual(loads, 1, "the weights must not be reloaded for every capture")
    }

    func testUnloadReleasesTheModelAndTheNextUseReloads() async throws {
        let engine = RecordingLocalEngine()
        let factory = CountingEngineFactory(engine: engine)
        let runtime = LocalModelRuntime(engineFactory: { try await factory.make(directory: $0) })
        let url = try directory("unload")

        _ = try await runtime.engine(for: url)
        await runtime.unload()
        let loadedAfterUnload = await runtime.isLoaded
        XCTAssertFalse(loadedAfterUnload)

        _ = try await runtime.engine(for: url)
        let loads = await factory.loadCount
        XCTAssertEqual(loads, 2)
    }

    /// §26: an idle model must not sit in memory across a long gap.
    func testAnIdleModelIsUnloaded() async throws {
        let engine = RecordingLocalEngine()
        let factory = CountingEngineFactory(engine: engine)
        let runtime = LocalModelRuntime(engineFactory: { try await factory.make(directory: $0) },
                                        idleTimeout: 60)
        let url = try directory("idle")

        _ = try await runtime.engine(for: url)
        await runtime.unloadIfIdle(now: Date().addingTimeInterval(61))
        let loaded = await runtime.isLoaded
        XCTAssertFalse(loaded)

        // Still warm well inside the window.
        _ = try await runtime.engine(for: url)
        await runtime.unloadIfIdle(now: Date())
        let stillLoaded = await runtime.isLoaded
        XCTAssertTrue(stillLoaded)
    }

    func testChangingTheModelDirectoryDropsTheOldWeights() async throws {
        let engine = RecordingLocalEngine()
        let factory = CountingEngineFactory(engine: engine)
        let runtime = LocalModelRuntime(engineFactory: { try await factory.make(directory: $0) })

        _ = try await runtime.engine(for: try directory("a"))
        _ = try await runtime.engine(for: try directory("b"))

        let loads = await factory.loadCount
        XCTAssertEqual(loads, 2, "a different model directory means a different model")
    }

    /// A build without the MLX runtime must refuse rather than pretend, and the refusal is an
    /// ordinary local failure — the router degrades to Local Lite.
    func testTheDefaultFactoryRefusesWhenTheRuntimeIsNotLinked() async throws {
        guard !LocalModelRuntime.isRuntimeLinked else {
            throw XCTSkip("this build links MLX, so the refusing path is unreachable")
        }
        let runtime = LocalModelRuntime()
        let url = try directory("nolink")
        do {
            _ = try await runtime.engine(for: url)
            XCTFail("expected a refusal")
        } catch let error as LocalAIError {
            XCTAssertTrue(error.isExpectedAbsence)
        }
    }

    /// The provider handed out by the runtime loads lazily: constructing it must be free.
    func testTheProviderLoadsLazily() async throws {
        let engine = RecordingLocalEngine(response: #"{"title":"T","summary":"s","content":"c","category":"","tags":["a"]}"#)
        let factory = CountingEngineFactory(engine: engine)
        let runtime = LocalModelRuntime(engineFactory: { try await factory.make(directory: $0) })
        let url = try directory("lazy")

        let provider = runtime.provider(modelDirectory: url, profiles: [])
        let loadsBeforeUse = await factory.loadCount
        XCTAssertEqual(loadsBeforeUse, 0, "building a provider must not load 350 MB")

        _ = try await provider.generate(from: ClipboardContent(text: "内容")!,
                                        existingCategories: [],
                                        preferredLanguage: .automatic)
        let loadsAfterUse = await factory.loadCount
        XCTAssertEqual(loadsAfterUse, 1)
    }
}

/// §20/§22: the guard that rejects a rewritten body which has dropped protected facts.
final class LocalFactPreservationTests: XCTestCase {
    private let source = """
    # Vision OCR 图片文字识别

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
    recognitionLevel 设置为 accurate，并打开 usesLanguageCorrection。
    中文需要把 recognitionLanguages 设置为 zh-Hans。
    实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别，全程不联网。
    """

    func testAFaithfulRewriteIsNotFlagged() {
        XCTAssertFalse(LocalFactPreservation.losesFacts(modelBody: source, source: source))
    }

    /// The exact failure observed on the real model: one sentence silently vanished.
    func testADroppedMeasurementIsFlagged() {
        let body = "在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别，设置 accurate 并打开 usesLanguageCorrection，中文用 zh-Hans。"
        XCTAssertTrue(LocalFactPreservation.losesFacts(modelBody: body, source: source),
                      "dropping the iPhone 15 Pro / 0.4 秒 measurement is data loss")
    }

    func testADroppedCodeIdentifierIsFlagged() {
        let body = "在 SwiftUI 里做本地文字识别，设置识别级别并打开语言纠正，中文用 zh-Hans。"
        XCTAssertTrue(LocalFactPreservation.losesFacts(modelBody: body, source: source))
    }

    func testRewordingThatKeepsTheFactsIsAllowed() {
        let body = """
        ## 要点

        - 用 SwiftUI 的 VNRecognizeTextRequest 做本地图片文字识别
        - recognitionLevel = accurate，usesLanguageCorrection = 打开
        - recognitionLanguages 设为 zh-Hans
        - 在 iPhone 15 Pro 上一张 A4 文档约 0.4 秒，全程不联网
        """
        XCTAssertFalse(LocalFactPreservation.losesFacts(modelBody: body,
                                                        title: "Vision OCR 图片文字识别",
                                                        source: source))
    }

    /// A short source has no meaningful ratio, so the fact check alone decides. Dropping
    /// `SwiftUI` is a loss even though the text is short.
    func testAShortSourceIsStillCheckedForFacts() {
        let short = "用 SwiftUI 调用 Vision。"
        XCTAssertTrue(LocalFactPreservation.losesFacts(modelBody: "Vision 调用示例。", source: short))
        XCTAssertFalse(LocalFactPreservation.losesFacts(modelBody: "Vision 调用示例。",
                                                        title: "SwiftUI",
                                                        source: short))
    }

    func testURLsAreProtected() {
        let withURL = "参考 https://example.com/docs/v2 的说明。"
        XCTAssertTrue(LocalFactPreservation.losesFacts(modelBody: "参考官方文档的说明。", source: withURL))
    }

    func testMissingTokensNamesWhatWasLost() {
        let body = "在 SwiftUI 里识别文字。"
        let missing = LocalFactPreservation.missingProtectedTokens(in: source, body: body)
        XCTAssertTrue(missing.contains("VNRecognizeTextRequest"), "got \(missing)")
        XCTAssertTrue(missing.contains("zh-Hans"), "got \(missing)")
        XCTAssertTrue(missing.contains("0.4"), "got \(missing)")
        XCTAssertFalse(missing.contains("SwiftUI"), "SwiftUI is present and must not be listed")
    }

    /// A hyphenated technical token must survive whole rather than degrade to its tail.
    func testHyphenatedTokensAreMatchedWhole() {
        let tokens = LocalFactPreservation.protectedTokens(in: "中文用 zh-Hans。")
        XCTAssertTrue(tokens.contains("zh-Hans"), "got \(tokens)")
    }

    func testEmptyInputIsNeverFlagged() {
        XCTAssertFalse(LocalFactPreservation.losesFacts(modelBody: "", source: source))
        XCTAssertFalse(LocalFactPreservation.losesFacts(modelBody: "x", source: ""))
    }
}

/// Regression tests for two defects found by running the real model.
final class LocalTaggingRegressionTests: XCTestCase {
    private let text = """
    # Vision OCR 图片文字识别

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
    中文需要把 recognitionLanguages 设置为 zh-Hans。
    """

    /// Tags are user-visible, so they must be real words. `tokens(in:)` decomposes the CJK run
    /// `图片文字识别` into overlapping bi-grams for search recall, which put the fragment `片文`
    /// into a tag list.
    func testTagsNeverContainCrossingCJKBigrams() {
        let tags = LocalTagExtractor().tags(in: text, title: "Vision OCR 图片文字识别")
        for fragment in ["片文", "字识", "对图", "片做", "地文"] {
            XCTAssertFalse(tags.contains(fragment), "\(fragment) is a fragment, not a word; got \(tags)")
        }
        for word in ["图片", "文字", "识别"] {
            XCTAssertTrue(tags.contains(word), "expected the real word \(word) in \(tags)")
        }
    }

    /// `normalizedKey` trims trailing punctuation, so `C++`, `C#` and `C` all key to `c`.
    /// Plain set deduplication dropped the specific spelling in favour of a bare `C`.
    func testTechnicalPunctuationSurvivesDeduplication() {
        XCTAssertTrue(LocalTextAnalyzer.wordTokens(in: "使用 C++ 和 SwiftUI").contains("C++"))
        XCTAssertTrue(LocalTextAnalyzer.wordTokens(in: "使用 C# 和 .NET").contains("C#"))
        XCTAssertTrue(LocalTextAnalyzer.tokens(in: "使用 C++ 和 SwiftUI").contains("C++"))
    }

    /// The script-run union exists because the system tokenizer drops tokens across a script
    /// boundary; removing the CJK bi-grams must not regress that.
    func testLatinTokensStillSpanScriptBoundaries() {
        XCTAssertTrue(LocalTextAnalyzer.wordTokens(in: "MySQL和Spring").contains("Spring"))
        XCTAssertTrue(LocalTextAnalyzer.wordTokens(in: "设置为 zh-Hans").contains("zh-Hans"))
    }
}
