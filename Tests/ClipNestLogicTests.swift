import Foundation
import XCTest
@testable import ClipNest

final class ClipNestLogicTests: XCTestCase {
    func testClipboardNormalizationAndHash() {
        let first = ClipboardContent(text: "  Swift actor\r\n protects state  ")
        let second = ClipboardContent(text: "Swift actor\n protects state")

        XCTAssertEqual(first?.text, second?.text)
        XCTAssertEqual(first?.kind, .plainText)
        XCTAssertEqual(ClipboardContent.hash(for: first!.text),
                       ClipboardContent.hash(for: second!.text))
    }

    func testClipboardURLKinds() {
        let url = ClipboardContent(text: "https://example.com/article")
        let mixed = ClipboardContent(text: "Read this: https://example.com/article")

        XCTAssertEqual(url?.kind, .url)
        XCTAssertEqual(url?.sourceURL?.absoluteString, "https://example.com/article")
        XCTAssertEqual(mixed?.kind, .textAndURL)
    }

    func testFileNameSanitizerRemovesPathCharacters() {
        let name = FileNameSanitizer.fileName(from: " Swift/Actor: \"安全\" ")

        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertFalse(name.isEmpty)
    }

    func testClassificationPrefersExistingFolderAndFallsBackToInbox() {
        let note = GeneratedNote(title: "Concurrency",
                                 summary: "",
                                 content: "Actor",
                                 category: "产品",
                                 tags: [],
                                 sourceURL: nil)
        let existing = ["iOS", "阅读"]
        let noNewFolders = ClassificationConfiguration(automaticallyClassify: true,
                                                       allowCreatingNewCategories: false,
                                                       defaultCategory: "Inbox")
        XCTAssertEqual(ClassificationService().classify(note: note,
                                                         existingCategories: existing,
                                                         configuration: noNewFolders),
                       ClassificationService.inbox)

        var matchingNote = note
        matchingNote.category = "iOS开发"
        XCTAssertEqual(ClassificationService().classify(note: matchingNote,
                                                         existingCategories: existing,
                                                         configuration: ClassificationConfiguration(
                                                            automaticallyClassify: true,
                                                            allowCreatingNewCategories: true,
                                                            defaultCategory: "Inbox")),
                       "iOS")
    }

    func testMarkdownBuilderKeepsMetadataAndOriginalContent() {
        let content = ClipboardContent(text: "Swift actor protects shared state\nhttps://example.com")!
        let note = GeneratedNote(title: "Swift Actor / Safety",
                                 summary: "隔离共享可变状态。",
                                 content: "Actor members are isolated.",
                                 category: "开发",
                                 tags: ["Swift", "Concurrency"],
                                 sourceURL: nil)

        let markdown = MarkdownNoteBuilder.make(note: note,
                                                originalContent: content,
                                                date: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("source: clipboard"))
        XCTAssertTrue(markdown.contains("sourceURL: \"https://example.com\""))
        XCTAssertTrue(markdown.contains("# Swift Actor / Safety"))
        XCTAssertTrue(markdown.contains("> Swift actor protects shared state"))
    }

    func testPromptIncludesExistingCategoriesAndContent() {
        let content = ClipboardContent(text: "A short note")!
        let prompt = NotePromptBuilder.systemPrompt(existingCategories: ["开发", "AI"],
                                                     preferredLanguage: .simplifiedChinese)
            + NotePromptBuilder.userPrompt(for: content)

        XCTAssertTrue(prompt.contains("- 开发"))
        XCTAssertTrue(prompt.contains("- AI"))
        XCTAssertTrue(prompt.contains("A short note"))
        XCTAssertTrue(prompt.contains("严格有效的 JSON"))
    }

    func testDocumentLoadGateRejectsOutOfOrderAndRetriedResults() {
        var gate = DocumentLoadRequestGate()
        let firstURL = URL(fileURLWithPath: "/tmp/First.md")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.md")

        let slowFirstRequest = gate.begin(for: firstURL)
        let currentSecondRequest = gate.begin(for: secondURL)

        XCTAssertFalse(gate.accepts(slowFirstRequest),
                       "A slow previous document must not overwrite the current document")
        XCTAssertTrue(gate.accepts(currentSecondRequest))

        let retriedSecondRequest = gate.begin(for: secondURL)
        XCTAssertFalse(gate.accepts(currentSecondRequest),
                       "A retry must supersede the earlier request for the same URL")
        XCTAssertTrue(gate.accepts(retriedSecondRequest))
    }

    @MainActor
    func testVaultStoreReadsMarkdownContentFromNestedFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestNestedRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let folder = root.appendingPathComponent("开发", isDirectory: true)
        let file = folder.appendingPathComponent("内容.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let expected = "# 内容\n\n## 正文\n\n这是文件夹里的正文。\n"
        try Data(expected.utf8).write(to: file)

        store.openVault(at: root)

        XCTAssertEqual(store.loadText(file), expected)
        XCTAssertEqual(
            store.rootNode?.children?.first(where: { $0.name == "开发" })?.children?.first?.url
                .resolvingSymlinksInPath(),
            file.resolvingSymlinksInPath()
        )
    }

