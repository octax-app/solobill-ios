import XCTest

/// Needs a local server with the demo data. See `ios/README.md`.
final class CustomersUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSearchFindsACustomerAndOpensTheDetails() {
        let app = launchSignedIn()
        app.tabBars.buttons["Customers"].tap()
        XCTAssertTrue(app.staticTexts["Al Noor Clinics"].waitForExistence(timeout: 10))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Haddad")

        // The server filters, so the other customers leave the list.
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Al Noor Clinics"]))
        let match = app.staticTexts["Haddad Logistics"]
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()

        // LabeledContent reads as one element, such as "Email, omar@example.com".
        XCTAssertTrue(contact(app, "Omar Haddad").waitForExistence(timeout: 10))
        XCTAssertTrue(contact(app, "omar@example.com").exists)
        XCTAssertTrue(element(app, "customer.billed").exists)
        XCTAssertTrue(app.staticTexts["Dedicated server"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Invoices and proformas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Linked original invoices"].waitForExistence(timeout: 5))
    }

    func testASearchWithNoMatchSaysSo() {
        let app = launchSignedIn()
        app.tabBars.buttons["Customers"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("zzz-nobody")
        XCTAssertTrue(app.staticTexts["No Results for “zzz-nobody”"].waitForExistence(timeout: 5))
    }

    func testOfflineShowsTheErrorAndRetry() {
        let app = relaunchOffline(launchSignedIn())
        app.tabBars.buttons["Customers"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Could not load"].exists)

        // Retry runs the load again and returns to the same error while still offline.
        app.buttons["retry"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
    }

    private func contact(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForDisappearance(of element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }
}
