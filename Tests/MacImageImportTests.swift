import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import ClipNest

/// The Mac image-import entry point.
///
/// iOS hands the capture pipeline a `PlatformImage` straight from `PHPickerViewController`.
/// macOS has no such picker, so `captureImportedImage(at:)` reads an image the user chose from
/// disk and joins the very same pipeline. These tests pin that join, and the failure behaviour
/// that keeps one unreadable pick from stranding the coordinator.
@MainActor
final class MacImageImportTests: XCTestCase {
    private struct StubGenerator: NoteGenerating {
        func generate(from content: ClipboardContent,
                      existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
            // The OCR text is echoed into the summary so the tests keep proving that the
            // recognized text reached the generator: since the picture now takes the note's
            // source slot, the transcription no longer renders as the body.
            GeneratedNote(title: "Imported Image Note",
                          summary: "Organized: \(content.rawText)",
                          content: content.rawText,
                          category: ClassificationService.inbox,
                          tags: [],
                          sourceURL: nil)
        }
    }

    /// An empty vault, plus a cleanup closure the caller defers.
    private func makeVault(_ label: String) throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        store.openVault(at: root)
        return store
    }

    /// A real, decodable image on disk. Deliberately written outside the vault, because the
    /// whole point of the Mac path is importing from wherever the user keeps the picture.
    private func makeExternalImageFile() throws -> URL {
        let image = TestImageFactory.make()
        let data = try XCTUnwrap(image.jpegDataForUpload(compressionQuality: 1.0),
                                 "the test image should encode to JPEG")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }

    private func makeExternalTextFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).txt")
        try "这不是图片".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCaptureImportedImageOrganizesThePickedFile() async throws {
        let store = try makeVault("MacImport")
        let source = try makeExternalImageFile()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: source)
        }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: StubGenerator(),
            ocrService: StubOCRService(text: "导入图片里的文字\n第二行"))

        try await withLocalModeDefaults {
            await coordinator.captureImportedImage(at: source)
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.state, .completed)

        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        let contents = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(contents.contains("导入图片里的文字"),
                      "an imported image must reach OCR the same way a phone photo does")
        XCTAssertTrue(contents.contains("# Imported Image Note"))
        XCTAssertTrue(contents.contains("](../Attachments/"),
                      "the picture itself takes the source slot in the saved note")
    }

    /// The storage format rule: whatever the user picks, the vault gets JPEG at the storage
    /// quality — a PNG pick must not keep its multi-megabyte original in the vault.
    func testAnImportedImageIsStoredAsJPEGAtTheStorageQuality() async throws {
        let store = try makeVault("MacImportJPEG")
        let source = try makeExternalPNGFile()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: source)
        }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: StubGenerator(),
            ocrService: StubOCRService(text: "转码存储的文字"))

        try await withLocalModeDefaults {
            await coordinator.captureImportedImage(at: source)
        }

        XCTAssertNil(coordinator.errorMessage)
        let rootURL = try XCTUnwrap(store.rootURL)
        let attachments = try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("Attachments", isDirectory: true),
            includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: XCTUnwrap(attachments.first))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF],
                       "a PNG pick is stored as JPEG")
        XCTAssertEqual(attachments.first?.pathExtension, "jpg")
    }

    private func makeExternalPNGFile() throws -> URL {
        let image = TestImageFactory.make()
        #if canImport(UIKit)
        let data = try XCTUnwrap(image.pngData())
        #elseif canImport(AppKit)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    func testCaptureImportedImageRejectsAFileThatIsNotAnImage() async throws {
        let store = try makeVault("MacImportBad")
        let source = try makeExternalTextFile()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: source)
        }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: StubGenerator(),
            ocrService: StubOCRService(text: "should never be reached"))

        await coordinator.captureImportedImage(at: source)

        XCTAssertEqual(coordinator.errorMessage,
                       String(localized: "That file could not be opened as an image."))
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.lastSavedURL, "an unreadable pick must not write a note")
    }

    func testCaptureImportedImageReportsAMissingFile() async throws {
        let store = try makeVault("MacImportMissing")
        defer { store.closeVault() }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: StubGenerator(),
            ocrService: StubOCRService(text: "should never be reached"))

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).png")
        await coordinator.captureImportedImage(at: missing)

        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.lastSavedURL)
    }

    /// A bad pick must not wedge the pipeline: the next good one still has to work.
    func testCoordinatorRecoversAfterAFailedImport() async throws {
        let store = try makeVault("MacImportRecover")
        let good = try makeExternalImageFile()
        let bad = try makeExternalTextFile()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }

        let coordinator = CaptureCoordinator(
            store: store,
            clipboardService: ClipboardService(),
            noteGenerator: StubGenerator(),
            ocrService: StubOCRService(text: "恢复之后的文字"))

        await coordinator.captureImportedImage(at: bad)
        XCTAssertNotNil(coordinator.errorMessage)

        try await withLocalModeDefaults {
            await coordinator.captureImportedImage(at: good)
        }

        XCTAssertNil(coordinator.errorMessage, "a successful import must clear the previous error")
        XCTAssertEqual(coordinator.state, .completed)
        let saved = try XCTUnwrap(coordinator.lastSavedURL)
        XCTAssertTrue(try String(contentsOf: saved, encoding: .utf8).contains("恢复之后的文字"))
    }
}
