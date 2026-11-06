import XCTest

/// Calls the test server directly, to seed each test's own rows and read what the server holds.
private struct ServerAPI {
    let url: String
    private var token = ""

    init(url: String) throws {
        self.url = url
        let signedIn = try object("POST", "auth/token", [
            "email": "owner@example.com", "password": "demo-password", "name": "OverviewUITests",
        ])
        token = try XCTUnwrap(signedIn["token"] as? String)
    }

    private func call(_ method: String, _ path: String, _ body: Any? = nil) throws -> Any {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(url)/api/v1/\(path)")))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let finished = XCTestExpectation(description: "\(method) \(path)")
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                result = .failure(error)
            } else if !(200..<300).contains(status) {
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                result = .failure(NSError(domain: "\(method) \(path) \(status): \(text)", code: status))
            } else {
                result = .success(data ?? Data())
            }
            finished.fulfill()
        }.resume()
        guard XCTWaiter().wait(for: [finished], timeout: 60) == .completed else {
            throw NSError(domain: "\(method) \(path) timed out", code: 0)
        }
        return try JSONSerialization.jsonObject(with: result.get())
    }

    private func object(_ method: String, _ path: String, _ body: Any? = nil) throws -> [String: Any] {
        try XCTUnwrap(try call(method, path, body) as? [String: Any])
    }

    private func firstID(_ path: String) throws -> Int {
        let rows = try XCTUnwrap(try call("GET", path) as? [[String: Any]])
        return try XCTUnwrap(rows.first?["id"] as? Int)
    }

    func overview(from: String, to: String) throws -> [String: Any] {
        try object("GET", "overview?from=\(from)&to=\(to)")
    }

    /// An issued invoice that belongs to the calling test.
    func issuedInvoice(dueOn: String) throws -> Int {
        let draft = try object("POST", "invoices", [
            "type": "invoice", "customerId": try firstID("customers"), "currency": "USD",
            "fxRate": 100_000_000, "taxEnabled": false, "taxRate": 0, "dueOn": dueOn,
            "lines": [[
                "description": "UI test line", "quantity": 10_000, "unitPrice": 1_234_500,
                "costAmount": 500_000, "costCurrency": "USD", "costFxRate": 100_000_000,
            ]],
        ])
        let id = try XCTUnwrap(draft["id"] as? Int)
        _ = try object("POST", "invoices/\(id)/issue")
        return id
    }

    /// An unpaid original that belongs to the calling test.
    func unpaidOriginal(dueOn: String) throws -> Int {
        let original = try object("POST", "originals", [
            "providerId": try firstID("providers"), "number": "UI-\(UUID().uuidString.prefix(8))",
            "issuedOn": "2026-10-05", "dueOn": dueOn, "currency": "USD", "fxRate": 100_000_000,
            "lines": [["description": "UI test line", "quantity": 10_000, "unitPrice": 600_000]],
        ])
        return try XCTUnwrap(original["id"] as? Int)
    }
}

/// Needs a local server with demo data. See `ios/README.md`.
final class OverviewUITests: XCTestCase {
    private let dueLater = "2099-01-01"
    private let dueLongAgo = "2020-01-01"

    override func setUp() {
        continueAfterFailure = false
    }

    private func ids(_ rows: Any?) throws -> [Int] {
        try XCTUnwrap(rows as? [[String: Any]]).compactMap { $0["id"] as? Int }
    }

    /// The month dates the web sends. The server's `today` is the same UTC day the web uses.
    private func monthDates(_ api: ServerAPI) throws -> (from: String, to: String) {
        let today = try XCTUnwrap(try api.overview(from: "2000-01-01", to: "2000-01-01")["today"] as? String)
        return ("\(today.prefix(7))-01", today)
    }

    /// `Money.format` for the demo server's USD base currency.
    private func usd(_ scaled: Int) -> String {
        let cents = (2 * abs(scaled) + 100) / 200
        let whole = String(cents / 100)
        var grouped = ""
        for (index, digit) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        let fraction = cents % 100
        return "\(scaled < 0 ? "-" : "")\(grouped).\(fraction < 10 ? "0" : "")\(fraction) USD"
    }

