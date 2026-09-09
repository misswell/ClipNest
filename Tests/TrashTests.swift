import XCTest
@testable import ClipNest

/// The in-vault recycle bin: delete moves items into `.trash` with a manifest,
/// restore puts them back, purge removes them for good.
@MainActor
final class TrashTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore()
        store.openVault(at: root)
    }

    override func tearDownWithError() throws {
        store.closeVault()
        try? FileManager.default.removeItem(at: root)
    }

    private func writeNote(_ name: String, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testDeleteMovesFileIntoTrashWithManifest() throws {
        let file = try writeNote("笔记.md", content: "# 重要内容")

        store.delete(file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let entries = store.trashEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.displayName, "笔记.md")
        XCTAssertEqual(entries.first?.originalRelativePath, "笔记.md")
        let trashedFile = VaultTrash.directoryURL(in: root).appendingPathComponent(entries[0].id)
        XCTAssertEqual(try String(contentsOf: trashedFile, encoding: .utf8), "# 重要内容")
    }

    func testRestorePutsFileBackToOriginalLocation() throws {
        let file = try writeNote("restore-me.md", content: "正文")

        store.delete(file)
        XCTAssertEqual(store.trashEntries().count, 1)
        store.restoreFromTrash(store.trashEntries()[0])

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "正文")
        XCTAssertEqual(store.trashEntries().count, 0)
    }

    func testRestoreAvoidsCollisionWithNewFile() throws {
        let file = try writeNote("note.md", content: "old version")
        store.delete(file)
        try Data("new version".utf8).write(to: file)

        store.restoreFromTrash(store.trashEntries()[0])

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new version")
        let restored = root.appendingPathComponent("note 2.md")
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), "old version")
        XCTAssertEqual(store.trashEntries().count, 0)
    }

    func testPurgeRemovesTrashedFilePermanently() throws {
        let file = try writeNote("gone.md", content: "bye")
        store.delete(file)
        let entry = store.trashEntries()[0]

        store.purgeFromTrash(entry)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VaultTrash.directoryURL(in: root).appendingPathComponent(entry.id).path))
        XCTAssertEqual(store.trashEntries().count, 0)
    }

    func testPurgeAllEmptiesTrash() throws {
        store.delete(try writeNote("a.md", content: "1"))
        store.delete(try writeNote("b.md", content: "2"))

        store.purgeAllTrash()

        XCTAssertEqual(store.trashEntries().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultTrash.directoryURL(in: root).path.appending("/manifest.json")))
    }

    func testDeleteMovesFolderWithContents() throws {
        let folder = root.appendingPathComponent("项目", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inside.md"))

        store.delete(folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let entries = store.trashEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isDirectory)

        store.restoreFromTrash(entries[0])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.md"), encoding: .utf8), "x")
    }

    func testPurgeOlderThanDropsExpiredEntries() throws {
        let file = try writeNote("old.md", content: "old")
        store.delete(file)
        var entries = VaultTrash.loadManifest(in: root)
        entries[0] = TrashEntry(id: entries[0].id,
                                originalRelativePath: entries[0].originalRelativePath,
                                displayName: entries[0].displayName,
                                isDirectory: entries[0].isDirectory,
                                deletedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60))
        VaultTrash.saveManifest(entries, in: root)

        VaultTrash.purgeOlderThan(Date().addingTimeInterval(-VaultTrash.autoPurgeInterval), in: root)

        XCTAssertEqual(VaultTrash.loadManifest(in: root).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VaultTrash.directoryURL(in: root).appendingPathComponent(entries[0].id).path))
        // The original location stays untouched — expired trash is gone for good.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTrashFolderIsHiddenFromExplorerEvenWithHiddenFilesShown() {
        let file = root.appendingPathComponent("visible.md")
        try? Data("x".utf8).write(to: file)
        store.delete(file)
        store.showHiddenFiles = true
        store.refresh()

        let names = (store.rootNode?.children ?? []).map(\.name)
        XCTAssertFalse(names.contains(VaultTrash.directoryName))
    }
}
