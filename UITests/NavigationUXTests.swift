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

    // MARK: - Helpers

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
