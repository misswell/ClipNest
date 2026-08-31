import XCTest
@testable import ClipNest

/// The photo-capture pipeline: OCR output must flow through the same organization
/// pipeline as clipboard content — generate → classify → save into the vault.
@MainActor
final class PhotoCapturePipelineTests: XCTestCase {
    private struct StubGenerator: NoteGenerating {
        func generate(from content: ClipboardContent,
                      existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
            GeneratedNote(title: "OCR Note",
                          summary: "Recognized from a photo",
                          content: content.rawText,
                          category: ClassificationService.inbox,
                          tags: [],
                          sourceURL: nil)
        }
    }

    func testCaptureTextOrganizesOCRTextIntoNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: ClipboardService(),
                                             noteGenerator: StubGenerator())
        await coordinator.captureText("Hello OCR test text\n会议纪要 08-29")

        XCTAssertEqual(coordinator.state, .completed)
        let savedURL = try XCTUnwrap(coordinator.lastSavedURL)
        let saved = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("Hello OCR test text"))
        XCTAssertTrue(saved.contains("会议纪要 08-29"))
        XCTAssertTrue(saved.contains("# OCR Note"))
    }

    func testCaptureTextWithWhitespaceOnlyInputStaysIdle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoCaptureEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: ClipboardService(),
                                             noteGenerator: StubGenerator())
        await coordinator.captureText("   \n  ")

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.lastSavedURL)
    }

    /// The "Save As-Is" fallback when AI generation is unavailable.
    func testSaveRawClipboardWritesOCRTextIntoInbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)

        // The "Save As-Is" fallback when AI generation is unavailable.
        let content = ClipboardContent(text: "Hello OCR test text\n会议纪要 08-29")!
        let url = try await store.saveRawClipboard(content)

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("Hello OCR test text"))
        XCTAssertTrue(saved.contains("会议纪要 08-29"))
        XCTAssertTrue(url.path.contains(ClassificationService.inbox))
    }
}
