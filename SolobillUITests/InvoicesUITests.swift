import XCTest

/// Needs a local server with the demo data. See `ios/README.md`. Tests that change a document
/// create their own through the API, so they never touch data another test reads.
@MainActor
final class InvoicesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openInvoices(_ app: XCUIApplication) {
        app.tabBars.buttons["Invoices"].tap()
        XCTAssertTrue(app.segmentedControls["invoices.kind"].waitForExistence(timeout: 10))
    }

    /// Scrolls the list until `target` can be tapped.
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !(target.exists && target.isHittable), attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 2))
    }

    private func replaceText(of field: XCUIElement, with text: String) {
        field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    func testMarkAsPaidAndRemovingThePaymentReachTheServer() async throws {
        let api = try await TestAPI.signIn(server: testServerURL)
        let invoice = try await api.createIssuedInvoice()

        let app = launchSignedIn()
        openInvoices(app)
        let row = element(app, "invoice.row.\(invoice.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let status = element(app, "invoice.status")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Issued"))

        let markPaid = element(app, "invoice.markPaid")
        scrollTo(markPaid, in: app)
        markPaid.tap()
        let save = app.buttons["markPaid.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payment.delete.'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        let paid = try await api.invoice(id: invoice.id)
        XCTAssertEqual(paid.status, "paid")
        XCTAssertNotNil(paid.paidOn)

        scrollTo(remove, in: app)
        remove.tap()
        // The alert lists each of its buttons more than once.
        let confirm = app.alerts.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(app, "invoice.markPaid").waitForExistence(timeout: 10))
        let unpaid = try await api.invoice(id: invoice.id)
        XCTAssertEqual(unpaid.status, "issued")
        XCTAssertNil(unpaid.paidOn)
    }

    func testAPartPaymentLeavesTheRestDueAndADiscountClosesIt() async throws {
        let api = try await TestAPI.signIn(server: testServerURL)
        let invoice = try await api.createIssuedInvoice()

        let app = launchSignedIn()
        openInvoices(app)
        let row = element(app, "invoice.row.\(invoice.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 10))

        let addPayment = element(app, "invoice.addPayment")
        scrollTo(addPayment, in: app)
        addPayment.tap()
        let amount = app.textFields["payment.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        replaceText(of: amount, with: "1")
        app.buttons["payment.save"].tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payment.delete.'")).firstMatch.waitForExistence(timeout: 10))
        let partial = try await api.invoice(id: invoice.id)
        XCTAssertEqual(partial.status, "issued")
        XCTAssertNil(partial.paidOn)

        let addDiscount = element(app, "invoice.addDiscount")
        scrollTo(addDiscount, in: app)
        addDiscount.tap()
        let save = app.buttons["payment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(element(app, "invoice.discount").waitForExistence(timeout: 10))
        let settled = try await api.invoice(id: invoice.id)
        XCTAssertEqual(settled.status, "paid")
        XCTAssertNotNil(settled.paidOn)
    }

    func testACustomerPaymentShowsItsSplitAndRefusesACurrencyWithNothingOpen() async throws {
        let api = try await TestAPI.signIn(server: testServerURL)
        _ = try await api.createIssuedInvoice()

        let app = launchSignedIn()
        app.tabBars.buttons["Customers"].tap()
        let customer = app.staticTexts["Haddad Logistics"]
        XCTAssertTrue(customer.waitForExistence(timeout: 10))
        customer.tap()

        let add = element(app, "customer.addPayment")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        scrollTo(add, in: app)
        add.tap()

        let amount = app.textFields["customerPayment.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("1")
        let split = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'customerPayment.split.'")).firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["customerPayment.save"].isEnabled)

        app.buttons["customerPayment.currency"].tap()
        app.buttons["GBP"].tap()
        XCTAssertTrue(element(app, "customerPayment.noOpen").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["customerPayment.save"].isEnabled)
    }

    func testThePaidFilterShowsTheOMRInvoiceWithThreeDecimals() {
        let app = launchSignedIn()
        openInvoices(app)
        app.segmentedControls["invoices.status"].buttons["Paid"].tap()
        let amount = app.staticTexts["25.000 OMR"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.tap()

        let total = element(app, "invoice.total")
        scrollTo(total, in: app)
        XCTAssertTrue(total.label.contains("25.000 OMR"))
    }

    func testAnInvoiceOpensItsPDFWithAShareButton() {
        let app = launchSignedIn()
        openInvoices(app)
        let row = app.staticTexts["Haddad Logistics"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let open = element(app, "invoice.pdf")
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 10))
        scrollTo(open, in: app)
        open.tap()
        XCTAssertTrue(element(app, "pdf.view").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "pdf.share").waitForExistence(timeout: 5))
    }

    func testAProformaOpensWithoutMarkAsPaid() async throws {
        let api = try await TestAPI.signIn(server: testServerURL)
        let proforma = try await api.firstIssuedProforma()

        let app = launchSignedIn()
        app.tabBars.buttons["Customers"].tap()
        let customer = app.staticTexts[proforma.customerCompany]
        XCTAssertTrue(customer.waitForExistence(timeout: 10))
        customer.tap()
        XCTAssertTrue(app.staticTexts["Subscriptions"].waitForExistence(timeout: 10))
        let row = element(app, "customer.invoice.\(proforma.id)")
        scrollTo(row, in: app)
        row.tap()

        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Proforma'")).firstMatch.exists)
        scrollTo(element(app, "invoice.pdf"), in: app)
        XCTAssertFalse(element(app, "invoice.markPaid").exists)
    }

    func testOriginalListMarksPaidOpensThePDFAndAddPresentsTheForm() async throws {
        let api = try await TestAPI.signIn(server: testServerURL)
        let original = try await api.createOriginalWithPDF()

        let app = launchSignedIn()
        openInvoices(app)
        app.segmentedControls["invoices.kind"].buttons["Original"].tap()

        let add = app.buttons["originals.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        // The form blocks swiping away, so typed details are not lost by accident.
        let cancel = app.buttons["capture.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(add.waitForHittable(timeout: 5))

        let row = element(app, "original.row.\(original.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollTo(row, in: app)
        row.tap()

        let status = element(app, "original.status")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Unpaid"))

        let pdf = element(app, "original.pdf")
        scrollTo(pdf, in: app)
        pdf.tap()
        XCTAssertTrue(element(app, "pdf.view").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "pdf.share").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let markPaid = element(app, "original.markPaid")
        scrollTo(markPaid, in: app)
        markPaid.tap()
        let save = app.buttons["markPaid.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        let undo = element(app, "original.undoPaid")
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        let paid = try await api.original(id: original.id)
        XCTAssertNotNil(paid.paidOn)

        undo.tap()
        XCTAssertTrue(element(app, "original.markPaid").waitForExistence(timeout: 10))
        let unpaid = try await api.original(id: original.id)
        XCTAssertNil(unpaid.paidOn)
    }

    func testOfflineShowsTheErrorAndRetryOnBothLists() {
        let app = relaunchOffline(launchSignedIn())
        openInvoices(app)
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Could not load"].exists)

        app.segmentedControls["invoices.kind"].buttons["Original"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        app.buttons["retry"].tap()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: self)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }
}

/// A small API client for arranging data and checking the server's view of a change.
private struct TestAPI {
    struct Document: Decodable {
        let id: Int
        let status: String
        let paidOn: String?
    }

    struct Row: Decodable {
        let id: Int
        let status: String
        let customerCompany: String
    }

    struct Original: Decodable {
        let id: Int
        let paidOn: String?
    }

    private struct Named: Decodable {
        let id: Int
        let name: String
    }

    let server: String
    let token: String

    static func signIn(server: String) async throws -> TestAPI {
        struct Token: Decodable { let token: String }
        let body = ["email": "owner@example.com", "password": "demo-password", "name": "UI tests"]
        let api = TestAPI(server: server, token: "")
        let token: Token = try await api.call("POST", "auth/token", body: body)
        return TestAPI(server: server, token: token.token)
    }

    func invoice(id: Int) async throws -> Document { try await call("GET", "invoices/\(id)") }
    func original(id: Int) async throws -> Original { try await call("GET", "originals/\(id)") }

    func firstIssuedProforma() async throws -> Row {
        let rows: [Row] = try await call("GET", "invoices?type=proforma&status=issued")
        return try XCTUnwrap(rows.first)
    }

    func createIssuedInvoice() async throws -> Document {
        struct Customer: Decodable {
            let id: Int
            let company: String
        }
        struct Line: Encodable {
            let description = "UI test line"
            let quantity = 10_000
            let unitPrice = 1_000_000
            let costAmount = 0
            let costCurrency = "USD"
            let costFxRate = 100_000_000
        }
        struct Body: Encodable {
            let type = "invoice"
            let customerId: Int
            let currency = "USD"
            let fxRate = 100_000_000
            let taxEnabled = false
            let taxRate = 0
            let lines = [Line()]
        }
        let customers: [Customer] = try await call("GET", "customers?q=Haddad")
        let customer = try XCTUnwrap(customers.first)
        let draft: Document = try await call("POST", "invoices", body: Body(customerId: customer.id))
        return try await call("POST", "invoices/\(draft.id)/issue")
    }

    func createOriginalWithPDF() async throws -> Original {
        struct Line: Encodable {
            let description = "UI test original"
            let quantity = 10_000
            let unitPrice = 100_000
        }
        struct Body: Encodable {
            let providerId: Int
            let number: String
            let issuedOn = "2026-10-01"
            let currency = "USD"
            let fxRate = 100_000_000
            let lines = [Line()]
        }
        let providers: [Named] = try await call("GET", "providers")
        let provider = try XCTUnwrap(providers.first)
        let original: Original = try await call(
            "POST",
            "originals",
            body: Body(providerId: provider.id, number: "UI-\(UUID().uuidString.prefix(8))")
        )
        // Any issued customer invoice is a valid PDF to attach.
        let rows: [Row] = try await call("GET", "invoices?type=invoice&status=paid")
        let pdf = try await bytes("invoices/\(try XCTUnwrap(rows.first).id)/pdf")
        try await upload(pdf, toOriginal: original.id)
        return original
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server)/api/v1/\(path)")))
        request.httpMethod = method
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func call<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        let (data, _) = try await URLSession.shared.data(for: try request(method, path))
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func call<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: some Encodable
    ) async throws -> Response {
        var request = try request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func bytes(_ path: String) async throws -> Data {
        try await URLSession.shared.data(for: try request("GET", path)).0
    }

    private func upload(_ pdf: Data, toOriginal id: Int) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"original.pdf\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try request("POST", "originals/\(id)/pdf")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
