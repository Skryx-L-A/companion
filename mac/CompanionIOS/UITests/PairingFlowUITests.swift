// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

/// The one way through the app that no package test reaches: from the pairing screen into the
/// app itself.
///
/// The manual way is used because it needs no daemon — it stores what is typed and connects
/// afterwards. What is checked here is the way through, not that the connection comes up: the
/// machine in these fields does not exist.
final class PairingFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheManualWayLeadsFromTheWelcomeScreenIntoTheApp() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Willkommen"].waitForExistence(timeout: 20),
            "the welcome screen is what an unpaired app shows")
        attach(app, named: "01-willkommen")

        app.descendants(matching: .any).matching(identifier: "weg-manual").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Von Hand eintragen"].waitForExistence(timeout: 10))

        type("100.64.0.7:47801", into: app.textFields["Adresse, zum Beispiel 100.64.0.7:47801"])
        type(String(repeating: "ab12cd34", count: 8), into: app.textFields["Fingerabdruck des Zertifikats"])
        type("m-uitest", into: app.textFields["Maschinenkennung"])
        type("Testmaschine", into: app.textFields["Name der Maschine, optional"])
        type("t-uitest", into: app.textFields["Token"])
        attach(app, named: "02-von-hand")

        app.buttons["Speichern"].tap()

        XCTAssertTrue(
            app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20),
            "a paired app shows its three places; what is on screen instead: "
                + app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Companion"].exists)
        XCTAssertTrue(app.tabBars.buttons["Maschinen"].exists)
        attach(app, named: "03-sessions")

        app.tabBars.buttons["Maschinen"].tap()
        XCTAssertTrue(app.staticTexts["Testmaschine"].waitForExistence(timeout: 10))
        attach(app, named: "04-maschinen")

        app.tabBars.buttons["Companion"].tap()
        XCTAssertTrue(app.navigationBars["Companion"].waitForExistence(timeout: 10))
        // The figure and the talk button are both on this tab (DESIGN.md, section Mobil).
        XCTAssertTrue(
            app.staticTexts["Halte die Taste und sprich."].waitForExistence(timeout: 10),
            "the talk button explains itself before it is pressed")
        attach(app, named: "05-companion")

        // The microphone screen comes before the system dialog, and only a deliberate tap on
        // it opens that dialog — so this stops one step short of the real prompt.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sprechen'")).firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Mikrofon"].waitForExistence(timeout: 10),
            "the explanation comes before iOS asks; what is on screen instead: "
                + app.debugDescription)
        attach(app, named: "06-mikrofon-erklaerung")
        app.buttons["Jetzt nicht"].tap()
        XCTAssertTrue(app.navigationBars["Companion"].waitForExistence(timeout: 10))
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field missing: \(field)")
        field.tap()
        field.typeText(text)
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
