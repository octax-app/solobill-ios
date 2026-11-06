import XCTest

/// Needs a local server with the demo account. See `ios/README.md`.
final class LoginUITests: XCTestCase {
    private var server: String { ProcessInfo.processInfo.environment["TEST_SERVER_URL"] ?? "http://localhost:3000" }

    private func launch(server: String? = nil, appLock: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", server ?? self.server, "-skipPushPrompt", "YES", "-skipAppLock", appLock ? "NO" : "YES"]
        app.launch()
        return app
    }

    /// Leaves the app signed out, so each test starts at the login screen.
    private func signOutIfNeeded(_ app: XCUIApplication) {
        let signOut = app.buttons["signOut"]
        if signOut.waitForExistence(timeout: 2) {
            signOut.tap()
            XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
        }
    }

    private func logIn(_ app: XCUIApplication, password: String) {
        let email = app.textFields["login.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("owner@example.com")
        let field = app.secureTextFields["login.password"]
        field.tap()
        field.typeText(password)
        app.buttons["login.submit"].tap()
    }

    func testWrongPasswordShowsTheServerMessage() {
        let app = launch()
        signOutIfNeeded(app)
        logIn(app, password: "wrong-password")
        let message = app.staticTexts["login.error"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Email or password is incorrect")
    }

    func testLogInReachesTheTabsAndSignOutReturns() {
        let app = launch()
        signOutIfNeeded(app)
        logIn(app, password: "demo-password")
        XCTAssertTrue(app.tabBars.buttons["Customers"].waitForExistence(timeout: 10))
        app.terminate()

        // The token survives a relaunch, in the Keychain, so login is not asked for again.
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Customers"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login.submit"].exists)

        signOutIfNeeded(app)
        XCTAssertTrue(app.buttons["login.submit"].exists)
    }

    func testAReopenedAppStaysLockedUntilAuthenticated() {
        let app = launch()
        signOutIfNeeded(app)
        logIn(app, password: "demo-password")
        XCTAssertTrue(app.tabBars.buttons["Customers"].waitForExistence(timeout: 10))
        app.terminate()

        let locked = launch(appLock: true)
        XCTAssertFalse(locked.tabBars.buttons["Customers"].waitForExistence(timeout: 4))
        XCTAssertFalse(locked.buttons["login.submit"].exists)
        locked.terminate()

        signOutIfNeeded(launch())
    }

    func testAnUnreachableServerExplainsItself() {
        let app = launch()
        signOutIfNeeded(app)
        app.terminate()
        let offline = launch(server: "http://localhost:1")
        logIn(offline, password: "demo-password")
        let message = offline.staticTexts["login.error"]
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        XCTAssertTrue(message.label.contains("offline"))
    }
}
