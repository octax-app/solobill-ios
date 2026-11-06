import XCTest

/// Needs a local server with demo data. See `ios/README.md`.
final class ProformasUITests: XCTestCase {
    private var api: DemoServerAPI!

    override func setUp() {
        continueAfterFailure = false
        api = DemoServerAPI(server: testServerURL)
    }

    private func unique(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(6))"
    }

    private func openForm() -> XCUIApplication {
        let app = launchSignedIn()
        app.tabBars.buttons["Proformas"].tap()
        let new = app.buttons["proformas.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        XCTAssertTrue(app.buttons["proforma.provider"].waitForExistence(timeout: 15))
        return app
    }

    private func addService(_ app: XCUIApplication, _ name: String) {
        tap(app, app.buttons["proforma.addService"])
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) is not offered")
        item.tap()
    }

    private func save(_ app: XCUIApplication) {
        tap(app, app.buttons["proforma.save"])
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 15))
    }

    private func issue(_ app: XCUIApplication) {
        tap(app, app.buttons["proforma.review.issue"])
    }

    private func assertPDFShown(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["pdf.view"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["pdf.share"].waitForExistence(timeout: 5))
    }

    func testCreateFromProviderAndLeadThenIssueAndShare() {
        let overview = api.object("GET", "overview")
        let service = unique("Managed server")
        api.addService(provider: "Contabo", name: service, price: 1_200_000, cost: 700_000)

        let app = openForm()
        choose(app, "proforma.provider", "Contabo")
        choose(app, "proforma.customer", "Layla Nasser (lead)")
        addService(app, service)

        let price = app.textFields["proforma.line.0.price"]
        XCTAssertTrue(scrolled(app, to: price))
        XCTAssertEqual(price.value as? String, "120")
        XCTAssertEqual(app.textFields["proforma.line.0.cost"].value as? String, "70")

        let tax = app.switches["proforma.taxEnabled"]
        XCTAssertTrue(scrolled(app, to: tax))
        tax.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let taxRate = app.textFields["proforma.taxRate"]
        XCTAssertTrue(scrolled(app, to: taxRate))
        XCTAssertEqual(taxRate.value as? String, "5")
        keepScreenshot("form")

        save(app)
        XCTAssertTrue(label(app, "proforma.review.total").contains("126.00 USD"))
        keepScreenshot("review")
        issue(app)
        assertPDFShown(app)
        keepScreenshot("pdf")

        let saved = api.newestProforma()
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertFalse((saved["number"] as? String ?? "").isEmpty)
        XCTAssertEqual(saved["providerId"] as? Int, api.id(ofProvider: "Contabo"))
        XCTAssertEqual(saved["total"] as? Int, 1_260_000)
        XCTAssertEqual(saved["taxRate"] as? Int, 50_000)
        let line = (saved["lines"] as? [[String: Any]])?.first
        XCTAssertEqual(line?["unitPrice"] as? Int, 1_200_000)
        XCTAssertEqual(line?["costAmount"] as? Int, 700_000)
        XCTAssertEqual(line?["costFxRate"] as? Int, 100_000_000)

        let after = api.object("GET", "overview")
        XCTAssertEqual((after["summary"] as? [String: Any])?["revenue"] as? Int, (overview["summary"] as? [String: Any])?["revenue"] as? Int)
        XCTAssertEqual(after["toCollectTotal"] as? Int, overview["toCollectTotal"] as? Int)
        let customer = api.object("GET", "customers/\(api.id(ofCustomer: "Layla Nasser"))")
        XCTAssertEqual(customer["status"] as? String, "lead")
    }

    func testNonBaseCurrencySendsTheRates() throws {
        let code = try XCTUnwrap(api.currencyWithoutRate())
        let service = unique("Backup plan")
        api.addService(provider: "Contabo", name: service, price: 500_000, cost: 300_000)

        let app = openForm()
        choose(app, "proforma.provider", "Contabo")
        choose(app, "proforma.customer", "Al Noor Clinics")
        addService(app, service)

        // The form is in OMR and the service in USD, so the USD price must not be used as OMR.
        let rate = app.textFields["proforma.fxRate"]
        XCTAssertTrue(scrolled(app, to: rate))
        XCTAssertEqual(rate.value as? String, "2.6")
        let price = app.textFields["proforma.line.0.price"]
        XCTAssertTrue(scrolled(app, to: price))
        XCTAssertNotEqual(price.value as? String, "50")
        XCTAssertTrue(app.staticTexts["proforma.line.0.priceHint"].label.contains("50.00 USD"))
        type(app, "12.345", into: price)

        // A cost in a currency with no rate yet: the owner is asked for it.
        choose(app, "proforma.line.0.costCurrency", code)
        let costRate = app.textFields["proforma.line.0.costRate"]
        XCTAssertTrue(scrolled(app, to: costRate))
        tap(app, app.buttons["proforma.save"])
        XCTAssertTrue(label(app, "proforma.error").contains("Enter the exchange rate for \(code)"))
        keepScreenshot("rate-needed")
        type(app, "0.4", into: costRate)

        save(app)
        XCTAssertTrue(label(app, "proforma.review.total").contains("12.345 OMR"))
        keepScreenshot("review-omr")
        issue(app)
        assertPDFShown(app)
        keepScreenshot("pdf-omr")

        let saved = api.newestProforma()
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual(saved["currency"] as? String, "OMR")
        XCTAssertEqual(saved["fxRate"] as? Int, 260_000_000)
        XCTAssertEqual(saved["total"] as? Int, 123_450)
        let line = (saved["lines"] as? [[String: Any]])?.first
        XCTAssertEqual(line?["costCurrency"] as? String, code)
        XCTAssertEqual(line?["costFxRate"] as? Int, 40_000_000)
    }

    func testCustomerCurrencyWithNoRateAsksForIt() throws {
        let code = try XCTUnwrap(api.currencyWithoutRate())
        let name = unique("Rate test customer")
        _ = api.object("POST", "customers", ["name": name, "status": "lead", "currency": code])

        let app = openForm()
        choose(app, "proforma.customer", "\(name) (lead)")
        let rate = app.textFields["proforma.fxRate"]
        XCTAssertTrue(scrolled(app, to: rate))
        XCTAssertTrue(app.staticTexts["There is no rate for \(code) yet. Type the rate."].exists)
        type(app, "0.5", into: rate)

        tap(app, app.buttons["proforma.addLine"])
        type(app, "Setup", into: app.textFields["proforma.line.0.description"])
        type(app, "10", into: app.textFields["proforma.line.0.price"])
        save(app)
        issue(app)
        assertPDFShown(app)

        let saved = api.newestProforma()
        XCTAssertEqual(saved["currency"] as? String, code)
        XCTAssertEqual(saved["fxRate"] as? Int, 50_000_000)
    }

    func testOfflineShowsTheErrorAndRetry() {
        let app = relaunchOffline(launchSignedIn())
        app.tabBars.buttons["Proformas"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["You appear to be offline. Check your connection and try again."].exists)
        keepScreenshot("offline-list")

        app.buttons["proformas.new"].tap()
        XCTAssertTrue(app.buttons["proforma.cancel"].waitForExistence(timeout: 5))
        // The list stays behind the sheet with its own Retry, so this waits for a second one.
        XCTAssertTrue(app.buttons.matching(identifier: "retry").element(boundBy: 1).waitForExistence(timeout: 15))
        app.buttons["proforma.cancel"].tap()
    }

    func testAFailedIssueKeepsTheDraftAndRetriesWithoutADuplicate() {
        let number = unique("PF").replacingOccurrences(of: " ", with: "-")
        let before = api.proformas().count

        let app = openForm()
        choose(app, "proforma.customer", "Haddad Logistics")
        tap(app, app.buttons["proforma.addLine"])
        type(app, "Domain transfer", into: app.textFields["proforma.line.0.description"])
        type(app, "25", into: app.textFields["proforma.line.0.price"])
        type(app, number, into: app.textFields["proforma.number"])
        save(app)

        // Back and save again updates the same draft.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        type(app, "Paid in advance", into: app.textFields["proforma.notes"])
        save(app)
        XCTAssertEqual(api.proformas().count, before + 1)
        let draft = api.newestProforma()
        XCTAssertEqual(draft["notes"] as? String, "Paid in advance")

        let blocker = api.issueProforma(number: number, customerId: draft["customerId"] as? Int ?? 0)
        issue(app)
        XCTAssertTrue(label(app, "proforma.review.error").contains("is already used"))
        keepScreenshot("issue-failed")
        let id = draft["id"] as? Int ?? 0
        XCTAssertEqual(api.invoice(id)["status"] as? String, "draft")

        _ = api.object("POST", "invoices/\(blocker)/void")
        issue(app)
        assertPDFShown(app)

        XCTAssertEqual(api.invoice(id)["status"] as? String, "issued")
        XCTAssertEqual(api.invoice(id)["number"] as? String, number)
        XCTAssertEqual(api.proformas().count, before + 2, "One draft plus the blocking proforma")
    }

    func testADraftLeftBehindCanBeIssuedFromTheList() {
        let app = openForm()
        choose(app, "proforma.customer", "Haddad Logistics")
        tap(app, app.buttons["proforma.addLine"])
        type(app, "Email hosting", into: app.textFields["proforma.line.0.description"])
        type(app, "15", into: app.textFields["proforma.line.0.price"])
        save(app)
        let id = api.newestProforma()["id"] as? Int ?? 0

        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, app.buttons["proforma.cancel"])
        let row = app.buttons["proforma.row.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        keepScreenshot("list")
        row.tap()
        issue(app)
        assertPDFShown(app)
        XCTAssertEqual(api.invoice(id)["status"] as? String, "issued")
    }

    func testIssuedProformaOpensItsDetails() {
        let app = launchSignedIn()
        app.tabBars.buttons["Proformas"].tap()
        let issued = api.proformas().first { $0["status"] as? String == "issued" }
        let row = app.buttons["proforma.row.\(issued?["id"] as? Int ?? 0)"]
        tap(app, row)
        XCTAssertTrue(app.navigationBars.buttons["Proformas"].waitForExistence(timeout: 5))
    }
}
