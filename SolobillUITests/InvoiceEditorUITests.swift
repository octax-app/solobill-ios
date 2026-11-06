import XCTest

private extension DemoServerAPI {
    func addCustomer(_ name: String, currency: String = "USD") -> Int {
        object("POST", "customers", ["name": name, "status": "active", "currency": currency])["id"] as? Int ?? 0
    }

    func serviceID(named name: String) -> Int {
        list("services").first { $0["name"] as? String == name }?["id"] as? Int ?? 0
    }

    func addSubscription(customerId: Int, serviceId: Int) -> JSON {
        object("POST", "subscriptions", [
            "customerId": customerId, "serviceId": serviceId, "startedOn": "2026-10-01",
            "costCurrency": "USD", "priceCurrency": "USD",
            "lines": [["description": "Backup seats", "costAmount": 100_000, "priceAmount": 300_000]],
        ])
    }

    func draftLine(_ overrides: JSON = [:]) -> JSON {
        let line: JSON = [
            "description": "Support", "quantity": 10_000, "unitPrice": 1_000_000,
            "costAmount": 200_000, "costCurrency": "USD", "costFxRate": 100_000_000,
        ]
        return line.merging(overrides) { _, new in new }
    }

    func addDraft(type: String = "invoice", customerId: Int, line: JSON? = nil, fields: JSON = [:]) -> Int {
        let body: JSON = [
            "type": type, "customerId": customerId, "currency": "USD", "fxRate": 100_000_000,
            "taxEnabled": false, "taxRate": 0, "lines": [line ?? draftLine()],
        ]
        return object("POST", "invoices", body.merging(fields) { _, new in new })["id"] as? Int ?? 0
    }

    /// A second template, made from a real PDF, and a provider that defaults to it.
    func addTemplateAndProvider(_ name: String, customerId: Int) -> (template: Int, provider: Int) {
        let pdf = bytes("invoices/\(addIssued(customerId: customerId))/pdf")
        let template = upload("templates", name: name, pdf: pdf)["id"] as? Int ?? 0
        let provider = object("POST", "providers", ["name": name, "defaultTemplateId": template])["id"] as? Int ?? 0
        return (template, provider)
    }

    func addIssued(type: String = "invoice", customerId: Int) -> Int {
        let id = addDraft(type: type, customerId: customerId)
        _ = object("POST", "invoices/\(id)/issue")
        return id
    }
}

/// Needs a local server with demo data. See `ios/README.md`.
final class InvoiceEditorUITests: XCTestCase {
    private var api: DemoServerAPI!

    override func setUp() {
        continueAfterFailure = false
        api = DemoServerAPI(server: testServerURL)
    }

    /// Sorts last, so these do not push the seeded customers off the lists other tests read.
    private func unique(_ prefix: String) -> String {
        "Zz \(prefix) \(UUID().uuidString.prefix(6))"
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openForm() -> XCUIApplication {
        let app = launchSignedIn()
        app.tabBars.buttons["Invoices"].tap()
        let new = app.buttons["invoices.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        XCTAssertTrue(app.buttons["invoice.customer"].waitForExistence(timeout: 15))
        return app
    }

    private func openInvoice(_ id: Int, filter: String) -> XCUIApplication {
        let app = launchSignedIn()
        app.tabBars.buttons["Invoices"].tap()
        let status = app.segmentedControls["invoices.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.buttons[filter].tap()
        let row = element(app, "invoice.row.\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        tap(app, row)
        return app
    }

    private func pick(_ app: XCUIApplication, _ link: String, startingWith name: String) {
        tap(app, app.buttons[link])
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) is not offered")
        item.tap()
    }

    private func save(_ app: XCUIApplication) {
        tap(app, app.buttons["invoice.save"])
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 15))
    }

    private func addTypedLine(_ app: XCUIApplication, position: Int = 0, _ description: String, price: String) {
        tap(app, app.buttons["invoice.addLine"])
        type(app, description, into: app.textFields["invoice.line.\(position).description"])
        type(app, price, into: app.textFields["invoice.line.\(position).price"])
    }

    func testCreateWithServiceSubscriptionAndTypedLineThenIssue() {
        let customer = unique("Invoice customer")
        let customerId = api.addCustomer(customer)
        let serviceName = unique("Managed server")
        api.addService(provider: "Contabo", name: serviceName, price: 1_000_000, cost: 400_000)
        let serviceId = api.serviceID(named: serviceName)
        let subscription = api.addSubscription(customerId: customerId, serviceId: serviceId)

        let app = openForm()
        choose(app, "invoice.provider", "Contabo")
        choose(app, "invoice.customer", customer)
        pick(app, "invoice.addService", startingWith: serviceName)
        pick(app, "invoice.addSubscription", startingWith: serviceName)
        addTypedLine(app, position: 2, "Setup", price: "5")
        let due = app.switches["invoice.hasDueOn"]
        XCTAssertTrue(scrolled(app, to: due))
        due.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual("\(due.value ?? "")", "1")
        keepScreenshot("invoice-form")

        save(app)
        XCTAssertTrue(label(app, "invoice.review.total").contains("135.00 USD"))
        keepScreenshot("invoice-review")
        tap(app, app.buttons["invoice.review.issue"])
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "invoice.status").label.contains("Issued"))
        keepScreenshot("invoice-issued")

