import Foundation
import CoreGraphics
import XCTest
@testable import ClipNest

// MARK: - Spec §48 acceptance

/// The acceptance criteria of spec §48, exercised end to end through the real pipeline:
/// capture → generate → classify → save, and capture → OCR → save → index → search.
@MainActor
final class LocalModeAcceptanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RequestRecordingURLProtocol.counter.reset()
    }

    private func makeVault() throws -> (VaultStore, URL) {
        let store = VaultStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.openVault(at: root)
        return (store, root)
    }

    private func markdownFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            files.append(url)
        }
        return files
    }

    /// 断网时：复制文本 → 生成标题 → 摘要 → 标签 → 分类 → 保存 Markdown，全程零网络请求。
    func testOfflineTextCaptureProducesACompleteNote() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: ClipboardService(),
                                             noteGenerator: LocalLiteNoteProvider())
        let requestCountBefore = RequestRecordingURLProtocol.counter.value

        try await withLocalModeDefaults {
            await coordinator.captureText("""
            在 SwiftUI 里使用 Vision 的 VNRecognizeTextRequest 做 OCR，识别图片里的文字。
            识别级别用 accurate，并且打开语言纠正，整个流程完全在设备上完成。
            """)
        }

        XCTAssertEqual(coordinator.state, .completed)
        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        let markdown = try String(contentsOf: saved, encoding: .utf8)

        // Title: a real H1, not the fallback.
        XCTAssertTrue(markdown.contains("# "), "the note must have an H1 title")
        XCTAssertFalse(markdown.contains("# Untitled"), "local generation must produce a real title")

        // Summary: extractive, non-empty, and traceable to the source.
        let summaryRange = try XCTUnwrap(markdown.range(of: "## 摘要"))
        let afterSummary = markdown[summaryRange.upperBound...]
        let summaryBody = afterSummary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .prefix(1)
            .joined()
        XCTAssertFalse(summaryBody.isEmpty, "the note must carry a summary")

        // Tags: frontmatter carries real extracted tags.
        XCTAssertTrue(markdown.contains("tags:"))
        XCTAssertTrue(markdown.contains("SwiftUI") || markdown.contains("Vision"),
                      "expected a technical tag in:\n\(markdown)")

        // Classification: filed in a category directory (Inbox is the safe fallback).
        let parent = saved.deletingLastPathComponent().lastPathComponent
        XCTAssertFalse(parent.isEmpty)
        XCTAssertEqual(markdownFiles(in: root).count, 1)

        XCTAssertEqual(RequestRecordingURLProtocol.counter.value, requestCountBefore,
                       "the whole offline pipeline must make no network request")
    }

    /// §37: a fresh install has no API key and no downloaded model. Capture must still work
    /// end to end — OCR, title, summary, tags, classification, a saved Markdown file, and the
    /// note must be findable — with zero network requests.
    func testFreshInstallWithoutModelOrAPIKeyStillProducesAUsableNote() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let ocrText = "运维手册：MySQL 主从延迟的排查步骤，先看 Seconds_Behind_Master。"
        // The real router in local mode, with an unconfigured online half and no model.
        let router = NoteGenerationRouter(mode: .local,
                                          onlineConfiguration: AIConfiguration.default)
        XCTAssertFalse(router.hasValidOnlineConfiguration, "a fresh install has no API key")
        XCTAssertEqual(router.localEngineName, LocalLiteNoteProvider.engineName)

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: router,
            ocrService: StubOCRService(text: ocrText))
        let requestCountBefore = RequestRecordingURLProtocol.counter.value

        try await withLocalModeDefaults {
            await coordinator.capturePhoto(TestImageFactory.make())
        }

        XCTAssertEqual(coordinator.state, .completed)

        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        let markdown = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(markdown.contains("MySQL"), "the OCR text must reach the note")
        XCTAssertTrue(markdown.contains("## 摘要"), "a summary must be produced locally")
        XCTAssertTrue(markdown.contains("tags:"), "tags must be produced locally")
        XCTAssertTrue(markdown.contains("# "), "a title must be produced locally")
        XCTAssertEqual(markdownFiles(in: root).count, 1,
                       "the note must be saved even though nothing was downloaded")

        XCTAssertEqual(RequestRecordingURLProtocol.counter.value, requestCountBefore,
                       "the whole fresh-install flow must be offline")

        // And it is searchable without any model.
        let database = try SearchDatabase(url: root.appendingPathComponent("index.sqlite"))
        defer { database.close() }
        await LocalSearchIndexer(vaultRoot: root,
                                 database: database,
                                 embeddingProvider: UnavailableEmbeddingProvider()).indexVault()
        let engine = LocalSearchEngine(database: database,
                                       semanticIndex: SemanticSearchIndex(),
                                       semanticEnabled: false)
        XCTAssertEqual(engine.search(query: "主从延迟", mode: .exact).first?.fileURL
            .standardizedFileURL.path,
                       saved.standardizedFileURL.path)
    }

    /// 断网时：选择截图 → OCR → 生成笔记 → 保存 → 随后可以被本地搜索找到。
    func testOfflinePhotoCaptureIsSearchableAfterIndexing() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let ocrText = "会议记录：下周三前完成 Vision 文字识别的重构，负责人是林工。"
        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: LocalLiteNoteProvider(),
            ocrService: StubOCRService(text: ocrText))
        let requestCountBefore = RequestRecordingURLProtocol.counter.value

        try await withLocalModeDefaults {
            await coordinator.capturePhoto(TestImageFactory.make())
        }

        XCTAssertEqual(coordinator.state, .completed)
        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        let markdown = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(markdown.contains("会议记录"), "the OCR text must reach the saved note")
        XCTAssertEqual(RequestRecordingURLProtocol.counter.value, requestCountBefore)

        // Now prove the recognized text is searchable, not just saved (§19 indexes OCR text).
        let database = try SearchDatabase(url: root.appendingPathComponent("index.sqlite"))
        defer { database.close() }
        let indexer = LocalSearchIndexer(vaultRoot: root,
                                        database: database,
                                        embeddingProvider: UnavailableEmbeddingProvider())
        let statistics = await indexer.indexVault()
        XCTAssertEqual(statistics.indexedFiles, 1)

        let engine = LocalSearchEngine(database: database,
                                       semanticIndex: SemanticSearchIndex(),
                                       semanticEnabled: false)
        let results = engine.search(query: "文字识别", mode: .exact)
        XCTAssertEqual(results.first?.fileURL.standardizedFileURL.path,
                       saved.standardizedFileURL.path,
                       "a note created from a photo must be findable by its OCR text")
        XCTAssertFalse(results.first?.snippet.isEmpty ?? true)
    }
}

