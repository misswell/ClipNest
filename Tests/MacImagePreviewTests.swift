import AppKit
import SwiftUI
import XCTest
@testable import ClipNest

@MainActor
final class MacImagePreviewTests: XCTestCase {
    func testPhoneAttachmentWithOnlyAnICloudPlaceholderResolvesToItsDownloadURL() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CloudImagePreview-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let placeholder = folder.appendingPathComponent(".phone.jpg.icloud")
        try Data().write(to: placeholder)
        let folderID = try XCTUnwrap(folder.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
        let document = root.appendingPathComponent("Inbox/note.md")
        for source in ["../Attachments/phone.jpg", "Attachments/phone.jpg", "phone.jpg"] {
            let resolved = try XCTUnwrap(VaultStore.resolveImageURL(source, relativeTo: document, rootURL: root),
                                         "cloud-only attachments must reach the download layer")
            XCTAssertEqual(resolved.lastPathComponent, "phone.jpg")
            // The temporary directory can be spelled /var or /private/var on macOS.
            // Compare the existing parent identity; the logical image does not exist yet.
            XCTAssertEqual(try resolved.deletingLastPathComponent().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
                           folderID)
        }
        XCTAssertNil(VaultStore.resolveImageURL("missing.jpg", relativeTo: document, rootURL: root))
        let local = folder.appendingPathComponent("local.jpg")
        try Data([1, 2, 3]).write(to: local)
        XCTAssertEqual(VaultStore.resolveImageURL("../Attachments/local.jpg", relativeTo: document, rootURL: root)?.resolvingSymlinksInPath().path,
                       local.resolvingSymlinksInPath().path)
    }

    func testCapturedAttachmentIsVisibleInMacPreview() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MacImagePreview-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 300,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        let image = PlatformImage.from(cgImage: try XCTUnwrap(context.makeImage()))
        let attachment = folder.appendingPathComponent("capture.jpg")
        try await VaultFileAccess.shared.write(try XCTUnwrap(image.jpegDataForStorage(compressionQuality: 0.5)), to: attachment)
        let document = root.appendingPathComponent("Inbox/note.md")
        let resolved = try XCTUnwrap(VaultStore.resolveImageURL("../Attachments/capture.jpg", relativeTo: document, rootURL: root))
        let decoded = await VaultImageLoader.image(for: resolved, maxPixelSize: 2048)
        XCTAssertNotNil(decoded)

        let view = MarkdownPreview(markdown: "# Recognized image\n\n![Original](../Attachments/capture.jpg)",
                                   resolveImage: { _ in nil }, documentURL: document, vaultRootURL: root)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        var redPixels = 0
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            redPixels = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                        redPixels += 1
                    }
                }
            }
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/clipnest-mac-image-preview.png"))
            if redPixels > 1_000 { break }
        }
        XCTAssertGreaterThan(redPixels, 1_000, "the loaded attachment must occupy visible space in the Mac preview")
    }
}
