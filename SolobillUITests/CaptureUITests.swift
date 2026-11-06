import UIKit
import XCTest

/// Needs a local server with the demo account. See `ios/README.md`.
final class CaptureUITests: XCTestCase {
    private struct Original: Decodable {
        let id: Int
        let number: String
        let currency: String
        let total: Int
        let pdfFile: String?
    }

    private struct Provider: Decodable {
        let id: Int
        let name: String
    }

    private var inbox: URL {
        get throws {
            // The test runner has no App Group of its own, so the script passes the app's folder.
            let path = try XCTUnwrap(
                ProcessInfo.processInfo.environment["TEST_APP_GROUP_PATH"],
                "Set TEST_RUNNER_TEST_APP_GROUP_PATH, see ios/README.md"
            )
            return URL(fileURLWithPath: path).appending(path: "inbox")
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try clearInbox()
    }

    override func tearDownWithError() throws {
        try clearInbox()
    }

    // MARK: Inbox

    private func clearInbox() throws {
        try? FileManager.default.removeItem(at: try inbox)
    }

    private func waitingFiles() throws -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: try inbox, includingPropertiesForKeys: nil)) ?? []
    }

    /// Places a PDF the same way the extension does.
    private func placePDF() throws {
        let folder = try inbox
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("Sample invoice" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        try data.write(to: folder.appending(path: "\(stamp)-\(UUID().uuidString).pdf"))
    }

    // MARK: API

    private func call(_ path: String, token: String? = nil, json: String? = nil) throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(testServerURL)/api/v1/\(path)")))
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpMethod = "POST"
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = expectation(description: path)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = data.map(Result.success) ?? .failure(error ?? URLError(.unknown))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try result.get()
    }

    private func token() throws -> String {
        struct Response: Decodable { let token: String }
        let body = #"{"email":"owner@example.com","password":"demo-password","name":"capture test"}"#
        return try JSONDecoder().decode(Response.self, from: try call("auth/token", json: body)).token
    }

    private func originals(number: String) throws -> [Original] {
        let rows = try JSONDecoder().decode([Original].self, from: try call("originals", token: try token()))
        return rows.filter { $0.number == number }
    }

    private func firstProvider() throws -> Provider {
        let rows = try JSONDecoder().decode([Provider].self, from: try call("providers", token: try token()))
        return try XCTUnwrap(rows.first)
    }

    // MARK: Form

    private func uniqueNumber() -> String { "UI-\(UUID().uuidString.prefix(8))" }

    private func launchWithForm() -> XCUIApplication {
        launch(extra: ["-openOriginalForm", "YES"])
    }

    /// `launchSignedIn` sets its own arguments, so sign in with it first when a test needs more.
    private func launch(extra: [String] = []) -> XCUIApplication {
        let first = launchSignedIn()
        guard !extra.isEmpty else { return first }
        first.terminate()
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", testServerURL, "-skipPushPrompt", "YES", "-skipAppLock", "YES"] + extra
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.isHittable, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(element) cannot be reached")
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
        reveal(field, in: app)
        field.tap()
        field.typeText(text)
    }

    private func replace(_ text: String, in identifier: String, app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
        reveal(field, in: app)
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }

    private func choose(_ option: String, from identifier: String, in app: XCUIApplication) {
        let row = app.buttons[identifier].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), identifier)
        reveal(row, in: app)
        row.tap()
        // A menu picker's options are buttons.
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), option)
        choice.tap()
    }

    private func fillIn(_ app: XCUIApplication, number: String) throws {
        try choose(firstProvider().name, from: "capture.provider", in: app)
        type(number, into: "capture.number", in: app)
        type("Hosting for one month", into: "capture.line0.description", in: app)
        replace("2", in: "capture.line0.quantity", app: app)
        type("12.5", into: "capture.line0.unitPrice", in: app)
    }

    private func save(_ app: XCUIApplication) {
        let save = app.buttons["capture.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
    }

    private func assertGone(_ element: XCUIElement) {
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: 15)
    }

    // MARK: Tests

    func testFillsInTheFormAndSavesAnOriginal() throws {
        let app = launchWithForm()
        let number = uniqueNumber()
        try fillIn(app, number: number)
        save(app)
        assertGone(app.buttons["capture.save"])

        let saved = try XCTUnwrap(originals(number: number).first)
        XCTAssertEqual(saved.total, 250_000)
        XCTAssertEqual(saved.currency, "USD")
        XCTAssertNil(saved.pdfFile)
    }

    func testAThreeDecimalCurrencyUsesTheLastRate() throws {
        // Gives the server a last rate for OMR, so the form has one to prefill.
        let provider = try firstProvider()
        let body = """
        {"providerId":\(provider.id),"number":"\(uniqueNumber())","issuedOn":"2026-01-01","currency":"OMR",\
        "fxRate":260000000,"lines":[{"description":"Seed","quantity":10000,"unitPrice":10000}]}
        """
        _ = try call("originals", token: try token(), json: body)

        let app = launchWithForm()
        let number = uniqueNumber()
        try choose(provider.name, from: "capture.provider", in: app)
        type(number, into: "capture.number", in: app)
        try choose("OMR", from: "capture.currency", in: app)
        let rate = app.textFields["capture.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 5))
        let prefilled = NSPredicate(format: "value == '2.6'")
        wait(for: [expectation(for: prefilled, evaluatedWith: rate)], timeout: 5)
        type("Hosting", into: "capture.line0.description", in: app)
        type("12.345", into: "capture.line0.unitPrice", in: app)
        save(app)
        assertGone(app.buttons["capture.save"])

        let saved = try XCTUnwrap(originals(number: number).first)
        XCTAssertEqual(saved.currency, "OMR")
        XCTAssertEqual(saved.total, 123_450)
    }

    func testTheServersMessageShowsWhenItRefusesTheForm() throws {
        let app = launchWithForm()
        try choose(firstProvider().name, from: "capture.provider", in: app)
        type("1", into: "capture.line0.unitPrice", in: app)
        save(app)
        let alert = app.alerts["Could not save"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["Enter a description"].exists)
    }

    func testAWaitingPDFOpensInTheFormAndIsSavedWithIt() throws {
        try placePDF()
        let app = launch()
        let attached = app.buttons["capture.pdfAttached"]
        XCTAssertTrue(attached.waitForExistence(timeout: 10))
        XCTAssertEqual(try waitingFiles().count, 1, "The file stays until the form finishes")

        let number = uniqueNumber()
        try fillIn(app, number: number)
        save(app)
        assertGone(app.buttons["capture.save"])

        let saved = try XCTUnwrap(originals(number: number).first)
        XCTAssertNotNil(saved.pdfFile)
        XCTAssertTrue(try waitingFiles().isEmpty)
    }

    func testTheCaptureURLOpensAPDFPlacedWhileInTheBackground() throws {
        let app = launch()
        XCUIDevice.shared.press(.home)
        try placePDF()
        app.open(try XCTUnwrap(URL(string: "solobill://capture")))
        XCTAssertTrue(app.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
    }

    func testAPDFIsFoundWhenTheAppBecomesActiveWithoutTheURL() throws {
        let app = launch()
        XCUIDevice.shared.press(.home)
        try placePDF()
        app.activate()
        XCTAssertTrue(app.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
    }

    func testALockedAppWaitsAndNothingIsLost() throws {
        _ = launchSignedIn().terminate()
        try placePDF()

        let locked = XCUIApplication()
        locked.launchArguments = ["-serverURL", testServerURL, "-skipPushPrompt", "YES", "-skipAppLock", "NO"]
        locked.launch()
        XCTAssertFalse(locked.buttons["capture.pdfAttached"].waitForExistence(timeout: 4))
        XCTAssertEqual(try waitingFiles().count, 1)
        locked.terminate()

        let unlocked = launch()
        XCTAssertTrue(unlocked.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
    }

    func testTypedDetailsSurviveTheAppLocking() throws {
        try placePDF()
        let app = launch()
        XCTAssertTrue(app.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
        let number = uniqueNumber()
        type(number, into: "capture.number", in: app)

        XCUIDevice.shared.press(.home)
        app.activate()

        let field = app.textFields["capture.number"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, number)
    }

    func testCancelRemovesTheWaitingPDF() throws {
        try placePDF()
        let app = launch()
        XCTAssertTrue(app.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
        app.buttons["capture.cancel"].tap()
        // The confirmation dialog can expose its button twice.
        let discard = app.buttons["capture.discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertEqual(try waitingFiles().count, 1)
        discard.tap()
        assertGone(app.buttons["capture.save"])
        XCTAssertTrue(try waitingFiles().isEmpty)
    }

    func testAFailedUploadRetriesOnlyTheUpload() throws {
        try placePDF()
        let app = launch(extra: ["-failFirstPDFUpload", "YES"])
        XCTAssertTrue(app.buttons["capture.pdfAttached"].waitForExistence(timeout: 10))
        let number = uniqueNumber()
        try fillIn(app, number: number)
        save(app)

        let retry = app.buttons["capture.retryUpload"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["capture.uploadError"].label.contains("offline"))
        XCTAssertEqual(try originals(number: number).count, 1)
        XCTAssertNil(try originals(number: number).first?.pdfFile)
        XCTAssertEqual(try waitingFiles().count, 1)

        // The retry state must survive a lock, or the owner could save a duplicate.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))

        retry.tap()
        assertGone(retry)
        XCTAssertEqual(try originals(number: number).count, 1)
        XCTAssertNotNil(try originals(number: number).first?.pdfFile)
        XCTAssertTrue(try waitingFiles().isEmpty)
    }

    func testOfflineShowsTheErrorAndRetry() throws {
        launchSignedIn().terminate()
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", "http://localhost:1", "-skipPushPrompt", "YES", "-skipAppLock", "YES", "-openOriginalForm", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["You appear to be offline. Check your connection and try again."].exists)
        XCTAssertTrue(app.buttons["capture.cancel"].exists)
    }
}
