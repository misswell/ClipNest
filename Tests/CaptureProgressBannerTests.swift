import XCTest
@testable import ClipNest

/// Objective ②, the user-visible half: what the banner says while a note is being organized.
///
/// `NoteGenerationProgressTests` already proves the *provider* emits the right phases. These tests
/// cover the next hop — the phase reaching the banner — because a phase that never reaches
/// `statusMessage` is indistinguishable to the user from the static spinner this work replaced.
@MainActor
final class CaptureProgressBannerTests: XCTestCase {
    private final class QuietClipboard: ClipboardProviding {
        func changeCount() -> Int { 0 }
        func readCurrent() -> ClipboardSnapshot? { nil }
    }

    private func makeCoordinator() -> CaptureCoordinator {
        CaptureCoordinator(store: VaultStore(),
                           clipboardService: QuietClipboard(),
                           noteGenerator: nil)
    }

    func testPreparingTheEngineSaysSoRatherThanLookingStuck() {
        let coordinator = makeCoordinator()

        coordinator.applyGenerationProgress(.preparingEngine(engineName: "Qwen3 0.6B"))

        XCTAssertEqual(coordinator.generationProgress,
                       .preparingEngine(engineName: "Qwen3 0.6B"))
        // Compared through the same lookup the app uses rather than as a literal: the test host
        // runs under the device locale, and this still catches the real regression — a phase wired
        // to the wrong message key.
        XCTAssertEqual(coordinator.statusMessage,
                       String(localized: "Preparing the on-device model…"))
    }

    /// Once real content exists, the status stops hedging and says what is happening.
    func testAGrowingPreviewSwitchesTheMessageToWriting() {
        let coordinator = makeCoordinator()
        let preview = NotePreview(title: "视觉 OCR", summary: "用 VNRecognizeTextRequest…")

        coordinator.applyGenerationProgress(.generating(preview: preview))

        XCTAssertEqual(coordinator.generationProgress, .generating(preview: preview))
        XCTAssertEqual(coordinator.statusMessage, String(localized: "Writing the note…"))
    }

    /// The preview is only shown once there is something to show. A frame that arrives before any
    /// field has been parsed must not replace the message with an empty title and summary.
    func testAnEmptyPreviewKeepsTheGenericMessage() {
        let coordinator = makeCoordinator()
        let empty = NotePreview()

        XCTAssertTrue(empty.isEmpty)
        coordinator.applyGenerationProgress(.generating(preview: empty))

        // Which generic message is shown depends on whether a model happens to be installed on the
        // machine running the tests, so the stable assertion is that the banner did *not* claim to
        // be writing anything yet.
        XCTAssertFalse(coordinator.statusMessage.isEmpty)
        XCTAssertNotEqual(coordinator.statusMessage, String(localized: "Writing the note…"))
    }

    func testFinishingSaysTheNoteIsBeingSaved() {
        let coordinator = makeCoordinator()

        coordinator.applyGenerationProgress(.finishing)

        XCTAssertEqual(coordinator.generationProgress, .finishing)
        XCTAssertEqual(coordinator.statusMessage, String(localized: "Saving note…"))
    }

    /// §22's counterweight in the UI: the phases must be able to progress *forwards*. A banner that
    /// fell back from "writing" to "preparing" would look like the work restarted.
    func testTheBannerOnlyEverMovesForward() {
        let coordinator = makeCoordinator()
        let preview = NotePreview(title: "T", summary: "s")

        coordinator.applyGenerationProgress(.preparingEngine(engineName: "Qwen3 0.6B"))
        let preparing = coordinator.statusMessage
        coordinator.applyGenerationProgress(.generating(preview: preview))
        let writing = coordinator.statusMessage
        coordinator.applyGenerationProgress(.finishing)
        let saving = coordinator.statusMessage

        XCTAssertEqual([preparing, writing, saving],
                       [String(localized: "Preparing the on-device model…"),
                        String(localized: "Writing the note…"),
                        String(localized: "Saving note…")])
        // The three must also be visually distinct, or the banner would appear frozen even though
        // the phase underneath was advancing.
        XCTAssertEqual(Set([preparing, writing, saving]).count, 3)
    }

    /// The progress detail is live-only: a stale preview must never linger on the banner after the
    /// capture that produced it has finished.
    func testProgressIsClearedWhenNothingIsRunning() async throws {
        let (store, root) = try makeVault()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let coordinator = CaptureCoordinator(store: store,
                                             clipboardService: QuietClipboard(),
                                             noteGenerator: LocalLiteNoteProvider())

        try await withLocalModeDefaults {
            await coordinator.captureText("在 SwiftUI 里使用 Vision 做 OCR，完全在设备上完成。")
        }

        XCTAssertEqual(coordinator.state, .completed)
        XCTAssertNil(coordinator.generationProgress,
                     "a finished capture must not leave preview text on the banner")
    }

    private func makeVault() throws -> (VaultStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestBanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        store.openVault(at: root)
        return (store, root)
    }
}