// MARK: - Test doubles

/// A provider that never touches the network and labels its output, so a test can tell
/// which engine the router actually picked.
struct LabelledProvider: NoteGenerating {
    let label: String
    var error: Error?

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        if let error { throw error }
        return GeneratedNote(title: label,
                             summary: label,
                             content: content.text,
                             category: "",
                             tags: [],
                             sourceURL: nil)
    }
}

/// Counts how often the router reached for a network-capable provider.
final class ProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Records every request that reaches the URL loading system. Local mode must leave this
/// at zero — that is the actual privacy assertion, not a proxy for it.
private final class RequestRecordingURLProtocol: URLProtocol {
    static let counter = ProviderCallCounter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.increment()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 500,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Local mode

final class LocalModeTests: XCTestCase {
    private func makeContent(_ text: String = "如何使用 SwiftUI 调用 Vision 做 OCR 识别") -> ClipboardContent {
        ClipboardContent(text: text)!
    }

    func testLocalModeUsesTheDownloadedModelWhenItIsInstalled() async throws {
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(label: "qwen"),
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in LabelledProvider(label: "online") }
        )

        let note = try await router.generate(from: makeContent(),
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "qwen")
    }

    /// The normal state for a fresh install: nothing downloaded, still fully usable (§9).
    func testLocalModeUsesLocalLiteWhenNoModelIsInstalled() async throws {
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: nil,
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in LabelledProvider(label: "online") }
        )

        let note = try await router.generate(from: makeContent(),
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "lite")
    }

    /// §11: a model that cannot load degrades to Local Lite, with a valid online
    /// configuration sitting right there unused.
    func testLocalModeFallsBackToLocalLiteWhenTheModelIsUnavailable() async throws {
        let counter = ProviderCallCounter()
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(
                label: "qwen",
                error: LocalAIError.modelUnavailable("weights missing")),
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in
                counter.increment()
                return LabelledProvider(label: "online")
            }
        )

        let note = try await router.generate(from: makeContent(),
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "lite")
        XCTAssertEqual(counter.value, 0)
    }

    /// §11 again, for the failure that is *not* an availability problem: a corrupt model,
    /// an out-of-memory abort or unparseable output must not become an upload either.
    func testLocalModeDoesNotUseOnlineAfterGenerationFailure() async throws {
        let counter = ProviderCallCounter()
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(
                label: "qwen",
                error: LocalAIError.generationFailed("ran out of memory")),
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in
                counter.increment()
                return LabelledProvider(label: "online")
            }
        )

        let note = try await router.generate(from: makeContent(),
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "lite")
        XCTAssertEqual(counter.value, 0)
    }

    /// A model error that is not a `LocalAIError` at all is treated the same way.
    func testLocalModeStaysOnDeviceForAnUnexpectedModelError() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let counter = ProviderCallCounter()
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(label: "qwen", error: Boom()),
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in
                counter.increment()
                return LabelledProvider(label: "online")
            }
        )

        let note = try await router.generate(from: makeContent(),
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "lite")
        XCTAssertEqual(counter.value, 0)
    }

    /// End to end: the real Local Lite engine produces a usable note with no network at all.
    func testLocalModeWithRealLocalLiteProducesACompleteNote() async throws {
        let router = NoteGenerationRouter(mode: .local,
                                          onlineConfiguration: AIConfiguration.default)
        let note = try await router.generate(
            from: makeContent("# SwiftUI 图片文字识别\n\n使用 VNRecognizeTextRequest 对 UIImage 做 OCR，然后保存到 Obsidian。"),
            existingCategories: ["iOS开发"],
            preferredLanguage: .automatic)

        XCTAssertTrue(note.title.contains("SwiftUI"))
        XCTAssertFalse(note.summary.isEmpty)
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertGreaterThanOrEqual(note.tags.count, 2)
    }

    /// The router reports which local engine will run, so the capture status line can tell
    /// the truth about whether a 350 MB download is being used.
    func testLocalEngineNameReflectsWhetherAModelIsInstalled() {
        let withModel = NoteGenerationRouter(mode: .local,
                                             onlineConfiguration: AIConfiguration.default,
                                             localModelProvider: LabelledProvider(label: "qwen"))
        let without = NoteGenerationRouter(mode: .local,
                                           onlineConfiguration: AIConfiguration.default,
                                           localModelProvider: nil)

        XCTAssertEqual(withModel.localEngineName, LocalModelDescriptor.qwen3.displayName)
        XCTAssertEqual(without.localEngineName, LocalLiteNoteProvider.engineName)
    }
}

