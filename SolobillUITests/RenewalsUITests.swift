import XCTest

/// The demo has only two renewal drafts, and three of these tests use one up, so one server run
/// cannot cover them all. A test whose draft is gone skips and says so. A skip is not a pass:
/// restart `ios/scripts/dev-server.sh`, run `xcrun simctl keychain "iPhone 17" reset`, then run
/// the skipped tests. For example, run these two groups, each on a fresh server:
///
///     testConfirmsTheMeteredAmountThenIssues, testIssuesTheFixedPriceDraft, testOfflineShowsTheErrorAndRetry
///     testMissingRatesMustBeTyped, testDiscardVoidsTheDraftAfterConfirmation
final class RenewalsUITests: XCTestCase {
    private let api = RenewalsAPI()

    override func setUp() {
        continueAfterFailure = false
        api.baseURL = testServerURL
    }

    func testIssuesTheFixedPriceDraft() throws {
        let draft = try api.drafts().first { $0.lines.allSatisfy(\.amountConfirmed) }.orSkip("a fixed draft")
        let renewalBefore = try api.nextRenewal(of: draft)
        let app = openReview(of: draft)

        confirmIssue(in: app, draft: draft)

        let issued = try api.invoice(draft.id)
        XCTAssertEqual(issued.status, "issued")
        XCTAssertTrue(app.staticTexts["renewal.number"].label.hasSuffix(try XCTUnwrap(issued.number)))
        XCTAssertNotEqual(try api.nextRenewal(of: draft), renewalBefore)

        let pdf = app.buttons["renewal.pdf"]
        reveal(pdf, in: app)
        pdf.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pdf.view"].waitForExistence(timeout: 15))
        attachScreenshot(app, "issued-pdf")
        goBack(app)
        goBack(app)
        XCTAssertTrue(app.navigationBars["Renewals"].waitForExistence(timeout: 5))
        expectGone(draft, in: app)
    }

    func testConfirmsTheMeteredAmountThenIssues() throws {
        let draft = try api.drafts().first { !$0.lines[0].amountConfirmed }.orSkip("a metered draft")
        let renewalBefore = try api.nextRenewal(of: draft)
        let app = openReview(of: draft)
        attachScreenshot(app, "metered-before")

        let issue = app.buttons["renewal.issue"]
        reveal(issue, in: app)
        XCTAssertFalse(issue.isEnabled, "The server refuses an unconfirmed amount, so issuing starts disabled")

        replaceText(of: app.textFields["renewal.quantity.0"], with: "2", in: app)
        replaceText(of: app.textFields["renewal.unitPrice.0"], with: "5.125", in: app)
        let save = app.buttons["renewal.save"]
        reveal(save, in: app)
        save.tap()

        // Two lots of 5.125 OMR, shown from the server's answer with three decimals.
        waitForValue(app.staticTexts["renewal.total"], "10.250 OMR")
        attachScreenshot(app, "metered-confirmed")
        let saved = try api.invoice(draft.id)
        XCTAssertEqual(saved.status, "draft")
        XCTAssertEqual(saved.total, 102_500)
        XCTAssertEqual(saved.lines[0].quantity, 20_000)
        XCTAssertEqual(saved.lines[0].unitPrice, 51_250)
        XCTAssertTrue(saved.lines[0].amountConfirmed)
        expectOnlyAmountChanged(from: draft, to: saved)

        confirmIssue(in: app, draft: saved)

        let issued = try api.invoice(draft.id)
        XCTAssertEqual(issued.status, "issued")
        XCTAssertTrue(issued.lines[0].amountConfirmed)
        XCTAssertTrue(app.staticTexts["renewal.number"].label.hasSuffix(try XCTUnwrap(issued.number)))
        XCTAssertNotEqual(try api.nextRenewal(of: draft), renewalBefore)
    }

    func testDiscardVoidsTheDraftAfterConfirmation() throws {
        let draft = try api.drafts().first.orSkip("any draft")
        let renewalBefore = try api.nextRenewal(of: draft)
        let app = openReview(of: draft)

        let discard = app.buttons["renewal.discard"]
        reveal(discard, in: app)
        discard.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'next renewal date'")).exists)
        attachScreenshot(app, "discard-alert")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(try api.invoice(draft.id).status, "draft")

        discard.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Discard renewal"].tap()

        XCTAssertTrue(app.navigationBars["Renewals"].waitForExistence(timeout: 10))
        expectGone(draft, in: app)
        XCTAssertEqual(try api.invoice(draft.id).status, "void")
        XCTAssertNotEqual(try api.nextRenewal(of: draft), renewalBefore)
    }

