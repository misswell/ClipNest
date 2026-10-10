import XCTest
@testable import ClipNest

@MainActor
final class DocumentManagementTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore()
        store.openVault(at: root)
    }

    override func tearDownWithError() throws {
        store.closeVault()
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ name: String, body: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        store.refresh()
        return url
    }

    func testRenamePreservesExtensionAndFollowsSelectedDescendant() throws {
        let file = try note("Folder/Note.md")
        store.selectedFileURL = file
        let folder = file.deletingLastPathComponent()
        let renamed = try XCTUnwrap(store.rename(folder, to: "New Folder"))
        let expected = renamed.appendingPathComponent("Note.md")
        XCTAssertEqual(store.selectedFileURL, expected)
        XCTAssertEqual(store.lastDocumentMove?.relocated(file), expected)
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), "original")
        let renamedFile = try XCTUnwrap(store.rename(expected, to: "New title"))
        XCTAssertEqual(renamedFile.lastPathComponent, "New title.md")
        XCTAssertEqual(store.selectedFileURL, renamedFile)
    }

    func testRenameCollisionKeepsBothDocumentsAndSelection() throws {
        let first = try note("A.md", body: "first")
        let second = try note("B.md", body: "second")
        store.selectedFileURL = first
        XCTAssertNil(store.rename(first, to: "B.md"))
        XCTAssertNotNil(store.operationError)
        XCTAssertEqual(store.selectedFileURL, first)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertEqual(store.rename(first, to: "A.md"), first)
    }

    func testNamesCannotEscapeTheVaultOrHideANote() throws {
        let file = try note("Original.md")
        for invalid in ["../outside", "nested/path", ".hidden", "..", "bad\nname", "a:b", "a\\b"] {
            XCTAssertNil(store.rename(file, to: invalid), invalid)
            XCTAssertNil(store.createFile(named: invalid), invalid)
            XCTAssertNil(store.createFolder(named: invalid), invalid)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.rename(root, to: "Changed vault"))
        XCTAssertFalse(store.delete(root))
    }

    func testSaveQueuedBeforeRenameFollowsTheNewPath() async throws {
        let file = try note("Old.md")
        store.save("pending edit", to: file)
        let destination = try XCTUnwrap(store.rename(file, to: "New"))
        try await waitForBody("pending edit", at: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLateSaveFollowsMultipleDirectoryAndFileRenames() async throws {
        let file = try note("Folder/Old.md")
        let renamedFolder = try XCTUnwrap(store.rename(file.deletingLastPathComponent(), to: "Renamed"))
        let destination = try XCTUnwrap(store.rename(renamedFolder.appendingPathComponent("Old.md"), to: "New"))
        store.save("latest edit", to: file)
        try await waitForBody("latest edit", at: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSaveQueuedBeforeDeleteCannotRecreateTheNote() async throws {
        let file = try note("Deleted.md")
        store.selectedFileURL = file
        store.save("pending edit", to: file)
        XCTAssertTrue(store.delete(file))
        // The storage actor is reached after the main-actor save task has started.
        await Task.yield()
        _ = try await VaultFileAccess.shared.writeExistingText("late edit", to: file, revision: UInt64.max)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.selectedFileURL)
        XCTAssertEqual(store.trashEntries().count, 1)
    }

    func testQueuedEditDoesNotOverwriteANewNoteReusingTheOldName() async throws {
        let original = try note("Original.md")
        store.save("edited original", to: original)
        let renamed = try XCTUnwrap(store.rename(original, to: "Renamed"))
        let newNote = try XCTUnwrap(store.createFile(named: "Original.md"))
        try await waitForBody("edited original", at: renamed)
        XCTAssertEqual(try String(contentsOf: newNote, encoding: .utf8), "# Original\n\n")
    }

    func testFailedTrashKeepsDocumentAndSelection() throws {
        let file = try note("Safe.md")
        // A regular file at .trash prevents creation of the recycle-bin directory.
        try "blocker".write(to: root.appendingPathComponent(".trash"), atomically: true, encoding: .utf8)
        store.selectedFileURL = file
        XCTAssertFalse(store.delete(file))
        XCTAssertEqual(store.selectedFileURL, file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertNotNil(store.operationError)
    }

    func testDeletingAFolderClearsTheSelectedDescendant() throws {
        let file = try note("Folder/Note.md")
        store.selectedFileURL = file
        XCTAssertTrue(store.delete(file.deletingLastPathComponent()))
        XCTAssertNil(store.selectedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testManifestWriteFailureRollsDeletionBack() throws {
        let file = try note("Keep.md")
        let manifest = VaultTrash.manifestURL(in: root)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        store.selectedFileURL = file
        XCTAssertFalse(store.delete(file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertEqual(store.selectedFileURL, file)
        XCTAssertNotNil(store.operationError)
    }

    func testInvalidTrashPathsCannotRestoreOrPurgeOutsideTheVault() throws {
        let entry = TrashEntry(id: "../outside", originalRelativePath: "../outside.md",
                               displayName: "Invalid", isDirectory: false, deletedAt: Date())
        XCTAssertThrowsError(try VaultTrash.restore(entry, in: root))
        XCTAssertThrowsError(try VaultTrash.purge(entry, in: root))
    }

    func testAutosaveNotifiesSearchAfterBytesAreWritten() async throws {
        let file = try note("Indexed.md")
        let event = expectation(description: "Search receives saved path")
        let token = NotificationCenter.default.addObserver(forName: .vaultFilesDidChange, object: store, queue: nil) { info in
            let paths = info.userInfo?["paths"] as? [String] ?? []
            if paths.contains(file.path), (try? String(contentsOf: file, encoding: .utf8)) == "new searchable body" {
                event.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.save("new searchable body", to: file)
        await fulfillment(of: [event], timeout: 5)
    }

    func testCheckboxToggleMatchesPreviewAndKeepsExamplesUntouched() {
        let body = "```md\n- [ ] code example\n```\n\n> - [ ] quoted example\n\n- [ ] first\n  - [X] second\n"
        let first = MarkdownParser.togglingCheckbox(at: 0, in: body)
        XCTAssertEqual(first, body.replacingOccurrences(of: "- [ ] first", with: "- [x] first"))
        XCTAssertEqual(MarkdownParser.togglingCheckbox(at: 1, in: body),
                       body.replacingOccurrences(of: "- [X] second", with: "- [ ] second"))
        XCTAssertNil(MarkdownParser.togglingCheckbox(at: 2, in: body))
    }

    func testCancelledIndexPassDoesNotDeleteUnvisitedFiles() async throws {
        _ = try note("Indexed.md", body: "# Retained\nsearchable body")
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("Index-\(UUID().uuidString).sqlite")
        let database = try SearchDatabase(url: dbURL)
        defer { database.close(); try? FileManager.default.removeItem(at: dbURL) }
        let indexer = LocalSearchIndexer(vaultRoot: root, database: database, semanticSearchEnabled: false)
        _ = await indexer.indexVault()
        let count = database.chunkCount()
        XCTAssertGreaterThan(count, 0)
        let task = Task { await indexer.indexVault() }
        task.cancel()
        _ = await task.value
        XCTAssertEqual(database.chunkCount(), count)
    }

    func testSwitchingVaultDuringIndexingCanIndexTheNewVault() async throws {
        _ = try note("Old.md", body: "old vault")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "# Newvaultunique\nnew vault body".write(to: other.appendingPathComponent("New.md"), atomically: true, encoding: .utf8)
        let controller = LocalSearchController()
        defer {
            controller.attach(vaultRoot: nil)
            for vault in [root!, other] {
                let db = LocalSearchController.databaseURL(for: vault)
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
            }
        }
        controller.attach(vaultRoot: root)
        controller.rebuild()
        XCTAssertTrue(controller.isIndexing)
        controller.attach(vaultRoot: other)
        controller.rebuild()
        let deadline = Date().addingTimeInterval(5)
        while controller.isIndexing, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isIndexing)
        XCTAssertFalse(controller.keywordResults(for: "Newvaultunique").isEmpty)
    }

    #if os(macOS)
    func testShellArgumentsKeepSubstitutionSyntaxLiteral() throws {
        let text = "quote' double\" $HOME $(printf expanded) `printf expanded` \\ slash\nsecond line"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "printf %s " + ShellArgument.quote(text)]
        let output = Pipe()
        task.standardOutput = output
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), text)
    }

    func testWikiInitializationPreservesExistingContentAndReportsFailure() throws {
        let schema = try note("CLAUDE.md", body: "User schema")
        try WikiService.initialize(root)
        XCTAssertEqual(try String(contentsOf: schema, encoding: .utf8), "User schema")
        XCTAssertTrue(WikiService.isInitialized(root))
        let blocked = root.appendingPathComponent("Blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "blocker".write(to: blocked.appendingPathComponent("wiki"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WikiService.initialize(blocked))
        XCTAssertFalse(WikiService.isInitialized(blocked))
    }
    #endif

    func testRecentMoveFoldersKeepNewestFirstWithoutDuplicates() {
        let key = ClipNestSettings.recentMoveFolders
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        let top = root.appendingPathComponent("工作")
        let nested = top.appendingPathComponent("2026")
        RecentMoveFolders.record(top)
        RecentMoveFolders.record(nested)
        RecentMoveFolders.record(top)

        XCTAssertEqual(RecentMoveFolders.paths(
            in: UserDefaults.standard.string(forKey: key) ?? ""),
            [top.standardizedFileURL.path, nested.standardizedFileURL.path])
    }

    private func waitForBody(_ body: String, at url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? String(contentsOf: url, encoding: .utf8)) == body { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The pending edit was not saved at the new path")
    }
}