        let row = api.list("invoices?customerId=\(customerId)")
        XCTAssertEqual(row.count, 1)
        let saved = api.invoice(row[0]["id"] as? Int ?? 0)
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual(saved["type"] as? String, "invoice")
        XCTAssertEqual(saved["total"] as? Int, 1_350_000)
        XCTAssertEqual(saved["serviceId"] as? Int, serviceId)
        XCTAssertFalse(saved["dueOn"] is NSNull)
        let lines = saved["lines"] as? [[String: Any]] ?? []
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1]["subscriptionId"] as? Int, subscription["id"] as? Int)
        XCTAssertEqual(lines[1]["description"] as? String, "Backup seats")
        XCTAssertEqual(lines[1]["costAmount"] as? Int, 100_000)
    }

    func testSavingAgainUpdatesOneDraftAndKeepAsDraftCloses() {
        let customer = unique("One draft customer")
        let customerId = api.addCustomer(customer)

        let app = openForm()
        choose(app, "invoice.customer", customer)
        addTypedLine(app, "Domain", price: "10")
        save(app)
        app.navigationBars["Review"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["New invoice"].waitForExistence(timeout: 15))
        type(app, "Second save", into: app.textFields["invoice.notes"])
        save(app)
        tap(app, app.buttons["invoice.review.keep"])
        XCTAssertTrue(app.segmentedControls["invoices.status"].waitForExistence(timeout: 5))

        let rows = api.list("invoices?customerId=\(customerId)")
        XCTAssertEqual(rows.count, 1)
        let id = rows[0]["id"] as? Int ?? 0
        XCTAssertEqual(api.invoice(id)["notes"] as? String, "Second save")
        XCTAssertEqual(api.invoice(id)["status"] as? String, "draft")
        XCTAssertTrue(element(app, "invoice.row.\(id)").waitForExistence(timeout: 10))
    }

    func testEditingADraftKeepsItsHiddenFieldsAndTemplate() {
        let customerId = api.addCustomer(unique("Edit customer"))
        let serviceName = unique("Edit service")
        api.addService(provider: "Contabo", name: serviceName, price: 1_000_000, cost: 400_000)
        let serviceId = api.serviceID(named: serviceName)
        let subscription = api.addSubscription(customerId: customerId, serviceId: serviceId)
        let subscriptionId = subscription["id"] as? Int ?? 0
        let lineId = (subscription["lines"] as? [[String: Any]])?.first?["id"] as? Int ?? 0
        // Contabo resolves to the default template, so opening this draft must not switch to it.
        let template = api.addTemplateAndProvider(unique("Edit layout"), customerId: customerId).template
        let id = api.addDraft(
            customerId: customerId,
            line: api.draftLine([
                "subscriptionId": subscriptionId, "subscriptionLineId": lineId,
                "periodStart": "2026-10-01", "description": "Backup seats",
            ]),
            fields: [
                "providerId": api.id(ofProvider: "Contabo"), "serviceId": serviceId,
                "templateId": template, "dueOn": "2026-12-15", "issueDate": "2026-10-15",
            ]
        )

        let app = openInvoice(id, filter: "Draft")
        tap(app, app.buttons["invoice.review.edit"])
        XCTAssertTrue(app.navigationBars["Edit invoice"].waitForExistence(timeout: 15))
        let price = app.textFields["invoice.line.0.price"]
        XCTAssertTrue(scrolled(app, to: price))
        XCTAssertEqual(price.value as? String, "100")
        type(app, "5", into: price)
        keepScreenshot("edit-draft")
        save(app)
        tap(app, app.buttons["invoice.review.keep"])

        let saved = api.invoice(id)
        XCTAssertEqual(saved["status"] as? String, "draft")
        XCTAssertEqual(saved["templateId"] as? Int, template)
        XCTAssertEqual(saved["serviceId"] as? Int, serviceId)
        XCTAssertEqual(saved["dueOn"] as? String, "2026-12-15")
        XCTAssertEqual(saved["issueDate"] as? String, "2026-10-15")
        XCTAssertEqual(saved["total"] as? Int, 10_050_000)
        let line = (saved["lines"] as? [[String: Any]])?.first
        XCTAssertEqual(line?["subscriptionId"] as? Int, subscriptionId)
        XCTAssertEqual(line?["subscriptionLineId"] as? Int, lineId)
        XCTAssertEqual(line?["periodStart"] as? String, "2026-10-01")
        XCTAssertEqual(line?["unitPrice"] as? Int, 10_050_000)
    }

    func testARequiredCustomItemStopsTheIssueUntilItIsFilled() throws {
        let template = try XCTUnwrap(api.list("templates").first { $0["isDefault"] as? Bool == true })
        let templateId = try XCTUnwrap(template["id"] as? Int)
        let regions = template["regions"] ?? []
        let fieldId = UUID().uuidString.lowercased()
        _ = api.object("PUT", "templates/\(templateId)/regions", [
            "regions": regions,
            "customFields": [[
                "id": fieldId, "label": "PO number", "type": "text", "required": true, "order": 0, "region": "document_meta",
            ]],
        ])
        nonisolated(unsafe) let restored: [String: Any] = ["regions": regions, "customFields": []]
        addTeardownBlock { [api] in
            _ = api?.object("PUT", "templates/\(templateId)/regions", restored)
        }
        let customer = unique("Custom item customer")
        let customerId = api.addCustomer(customer)

        let app = openForm()
        choose(app, "invoice.customer", customer)
        let item = app.textFields["invoice.custom.\(fieldId)"]
        XCTAssertTrue(scrolled(app, to: item))
        addTypedLine(app, "Domain", price: "10")
        save(app)
        tap(app, app.buttons["invoice.review.issue"])
        XCTAssertTrue(label(app, "invoice.review.error").contains("Enter PO number"))
        keepScreenshot("custom-item-required")

        app.navigationBars["Review"].buttons.element(boundBy: 0).tap()
        type(app, "PO-77", into: app.textFields["invoice.custom.\(fieldId)"])
        save(app)
        tap(app, app.buttons["invoice.review.issue"])
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 15))

        let rows = api.list("invoices?customerId=\(customerId)")
        let saved = api.invoice(rows[0]["id"] as? Int ?? 0)
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual((saved["customValues"] as? [String: Any])?[fieldId] as? String, "PO-77")
    }

    func testChangingTheProviderPicksItsTemplate() {
        let name = unique("Layout provider")
        _ = api.addTemplateAndProvider(name, customerId: api.addCustomer(unique("Layout customer")))

        let app = openForm()
        choose(app, "invoice.provider", name)
        let picker = app.buttons["invoice.template"]
        XCTAssertTrue(scrolled(app, to: picker))
        let updated = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)
        wait(for: [expectation(for: updated, evaluatedWith: picker)], timeout: 10)
    }

    func testACustomerPageOpensTheFormWithThatCustomer() {
        let customer = unique("Page customer")
        let customerId = api.addCustomer(customer)

        let app = launchSignedIn()
        app.tabBars.buttons["Customers"].tap()
        let row = element(app, "customer.row.\(customerId)")
        XCTAssertTrue(scrolled(app, to: row))
        row.tap()
        tap(app, app.buttons["customer.newInvoice"])
        let picker = app.buttons["invoice.customer"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertTrue("\(picker.label) \(picker.value as? String ?? "")".contains(customer))
        addTypedLine(app, "Domain", price: "10")
        save(app)
        tap(app, app.buttons["invoice.review.issue"])
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 15))

        XCTAssertEqual(api.list("invoices?customerId=\(customerId)").count, 1)
    }

    func testADraftCanBeDeleted() {
        let customerId = api.addCustomer(unique("Delete customer"))
        let id = api.addDraft(customerId: customerId)

        let app = openInvoice(id, filter: "Draft")
        tap(app, app.buttons["invoice.review.delete"])
        let confirm = app.alerts.buttons["Delete draft"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.segmentedControls["invoices.status"].waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: element(app, "invoice.row.\(id)"))], timeout: 10)
        XCTAssertTrue(api.list("invoices?customerId=\(customerId)").isEmpty)
    }

    func testARenewalDraftGoesToTheRenewalReview() throws {
        let draft = api.list("invoices?type=invoice&status=draft").first { $0["source"] as? String == "renewal" }
        let id = try XCTUnwrap(draft?["id"] as? Int, "The demo renewal drafts are used up. Use a fresh server.")

        let app = openInvoice(id, filter: "Draft")
        XCTAssertFalse(app.buttons["invoice.review.edit"].waitForExistence(timeout: 3))
        tap(app, app.buttons["invoice.reviewRenewal"])
        XCTAssertTrue(app.navigationBars["Renewal draft"].waitForExistence(timeout: 15))
        XCTAssertEqual(api.invoice(id)["status"] as? String, "draft")
    }

    func testVoidStopsAnInvoiceCounting() {
        let before = api.object("GET", "overview")["toCollectTotal"] as? Int
        let customerId = api.addCustomer(unique("Void customer"))
        let id = api.addIssued(customerId: customerId)
        let number = api.invoice(id)["number"] as? String
        XCTAssertNotEqual(api.object("GET", "overview")["toCollectTotal"] as? Int, before)

        let app = openInvoice(id, filter: "Issued")
        tap(app, app.buttons["invoice.void"])
        let confirm = app.alerts.buttons["Void document"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let voided = NSPredicate(format: "label CONTAINS 'Void'")
        wait(for: [expectation(for: voided, evaluatedWith: element(app, "invoice.status"))], timeout: 15)
        XCTAssertEqual(api.invoice(id)["status"] as? String, "void")
        XCTAssertEqual(api.invoice(id)["number"] as? String, number)
        XCTAssertEqual(api.object("GET", "overview")["toCollectTotal"] as? Int, before)
    }

    func testConvertingAProformaOpensADraftInvoice() {
        let customerId = api.addCustomer(unique("Convert customer"))
        let proforma = api.addIssued(type: "proforma", customerId: customerId)

        let app = launchSignedIn()
        app.tabBars.buttons["Proformas"].tap()
        let row = element(app, "proforma.row.\(proforma)")
        XCTAssertTrue(scrolled(app, to: row))
        row.tap()
        tap(app, app.buttons["invoice.convert"])
        XCTAssertTrue(app.navigationBars["Edit invoice"].waitForExistence(timeout: 15))
        keepScreenshot("converted-draft")
        save(app)
        tap(app, app.buttons["invoice.review.issue"])
        let issued = NSPredicate(format: "label CONTAINS 'Issued'")
        wait(for: [expectation(for: issued, evaluatedWith: element(app, "invoice.status"))], timeout: 15)

        XCTAssertEqual(api.invoice(proforma)["status"] as? String, "converted")
        let invoices = api.list("invoices?type=invoice&customerId=\(customerId)")
        XCTAssertEqual(invoices.count, 1)
        let saved = api.invoice(invoices[0]["id"] as? Int ?? 0)
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual(saved["convertedFromId"] as? Int, proforma)
    }

    func testReversingKeepsTheNumberAndReissuingDoesNotAdvanceTheRenewalTwice() {
        let customerId = api.addCustomer(unique("Reverse customer"))
        let serviceName = unique("Reverse service")
        api.addService(provider: "Contabo", name: serviceName, price: 1_000_000, cost: 400_000)
        let subscription = api.addSubscription(customerId: customerId, serviceId: api.serviceID(named: serviceName))
        let subscriptionId = subscription["id"] as? Int ?? 0
        let lineId = (subscription["lines"] as? [[String: Any]])?.first?["id"] as? Int ?? 0
        let id = api.addDraft(customerId: customerId, line: api.draftLine([
            "subscriptionId": subscriptionId, "subscriptionLineId": lineId, "description": "Backup seats",
        ]))
        _ = api.object("POST", "invoices/\(id)/issue")
        let issued = api.invoice(id)
        let number = issued["number"] as? String
        let period = (issued["lines"] as? [[String: Any]])?.first?["periodStart"] as? String
        XCTAssertNotNil(period)
        let renewal = api.list("subscriptions?customerId=\(customerId)").first?["nextRenewalOn"] as? String

        let app = openInvoice(id, filter: "Issued")
        tap(app, app.buttons["invoice.reverse"])
        let confirm = app.alerts.buttons["Reverse document"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        keepScreenshot("reverse-confirm")
        confirm.tap()

        let edit = app.buttons["invoice.review.edit"]
        XCTAssertTrue(scrolled(app, to: edit))
        let draft = api.invoice(id)
        XCTAssertEqual(draft["status"] as? String, "draft")
        XCTAssertEqual(draft["number"] as? String, number)
        XCTAssertTrue(draft["pdfFile"] is NSNull)
        XCTAssertTrue(draft["issuedOn"] is NSNull)
        XCTAssertEqual(draft["issueDate"] as? String, issued["issuedOn"] as? String)

        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit invoice"].waitForExistence(timeout: 15))
        let field = app.textFields["invoice.number"]
        XCTAssertTrue(scrolled(app, to: field))
        XCTAssertEqual(field.value as? String, number)
        let price = app.textFields["invoice.line.0.price"]
        XCTAssertTrue(scrolled(app, to: price))
        type(app, "5", into: price)
        save(app)
        tap(app, app.buttons["invoice.review.keep"])
        tap(app, app.buttons["invoice.review.issue"])
        let reissued = NSPredicate(format: "label CONTAINS 'Issued'")
        wait(for: [expectation(for: reissued, evaluatedWith: element(app, "invoice.status"))], timeout: 15)

        let saved = api.invoice(id)
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual(saved["number"] as? String, number)
        XCTAssertEqual(saved["issuedOn"] as? String, issued["issuedOn"] as? String)
        XCTAssertEqual(saved["total"] as? Int, 10_050_000)
        XCTAssertEqual((saved["lines"] as? [[String: Any]])?.first?["periodStart"] as? String, period)
        XCTAssertEqual(api.list("subscriptions?customerId=\(customerId)").first?["nextRenewalOn"] as? String, renewal)
        XCTAssertFalse(api.bytes("invoices/\(id)/pdf").isEmpty)
    }

    func testReverseIsNotOfferedOnceAPaymentIsRecorded() {
        let customerId = api.addCustomer(unique("Paid part customer"))
        let id = api.addIssued(customerId: customerId)
        _ = api.object("POST", "invoices/\(id)/payments", ["kind": "payment", "amount": 10_000])

        let app = openInvoice(id, filter: "Issued")
        XCTAssertTrue(scrolled(app, to: app.buttons["invoice.void"]))
        XCTAssertFalse(app.buttons["invoice.reverse"].exists)
    }

    func testAReversedProformaReturnsToDraft() {
        let customerId = api.addCustomer(unique("Reverse proforma customer"))
        let id = api.addIssued(type: "proforma", customerId: customerId)
        let number = api.invoice(id)["number"] as? String

        let app = launchSignedIn()
        app.tabBars.buttons["Proformas"].tap()
        let row = element(app, "proforma.row.\(id)")
        XCTAssertTrue(scrolled(app, to: row))
        row.tap()
        tap(app, app.buttons["invoice.reverse"])
        let confirm = app.alerts.buttons["Reverse document"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(scrolled(app, to: app.buttons["proforma.review.edit"]))
        XCTAssertEqual(api.invoice(id)["status"] as? String, "draft")
        XCTAssertEqual(api.invoice(id)["number"] as? String, number)
    }

    func testUndoPaidReturnsToIssuedAndReverseIsOfferedAgain() {
        let customerId = api.addCustomer(unique("Undo customer"))
        let id = api.addIssued(customerId: customerId)
        _ = api.object("POST", "invoices/\(id)/paid", [:])

        let app = openInvoice(id, filter: "Paid")
        XCTAssertFalse(app.buttons["invoice.reverse"].exists)
        tap(app, app.buttons["invoice.undoPaid"])
        let confirm = app.alerts.buttons["Undo paid"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        keepScreenshot("undo-paid")
        confirm.tap()

        XCTAssertTrue(scrolled(app, to: app.buttons["invoice.reverse"]))
        let saved = api.invoice(id)
        XCTAssertEqual(saved["status"] as? String, "issued")
        XCTAssertEqual(saved["paidAmount"] as? Int, 0)
        XCTAssertEqual((saved["payments"] as? [[String: Any]])?.count, 0)
    }

    func testUndoPaidWarnsAboutACustomerPaymentAndRemovesItWhole() {
        let customerId = api.addCustomer(unique("Group customer"))
        let first = api.addIssued(customerId: customerId)
        let second = api.addIssued(customerId: customerId)
        // One full invoice, and part of the other.
        _ = api.object("POST", "customers/\(customerId)/payments", ["currency": "USD", "amount": 1_500_000])
        let paid = [first, second].first { api.invoice($0)["status"] as? String == "paid" } ?? 0
        let partial = paid == first ? second : first

        let app = openInvoice(paid, filter: "Paid")
        tap(app, app.buttons["invoice.undoPaid"])
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'split across'")).firstMatch.waitForExistence(timeout: 5))
        keepScreenshot("undo-paid-customer-payment")
        app.alerts.buttons["Undo paid"].tap()
        XCTAssertTrue(scrolled(app, to: app.buttons["invoice.reverse"]))

        XCTAssertEqual(api.invoice(paid)["paidAmount"] as? Int, 0)
        XCTAssertEqual(api.invoice(partial)["paidAmount"] as? Int, 0)
    }

    func testAPartlyPaidInvoiceHasNoUndoPaid() {
        let customerId = api.addCustomer(unique("Part customer"))
        let id = api.addIssued(customerId: customerId)
        _ = api.object("POST", "invoices/\(id)/payments", ["kind": "payment", "amount": 10_000])

        let app = openInvoice(id, filter: "Issued")
        XCTAssertTrue(scrolled(app, to: app.buttons["invoice.void"]))
        XCTAssertFalse(app.buttons["invoice.undoPaid"].exists)
    }

    func testDuplicatingOpensTheCopyInTheEditorAndIssuesUnderANewNumber() {
        let customerId = api.addCustomer(unique("Copy customer"))
        let id = api.addIssued(customerId: customerId)
        _ = api.object("POST", "invoices/\(id)/paid", [:])
        let source = api.invoice(id)

        let app = openInvoice(id, filter: "Paid")
        tap(app, app.buttons["invoice.duplicate"])
        XCTAssertTrue(app.navigationBars["Edit invoice"].waitForExistence(timeout: 15))
        keepScreenshot("duplicate-editor")
        save(app)
        tap(app, app.buttons["invoice.review.keep"])
        XCTAssertTrue(app.buttons["invoice.duplicate"].waitForExistence(timeout: 10))

        let rows = api.list("invoices?customerId=\(customerId)")
        XCTAssertEqual(rows.count, 2)
        let copyId = rows.compactMap { $0["id"] as? Int }.first { $0 != id } ?? 0
        let copy = api.invoice(copyId)
        XCTAssertEqual(copy["status"] as? String, "draft")
        XCTAssertTrue(copy["number"] is NSNull)
        XCTAssertEqual(copy["total"] as? Int, source["total"] as? Int)
        XCTAssertEqual(api.invoice(id)["status"] as? String, "paid")

        _ = api.object("POST", "invoices/\(copyId)/issue")
        XCTAssertNotEqual(api.invoice(copyId)["number"] as? String, source["number"] as? String)
    }

    func testADraftCanBeDuplicatedFromItsReview() {
        let customerId = api.addCustomer(unique("Draft copy customer"))
        let id = api.addDraft(customerId: customerId)

        let app = openInvoice(id, filter: "Draft")
        tap(app, app.buttons["invoice.duplicate"])
        XCTAssertTrue(app.navigationBars["Edit invoice"].waitForExistence(timeout: 15))
        XCTAssertEqual(api.list("invoices?customerId=\(customerId)").count, 2)
    }

    func testDuplicateShowsTheServerRefusalWhenTheNextPeriodIsHeld() {
        let customerId = api.addCustomer(unique("Held customer"))
        let serviceName = unique("Held service")
        api.addService(provider: "Contabo", name: serviceName, price: 1_000_000, cost: 400_000)
        let subscription = api.addSubscription(customerId: customerId, serviceId: api.serviceID(named: serviceName))
        let lineId = (subscription["lines"] as? [[String: Any]])?.first?["id"] as? Int ?? 0
        let id = api.addDraft(customerId: customerId, line: api.draftLine([
            "subscriptionId": subscription["id"] as? Int ?? 0, "subscriptionLineId": lineId, "description": "Backup seats",
        ]))
        _ = api.object("POST", "invoices/\(id)/issue")
        // This copy holds the next period, so a second copy is refused.
        _ = api.object("POST", "invoices/\(id)/duplicate")

        let app = openInvoice(id, filter: "Issued")
        tap(app, app.buttons["invoice.duplicate"])
        let error = element(app, "invoice.duplicate.error")
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertFalse(error.label.isEmpty)
        keepScreenshot("duplicate-refused")
        XCTAssertEqual(api.list("invoices?customerId=\(customerId)").count, 2)
    }

    func testADiscountIsTypedBeforeTaxAndTheTotalsShowIt() {
        let customerId = api.addCustomer(unique("Discount customer"))
        let id = api.addDraft(customerId: customerId, fields: ["taxEnabled": true, "taxRate": 50_000])
        _ = api.object("POST", "invoices/\(id)/issue")
        let pdf = api.bytes("invoices/\(id)/pdf")

        let app = openInvoice(id, filter: "Issued")
        tap(app, app.buttons["invoice.addDiscount"])
        let amount = app.textFields["payment.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        XCTAssertEqual(amount.value as? String, "100")
        XCTAssertEqual(amount.placeholderValue, "Amount before tax in USD")
        amount.tap()
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        amount.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "10")
        XCTAssertTrue(element(app, "payment.offDue").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "payment.offDue").label.contains("10.50 USD"))
        keepScreenshot("discount-sheet")
        app.buttons["payment.save"].tap()

        XCTAssertTrue(label(app, "invoice.discount").contains("-10.00 USD"))
        XCTAssertTrue(label(app, "invoice.tax").contains("4.50 USD"))
        XCTAssertTrue(label(app, "invoice.total").contains("94.50 USD"))
        XCTAssertTrue(label(app, "invoice.due").contains("94.50 USD"))
        keepScreenshot("discount-totals")

        let saved = api.invoice(id)
        XCTAssertEqual(saved["discountAmount"] as? Int, 105_000)
        XCTAssertEqual(saved["total"] as? Int, 1_050_000)
        XCTAssertNotEqual(api.bytes("invoices/\(id)/pdf"), pdf)
    }

    func testEditingCostAfterIssueLeavesThePDFAlone() {
        let customerId = api.addCustomer(unique("Cost customer"))
        let id = api.addIssued(customerId: customerId)
        let pdf = api.bytes("invoices/\(id)/pdf")
        XCTAssertFalse(pdf.isEmpty)

        let app = openInvoice(id, filter: "Issued")
        tap(app, app.buttons["invoice.line.0.editCost"])
        let amount = app.textFields["cost.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 15))
        tap(app, amount)
        amount.typeText("5")
        keepScreenshot("edit-cost")
        tap(app, app.buttons["cost.save"])
        XCTAssertTrue(element(app, "invoice.status").waitForExistence(timeout: 15))

        let line = (api.invoice(id)["lines"] as? [[String: Any]])?.first
        XCTAssertEqual(line?["costAmount"] as? Int, 2_050_000)
        XCTAssertEqual(line?["costBase"] as? Int, 2_050_000)
        XCTAssertEqual(api.bytes("invoices/\(id)/pdf"), pdf)
    }
}