    /// Clears the rates through the API, because the demo always has them, and restores them after.
    func testMissingRatesMustBeTyped() throws {
        let draft = try api.drafts().first { !$0.lines[0].amountConfirmed }.orSkip("a metered draft")
        let saved = try api.rawInvoice(draft.id)
        addTeardownBlock { [api] in try api.put(draft.id, saved) }
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var cleared = original
        cleared["fxRate"] = 0
        var line = try XCTUnwrap((original["lines"] as? [[String: Any]])?.first)
        line["costCurrency"] = "EUR"
        line["costFxRate"] = 0
        cleared["lines"] = [line]
        try api.put(draft.id, JSONSerialization.data(withJSONObject: cleared))

        let app = openReview(of: draft)
        let save = app.buttons["renewal.save"]
        let invoiceRate = app.textFields["renewal.fxRate"]
        let costRate = app.textFields["renewal.costRate.EUR"]
        reveal(costRate, in: app)
        attachScreenshot(app, "missing-rates")
        reveal(save, in: app)
        XCTAssertFalse(save.isEnabled)

        scrollToTop(app)
        replaceText(of: invoiceRate, with: "2.6", in: app)
        replaceText(of: costRate, with: "1.1", in: app)
        reveal(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["renewal.total"].waitForExistence(timeout: 10))
        try expectEventually(try self.api.invoice(draft.id).fxRate == 260_000_000)
        let updated = try api.invoice(draft.id)
        XCTAssertEqual(updated.lines[0].costFxRate, 110_000_000)
        XCTAssertEqual(updated.lines[0].quantity, draft.lines[0].quantity, "The amount was accepted as it stood")
        XCTAssertEqual(updated.lines[0].unitPrice, draft.lines[0].unitPrice)
        XCTAssertTrue(updated.lines[0].amountConfirmed)
    }

    func testOfflineShowsTheErrorAndRetry() {
        let app = launchSignedIn()
        relaunchOffline(app)
        app.tabBars.buttons["Renewals"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'offline'")).exists)
        attachScreenshot(app, "offline")
        app.terminate()
    }

    // MARK: - Steps

    private func openReview(of draft: RenewalsAPI.Draft) -> XCUIApplication {
        let app = launchSignedIn()
        app.tabBars.buttons["Renewals"].tap()
        let row = app.buttons["renewals.row.\(draft.id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attachScreenshot(app, "list")
        row.tap()
        XCTAssertTrue(app.staticTexts["renewal.status"].waitForExistence(timeout: 10))
        dismissSavePassword(app)
        return app
    }

    /// After a login on a fresh Keychain, iOS can offer to save the password over the screen.
    private func dismissSavePassword(_ app: XCUIApplication) {
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) {
                notNow.tap()
                return
            }
        }
    }

    /// Cancels once to prove nothing issues without the owner, then confirms.
    private func confirmIssue(in app: XCUIApplication, draft: RenewalsAPI.Draft) {
        let issue = app.buttons["renewal.issue"]
        reveal(issue, in: app)
        XCTAssertTrue(issue.isEnabled)
        issue.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        attachScreenshot(app, "issue-alert")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(try? api.invoice(draft.id).status, "draft")

        issue.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Issue invoice"].tap()
        scrollToTop(app)
        XCTAssertTrue(app.staticTexts["renewal.number"].waitForExistence(timeout: 20))
        attachScreenshot(app, "issued")
    }

    private func expectOnlyAmountChanged(from before: RenewalsAPI.Draft, to after: RenewalsAPI.Draft) {
        XCTAssertEqual(after.fxRate, before.fxRate)
        XCTAssertEqual(after.dueOn, before.dueOn)
        XCTAssertEqual(after.customerId, before.customerId)
        XCTAssertEqual(after.lines[0].description, before.lines[0].description)
        XCTAssertEqual(after.lines[0].periodStart, before.lines[0].periodStart)
        XCTAssertEqual(after.lines[0].subscriptionId, before.lines[0].subscriptionId)
        XCTAssertEqual(after.lines[0].costAmount, before.lines[0].costAmount)
        XCTAssertEqual(after.lines[0].costCurrency, before.lines[0].costCurrency)
        XCTAssertEqual(after.lines[0].costFxRate, before.lines[0].costFxRate)
    }

