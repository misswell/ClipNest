import XCTest
import SwiftUI
import AppKit
@testable import ClipNest

/// Renders the macOS shell offscreen through the same environment the app injects.
///
/// This is the guard for the title-bar capture buttons: `VSCodeLayout` reads
/// `CaptureCoordinator` from the environment, so if that object were ever not provided, or the
/// top bar failed to lay out, this would fail instead of the app dying on launch.
@MainActor
final class MacShellRenderTests: XCTestCase {
    private func makeStore(_ label: String) throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Render check\n\nbody".write(to: root.appendingPathComponent("note.md"),
                                           atomically: true, encoding: .utf8)
        let store = VaultStore()
        store.openVault(at: root)
        addTeardownBlock {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        return store
    }

    func testMacShellRendersWithTheCaptureEnvironment() throws {
        let store = try makeStore("MacShellRender")

        let coordinator = CaptureCoordinator(store: store)
        let view = VSCodeLayout()
            .environmentObject(store)
            .environmentObject(store.selection)
            .environmentObject(LocalSearchController())
            .environmentObject(coordinator)

        let size = NSSize(width: 1200, height: 760)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        // A blank render means the shell laid out to nothing, which is what a missing
        // environment object or a broken top bar would look like.
        XCTAssertGreaterThan(png.count, 5_000, "the shell should render something")

        // Keep the bitmap for eyeballing; the path is stable so a human can open it.
        let out = ProcessInfo.processInfo.environment["CLIPNEST_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "clipnest-mac-shell.png"
        try png.write(to: URL(fileURLWithPath: out))
    }
}
