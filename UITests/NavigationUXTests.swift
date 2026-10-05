import XCTest

/// Two navigation-experience regressions reported from real use:
///
/// 1. Deleting the open note must land back on a list — the deleted note's editor must
///    not stay on screen showing a file that no longer exists (in the Vault tab *or*
///    pushed inside the Timeline's own stack).
/// 2. Returning to the Vault tab must show the tab's list where the user left it — the
///    tab re-appearance must not push the last-opened note back into detail
///    (reported as "tapping the home tab clicks through to a note").
///
/// Every test creates its own uniquely named note, so the tests are order-independent
/// even though the delete tests remove their note from the shared sample vault.
final class NavigationUXTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // A fresh install shows the onboarding empty state; the sample vault makes the
        // tree deterministic. An already-restored vault skips this.
        let sample = app.buttons["Open Sample Vault"]
        if sample.waitForExistence(timeout: 5) {
            sample.tap()
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "the main tab bar should be visible")
        // A fresh install seeds the sample vault and auto-opens its Welcome note. Go back
        // to the tree, so every test starts from the list regardless of install state.
        if app.navigationBars["Welcome"].waitForExistence(timeout: 3) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    // MARK: - Bug: delete must return to the list (Vault tab)

    func testDeletingTheOpenNoteReturnsToTheList() throws {
        // Creating a note opens it directly, so the editor is already up.
        let name = "Delete Return \(UUID().uuidString.prefix(6)).md"
        try createNote(name)
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))

        // A manually opened note carries the delete action behind the ellipsis menu.
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), "the editor toolbar should offer the menu")
        more.tap()
        let deleteItem = app.buttons["Delete Note"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))
        deleteItem.tap()

        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the confirmation alert should appear")
        confirm.tap()

        // Back on the list: the tree is visible again and the editor is gone.
        XCTAssertFalse(app.navigationBars[title(of: name)].waitForExistence(timeout: 3),
                       "the deleted note's editor must not stay on screen")
        XCTAssertTrue(app.buttons["Getting Started.md"].waitForExistence(timeout: 5),
                      "the vault tree (list) is showing again")
    }

    // MARK: - Bug: delete must return to the list (Timeline tab)

    func testDeletingATimelineOpenedNoteReturnsToTheTimelineList() throws {
        let name = "Timeline Delete \(UUID().uuidString.prefix(6)).md"
        try createNote(name)

        app.tabBars.buttons["Timeline"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@",
                                                     title(of: name))).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the timeline should list the newly created note")
        row.tap()
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))

        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let deleteItem = app.buttons["Delete Note"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))
        deleteItem.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertFalse(app.navigationBars[title(of: name)].waitForExistence(timeout: 3),
                       "the deleted note's editor must not stay pushed in the Timeline")
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5),
                      "the timeline list is showing again")
    }

    // MARK: - Bug: the Vault tab must not re-push the last note

    func testReturningToTheVaultTabShowsTheListNotTheLastNote() throws {
        // Creating a note opens it directly (selection is set by the store).
        let name = "Tab Return \(UUID().uuidString.prefix(6)).md"
        try createNote(name)
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))

        // Back to the list, then leave the tab and come back.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Vault"].tap()

        XCTAssertFalse(app.navigationBars[title(of: name)].waitForExistence(timeout: 3),
                       "returning to the Vault tab must not push the last-opened note")
        XCTAssertTrue(app.buttons["Getting Started.md"].waitForExistence(timeout: 5),
                      "the list the user left is still showing")
    }

    // MARK: - Image viewer: tapping a preview image opens it full screen

    func testTappingAPreviewImageOpensTheFullScreenViewer() throws {
        // A fresh install seeds the sample vault and auto-opens its Welcome note; otherwise
        // open Welcome.md from the tree.
        if !app.navigationBars["Welcome"].waitForExistence(timeout: 3) {
            let row = app.buttons["Welcome.md"]
            var scrolls = 0
            while !row.exists, scrolls < 8 {
                app.swipeUp()
                scrolls += 1
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            while !row.isHittable, scrolls < 12 {
                app.swipeUp()
                scrolls += 1
            }
            row.tap()
        }
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 5))

        // Welcome.md opens in Preview and embeds the sample banner. It sits below the fold
        // of the lazy preview stack, so scroll until the element materializes.
        let image = app.descendants(matching: .any)["View Full Image"].firstMatch
        var attempts = 0
        while !image.exists, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(image.waitForExistence(timeout: 3),
                      "the embedded banner should render in the preview")
        while image.exists && !image.isHittable, attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        image.tap()

        XCTAssertTrue(app.buttons["Close Image Viewer"].waitForExistence(timeout: 5),
                      "the full-screen viewer should open")
        app.buttons["Close Image Viewer"].tap()
        XCTAssertFalse(app.buttons["Close Image Viewer"].waitForExistence(timeout: 2),
                       "closing returns to the note preview")
    }

    // MARK: - Helpers

    func testNoteDetailsBookmarkAndPropertiesAreEditable() throws {
        let name = "Details \(UUID().uuidString.prefix(6)).md"
        try createNote(name)
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["Note Details"].tap()
        XCTAssertTrue(app.navigationBars["Note Details"].waitForExistence(timeout: 5))
        app.buttons["Add Bookmark"].tap()
        XCTAssertTrue(app.buttons["Remove Bookmark"].waitForExistence(timeout: 3))
        app.buttons["Edit Properties"].tap()
        let yaml = app.textViews.firstMatch
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        yaml.tap(); yaml.typeText("aliases: [ReviewAlias]\ntags: [ui/test]\nstatus: active")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["aliases, [ReviewAlias]"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))
    }

    func testDailyNoteOpensExistingNoteAndShowsDetails() throws {
        app.tabBars.buttons["Knowledge"].tap()
        XCTAssertTrue(app.navigationBars["Knowledge"].waitForExistence(timeout: 5))
        app.buttons["Knowledge Actions"].tap()
        app.buttons["Open Daily Note"].tap()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(app.navigationBars[formatter.string(from: Date())].waitForExistence(timeout: 10))
        app.buttons["More"].tap(); app.buttons["Note Details"].tap()
        XCTAssertTrue(app.navigationBars["Note Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Outline"].exists)
    }

    func testNewCanvasCreatesAnEditableCard() throws {
        app.tabBars.buttons["Knowledge"].tap()
        app.buttons["Knowledge Actions"].tap(); app.buttons["New Canvas"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        let name = "Canvas-\(UUID().uuidString.prefix(6))"
        field.typeText(name + ".canvas")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
        app.buttons["Add Card"].tap(); app.buttons["Text"].tap()
        XCTAssertTrue(app.staticTexts["New card"].waitForExistence(timeout: 5))
    }

    func testInternalLinkCreatesMissingNoteAndNavigatesToIt() throws {
        let name = "Links-\(UUID().uuidString.prefix(6)).md"
        let missing = "Linked-\(UUID().uuidString.prefix(6))"
        try createNote(name)
        XCTAssertTrue(app.navigationBars[title(of: name)].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\n[[" + missing + "]]\n")
        app.buttons["Preview"].tap()
        let link = app.staticTexts[missing]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.alerts["Create Linked Note?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars[missing].waitForExistence(timeout: 5))
    }

    func testNewBaseListsNotesAndSavesAChangedView() throws {
        app.tabBars.buttons["Knowledge"].tap()
        app.buttons["Knowledge Actions"].tap(); app.buttons["New Base"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        let name = "Base-\(UUID().uuidString.prefix(6))"
        field.typeText(name + ".base"); app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Getting Started"].waitForExistence(timeout: 15))
        app.buttons["Edit Base"].tap()
        let yaml = app.textViews.firstMatch
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        yaml.tap(); yaml.press(forDuration: 1.1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
        else { yaml.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 600)) }
        yaml.typeText("filters: 'file.ext == \"md\"'\nviews:\n  - type: cards\n    name: Cards\n    order: [file.name]")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Getting Started"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Edit Base"].exists)
    }

    func testInvalidNewNoteNameShowsAnError() throws {
        try createNote("invalid/path")
        XCTAssertTrue(app.alerts["File Operation Failed"].waitForExistence(timeout: 5))
        app.alerts["File Operation Failed"].buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Getting Started.md"].waitForExistence(timeout: 5))
    }

    func testRenamingTheOpenNoteUpdatesItsTitleAndTreeRow() throws {
        let original = "Rename \(UUID().uuidString.prefix(6)).md"
        try createNote(original)
        XCTAssertTrue(app.navigationBars[title(of: original)].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        let rename = app.buttons["Rename Note"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        let newTitle = "New title 1.2 \(UUID().uuidString.prefix(6))"
        field.typeText(newTitle)
        app.navigationBars.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars[newTitle].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons[newTitle + ".md"]
        for _ in 0..<8 where !row.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[original].exists)
    }

    private func title(of name: String) -> String {
        name.replacingOccurrences(of: ".md", with: "")
    }

    /// Creates a note through the + menu so tests never depend on each other's files.
    private func createNote(_ name: String) throws {
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the + toolbar button should exist")
        add.tap()
        let newItem = app.buttons["New File"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 3))
        newItem.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the name alert should appear")
        field.tap()
        // The alert pre-fills "Untitled"; the field's value is not always readable through
        // the accessibility layer, so unconditionally send enough deletes to clear it.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
        field.typeText(name)
        app.buttons["Create"].tap()
    }
}
