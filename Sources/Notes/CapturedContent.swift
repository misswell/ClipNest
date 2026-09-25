import Foundation
import CryptoKit

/// Where a capture came from (方案 §18). The kind only decides labelling and hashing today,
/// but it is the hook the clipboard-image path (方案 §22) will hang off.
enum CaptureSourceKind: String, Codable, Sendable {
    case clipboard
    case photo
    case importedImage
}

/// One image that travelled with a capture (方案 §18).
///
/// The bytes live only for the current task — they are never persisted to `UserDefaults` or
/// the pending-capture queue, so an interrupted capture retries without the image rather than
/// parking megabytes in settings storage (方案 §18).
struct CapturedImage: Equatable, Sendable {
    let data: Data
    let preferredExtension: String

    init(data: Data, preferredExtension: String) {
        self.data = data
        let cleaned = preferredExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.preferredExtension = cleaned.isEmpty ? "jpg" : cleaned
    }

    /// The extension to save under. The declared preference wins unless the bytes are
    /// recognisably a different container, so a renamed file still lands with the right type.
    var fileExtension: String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return preferredExtension
    }
}

/// Everything one capture produced, carried intact from the capture entry point to the save
/// transaction (方案 §18, §21).
///
/// This is the type that keeps the original image alive past OCR: the old pipeline reduced a
/// photo to its OCR text and threw the picture away, so "keep the original image" had
/// nothing to keep.
struct CapturedContent: Equatable, Sendable {
    var text: String
    var sourceURL: URL?
    var sourceKind: CaptureSourceKind
    var images: [CapturedImage]

    init(text: String,
         sourceURL: URL? = nil,
         sourceKind: CaptureSourceKind = .clipboard,
         images: [CapturedImage] = []) {
        self.text = text
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.images = images
    }

    var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The dedupe/queue hash for this capture. Image bytes participate so the same OCR text
    /// from a different picture is still a distinct capture.
    var hash: String {
        var hasher = SHA256()
        hasher.update(data: Data(ClipboardContent.normalize(text).utf8))
        for image in images {
            hasher.update(data: withUnsafeBytes(of: UInt32(image.data.count).bigEndian) { Data($0) })
            hasher.update(data: image.data.prefix(64))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The text representation the prompts and the draft editor consume. `nil` for an empty
    /// capture (e.g. a photo with no readable text) — callers decide what that means.
    var clipboardContent: ClipboardContent? {
        ClipboardContent(text: text)
    }
}

/// One attachment written during the current save transaction (方案 §20).
///
/// The list is the rollback manifest: if any later step of the save fails, everything in it
/// is deleted again, so a failed capture can never litter the vault with orphan files.
struct SavedAttachment: Equatable, Sendable {
    /// The absolute file URL inside the vault.
    let url: URL
    /// The vault-relative path used in the Markdown link, e.g. `Attachments/2026-09-25-UUID.jpg`.
    let relativePath: String
}
