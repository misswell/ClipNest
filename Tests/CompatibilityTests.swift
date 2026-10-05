import XCTest
@testable import ClipNest

@MainActor
final class CompatibilityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Compatibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func info(_ name: String, _ yaml: String = "") -> NoteKnowledge {
        MarkdownKnowledge.analyze("---\n" + yaml + "\n---\n# Body\n", url: root.appendingPathComponent(name + ".md"))
    }
    private func context(_ note: NoteKnowledge, formulas: [String: CanvasValue] = [:]) -> BaseContext {
        BaseContext(root: root, url: note.url, lookup: NoteLinkResolver(root: root, files: [note.url], aliases: [:]), formulas: formulas, currentNote: note)
    }

    func testYAMLTypesQuotedKeysNestedPropertiesAndAliases() throws {
        let values = try NoteProperties.parse("\"别名:名称\": ['第一', '第二']\naliases: [\"false\", '12']\ncount: 12\nfinished: true\nquoted: \"false\"\nempty: null\nreview:\n  status: draft\n")
        XCTAssertEqual(values["别名:名称"], .array([.string("第一"), .string("第二")]))
        XCTAssertEqual(values["count"], .number(12))
        XCTAssertEqual(values["finished"], .bool(true))
        XCTAssertEqual(values["quoted"], .string("false"))
        XCTAssertEqual(values["empty"], .null)
        XCTAssertEqual(values["review"]?.object?["status"], .string("draft"))
        XCTAssertEqual(NoteProperties.strings(values["aliases"]), ["false", "12"])
    }

    func testYAMLEditRetainsBodyOtherKeysCommentsAndAnchorReferences() throws {
        let original = "---\n# keep header\ncount: &amount 2\n# keep comment\ncopy: *amount\nsummary: |\n  two lines\n  stay intact\n---\n\n正文😀\n"
        let updated = try NoteProperties.setting(.number(5), key: "count", in: original)
        XCTAssertEqual(MarkdownKnowledge.body(updated), "\n正文😀\n")
        XCTAssertTrue(updated.contains("# keep header"))
        XCTAssertTrue(updated.contains("# keep comment"))
        XCTAssertTrue(updated.contains("summary: |\n  two lines\n  stay intact"))
        let values = try NoteProperties.parse(NoteProperties.yaml(updated))
        XCTAssertEqual(values["count"], .number(5))
        XCTAssertEqual(values["copy"], .number(5))
        let quoted = try NoteProperties.setting(.array([.string("别名")]), key: "别名:名称", in: updated)
        XCTAssertEqual(try NoteProperties.parse(NoteProperties.yaml(quoted))["别名:名称"], .array([.string("别名")]))
    }

    func testYAMLErrorsDoNotProduceReplacement() {
        XCTAssertThrowsError(try NoteProperties.parse("status: [unclosed"))
        XCTAssertThrowsError(try NoteProperties.parse("status: one\n\"status\": two"))
        XCTAssertThrowsError(try NoteProperties.setting(.string("new"), key: "status", in: "---\nstatus: [broken\n---\nBody"))
        XCTAssertThrowsError(try NoteProperties.parse("value: .inf"))
        XCTAssertThrowsError(try NoteProperties.parse("value: " + String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70)))
    }

    func testFootnotesIgnoreCodeAndKeepContinuationAndUnicodeRanges() {
        let text = "See [^例子]. `[^code]`\n[^例子]: 第一行😀\n    第二行\n~~~\n[^fake]: ignored\n~~~"
        let notes = NoteFootnotes.definitions(in: text)
        XCTAssertEqual(notes.map(\.id), ["例子"])
        XCTAssertEqual(notes.first?.text, "第一行😀\n第二行")
        let rendered = NoteFootnotes.inline("😀 [^例子] `[^code]`")
        XCTAssertTrue(rendered.contains("clipnest-note://open"))
        XCTAssertTrue(rendered.contains("`[^code]`"))
        XCTAssertEqual(NoteFootnotes.inline("[^x]: text"), "x. text")
    }

    func testBaseArithmeticPrecedenceNegativeExponentAndLazyIf() throws {
        let note = info("Book", "price: 12\nage: 4\na.b: 7\nauthors: [one, two]")
        let c = context(note, formulas: ["ppu": .string("(price / age).toFixed(2)")])
        XCTAssertEqual(try BaseExpression.evaluate("formula.ppu", note: note, context: c), .string("3.00"))
        XCTAssertEqual(try BaseExpression.evaluate("note[\"a.b\"]", note: note, context: c), .number(7))
        XCTAssertEqual(try BaseExpression.evaluate("authors[1]", note: note, context: c), .string("two"))
        XCTAssertEqual(try BaseExpression.evaluate("2 + 3 * 4", note: note, context: c), .number(14))
        XCTAssertEqual(try BaseExpression.evaluate("price * -2", note: note, context: c), .number(-24))
        XCTAssertEqual(try BaseExpression.evaluate("2e-3 * 4", note: note, context: c), .number(0.008))
        XCTAssertEqual(try BaseExpression.evaluate("if(false, unsupported(), price)", note: note, context: c), .number(12))
        XCTAssertEqual(try BaseExpression.evaluate("false && unsupported()", note: note, context: c), .bool(false))
        XCTAssertThrowsError(try BaseExpression.evaluate("price / 0", note: note, context: c))
    }

    func testBaseFormulaCyclesAndUnsupportedReservedFieldsFailExplicitly() {
        let note = info("Book")
        let c = context(note, formulas: ["a": .string("formula.b"), "b": .string("formula.a")])
        XCTAssertThrowsError(try BaseExpression.evaluate("formula.a", note: note, context: c))
        XCTAssertThrowsError(try BaseExpression.evaluate("file.unsupported", note: note, context: c))
        XCTAssertThrowsError(try BaseExpression.evaluate("now()", note: note, context: c))
    }

    func testBaseGlobalAndViewFiltersAliasesNestedTagsAndThis() throws {
        let first = info("folder/Book", "tags: [book/read]\nstatus: todo\nprice: 12\nreview: {status: draft}")
        let second = info("Other", "tags: [book]\nstatus: done\nprice: 2")
        let base = try NoteBase("filters: 'file.hasTag(\"book\")'\nviews:\n  - type: table\n    filters: 'status != \"done\" && file.inFolder(\"folder\")'\n    order: [file.name, review.status, this.file.name]")
        let rows = try base.rows(view: 0, notes: [first, second], root: root, url: first.url, aliases: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.1["review.status"], .string("draft"))
        XCTAssertEqual(rows.first?.1["this.file.name"], .string("Book"))
        let filter: CanvasValue = .object(["not": .array([.string("status == \"done\"")])])
        XCTAssertTrue(try BaseExpression.matches(filter, note: first, context: context(first)))
    }

    func testBaseSortUsesHiddenNumericColumnsMultipleCriteriaAndGroupOrder() throws {
        let first = info("A", "price: 20\nstatus: todo")
        let second = info("B", "price: 3\nstatus: todo")
        let third = info("C", "price: 99\nstatus: done")
        let base = try NoteBase("views:\n  - type: table\n    order: [file.name]\n    groupBy: {property: status, direction: ASC}\n    sort:\n      - {property: price, direction: DESC}\n      - {property: file.name, direction: ASC}\n    limit: 3")
        let rows = try base.rows(view: 0, notes: [second, first, third], root: root, url: root.appendingPathComponent("List.base"), aliases: [:])
        XCTAssertEqual(rows.map { $0.0.url.deletingPathExtension().lastPathComponent }, ["C", "A", "B"])
        XCTAssertEqual(rows.last?.1["price"], .number(3))
        let limited = try NoteBase("views: [{type: list, order: [file.name], limit: 1}]")
        XCTAssertEqual(try limited.rows(view: 0, notes: [first, second], root: root, url: root, aliases: [:]).count, 1)
        let invalid = try NoteBase("views: [{type: table, limit: -1}]")
        XCTAssertThrowsError(try invalid.rows(view: 0, notes: [], root: root, url: root, aliases: [:]))
    }

    func testBaseSchemaUnknownFieldsRetainedAndUnsupportedViewFails() throws {
        let base = try NoteBase("custom: {keep: true}\nviews: [{type: cards, name: Books}, {type: plugin-map}]")
        XCTAssertEqual(base.data["custom"]?.object?["keep"], .bool(true))
        XCTAssertThrowsError(try base.rows(view: 1, notes: [], root: root, url: root, aliases: [:]))
        XCTAssertThrowsError(try NoteBase("views: []"))
        XCTAssertThrowsError(try NoteBase("not: [valid"))
        XCTAssertEqual(BaseSummary.text(name: "Median", values: [.number(1), .number(3), .number(10), .number(12)]), "Median: 6.5")
        XCTAssertEqual(BaseSummary.text(name: "Unique", values: [.number(1), .string("1")]), "Unique: 2")
    }

    func testWorkspaceContainmentPersistenceAndFolderRelocation() throws {
        let note = root.appendingPathComponent("folder/Book.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFileAccess.createText("# Book", at: note)
        let layout = DesktopWorkspace(name: "Focus", tabs: ["folder/Book.md", "../outside.md", "missing.md"], selected: "folder/Book.md", activity: "explorer", sidebarVisible: true, sidebarWidth: 280, terminalVisible: false, terminalWidth: 520, mode: "preview", multipleTabs: true)
        XCTAssertEqual(layout.urls(in: root), [note])
        try DesktopWorkspaceRepository.save([layout], root: root)
        defer { try? DesktopWorkspaceRepository.save([], root: root) }
        XCTAssertEqual(DesktopWorkspaceRepository.load(root: root).first?.name, "Focus")
        DesktopWorkspaceRepository.relocate(VaultDocumentMove(source: root.appendingPathComponent("folder"), destination: root.appendingPathComponent("renamed")), root: root)
        XCTAssertEqual(DesktopWorkspaceRepository.load(root: root).first?.selected, "renamed/Book.md")
        XCTAssertTrue(DesktopWorkspaceRepository.load(root: root).first?.tabs.contains("renamed/Book.md") == true)
    }
}