    @MainActor
    func testLargeVaultRefreshesTreeAndMetadataWithoutBlockingTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestLargeVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documentCount = 10_000
        for index in 0..<documentCount {
            let url = root.appendingPathComponent("Note-\(index).md")
            FileManager.default.createFile(atPath: url.path,
                                           contents: Data("# Note \(index)\n".utf8))
        }

        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        store.openVault(at: root)
        XCTAssertTrue(store.isTreeLoading,
                      "A large vault should leave the main actor while its tree is built")

        let deadline = Date().addingTimeInterval(30)
        while store.isTreeLoading || store.isHomeSnapshotLoading {
            XCTAssertLessThan(Date(), deadline, "Large vault refresh did not finish in time")
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(store.rootNode?.children?.count, documentCount)
        XCTAssertEqual(store.homeSnapshot.markdownFiles.count, documentCount)
        XCTAssertEqual(store.homeSnapshot.timelineItems.count, documentCount)
    }

    @MainActor
    func testVaultStoreMovesDocumentsAndMaintainsManualOrder() throws {
        let defaults = UserDefaults.standard
        let sortKey = "settings.sortAscending"
        let savedSort = defaults.object(forKey: sortKey)
        defer {
            if let savedSort {
                defaults.set(savedSort, forKey: sortKey)
            } else {
                defaults.removeObject(forKey: sortKey)
            }
        }
        defaults.set(true, forKey: sortKey)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestMoveTests-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for name in ["A.md", "B.md", "C.md"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path,
                                           contents: Data("# \(name)\n".utf8))
        }

        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        let source = root.appendingPathComponent("B.md")
        store.selectedFileURL = source
        let moved = store.moveDocument(source, to: archive)

