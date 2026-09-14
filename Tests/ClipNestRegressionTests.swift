import Foundation
import XCTest
@testable import ClipNest

/// Regression coverage for the fixes in this round:
/// * opening a note always starts in Preview (`NoteOpenIntent`),
/// * vault reads/writes go through one coordinated, iCloud-aware layer,
/// * a document read failure surfaces an error instead of an empty document,
/// * the app's own autosave no longer looks like an external vault change.
final class ClipNestRegressionTests: XCTestCase {

    // MARK: - Navigation intent

    func testNewNotesOpenInPreviewUnlessEditWasExplicitlyRequested() {
        XCTAssertEqual(NoteOpenIntent.view.initialMode, .preview,
                       "Tapping a note must open the detail/preview, never the raw editor")
        XCTAssertEqual(NoteOpenIntent.edit.initialMode, .edit)
    }

    // MARK: - VaultFileAccess

    func testVaultFileAccessRoundTripsUnicodeAndLargeDocuments() async throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = VaultFileAccess()

        // Chinese, emoji and Latin accents survive the coordinated UTF-8 path.
        let unicode = "# 标题\n\n中文正文 🎉 émoji çedilla\n\n- [ ] 任务\n"
        let unicodeURL = root.appendingPathComponent("中文 笔记.md")
        try await access.write(Data(unicode.utf8), to: unicodeURL, revision: 1)
        let readUnicode = try await access.readText(at: unicodeURL)
        XCTAssertEqual(readUnicode, unicode)