    private func expectGone(_ draft: RenewalsAPI.Draft, in app: XCUIApplication) {
        let row = app.buttons["renewals.row.\(draft.id)"]
        expectEventually(!row.exists)
        if (try? api.drafts().isEmpty) == true {
            XCTAssertTrue(app.descendants(matching: .any)["renewals.empty"].waitForExistence(timeout: 5))
            attachScreenshot(app, "empty")
        }
    }

    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: - Helpers

    private func expectEventually(
        _ condition: @autoclosure () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        for _ in 0..<40 {
            if try condition() { return }
            RunLoop.current.run(until: .now + 0.25)
        }
        XCTFail("Condition never became true", file: file, line: line)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) is not on screen")
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<4 { app.collectionViews.firstMatch.swipeDown() }
    }

    /// The first tap only focuses the field, and a double tap selects the text to replace. Text
    /// with a decimal point can be left partly selected, so anything left over is cleared.
    private func replaceText(of field: XCUIElement, with text: String, in app: XCUIApplication) {
        reveal(field, in: app)
        field.tap()
        field.doubleTap()
        field.typeText(text)
        if field.value as? String != text {
            let current = field.value as? String ?? ""
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            field.typeText(deletes + text)
        }
        XCTAssertEqual(field.value as? String, text)
        field.typeText("\n")
    }

    /// `LabeledContent` reads as "Total, 10.250 OMR", so only the end of the label is the value.
    private func waitForValue(_ element: XCUIElement, _ value: String) {
        expectEventually(element.exists && element.label.hasSuffix(value))
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension Optional {
    /// Skips the test when the demo draft it needs was already used on this server.
    func orSkip(_ what: String) throws -> Wrapped {
        guard let self else { throw XCTSkip("No \(what) left. Restart the server for this test.") }
        return self
    }
}

/// Checks the server's view of a change, separately from what the app shows.
private final class RenewalsAPI: @unchecked Sendable {
    struct Line: Decodable {
        let description: String
        let quantity: Int
        let unitPrice: Int
        let periodStart: String?
        let subscriptionId: Int?
        let costAmount: Int
        let costCurrency: String
        let costFxRate: Int
        let amountConfirmed: Bool
    }

    struct Draft: Decodable {
        let id: Int
        let status: String
        let source: String
        let number: String?
        let customerId: Int
        let dueOn: String?
        let fxRate: Int
        let total: Int
        let lines: [Line]
    }

    private struct Row: Decodable { let id: Int; let source: String }
    private struct Token: Decodable { let token: String }
    private struct SubscriptionRow: Decodable { let id: Int; let nextRenewalOn: String? }
    private final class Reply: @unchecked Sendable {
        var data: Data?
        var status = 0
    }

    var baseURL = ""
    private var token: String?

    func drafts() throws -> [Draft] {
        let rows = try JSONDecoder().decode([Row].self, from: send("GET", "invoices?type=invoice&status=draft"))
        return try rows.filter { $0.source == "renewal" }.map { try invoice($0.id) }
    }

    func invoice(_ id: Int) throws -> Draft {
        try JSONDecoder().decode(Draft.self, from: send("GET", "invoices/\(id)"))
    }

    /// The server ignores the response-only fields, so this can go straight back through `put`.
    func rawInvoice(_ id: Int) throws -> Data {
        try send("GET", "invoices/\(id)")
    }

    func put(_ id: Int, _ body: Data) throws {
        _ = try send("PUT", "invoices/\(id)", body: body)
    }

    func nextRenewal(of draft: Draft) throws -> String? {
        let id = try XCTUnwrap(draft.lines[0].subscriptionId)
        let rows = try JSONDecoder().decode([SubscriptionRow].self, from: send("GET", "subscriptions"))
        return try XCTUnwrap(rows.first { $0.id == id }).nextRenewalOn
    }

    private func signIn() throws -> String {
        if let token { return token }
        let data = try send(
            "POST",
            "auth/token",
            body: JSONSerialization.data(
                withJSONObject: ["email": "owner@example.com", "password": "demo-password", "name": "UI test"]
            ),
            authenticated: false
        )
        let value = try JSONDecoder().decode(Token.self, from: data).token
        token = value
        return value
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, authenticated: Bool = true) throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(baseURL)/api/v1/\(path)")))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { request.setValue("Bearer \(try signIn())", forHTTPHeaderField: "Authorization") }
        request.httpBody = body

        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.data = data
            reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()

        let data = try XCTUnwrap(reply.data, "\(method) \(path) got no response")
        XCTAssertTrue((200..<300).contains(reply.status), "\(method) \(path): \(String(decoding: data, as: UTF8.self))")
        return data
    }
}
