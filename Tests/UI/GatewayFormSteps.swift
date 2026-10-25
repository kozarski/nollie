import XCTest

/// The gateway form, driven the way a person fills it: shared by the flows that add a gateway.
extension DemoCase {
    /// From the bots list to a blank form: Settings, Connection, Advanced, then adding one by address.
    func openAddGatewayForm() {
        tap("chats.settings", timeout: 30)
        scrollTo("settings.row.gateways").tap()
        scrollTo("settings.connection.advanced").tap()
        scrollTo("settings.connection.add").tap()
        XCTAssertTrue(find("gateway.url").waitForExistence(timeout: 10), "the gateway form did not open")
    }

    /// Types into one of the form's fields, replacing what was there.
    func fillField(_ id: String, with words: String) {
        let field = find(id)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "\(id) is not there")
        // The form scrolls under the keyboard: slide it until the field can be touched.
        for _ in 0..<6 where !field.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(field.isHittable, "\(id) cannot be reached")
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(words)
    }

    /// Picks the sign-in method by its title ("Username & password").
    func chooseSignInMethod(_ title: String) {
        let picker = find("gateway.authMethod")
        for turn in 0..<6 where !picker.isHittable { if turn % 2 == 0 { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) } }
        XCTAssertTrue(picker.isHittable, "the sign-in method cannot be reached")
        picker.tap()
        press(title)
    }

    /// Name, address, then a user name and password, leaving the Remember switch as it is.
    func fillPasswordGateway(name: String, address: String, user: String, password: String) {
        fillField("gateway.name", with: name)
        fillField("gateway.url", with: address)
        chooseSignInMethod("Username & password")
        fillField("gateway.username", with: user)
        fillField("gateway.password", with: password)
    }

    /// Runs the form's connection test and waits until it passes.
    func runConnectionTestUntilItPasses() {
        let test = scrollTo("gateway.test")
        test.tap()
        let save = find("gateway.save")
        XCTAssertTrue(wait(for: save, "enabled == true", timeout: 40), "the connection test did not pass")
    }
}

extension DemoCase {
    /// Takes a gateway a flow added back out, so the demo copy is as it was for the next flow. From
    /// wherever the app is, through Settings, Connection and Advanced; quiet when anything is missing.
    func removeSavedGateway(named name: String) {
        guard app.state == .runningForeground else { return }
        for _ in 0..<3 where !find("settings.page").exists && !find("settings.row.gateways").exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() } else { break }
            pause(0.6)
        }
        if !find("settings.connection.advanced").exists && !find("settings.connection.add").exists {
            if !find("settings.row.gateways").exists, find("chats.settings").exists { find("chats.settings").tap() }
            let row = find("settings.row.gateways")
            guard row.waitForExistence(timeout: 10) else { return }
            if row.isHittable { row.tap() }
        }
        if !find("settings.connection.add").exists {
            let more = find("settings.connection.advanced")
            guard more.waitForExistence(timeout: 10) else { return }
            more.tap()
        }
        let trash = app.buttons["Remove \(name)"].firstMatch
        for _ in 0..<4 where !trash.exists { app.swipeUp(velocity: .slow) }
        guard trash.exists else { return }
        trash.tap()
        let confirm = app.alerts.buttons["Remove"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        pause(1)
    }
}