        XCTAssertEqual(moved?.standardizedFileURL,
                       archive.appendingPathComponent("B.md").standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("B.md").path))
        XCTAssertEqual(store.selectedFileURL?.standardizedFileURL, moved?.standardizedFileURL)

        let c = root.appendingPathComponent("C.md")
        XCTAssertTrue(store.canMoveDocument(c, direction: .up))
        XCTAssertTrue(store.moveDocumentInOrder(c, direction: .up))

        let rootDocuments = store.rootNode?.children?.filter { !$0.isDirectory }.map(\.name)
        XCTAssertEqual(rootDocuments, ["C.md", "A.md"])
        XCTAssertFalse(store.canMoveDocument(c, direction: .up))
        XCTAssertTrue(store.canMoveDocument(c, direction: .down))

        store.closeVault()
        let reloadedStore = VaultStore()
        defer { reloadedStore.closeVault() }
        reloadedStore.openVault(at: root)
        let reloadedDocuments = reloadedStore.rootNode?.children?.filter { !$0.isDirectory }.map(\.name)
        XCTAssertEqual(reloadedDocuments, ["C.md", "A.md"])
    }

    @MainActor
    func testVaultStoreWritesUniqueMarkdownFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        let existingDirectory = root.appendingPathComponent("开发", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let existingURL = existingDirectory.appendingPathComponent("Same Title.md")
        try Data("Existing note".utf8).write(to: existingURL)

        let content = ClipboardContent(text: "Original clipboard text")!
        let note = GeneratedNote(title: "Same Title",
                                 summary: "Summary",
                                 content: "Body",
                                 category: "开发",
                                 tags: [],
                                 sourceURL: nil)
        let first = try await store.saveGeneratedNote(note: note, originalContent: content)
        let second = try await store.saveGeneratedNote(note: note, originalContent: content)

        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        let existingText = try String(contentsOf: existingURL, encoding: .utf8)
        XCTAssertEqual(existingText, "Existing note")
        let generatedText = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(generatedText.contains("# Same Title"))
        XCTAssertTrue(generatedText.contains("## 摘要"))
        XCTAssertTrue(generatedText.contains("Summary"))
        XCTAssertTrue(generatedText.contains("## 内容"))
        XCTAssertTrue(generatedText.contains("Body"))
        XCTAssertTrue(generatedText.contains("## 原始内容"))
        XCTAssertTrue(generatedText.contains("> Original clipboard text"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(store.topLevelCategories().contains("开发"))

        let raw = ClipboardContent(text: "  Raw\r\nLine  ")!
        let rawURL = try await store.saveRawClipboard(raw,
                                                       date: Date(timeIntervalSince1970: 0))
        let rawMarkdown = try String(contentsOf: rawURL, encoding: .utf8)
        XCTAssertTrue(rawMarkdown.contains("  Raw\r\nLine  "))
    }

    func testOpenAICompatibleProviderDecodesStrictJSONResponse() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"choices":[{"message":{"content":"{\"title\":\"Generated\",\"summary\":\"Summary\",\"content\":\"Body\",\"category\":\"开发\",\"tags\":[\"Swift\"],\"sourceURL\":null}"}}]}"#.utf8)
            return (response, data)
        }

        let configuration = AIConfiguration(baseURL: "https://example.com/v1",
                                            apiKey: "test-key",
                                            model: "test-model",
                                            preferredLanguage: .automatic)
        let content = ClipboardContent(text: "A short note")!
        let note = try await OpenAICompatibleProvider(configuration: configuration, session: session)
            .generateNote(from: content,
                          existingCategories: ["开发"],
                          preferredLanguage: .automatic)

        XCTAssertEqual(note.title, "Generated")
        XCTAssertEqual(note.category, "开发")
        XCTAssertEqual(note.tags, ["Swift"])
    }

    @MainActor
    func testCoordinatorUsesChangeCountToAvoidRepeatedReads() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            ClipNestSettings.autoDetectClipboard,
            ClipNestSettings.autoGenerateNote,
            ClipNestSettings.lastClipboardHash,
            ClipNestSettings.lastSeenClipboardHash,
            ClipNestSettings.lastClipboardChangeCount,
            ClipNestSettings.lastAttemptedClipboardHash
        ]
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(true, forKey: ClipNestSettings.autoDetectClipboard)
        defaults.set(false, forKey: ClipNestSettings.autoGenerateNote)
        defaults.removeObject(forKey: ClipNestSettings.lastClipboardChangeCount)
        defaults.removeObject(forKey: ClipNestSettings.lastClipboardHash)
        defaults.removeObject(forKey: ClipNestSettings.lastAttemptedClipboardHash)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        let snapshot = ClipboardSnapshot(
            content: ClipboardContent(text: "Deferred clipboard")!,
            changeCount: 42,
            hash: ClipboardContent.hash(for: "Deferred clipboard")
        )
        let provider = FakeClipboardProvider(snapshot: snapshot)
        let coordinator = CaptureCoordinator(store: store, clipboardService: provider)

        await coordinator.start()
        await coordinator.sceneDidBecomeActive()

        XCTAssertEqual(provider.readCount, 1)
        XCTAssertEqual(defaults.integer(forKey: ClipNestSettings.lastClipboardChangeCount), 42)
    }

    @MainActor
    func testCoordinatorGeneratesAndSavesAutomatically() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            ClipNestSettings.autoDetectClipboard,
            ClipNestSettings.autoGenerateNote,
            ClipNestSettings.processingMode,
            ClipNestSettings.autoClassify,
            ClipNestSettings.allowNewCategories,
            ClipNestSettings.defaultCategory,
            ClipNestSettings.lastClipboardHash,
            ClipNestSettings.lastSeenClipboardHash,
            ClipNestSettings.lastClipboardChangeCount,
            ClipNestSettings.lastAttemptedClipboardHash
        ]
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(true, forKey: ClipNestSettings.autoDetectClipboard)
        defaults.set(true, forKey: ClipNestSettings.autoGenerateNote)
        defaults.set(ClipboardProcessingMode.automatic.rawValue, forKey: ClipNestSettings.processingMode)
        defaults.set(true, forKey: ClipNestSettings.autoClassify)
        defaults.set(false, forKey: ClipNestSettings.allowNewCategories)
        defaults.set(ClassificationService.inbox, forKey: ClipNestSettings.defaultCategory)
        defaults.removeObject(forKey: ClipNestSettings.lastClipboardHash)
        defaults.removeObject(forKey: ClipNestSettings.lastClipboardChangeCount)
        defaults.removeObject(forKey: ClipNestSettings.lastAttemptedClipboardHash)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestAutomaticTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("开发"), withIntermediateDirectories: true)

        let snapshot = ClipboardSnapshot(
            content: ClipboardContent(text: "Swift actor note")!,
            changeCount: 84,
            hash: ClipboardContent.hash(for: "Swift actor note")
        )
        let clipboard = FakeClipboardProvider(snapshot: snapshot)
        let generator = FakeNoteGenerator(note: GeneratedNote(
            title: "Swift Actor",
            summary: "隔离共享状态。",
            content: "Actor protects mutable state.",
            category: "开发",
            tags: ["Swift"],
            sourceURL: nil
        ))
        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: clipboard,
                                             noteGenerator: generator)

        await coordinator.start()
        XCTAssertEqual(store.selectedFileURL?.lastPathComponent, "Swift Actor.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("开发/Swift Actor.md").path))
        XCTAssertEqual(generator.callCount, 1)

        await coordinator.sceneDidBecomeActive()
        XCTAssertEqual(generator.callCount, 1)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FakeNoteGenerator: NoteGenerating {
    let note: GeneratedNote
    private(set) var callCount = 0

    init(note: GeneratedNote) {
        self.note = note
    }

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        callCount += 1
        return note
    }
}

@MainActor
private final class FakeClipboardProvider: ClipboardProviding {
    let snapshot: ClipboardSnapshot
    private(set) var readCount = 0

    init(snapshot: ClipboardSnapshot) {
        self.snapshot = snapshot
    }

    func changeCount() -> Int { snapshot.changeCount }

    func readCurrent() -> ClipboardSnapshot? {
        readCount += 1
        return snapshot
    }
}