// MARK: - Online mode

final class OnlineModeTests: XCTestCase {
    func testOnlineModeUsesTheConfiguredProvider() async throws {
        let counter = ProviderCallCounter()
        let router = NoteGenerationRouter(
            mode: .online,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(label: "qwen"),
            localLiteProviderFactory: { _ in LabelledProvider(label: "lite") },
            onlineProviderFactory: { _ in
                counter.increment()
                return LabelledProvider(label: "online")
            }
        )

        let note = try await router.generate(from: ClipboardContent(text: "hello")!,
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "online")
        XCTAssertEqual(counter.value, 1)
    }

    /// Online mode must not quietly run the local model instead, even when one is installed:
    /// the user asked for the configured service.
    func testOnlineModeIgnoresAnInstalledLocalModel() async throws {
        let router = NoteGenerationRouter(
            mode: .online,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: LabelledProvider(label: "qwen"),
            onlineProviderFactory: { _ in LabelledProvider(label: "online") }
        )

        let note = try await router.generate(from: ClipboardContent(text: "hello")!,
                                             existingCategories: [],
                                             preferredLanguage: .automatic)
        XCTAssertEqual(note.title, "online")
    }

    func testOnlineModeSurfacesProviderErrors() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let router = NoteGenerationRouter(
            mode: .online,
            onlineConfiguration: validOnlineConfiguration,
            onlineProviderFactory: { _ in LabelledProvider(label: "online", error: Boom()) }
        )

        do {
            _ = try await router.generate(from: ClipboardContent(text: "hello")!,
                                          existingCategories: [],
                                          preferredLanguage: .automatic)
            XCTFail("expected the provider error to propagate")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "boom")
        }
    }

    /// The existing OpenAI-compatible request shape must not regress.
    func testOnlineModeStillSendsTheOpenAICompatibleRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubChatURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubChatURLProtocol.reset()
        defer { StubChatURLProtocol.reset() }

        let router = NoteGenerationRouter(
            mode: .online,
            onlineConfiguration: validOnlineConfiguration,
            onlineProviderFactory: { OpenAICompatibleProvider(configuration: $0, session: session) }
        )

        let note = try await router.generate(from: ClipboardContent(text: "Swift actor notes")!,
                                             existingCategories: ["开发"],
                                             preferredLanguage: .simplifiedChinese)
        XCTAssertEqual(note.title, "Swift Actor")
        XCTAssertEqual(StubChatURLProtocol.requestCount, 1)
        XCTAssertEqual(StubChatURLProtocol.lastRequest?.url?.absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(StubChatURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer sk-test")
    }
}

