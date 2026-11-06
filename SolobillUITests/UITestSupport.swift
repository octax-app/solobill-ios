import XCTest

/// Shared helpers for UI tests. They need the local server from `ios/scripts/dev-server.sh`.
extension XCTestCase {
    var testServerURL: String {
        ProcessInfo.processInfo.environment["TEST_SERVER_URL"] ?? "http://localhost:3000"
    }

    /// Launches past the app lock, logging in with the demo account if needed.
    @discardableResult
    func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", testServerURL, "-skipPushPrompt", "YES", "-skipAppLock", "YES"]
        app.launch()
        let email = app.textFields["login.email"]
        if email.waitForExistence(timeout: 3) {
            email.tap()
            email.typeText("owner@example.com")
            let password = app.secureTextFields["login.password"]
            password.tap()
            password.typeText("demo-password")
            app.buttons["login.submit"].tap()
            dismissSavePassword(app)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// iOS offers to save the password after a fresh login, and the sheet covers the app.
    private func dismissSavePassword(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 10) { notNow.tap() }
    }

    /// Relaunches signed in against a port nothing listens on. The token stays valid, so each
    /// screen reaches its offline error and Retry button.
    @discardableResult
    func relaunchOffline(_ app: XCUIApplication) -> XCUIApplication {
        app.terminate()
        app.launchArguments = ["-serverURL", "http://localhost:1", "-skipPushPrompt", "YES", "-skipAppLock", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// Drags until the element can be tapped. It tries down the form first, then back up for a
    /// field above the current position. The drags are short, because on a small phone with the
    /// keyboard up a full swipe can jump over a row every time.
    ///
    /// An element right under the navigation bar, or behind the keyboard, counts as hittable, but
    /// the bar or the keyboard takes the tap, so it is moved clear first.
    @discardableResult
    func scrolled(_ app: XCUIApplication, to element: XCUIElement) -> Bool {
        var corrections = 0
        func drag(_ distance: CGFloat) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: distance < 0 ? 0.45 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        let keyboard = app.keyboards.firstMatch
        for attempt in 0..<34 {
            let visible = element.waitForExistence(timeout: 1) && element.isHittable
            if visible, !keyboard.exists || element.frame.maxY < keyboard.frame.minY {
                if element.frame.minY > 140 || corrections == 2 { return true }
                corrections += 1
                drag(80)
            } else {
                drag(attempt < 14 ? -160 : 160)
            }
        }
        return element.isHittable
    }

    func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(scrolled(app, to: element), "\(element) cannot be reached")
        element.tap()
    }

    func type(_ app: XCUIApplication, _ text: String, into field: XCUIElement) {
        tap(app, field)
        field.typeText(text)
    }

    /// Picks from a picker that opens its own list, then returns to the form.
    func choose(_ app: XCUIApplication, _ picker: String, _ option: String) {
        tap(app, app.buttons[picker])
        let row = app.buttons[option]
        for _ in 0..<12 where !row.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(option) is not offered")
        row.tap()
        XCTAssertTrue(app.buttons[picker].waitForExistence(timeout: 5))
    }

    func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(scrolled(app, to: element))
        return element.label
    }
}

/// Calls the test server directly, to set up data and to confirm what the app sent.
final class DemoServerAPI: @unchecked Sendable {
    typealias JSON = [String: Any]

    private final class Reply: @unchecked Sendable {
        var data = Data()
        var status = 0
    }

    private let server: String
    private var token = ""

    init(server: String) {
        self.server = server
        let body: JSON = ["email": "owner@example.com", "password": "demo-password", "name": "ui-test"]
        token = object("POST", "auth/token", body)["token"] as? String ?? ""
    }

    private func call(_ method: String, _ path: String, _ body: JSON?) -> Any {
        var request = URLRequest(url: URL(string: "\(server)/api/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.data = data ?? Data()
            reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        XCTAssertTrue((200..<300).contains(reply.status), "\(method) \(path): \(String(decoding: reply.data, as: UTF8.self))")
        return (try? JSONSerialization.jsonObject(with: reply.data)) ?? [:]
    }

    func object(_ method: String, _ path: String, _ body: JSON? = nil) -> JSON {
        call(method, path, body) as? JSON ?? [:]
    }

    func list(_ path: String) -> [JSON] {
        call("GET", path, nil) as? [JSON] ?? []
    }

    /// Sends a PDF as the `file` field of a multipart form, with a `name` field.
    func upload(_ path: String, name: String, pdf: Data) -> JSON {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"t.pdf\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "\(server)/api/v1/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reply.data = data ?? Data()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return (try? JSONSerialization.jsonObject(with: reply.data)) as? JSON ?? [:]
    }

    /// The raw response, such as a PDF.
    func bytes(_ path: String) -> Data {
        var request = URLRequest(url: URL(string: "\(server)/api/v1/\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reply.data = data ?? Data()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return reply.data
    }

    func id(ofProvider name: String) -> Int {
        list("providers").first { $0["name"] as? String == name }?["id"] as? Int ?? 0
    }

    func id(ofCustomer name: String) -> Int {
        list("customers").first { $0["name"] as? String == name }?["id"] as? Int ?? 0
    }

    /// A service with its own name and prices, so the test does not depend on the seeded catalog.
    func addService(provider: String, name: String, price: Int, cost: Int, currency: String = "USD") {
        _ = object("POST", "services", [
            "providerId": id(ofProvider: provider), "name": name, "pricing": "fixed", "cycle": "monthly",
            "defaultCost": cost, "defaultPrice": price, "currency": currency,
        ])
    }

    /// A currency nothing has used yet, so the app has no rate to prefill.
    func currencyWithoutRate() -> String? {
        ["AED", "BHD", "EGP", "EUR", "GBP", "IQD", "JOD", "KWD", "QAR", "SAR"].first { code in
            object("GET", "fx-rate?currency=\(code)")["rate"] is NSNull
        }
    }

    func proformas() -> [JSON] {
        list("invoices?type=proforma")
    }

    func invoice(_ id: Int) -> JSON {
        object("GET", "invoices/\(id)")
    }

    func newestProforma() -> JSON {
        invoice(proformas().first?["id"] as? Int ?? 0)
    }

    /// Issues a proforma directly, which takes `number` away from a draft in the app.
    func issueProforma(number: String, customerId: Int) -> Int {
        let line: JSON = [
            "description": "Blocks the number", "quantity": 10_000, "unitPrice": 10_000,
            "costCurrency": "USD", "costFxRate": 100_000_000,
        ]
        let draft = object("POST", "invoices", [
            "type": "proforma", "number": number, "customerId": customerId, "currency": "USD",
            "fxRate": 100_000_000, "taxEnabled": false, "taxRate": 0, "lines": [line],
        ])
        let id = draft["id"] as? Int ?? 0
        _ = object("POST", "invoices/\(id)/issue")
        return id
    }
}
