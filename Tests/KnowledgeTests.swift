import XCTest
@testable import ClipNest

@MainActor
final class KnowledgeTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Knowledge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore()
        store.openVault(at: root)
    }

    override func tearDownWithError() throws {
        store.closeVault()
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult private func note(_ path: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFileAccess.createText(text, at: url)
        store.refresh()
        return url
    }

    func testLinkParsingSkipsFencesInlineCodeCommentsAndEscapes() {
        let text = "[[有效😀#标题|显示]] [Local](folder/Local%20note.md#Part) ![[a.png|100]]\n`[[inline]]`\n~~~swift\n[[fenced]]\n~~~\n<!-- [[comment]] --> %%[[hidden]]%% \\[[escaped]]"
        let links = MarkdownKnowledge.links(in: text)
        XCTAssertEqual(links.map(\.target), ["有效😀#标题", "folder/Local%20note.md#Part", "a.png"])
        XCTAssertEqual(links.first?.label, "显示")
        XCTAssertTrue(links.last!.isEmbed)
        XCTAssertEqual((text as NSString).substring(with: links[0].targetRange), "有效😀#标题")
    }

    func testPropertiesAliasesTagsOutlineAndFrontmatterPreserveBody() {
        let text = "---\naliases: [\"Hello, world\", 别名]\ntags:\n  - project/mobile\n  - idea\ncustom: true\n---\n# 标题\n\nText #inline `#ignored`\n```\n# fake\n```\n## Detail\n"
        let info = MarkdownKnowledge.analyze(text, url: root.appendingPathComponent("A.md"))
        XCTAssertEqual(info.aliases, ["Hello, world", "别名"])
        XCTAssertEqual(info.tags, ["idea", "inline", "project/mobile"])
        XCTAssertEqual(info.headings.map(\.title), ["标题", "Detail"])
        XCTAssertEqual(info.properties["custom"], "true")
        XCTAssertEqual(MarkdownKnowledge.body(text), "# 标题\n\nText #inline `#ignored`\n```\n# fake\n```\n## Detail\n")
        XCTAssertEqual(MarkdownParser.parse(text).count, 4)
    }

    func testResolutionPrefersLocalFileAndRejectsAmbiguousAndOutsideNames() throws {
        let doc = try note("folder/Doc.md")
        let local = try note("folder/Target.md")
        let other = try note("other/Target.md")
        let files = [doc, local, other]
        XCTAssertEqual(MarkdownKnowledge.resolve("Target#Heading", from: doc, root: root, files: files), local)
        XCTAssertNil(MarkdownKnowledge.resolve("Target", from: root.appendingPathComponent("Root.md"), root: root, files: files))
        XCTAssertEqual(MarkdownKnowledge.resolve("other/Target", from: doc, root: root, files: files), other)
        XCTAssertNil(MarkdownKnowledge.resolve("../../outside.md", from: doc, root: root, files: files))
        XCTAssertNil(MarkdownKnowledge.resolve("https://example.org", from: doc, root: root, files: files))
        XCTAssertEqual(MarkdownKnowledge.resolve("别名", from: doc, root: root, files: files, aliases: ["别名": [other]]), other)
    }

    func testOpeningAliasBeforeVisitingKnowledgeHub() async throws {
        let doc = try note("Doc.md", "[[别名]]")
        let target = try note("Other.md", "---\n'aliases': ['别名']\n---\nBody")
        let result = await store.resolveNote("别名", from: doc)
        XCTAssertEqual(result, target)
    }

    func testRenameUpdatesIncomingLinksAndPreservesAliasAnchorAndCodeExamples() throws {
        let target = try note("Target.md", "# Section")
        let other = try note("other/链接.md", "[[Target#Section|别名]]\n[Label](../Target.md#Section)\n`[[Target]]`\n````\n[[Target]]\n````")
        let renamed = try XCTUnwrap(store.rename(target, to: "新 标题"))
        XCTAssertEqual(renamed.lastPathComponent, "新 标题.md")
        let updated = try VaultFileAccess.readDataImmediately(at: other)
        XCTAssertEqual(String(decoding: updated, as: UTF8.self), "[[新 标题#Section|别名]]\n[Label](../%E6%96%B0%20%E6%A0%87%E9%A2%98.md#Section)\n`[[Target]]`\n````\n[[Target]]\n````")
        XCTAssertEqual(try VaultHistory.versions(for: other, root: root).count, 1)
    }

    func testMovingNoteRebasesImagesAndOutgoingLinksWithoutChangingExternalURLs() throws {
        let image = root.appendingPathComponent("Attachments/photo.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: image)
        _ = try note("Related.md")
        let source = try note("Inbox/Note.md", "![image](../Attachments/photo.png)\n[Related](../Related.md)\n[[Related]]\n[web](https://example.org/a)")
        let folder = root.appendingPathComponent("deep/nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(store.moveDocument(source, to: folder))
        let updated = String(decoding: try VaultFileAccess.readDataImmediately(at: destination), as: UTF8.self)
        XCTAssertEqual(updated, "![image](../../Attachments/photo.png)\n[Related](../../Related.md)\n[[Related]]\n[web](https://example.org/a)")
    }

    func testRenameAbortsBeforeChangingFilesIfRewrittenYAMLWouldBeInvalid() throws {
        let source = try note("Target.md", "# Target")
        let text = "---\nrelated: '[[Target]]'\n---\nBody"
        let reference = try note("Reference.md", text)
        XCTAssertNil(store.rename(source, to: "Quoted'Name"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quoted'Name.md").path))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: reference), as: UTF8.self), text)
    }

    func testFolderRenameUpdatesChildrenAndIncomingReferences() async throws {
        let child = try note("Old/Child.md")
        let incoming = try note("Ref.md", "[[Old/Child]]")
        let renamed = await store.renameWithLinks(child.deletingLastPathComponent(), to: "New")
        let destination = try XCTUnwrap(renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Child.md").path))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: incoming), as: UTF8.self), "[[New/Child]]")
    }

    func testInvalidNoteAbortsRenameBeforeAnyFileChanges() throws {
        let source = try note("Source.md", "original")
        try Data([0xFF]).write(to: root.appendingPathComponent("Invalid.md"))
        XCTAssertNil(store.rename(source, to: "Destination"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Destination.md").path))
    }

    func testLinkRenderingPreservesRealMarkdownLinksAndUnicodeAliases() throws {
        let result = MarkdownKnowledge.renderInline("**Bold** [[笔记#段落|别名😀]] [web](https://example.org)")
        XCTAssertEqual(String(result.characters), "Bold 别名😀 web")
        let urls = result.runs.compactMap { $0.link }
        XCTAssertTrue(urls.contains { MarkdownKnowledge.navigationTarget($0) == "笔记#段落" })
        XCTAssertTrue(urls.contains { $0.absoluteString == "https://example.org" })
    }

    func testTemplateExpansionAndPropertyMergeDoNotOverwriteUserFields() throws {
        let template = "---\ntags: [template]\nstatus: draft\n---\n# {{title}}\n{{date:yyyy}} {{unknown}}"
        let expanded = NoteTemplate.expand(template, title: "标题", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(expanded.contains("# 标题\n1970 {{unknown}}"))
        let text = "---\ntags: [mine]\ncustom:\n  nested: value\n---\nMy body\n"
        let inserted = TemplateInsertion.insert(expanded, into: text)
        XCTAssertEqual(MarkdownKnowledge.properties(in: inserted)["tags"], "[mine]")
        XCTAssertEqual(MarkdownKnowledge.properties(in: inserted)["status"], "draft")
        XCTAssertTrue(inserted.contains("custom:\n  nested: value"))
        XCTAssertTrue(MarkdownKnowledge.body(inserted).hasPrefix("My body\n"))
        XCTAssertThrowsError(try TemplateInsertion.replacingProperties(in: text, yaml: "---\ninvalid"))
        XCTAssertEqual(try TemplateInsertion.replacingProperties(in: text, yaml: "aliases: [new]"), "---\naliases: [new]\n---\nMy body\n")
    }

    func testSearchSupportsQuotedTermsExclusionsNestedTagsPathsAndProperties() {
        let url = root.appendingPathComponent("Projects/Test.md")
        let note = MarkdownKnowledge.analyze("---\ntags: [project/mobile]\nstatus: active\n---\nSome long phrase", url: url)
        XCTAssertTrue(NoteSearchQuery.matches("tag:project path:Projects property:status=active \"long phrase\" -file:Other", note: note, root: root))
        XCTAssertFalse(NoteSearchQuery.matches("-tag:project", note: note, root: root))
        XCTAssertFalse(NoteSearchQuery.matches("property:status=finished", note: note, root: root))
    }

    func testOpenOrCreateExistingNoteDoesNotOverwriteAndRejectsSymlinkEscapes() throws {
        let existing = try note("Existing.md", "keep")
        XCTAssertEqual(store.openOrCreateNote(path: "Existing", text: "replace"), existing)
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: existing), as: UTF8.self), "keep")
        XCTAssertNil(store.openOrCreateNote(path: "../Escape"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertNil(store.openOrCreateNote(path: "Escape/Escaped-" + UUID().uuidString))
    }

    func testHistoryDeduplicatesAndCapsVersionsAndSurvivesRename() throws {
        let source = try note("Source.md", "current")
        for i in 0..<55 { try VaultHistory.record("Version \(i)", for: source, root: root) }
        try VaultHistory.record("Version 54", for: source, root: root)
        let versions = try VaultHistory.versions(for: source, root: root)
        XCTAssertEqual(versions.count, 50)
        XCTAssertEqual(versions.first?.text, "Version 54")
        let destination = try XCTUnwrap(store.rename(source, to: "Moved"))
        XCTAssertEqual(try VaultHistory.versions(for: destination, root: root).count, 50)
    }

    func testIndexBacklinksAliasBookmarksAndVaultSwitchIsolation() async throws {
        let target = try note("Target.md", "---\naliases: [别名]\n---\n# Title")
        let incoming = try note("Incoming.md", "[[别名]]")
        let index = VaultKnowledgeIndex()
        index.attach(root)
        index.ensureLoaded()
        for _ in 0..<100 { if !index.isLoading { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(index.backlinks(to: target).map(\.url), [incoming])
        index.toggleBookmark(target)
        XCTAssertTrue(index.isBookmarked(target))
        index.relocateBookmarks(.init(source: target, destination: root.appendingPathComponent("New.md")))
        XCTAssertTrue(index.isBookmarked(root.appendingPathComponent("New.md")))
        index.attach(nil)
        XCTAssertTrue(index.notes.isEmpty)
        XCTAssertTrue(index.bookmarks.isEmpty)
        XCTAssertFalse(index.isLoading)
    }

    func testEmbedsSelectHeadingOrBlockWithoutIncludingNextSection() {
        let text = "# First\nA paragraph ^abc\n\n## Sub\nText\n# Second\nOther"
        XCTAssertEqual(NoteEmbedView.fragment("First", in: text), "# First\nA paragraph ^abc\n\n## Sub\nText")
        XCTAssertEqual(NoteEmbedView.fragment("^abc", in: text), "# First\nA paragraph")
    }

    func testCanvasRoundTripRetainsUnknownFieldsAndEditsCardsAndEdges() throws {
        var canvas = try JSONCanvasDocument(text: "{\"plugin\":{\"enabled\":true},\"nodes\":[{\"id\":\"a\",\"type\":\"text\",\"x\":-50,\"y\":0,\"width\":250,\"height\":180,\"text\":\"A\",\"custom\":7}],\"edges\":[]}")
        canvas.add(type: "group", content: "Group", x: 50, y: 100)
        let group = canvas.nodes[1].id
        canvas.connect(from: "a", to: group)
        canvas.update("a", values: ["text": .string("Edited")])
        let roundtrip = try JSONCanvasDocument(text: canvas.text())
        XCTAssertEqual(roundtrip.data["plugin"]?.object?["enabled"], .bool(true))
        XCTAssertEqual(roundtrip.nodes[0].data["custom"], .number(7))
        XCTAssertEqual(roundtrip.nodes[0].content, "Edited")
        XCTAssertEqual(roundtrip.edges.count, 1)
        canvas.remove(group)
        XCTAssertEqual(canvas.nodes.count, 1)
        XCTAssertTrue(canvas.edges.isEmpty)
    }

    func testCanvasReferencesFollowNoteRenameWithoutLosingMetadata() throws {
        let source = try note("Source.md")
        let canvasURL = try note("Board.canvas", "{\"custom\":42,\"nodes\":[{\"id\":\"a\",\"type\":\"file\",\"x\":0,\"y\":0,\"width\":250,\"height\":180,\"file\":\"Source.md\",\"subpath\":\"#Heading\"}],\"edges\":[]}")
        XCTAssertNotNil(store.rename(source, to: "Destination"))
        let canvas = try JSONCanvasDocument(text: String(decoding: VaultFileAccess.readDataImmediately(at: canvasURL), as: UTF8.self))
        XCTAssertEqual(canvas.nodes[0].content, "Destination.md")
        XCTAssertEqual(canvas.nodes[0].data["subpath"], .string("#Heading"))
        XCTAssertEqual(canvas.data["custom"], .number(42))
        XCTAssertThrowsError(try JSONCanvasDocument(text: "{\"nodes\":[{\"id\":\"same\"},{\"id\":\"same\"}]}"))
    }

    func testSlidesIgnoreFrontmatterAndFencedSeparators() {
        let text = "---\ntags: [slides]\n---\n# One\n\n---\n\n# Two\n```\n\n---\n\n```"
        XCTAssertEqual(NoteSlides.split(text).count, 2)
        XCTAssertTrue(NoteSlides.split(text)[1].contains("```\n\n---"))
        XCTAssertEqual(NoteSlides.split("").count, 1)
    }

    func testMergePreservesBothBodiesUpdatesReferencesAndTrashesSource() throws {
        let source = try note("Source.md", "# Source Heading\n\nSource body")
        let target = try note("Destination.md", "# Destination Heading\n\nTarget body")
        let reference = try note("Ref.md", "[[Source#Source Heading|Alias]]")
        let mutation = try VaultNoteComposer.merge(source: source, destination: target, root: root,
                                                   expectedSource: "# Source Heading\n\nSource body")
        XCTAssertTrue(mutation.isMerge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let merged = String(decoding: try VaultFileAccess.readDataImmediately(at: target), as: UTF8.self)
        XCTAssertTrue(merged.contains("Target body"))
        XCTAssertTrue(merged.contains("Source body"))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: reference), as: UTF8.self), "[[Destination#Source Heading|Alias]]")
        XCTAssertEqual(VaultTrash.existingEntries(in: root).count, 1)
    }

    func testFailedMergeLeavesBothNotesAndReferencesUnchanged() throws {
        let source = try note("Source.md", "# Same\nSource")
        let target = try note("Target.md", "# Same\nTarget")
        _ = try note("Ref.md", "[[Source]]")
        XCTAssertThrowsError(try VaultNoteComposer.merge(source: source, destination: target, root: root, expectedSource: "# Same\nSource"))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: source), as: UTF8.self), "# Same\nSource")
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: target), as: UTF8.self), "# Same\nTarget")
        XCTAssertTrue(VaultTrash.existingEntries(in: root).isEmpty)
    }

    func testComposingAcrossFoldersKeepsLocalWikilinksAndRedirectsQuotedAlias() throws {
        _ = try note("Target.md", "Root target")
        _ = try note("folder/Target.md", "Local target")
        let text = "---\n'aliases': ['Former']\n---\n# Source\n[[Target]]"
        let source = try note("folder/Source.md", text)
        let destination = try note("Destination.md", "# Destination")
        let reference = try note("Reference.md", "[[Former]]")
        _ = try VaultNoteComposer.merge(source: source, destination: destination, root: root, expectedSource: text)
        let merged = String(decoding: try VaultFileAccess.readDataImmediately(at: destination), as: UTF8.self)
        XCTAssertTrue(merged.contains("[[folder/Target]]"))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: reference), as: UTF8.self), "[[Destination]]")
    }

    func testSectionExtractionPreservesOtherSectionsPropertiesAndRebasesAttachments() throws {
        let image = try note("Attachments/photo.png", "bytes")
        let body = "---\ncustom: true\n---\n# Keep\nOriginal\n# Extract\n![Photo](Attachments/photo.png)\n## Child\nChild body\n# Other\nRemaining"
        let source = try note("Source.md", body)
        let heading = try XCTUnwrap(MarkdownKnowledge.analyze(body, url: source).headings.first { $0.title == "Extract" })
        let destination = root.appendingPathComponent("Extracted/Section.md")
        let replacement = try VaultNoteComposer.extract(source: source, destination: destination, root: root, text: body, heading: heading)
        XCTAssertTrue(replacement.contains("custom: true"))
        XCTAssertTrue(replacement.contains("[[Extracted/Section]]"))
        XCTAssertTrue(replacement.contains("# Other\nRemaining"))
        XCTAssertFalse(replacement.contains("Child body"))
        let extracted = String(decoding: try VaultFileAccess.readDataImmediately(at: destination), as: UTF8.self)
        XCTAssertTrue(extracted.contains("../Attachments/" + image.lastPathComponent))
        XCTAssertTrue(extracted.contains("Child body"))
        XCTAssertThrowsError(try VaultNoteComposer.extract(source: source, destination: destination, root: root, text: body, heading: heading))
    }

    func testMediaImportDoesNotFollowAttachmentFolderSymlink() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Recording-" + UUID().uuidString + ".m4a")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let destination = try VaultFileAccess.importMedia(from: file, root: root)
        XCTAssertEqual(try VaultFileAccess.readDataImmediately(at: destination), Data([1, 2, 3]))
        try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Attachments"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try VaultFileAccess.importMedia(from: file, root: root))
    }

    func testRenamingAnAliasedNoteKeepsStableAliasLinksAndRebasesRelativeWikiLinks() throws {
        let target = try note("Target.md", "---\naliases: [Stable Alias]\n---\nBody")
        let source = try note("Inbox/Source.md", "[[Stable Alias]]\n[[../Target]]")
        XCTAssertNotNil(store.rename(target, to: "Renamed"))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: source), as: UTF8.self), "[[Stable Alias]]\n[[Renamed]]")
        let local = try note("Inbox/Local.md")
        let linked = try note("Inbox/Move.md", "[[Local]]")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let moved = try XCTUnwrap(store.moveDocument(linked, to: root.appendingPathComponent("Nested")))
        XCTAssertEqual(String(decoding: try VaultFileAccess.readDataImmediately(at: moved), as: UTF8.self), "[[Inbox/Local]]")
        XCTAssertEqual(MarkdownKnowledge.resolve("Inbox/Local", from: moved, root: root, files: [local, moved]), local)
    }

    func testObsidianDateTokensAndLiteralBrackets() {
        XCTAssertEqual(NoteLibrarySettings.compatibleDateFormat("YYYY-MM-DD [journal]"), "yyyy-MM-dd 'journal'")
        XCTAssertEqual(NoteLibrarySettings.compatibleDateFormat("yyyy-MM-dd HH:mm"), "yyyy-MM-dd HH:mm")
        XCTAssertEqual(NoteLibrarySettings.compatibleDateFormat("dddd A"), "EEEE a")
    }
}