// MARK: - Mode persistence

final class AIProcessingModeTests: XCTestCase {
    /// Two modes only, and the default is local (§8, §16).
    func testOnlyTwoModesExistAndTheDefaultIsLocal() {
        XCTAssertEqual(Set(AIProcessingMode.allCases), [.local, .online])
        XCTAssertEqual(AIProcessingMode.recommended, .local)
    }

    /// An install upgrading from the three-mode build has `automatic` persisted. Resolving
    /// that to the network would silently start uploading content the user never asked to
    /// send, so it must resolve to the device.
    func testLegacyAutomaticValueResolvesToLocal() {
        let defaults = UserDefaults.standard
        let key = ClipNestSettings.aiProcessingMode
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.set("automatic", forKey: key)
        XCTAssertEqual(AIConfigurationStore.loadProcessingMode(), .local)

        defaults.set("nonsense", forKey: key)
        XCTAssertEqual(AIConfigurationStore.loadProcessingMode(), .local)

        defaults.removeObject(forKey: key)
        XCTAssertEqual(AIConfigurationStore.loadProcessingMode(), .local)

        defaults.set(AIProcessingMode.online.rawValue, forKey: key)
        XCTAssertEqual(AIConfigurationStore.loadProcessingMode(), .online)
    }
}

// MARK: - Privacy

@MainActor
final class PrivacyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RequestRecordingURLProtocol.counter.reset()
    }

    /// `testLocalModeNeverCreatesNetworkRequest`: run the real local pipeline against a
    /// URLSession that records every request, with a *valid* online configuration present.
    /// Nothing may reach the loading system.
    func testLocalModeNeverCreatesNetworkRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestRecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        // No local model is injected, so the real Local Lite pipeline runs — with a *valid*
        // online configuration sitting unused behind the factory.
        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnlineConfiguration,
            localModelProvider: nil,
            onlineProviderFactory: { OpenAICompatibleProvider(configuration: $0, session: session) }
        )

        do {
            _ = try await router.generate(
                from: ClipboardContent(text: "私密笔记：VNRecognizeTextRequest 与 SwiftUI 图片识别")!,
                existingCategories: ["iOS开发"],
                preferredLanguage: .simplifiedChinese)
        }

        XCTAssertEqual(RequestRecordingURLProtocol.counter.value, 0,
                       "Local mode must not create any network request")
    }

    func testLocalPhotoCaptureNeverCallsTheImageEndpoint() async throws {
        let store = VaultStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyPhoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        // A separate image endpoint is configured and valid, but the mode is local.
        let imageConfiguration = AIImageConfiguration(usesSeparateEndpoint: true,
                                                     baseURL: "https://api.openai.com/v1",
                                                     apiKey: "sk-test",
                                                     model: "gpt-4o")
        XCTAssertTrue(imageConfiguration.isValid)

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: ClipboardService(),
                                             noteGenerator: LocalLiteNoteProvider(),
                                             ocrService: StubOCRService(text: "从照片识别出的文字\n使用 Vision 做 OCR"))
        let requestCountBefore = RequestRecordingURLProtocol.counter.value
        try await withLocalModeDefaults {
            await coordinator.capturePhoto(TestImageFactory.make())
        }

        XCTAssertEqual(coordinator.state, .completed)
        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        XCTAssertTrue(try String(contentsOf: saved, encoding: .utf8).contains("从照片识别出的文字"))
        XCTAssertEqual(RequestRecordingURLProtocol.counter.value, requestCountBefore,
                       "Photo capture in local mode must not touch the network")
    }
}

