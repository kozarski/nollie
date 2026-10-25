import XCTest

/// Editing a Board task from its own sheet: the Edit menu renames it (and it is renamed back) and
/// adds to its description, which is saved and shown; Done closes the sheet.
final class BoardEditUITests: DemoCase {
    private let original = "Remove rotated logs older than 90 days"

    private func openTask() throws {
        try startDemo()
        openBoard()
        pageToCard(original).tap()
        XCTAssertTrue(find("task.edit").waitForExistence(timeout: 15), "the task sheet did not open")
    }

    /// Renames through the Edit menu's alert.
    private func rename(to title: String) {
        tap("task.edit")
        press("Rename…")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no rename alert")
        field.tap()
        // The alert opens with the old title in the field: clear it, then write the new one.
        if let old = field.value as? String, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
        }
        field.typeText(title)
        app.alerts.buttons["Save"].tap()
    }

    func testRenamingATaskShowsTheNewTitleAndCanBePutBack() throws {
        try openTask()
        let renamed = "Remove rotated logs this week"
        rename(to: renamed)
        XCTAssertTrue(poll(15) { self.app.navigationBars.staticTexts[renamed].exists || self.text(renamed).exists },
                      "the sheet kept the old title")
        shot("board-edit-renamed")

        rename(to: original)
        XCTAssertTrue(poll(15) { self.app.navigationBars.staticTexts[self.original].exists || self.text(self.original).exists },
                      "the title was not put back")
    }

    func testAddingToTheDescriptionSavesAndShowsIt() throws {
        try openTask()
        tap("task.edit")
        let edit = app.buttons["Edit the Description"].firstMatch.exists ? "Edit the Description" : "Add a Description"
        press(edit)
        let editor = expectShown(app.textViews["Description"].firstMatch, within: 5, "no description editor")
        editor.tap()
        let added = "Checked twice by hand."
        editor.typeText(" " + added)
        press("Save")
        XCTAssertTrue(text(added).waitForExistence(timeout: 15), "the added words are not shown in the sheet")
        shot("board-edit-description")

        press("Done")
        XCTAssertTrue(poll(10) { !self.find("task.edit").exists }, "Done left the task sheet up")
    }
}
