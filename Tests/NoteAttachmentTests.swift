import XCTest
@testable import ClipNest

/// The attachment transaction (方案 §19, §20, §35 Case 6–8): images land in
/// `Attachments/` only when the format keeps them, the Markdown references what was
/// written, and any failure leaves neither a broken note nor orphan files.
@MainActor
final class NoteAttachmentTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteAttachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore()
        store.openVault(at: root)
    }

    override func tearDownWithError() throws {
        store.closeVault()
        try? FileManager.default.removeItem(at: root)
    }

    /// A tiny valid JPEG (one grey pixel) — the magic bytes make `fileExtension` resolve.
    private func jpegData() -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xD9])
    }

    private let note = GeneratedNote(title: "发票",
                                     summary: "一张发票照片",
                                     content: "",
                                     category: "Inbox",
                                     tags: [],
                                     sourceURL: nil)

    func testKeepingTheOriginalImageWritesTheAttachmentAndLinksIt() async throws {
        let image = CapturedImage(data: jpegData(), preferredExtension: "jpg")
        let captured = CapturedContent(text: "OCR 出来的发票文字",
                                       sourceKind: .photo,
                                       images: [image])

        let url = try await store.saveGeneratedNote(note: note,
                                                    captured: captured,
                                                    format: .default)

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(markdown.contains("OCR 出来的发票文字"),
                       "a photo capture keeps the picture as the source, not the OCR transcription")

        let attachmentsFolder = root.appendingPathComponent("Attachments", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: attachmentsFolder,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "exactly one attachment is written")
        XCTAssertEqual(files[0].pathExtension, "jpg")

        XCTAssertTrue(markdown.contains("](../Attachments/\(files[0].lastPathComponent))"),
                      "the note links the attachment with a vault-relative Markdown link")

        // The transaction is only clean when every piece is on disk together.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnImageThatOnlyParticipatesInRecognitionIsNotSaved() async throws {
        // 方案 §35 Case 7 — the image was read by OCR, but the format does not keep it.
        let image = CapturedImage(data: jpegData(), preferredExtension: "jpg")
        let captured = CapturedContent(text: "OCR 出来的发票文字",
                                       sourceKind: .photo,
                                       images: [image])
        var format = NoteFormatConfiguration.standard
        format.includeOriginalImage = false

        let url = try await store.saveGeneratedNote(note: note,
                                                    captured: captured,
                                                    format: format)

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Attachments/"),
                       "no attachment means no link")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Attachments").path),
            "no attachment folder is created (方案 §36⑰)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnEmptyImageListWritesNoAttachmentFolder() async throws {
        let captured = CapturedContent(text: "纯文字剪贴板内容")
        let url = try await store.saveGeneratedNote(note: note,
                                                    captured: captured,
                                                    format: .default)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Attachments").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 方案 §35 Case 8 — a vault whose `Attachments` name is occupied by a *file* makes
    /// attachment creation impossible. The reserved note file must be rolled back so no
    /// half-saved capture survives.
    func testAFailedAttachmentStepRollsTheNoteBack() async throws {
        let blocker = root.appendingPathComponent("Attachments")
        try Data("not a directory".utf8).write(to: blocker)

        let image = CapturedImage(data: jpegData(), preferredExtension: "jpg")
        let captured = CapturedContent(text: "OCR 出来的发票文字",
                                       sourceKind: .photo,
                                       images: [image])

        do {
            _ = try await store.saveGeneratedNote(note: note,
                                                  captured: captured,
                                                  format: .default)
            XCTFail("saving must fail when the attachment step fails")
        } catch let error as ClipNestVaultError {
            guard case .cannotWriteAttachment = error else {
                return XCTFail("expected .cannotWriteAttachment, got \(error)")
            }
        }

        // The Inbox folder holds no reserved-but-unfinished note file.
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.filter { $0.pathExtension == "md" }.isEmpty,
                      "the failed transaction must not leave note files behind")
        XCTAssertTrue(leftovers.isEmpty || leftovers.allSatisfy { $0.pathExtension != "md" })
    }
}
