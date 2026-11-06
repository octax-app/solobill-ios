import XCTest

/// Captures the main screens as PNG files, for the README and the App Store.
///
/// Skipped unless SCREENSHOT_DIR is set. Run it against `scripts/dev-server.sh`:
///
///     TEST_RUNNER_TEST_SERVER_URL=http://localhost:3100 TEST_RUNNER_SCREENSHOT_DIR=$PWD/docs/screenshots \
///       xcodebuild test -project Solobill.xcodeproj -scheme Solobill \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SolobillUITests/ScreenshotTests
final class ScreenshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to capture screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        continueAfterFailure = false
    }

    func testCaptureMainScreens() throws {
        let app = launchSignedIn()

        tab(app, "Overview")
        try save("overview")

        tab(app, "Customers")
        try save("customers")
        app.cells.firstMatch.tap()
        try save("customer")

        tab(app, "Invoices")
        try save("invoices")
        app.cells.firstMatch.tap()
        try save("invoice")

        tab(app, "Renewals")
        try save("renewals")
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No \(name) tab")
        button.tap()
        // Tapping the selected tab again returns to its root screen.
        if !app.navigationBars[name].waitForExistence(timeout: 2) { button.tap() }
    }

    /// Waits for loading to finish, then writes the screen to SCREENSHOT_DIR.
    private func save(_ name: String) throws {
        let spinner = XCUIApplication().activityIndicators.firstMatch
        let deadline = Date().addingTimeInterval(15)
        while spinner.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        keepScreenshot(name)
    }
}