        // A document past the progressive-hydration threshold round-trips byte for byte.
        let large = String(repeating: "# 大文件 😀 heading line\n", count: 30_000)
        XCTAssertGreaterThan(large.utf8.count, 256 * 1024,
                             "Guard the threshold the editor switches hydration strategy at")
        let largeURL = root.appendingPathComponent("large.md")
        try await access.write(Data(large.utf8), to: largeURL, revision: 1)
        let readLarge = try await access.readText(at: largeURL)
        XCTAssertEqual(readLarge, large)
    }

    func testOlderWriteRevisionCannotOverwriteANewerOne() async throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = VaultFileAccess()
        let url = root.appendingPathComponent("Note.md")

        try await access.write(Data("first".utf8), to: url, revision: 1)
        try await access.write(Data("second".utf8), to: url, revision: 2)
        // A late-finishing debounced save from an older revision must be dropped.
        try await access.write(Data("stale".utf8), to: url, revision: 1)

        let finalText = try await access.readText(at: url)
        XCTAssertEqual(finalText, "second")
    }

    func testUnreadableDocumentThrowsInsteadOfReturningEmptyText() async throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("does-not-exist.md")

        do {
            let text = try await VaultFileAccess.shared.readText(at: missing)
            XCTFail("Expected a read failure, got \(text.count) characters")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
            XCTAssertFalse(message?.isEmpty ?? true,
                           "The editor shows this message, so it must never be empty")
        }
    }

    // MARK: - Save / snapshot ordering

    @MainActor
    func testSelfWritePersistsAndMovesTheNoteToTheTopOfTheHomeSnapshot() async throws {
        let root = Self.makeTemporaryVault()
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        let oldest = root.appendingPathComponent("Oldest.md")
        let middle = root.appendingPathComponent("Middle.md")
        let newest = root.appendingPathComponent("Newest.md")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, url) in [oldest, middle, newest].enumerated() {
            try Data("# \(url.lastPathComponent)\n".utf8).write(to: url)
            try Self.setModificationDate(base.addingTimeInterval(TimeInterval(offset * 60)),
                                         for: url)
        }

        store.openVault(at: root)
        try await Self.waitForSnapshot(store)

        XCTAssertEqual(store.homeSnapshot.markdownFiles.first?.lastPathComponent, "Newest.md")

        store.save("updated body", to: oldest)
        // The in-memory snapshot reorders synchronously; the disk write is detached.
        XCTAssertEqual(store.homeSnapshot.markdownFiles.first?.lastPathComponent, "Oldest.md",
                       "A saved note must become the most recent note without a full vault refresh")

        try await Task.sleep(nanoseconds: 400_000_000)
        let written = try await store.loadText(oldest)
        XCTAssertEqual(written, "updated body")
        XCTAssertEqual(store.homeSnapshot.markdownFiles.count, 3,
                       "The cheap reorder must not drop or duplicate notes")
    }

    // MARK: - FSEvents self-write filtering

    /// The self-write filter must not blind the watcher: a note created by an agent, git or
    /// the terminal still has to appear. This drives the real FSEvents callback, which also
    /// covers the `kFSEventStreamCreateFlagUseCFTypes` path decoding.
    @MainActor
    func testExternalFileChangeStillRefreshesTheVault() async throws {
        let root = Self.makeTemporaryVault()
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }

        try Data("# A\n".utf8).write(to: root.appendingPathComponent("A.md"))
        store.openVault(at: root)
        try await Self.waitForSnapshot(store)
        XCTAssertEqual(store.homeSnapshot.markdownFiles.count, 1)

        try Data("# B\n".utf8).write(to: root.appendingPathComponent("B.md"))

        let deadline = Date().addingTimeInterval(10)
        while store.homeSnapshot.markdownFiles.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(store.homeSnapshot.markdownFiles.count, 2,
                       "An externally created note must still refresh the vault")
    }

    func testWriteEventFilterDropsTheAppsOwnWrites() {
        var filter = VaultWriteEventFilter()
        let note = URL(fileURLWithPath: "/tmp/vault/Note.md")
        filter.noteWrite(to: note)

        XCTAssertTrue(filter.isSelfWriteNoise(paths: [note.path], fileExists: { _ in true }),
                      "Our own autosave must not trigger a full vault refresh")

        // The atomic write's scratch file lives beside the note and is already renamed away.
        let scratch = "/tmp/vault/.dat.nosync-9F2A"
        XCTAssertTrue(filter.isSelfWriteNoise(paths: [scratch], fileExists: { _ in false }))
    }

    func testWriteEventFilterKeepsExternalChangesAndBatches() {
        var filter = VaultWriteEventFilter()
        filter.noteWrite(to: URL(fileURLWithPath: "/tmp/vault/Note.md"))

        XCTAssertFalse(filter.isSelfWriteNoise(paths: ["/tmp/vault/Other.md"],
                                              fileExists: { _ in true }),
                       "An external edit must still refresh the vault")
        XCTAssertFalse(filter.isSelfWriteNoise(paths: ["/tmp/vault/New.md"],
                                              fileExists: { _ in true }),
                       "An externally created note must still appear")
        XCTAssertFalse(filter.isSelfWriteNoise(paths: [], fileExists: { _ in true }),
                       "An empty batch is not evidence of a self-write")
        XCTAssertFalse(filter.isSelfWriteNoise(paths: ["/tmp/other/.hidden"],
                                              fileExists: { _ in false }),
                       "A hidden file outside the written directory is external")
    }

    func testWriteEventFilterForgetsWritesOutsideItsWindow() {
        var filter = VaultWriteEventFilter()
        let note = URL(fileURLWithPath: "/tmp/vault/Note.md")
        let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        filter.noteWrite(to: note, at: writtenAt)

        let later = writtenAt.addingTimeInterval(VaultWriteEventFilter.defaultWindow + 1)
        XCTAssertFalse(filter.isSelfWriteNoise(paths: [note.path],
                                              now: later,
                                              fileExists: { _ in true }),
                       "A delayed event must not be swallowed forever")
    }

    // MARK: - Metadata cache

    func testMetadataCacheDefersToDiskOnlyAfterInvalidation() throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try Data("one".utf8).write(to: file)

        let cache = VaultMetadataCache(ttl: 60)
        let first = cache.modificationDate(for: file)

        let bumped = Date(timeIntervalSince1970: 1_800_000_000)
        try Self.setModificationDate(bumped, for: file)

        XCTAssertEqual(cache.modificationDate(for: file), first,
                       "Within the TTL the cached metadata must be reused without a stat")

        cache.invalidate(paths: [file.path])
        XCTAssertEqual(cache.modificationDate(for: file).timeIntervalSince1970,
                       bumped.timeIntervalSince1970,
                       accuracy: 1.0,
                       "An event for this path must force a re-read")
    }

    // MARK: - Obsidian vault discovery

    func testObsidianLocatorFindsVaultsAndSkipsPlainFolders() throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        for name in ["Work Vault", "Journal"] {
            let vault = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: vault.appendingPathComponent(".obsidian", isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        // A folder of Markdown that was never opened in Obsidian has no marker.
        try fm.createDirectory(at: root.appendingPathComponent("Plain Notes", isDirectory: true),
                               withIntermediateDirectories: true)
        // A *file* named `.obsidian` must not be mistaken for the marker folder.
        let impostor = root.appendingPathComponent("Fake", isDirectory: true)
        try fm.createDirectory(at: impostor, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: impostor.appendingPathComponent(".obsidian"))

        let found = ObsidianVaultLocator.discoverVaults(roots: [root])
        XCTAssertEqual(Set(found.map(\.name)), ["Work Vault", "Journal"],
                       "Only folders carrying a .obsidian directory are vaults")
        XCTAssertTrue(found.allSatisfy { !$0.isICloudDrive })
    }

    func testObsidianLocatorKeepsPreviouslyOpenedVaultsAndDeduplicates() throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // Mirrors the real layout inside Obsidian's iCloud container.
        let container = root.appendingPathComponent("iCloud~md~obsidian/Documents", isDirectory: true)
        let opened = container.appendingPathComponent("Second Brain", isDirectory: true)
        try fm.createDirectory(at: opened.appendingPathComponent(".obsidian", isDirectory: true),
                               withIntermediateDirectories: true)
        let neighbour = container.appendingPathComponent("Research", isDirectory: true)
        try fm.createDirectory(at: neighbour.appendingPathComponent(".obsidian", isDirectory: true),
                               withIntermediateDirectories: true)

        // Nothing is discoverable on its own (this is the iOS sandbox case), but a vault the
        // user already opened still shows up — and its container is scanned for siblings.
        let found = ObsidianVaultLocator.discoverVaults(includingRecent: [opened], roots: [])
        XCTAssertEqual(Set(found.map(\.name)), ["Second Brain", "Research"])
        XCTAssertEqual(found.count, 2, "The recent vault must not be listed twice")
        XCTAssertTrue(found.allSatisfy(\.isICloudDrive))

        XCTAssertTrue(ObsidianVaultLocator.looksLikeObsidianLocation(opened))
        XCTAssertFalse(ObsidianVaultLocator.looksLikeObsidianLocation(root.appendingPathComponent("Notes")))
    }

    func testObsidianLocatorStopsAtTheLimit() throws {
        let root = Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            let vault = root.appendingPathComponent("Vault \(index)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent(ObsidianVaultLocator.vaultMarkerName, isDirectory: true),
                withIntermediateDirectories: true)
        }
        XCTAssertEqual(ObsidianVaultLocator.discoverVaults(roots: [root], limit: 3).count, 3)
    }

    // MARK: - Helpers

    private static func makeTemporaryVault() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipNestRegression-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `FileManager.setAttributes` silently ignores `.modificationDate` on this platform;
    /// `URL.setResourceValues` is the supported path.
    private static func setModificationDate(_ date: Date, for url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.contentModificationDate = date
        try target.setResourceValues(values)
    }

    @MainActor
    private static func waitForSnapshot(_ store: VaultStore,
                                        timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isTreeLoading || store.isHomeSnapshotLoading {
            XCTAssertLessThan(Date(), deadline, "Vault snapshot did not settle in time")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