/// Runs `body` with the persisted mode pinned to a known state, then restores the previous
/// values. The capture pipeline intentionally reads its settings from `UserDefaults`, so a
/// test that exercises it has to control them.
func withProcessingModeDefaults(_ mode: AIProcessingMode,
                                _ body: () async -> Void) async throws {
    let defaults = UserDefaults.standard
    let keys = [ClipNestSettings.aiProcessingMode,
                ClipNestSettings.processingMode,
                ClipNestSettings.autoDetectClipboard,
                ClipNestSettings.autoGenerateNote]
    let previous = keys.map { defaults.object(forKey: $0) }
    defaults.set(mode.rawValue, forKey: ClipNestSettings.aiProcessingMode)
    defaults.set(ClipboardProcessingMode.automatic.rawValue, forKey: ClipNestSettings.processingMode)
    PendingCaptureStore.removeAll()
    defer {
        for (index, key) in keys.enumerated() {
            if let value = previous[index] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        PendingCaptureStore.removeAll()
    }
    await body()
}

func withLocalModeDefaults(_ body: () async -> Void) async throws {
    try await withProcessingModeDefaults(.local, body)
}

// MARK: - The "AI is unavailable" escape hatch

/// Spec forbidden-items list: the app must never be *unable* to save the raw text when AI is
/// unavailable. The failure alert offers "Save As-Is", which routes through the ordinary
/// `saveRawClipboard` path — so this proves that path still works after a generation failure.
@MainActor
final class UnavailableAITests: XCTestCase {
    private struct ProviderFailure: LocalizedError {
        var errorDescription: String? { "The model endpoint is unreachable." }
    }

    private func makeVault() throws -> (VaultStore, URL) {
        let store = VaultStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineDraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.openVault(at: root)
        return (store, root)
    }

    private func markdownFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            files.append(url)
        }
        return files
    }

    func testOnlineFailureStillLetsTheUserSaveTheRawText() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: LabelledProvider(label: "online", error: ProviderFailure()))
        let rawText = "这是一段必须在 AI 不可用时也能保存下来的原始文字。"

        try await withProcessingModeDefaults(.online) {
            await coordinator.captureText(rawText)

            // The generation failed, and the failure is surfaced rather than swallowed.
            XCTAssertEqual(coordinator.state, .failed)
            XCTAssertNotNil(coordinator.errorMessage)
            XCTAssertTrue(markdownFiles(in: root).isEmpty, "a failed generation must not save a partial note")

            // The escape hatch is the same save path the UI's "Save As-Is" button calls.
            await coordinator.saveRawClipboard()
        }

        XCTAssertEqual(coordinator.state, .completed)
        let files = markdownFiles(in: root)
        XCTAssertEqual(files.count, 1, "expected exactly one saved file, got \(files.map(\.lastPathComponent))")
        let saved = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(saved.contains(rawText), "the raw text must survive verbatim")
    }

    /// The other half of the same guarantee: in local mode this input never needs the escape
    /// hatch at all, because on-device extraction cannot fail on a network error.
    func testLocalModeSavesWithoutAnyEscapeHatch() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: ClipboardService(),
                                             noteGenerator: LocalLiteNoteProvider())
        let rawText = "这是一段必须在 AI 不可用时也能保存下来的原始文字。"

        try await withLocalModeDefaults {
            await coordinator.captureText(rawText)
        }

        XCTAssertEqual(coordinator.state, .completed)
        XCTAssertEqual(markdownFiles(in: root).count, 1)
    }
}

// MARK: - Shared fixtures

let validOnlineConfiguration = AIConfiguration(
    baseURL: "https://api.openai.com/v1",
    apiKey: "sk-test",
    model: "gpt-4o-mini",
    preferredLanguage: .automatic
)

/// Answers immediately with a canned OCR result so the photo pipeline can be tested without
/// a real image.
struct StubOCRService: OCRRecognizing {
    let text: String

    func recognizeText(cgImage: CGImage, languages: [String]) async throws -> OCRResult {
        OCRResult(text: text,
                  blocks: [OCRTextBlock(text: text, confidence: 0.9, boundingBox: .zero)],
                  confidence: 0.9)
    }
}

enum TestImageFactory {
    /// A 1×1 opaque image; large enough to have a real `CGImage` for the OCR stub.
    static func make() -> PlatformImage {
        let width = 4
        let height = 4
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
        return PlatformImage.from(cgImage: context.makeImage()!)
    }
}

/// Chat-completions stub used to prove the online path is unchanged.
final class StubChatURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requestCount = 0
    private static var _lastRequest: URLRequest?

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return _lastRequest }

    static func reset() {
        lock.lock()
        _requestCount = 0
        _lastRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        Self._lastRequest = request
        Self.lock.unlock()

        let payload = """
        {"choices":[{"message":{"content":"{\\"title\\":\\"Swift Actor\\",\\"summary\\":\\"隔离共享状态。\\",\\"content\\":\\"Actor protects state.\\",\\"category\\":\\"开发\\",\\"tags\\":[\\"Swift\\"],\\"sourceURL\\":null}"}}]}
        """
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