    private func text(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts[id]
    }

    /// Rows are built lazily, so this scrolls down until the element exists.
    private func scrollToExist(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.waitForExistence(timeout: 2) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists, "\(element) was not found")
    }

    /// Scrolls down until the element can be tapped. Waits first, so a slow machine does not
    /// scroll past an element that is about to load.
    private func scrollToTap(_ element: XCUIElement, in app: XCUIApplication) {
        scrollToExist(element, in: app)
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) is not on screen")
    }

    /// Waits for figures from the given period. The header shows the dates the server echoed, so
    /// this cannot pass on the previous period's figures.
    private func waitForPeriod(from: String, to: String, in app: XCUIApplication) throws {
        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.dateFormat = "yyyy-MM-dd"
        let shown = DateFormatter()
        shown.locale = days.locale
        shown.dateFormat = "d MMM yyyy"
        let start = shown.string(from: try XCTUnwrap(days.date(from: from)))
        let end = shown.string(from: try XCTUnwrap(days.date(from: to)))
        let header = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'overview.period' AND label ==[c] %@", "\(start) to \(end)")
        ).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "Overview for \(from) to \(to) did not load")
    }

    private func markPaid(_ button: XCUIElement, in app: XCUIApplication) {
        scrollToTap(button, in: app)
        button.tap()
        let save = app.buttons["markPaid.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
    }

    func testMarkingAnInvoicePaidRemovesItFromToCollect() throws {
        let api = try ServerAPI(url: testServerURL)
        let id = try api.issuedInvoice(dueOn: dueLater)
        let month = try monthDates(api)
        let before = try api.overview(from: month.from, to: month.to)
        XCTAssertTrue(try ids(before["toCollect"]).contains(id))

        let app = launchSignedIn()
        let pay = app.buttons["overview.pay.invoice.\(id)"]
        try waitForPeriod(from: month.from, to: month.to, in: app)
        markPaid(pay, in: app)
        XCTAssertTrue(pay.waitForNonExistence(timeout: 30))

        let after = try api.overview(from: month.from, to: month.to)
        XCTAssertFalse(try ids(after["toCollect"]).contains(id))
    }

    func testMarkingAnOriginalPaidRemovesItFromToPay() throws {
        let api = try ServerAPI(url: testServerURL)
        let id = try api.unpaidOriginal(dueOn: dueLater)
        let month = try monthDates(api)
        XCTAssertTrue(try ids(try api.overview(from: month.from, to: month.to)["toPay"]).contains(id))

        let app = launchSignedIn()
        let pay = app.buttons["overview.pay.original.\(id)"]
        try waitForPeriod(from: month.from, to: month.to, in: app)
        markPaid(pay, in: app)
        XCTAssertTrue(pay.waitForNonExistence(timeout: 30))

        let after = try api.overview(from: month.from, to: month.to)
        XCTAssertFalse(try ids(after["toPay"]).contains(id))
    }

    func testDisplayedFiguresMatchTheServerForEachPeriod() throws {
        let api = try ServerAPI(url: testServerURL)
        let today = try monthDates(api).to
        let year = today.prefix(4)
        let quarterStart = (Int(today.dropFirst(5).prefix(2))! - 1) / 3 * 3 + 1
        // Custom starts on the month's dates. Each period differs from the last, so the list
        // reloads and returns to the top.
        let periods: [(name: String, from: String)] = [
            ("Month", "\(today.prefix(7))-01"),
            ("Quarter", "\(year)-\(quarterStart < 10 ? "0" : "")\(quarterStart)-01"),
            ("Year", "\(year)-01-01"),
            ("Custom", "\(today.prefix(7))-01"),
        ]

        let app = launchSignedIn()
        for period in periods {
            app.buttons[period.name].tap()
            try waitForPeriod(from: period.from, to: today, in: app)

            let server = try api.overview(from: period.from, to: today)
            let summary = try XCTUnwrap(server["summary"] as? [String: Any])
            let unallocated = try XCTUnwrap(server["unallocatedCost"] as? Int)
            let drafts = try XCTUnwrap(server["draftsToReview"] as? Int)
            print("OVERVIEW \(period.name) \(period.from)..\(today) server unallocated=\(usd(unallocated)) drafts=\(drafts)")

            // The notices are above the figures, so check them before scrolling.
            let notice = text("overview.unallocated", in: app)
            XCTAssertEqual(notice.exists, unallocated > 0, period.name)
            if unallocated > 0 { XCTAssertTrue(notice.label.contains(usd(unallocated)), notice.label) }
            let draftNotice = text("overview.drafts", in: app)
            XCTAssertEqual(draftNotice.exists, drafts > 0, period.name)
            if drafts > 0 { XCTAssertTrue(draftNotice.label.hasPrefix("\(drafts) renewal draft"), draftNotice.label) }

            // In the order they appear on screen, because scrolling only goes down.
            let expected = [
                ("overview.revenue", usd(try XCTUnwrap(summary["revenue"] as? Int))),
                ("overview.cost", usd(try XCTUnwrap(summary["cost"] as? Int))),
                ("overview.profit", usd(try XCTUnwrap(summary["profit"] as? Int))),
                ("overview.margin", "\(try XCTUnwrap(summary["margin"] as? NSNumber))%"),
                ("overview.toCollectTotal", usd(try XCTUnwrap(server["toCollectTotal"] as? Int))),
                ("overview.toPayTotal", usd(try XCTUnwrap(server["toPayTotal"] as? Int))),
            ]
            for (id, value) in expected {
                let shown = text(id, in: app)
                scrollToExist(shown, in: app)
                print("OVERVIEW \(period.name) \(period.from)..\(today) \(id) app=\(shown.label) server=\(value)")
                XCTAssertEqual(shown.label, value, "\(period.name) \(id)")
            }
        }
    }

    func testReturningToTheTabShowsWhatChangedElsewhere() throws {
        let api = try ServerAPI(url: testServerURL)
        let month = try monthDates(api)
        let app = launchSignedIn()
        try waitForPeriod(from: month.from, to: month.to, in: app)

        let id = try api.issuedInvoice(dueOn: dueLongAgo)
        app.tabBars.buttons["Customers"].tap()
        app.tabBars.buttons["Overview"].tap()
        scrollToExist(app.buttons["overview.pay.invoice.\(id)"], in: app)
    }

    func testOverdueUsesTheServerDay() throws {
        let api = try ServerAPI(url: testServerURL)
        let overdue = try api.issuedInvoice(dueOn: dueLongAgo)
        let notDue = try api.issuedInvoice(dueOn: dueLater)
        let month = try monthDates(api)

        let app = launchSignedIn()
        try waitForPeriod(from: month.from, to: month.to, in: app)
        scrollToExist(text("overview.overdue.invoice.\(overdue)", in: app), in: app)
        scrollToExist(app.buttons["overview.pay.invoice.\(notDue)"], in: app)
        XCTAssertFalse(text("overview.overdue.invoice.\(notDue)", in: app).exists)
    }

    func testRowsOpenTheirDetailAndTheActionDoesNot() throws {
        let api = try ServerAPI(url: testServerURL)
        let id = try api.issuedInvoice(dueOn: dueLongAgo)
        let month = try monthDates(api)

        let app = launchSignedIn()
        try waitForPeriod(from: month.from, to: month.to, in: app)

        let pay = app.buttons["overview.pay.invoice.\(id)"]
        scrollToTap(pay, in: app)
        pay.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The action should open the sheet, not push")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))

        let row = app.descendants(matching: .any)["overview.row.invoice.\(id)"].firstMatch
        scrollToTap(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons["signOut"].waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 10))
    }

    func testOfflineShowsTheErrorAndRetryAndKeepsSignOut() throws {
        let offline = relaunchOffline(launchSignedIn())
        let retry = offline.buttons["retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(offline.staticTexts["Could not load"].exists)
        XCTAssertTrue(offline.buttons["signOut"].exists)

        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))

        // Changing the period from the error screen tries again, and fails the same clear way.
        offline.buttons["Year"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
    }
}
