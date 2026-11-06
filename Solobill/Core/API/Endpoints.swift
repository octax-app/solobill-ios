import Foundation

/// One typed call per `/api/v1` route the app uses. Screens call these, not raw paths.
extension APIClient {
    func createToken(email: String, password: String, code: String?, name: String) async throws -> ApiToken {
        struct Body: Encodable {
            let email: String
            let password: String
            let code: String?
            let name: String
        }
        return try await post(
            "auth/token",
            body: Body(email: email, password: password, code: code, name: name),
            authenticated: false
        )
    }

    func revokeToken(id: Int) async throws {
        try await delete("auth/tokens/\(id)")
    }

    func me() async throws -> Me { try await get("auth/me") }
    func settings() async throws -> AppSettings { try await get("settings") }

    /// With no dates the server uses the current month, the same as the web overview.
    func overview(from: String? = nil, to: String? = nil) async throws -> Overview {
        try await get("overview", query: ["from": from, "to": to])
    }

    func customers(search: String? = nil, status: CustomerStatus? = nil) async throws -> [Customer] {
        try await get("customers", query: ["q": search, "status": status?.rawValue])
    }

    func customer(id: Int) async throws -> Customer { try await get("customers/\(id)") }

    func customerSummary(id: Int) async throws -> CustomerSummary {
        try await get("customers/\(id)/summary")
    }

    func providers() async throws -> [Provider] { try await get("providers") }

    func services(providerId: Int? = nil) async throws -> [Service] {
        try await get("services", query: ["providerId": providerId.map(String.init)])
    }

    func subscriptions(customerId: Int? = nil) async throws -> [Subscription] {
        try await get("subscriptions", query: ["customerId": customerId.map(String.init)])
    }

    func templates() async throws -> [Template] { try await get("templates") }

    /// The last rate used for a currency, to prefill the form. Nil if there is none yet.
    func lastFxRate(currency: String) async throws -> Int? {
        struct Response: Decodable { let rate: Int? }
        let response: Response = try await get("fx-rate", query: ["currency": currency])
        return response.rate
    }

    func resolveTemplate(serviceId: Int? = nil, providerId: Int? = nil) async throws -> Int {
        struct Response: Decodable { let templateId: Int }
        let response: Response = try await get(
            "resolve-template",
            query: ["serviceId": serviceId.map(String.init), "providerId": providerId.map(String.init)]
        )
        return response.templateId
    }

    /// `statuses` are sent comma separated, for example `[.issued, .paid]`.
    func invoices(
        type: DocumentType? = nil,
        statuses: [DocumentStatus] = [],
        customerId: Int? = nil
    ) async throws -> [InvoiceRow] {
        try await get(
            "invoices",
            query: [
                "type": type?.rawValue,
                "status": statuses.isEmpty ? nil : statuses.map(\.rawValue).joined(separator: ","),
                "customerId": customerId.map(String.init),
            ]
        )
    }

    func invoice(id: Int) async throws -> InvoiceFull { try await get("invoices/\(id)") }

    func createDraft(_ input: InvoiceInput) async throws -> InvoiceFull {
        try await post("invoices", body: input)
    }

    func updateDraft(id: Int, _ input: InvoiceInput) async throws -> InvoiceFull {
        try await put("invoices/\(id)", body: input)
    }

    func deleteDraft(id: Int) async throws { try await delete("invoices/\(id)") }

    func invoicePDF(id: Int) async throws -> Data { try await data("invoices/\(id)/pdf") }

    func issue(id: Int) async throws -> InvoiceFull { try await post("invoices/\(id)/issue") }

    /// Voids a document. On a renewal draft this is the discard action.
    @discardableResult
    func void(id: Int) async throws -> Invoice { try await post("invoices/\(id)/void") }

    /// Sends an issued document back to draft and deletes its stored PDF. It keeps its number. The
    /// server refuses a paid document or one with payments.
    func reverse(id: Int) async throws -> InvoiceFull { try await post("invoices/\(id)/reverse") }

    /// Removes every payment and discount on a paid invoice, and returns it to issued. A customer
    /// payment is removed whole, from every invoice it covers.
    func undoPayments(id: Int) async throws -> InvoiceFull {
        try await post("invoices/\(id)/undo-payments")
    }

    /// Copies a document into a new draft, and returns that draft.
    func duplicate(id: Int) async throws -> InvoiceFull { try await post("invoices/\(id)/duplicate") }

    /// Turns an issued proforma into a draft invoice, and returns that draft.
    func convert(id: Int) async throws -> Invoice { try await post("invoices/\(id)/convert") }

    /// Cost is internal, so this works after issue. Nothing on the document changes.
    func updateLineCost(invoiceId: Int, lineId: Int, _ input: LineCostInput) async throws {
        let _: [InvoiceLine] = try await patch("invoices/\(invoiceId)/lines/\(lineId)/cost", body: input)
    }

    func originalLines() async throws -> [OriginalLineOption] { try await get("original-lines") }

    private struct PaidBody: Encodable { let paidOn: String }

    @discardableResult
    func markPaid(invoiceId: Int, on day: String) async throws -> Invoice {
        try await post("invoices/\(invoiceId)/paid", body: PaidBody(paidOn: day))
    }

    @discardableResult
    func markUnpaid(invoiceId: Int) async throws -> Invoice {
        try await post("invoices/\(invoiceId)/unpaid")
    }

    @discardableResult
    func addPayment(invoiceId: Int, _ input: PaymentInput) async throws -> InvoiceFull {
        try await post("invoices/\(invoiceId)/payments", body: input)
    }

    /// Removes the row, and every other row of the same customer payment.
    func deletePayment(id: Int) async throws { try await delete("payments/\(id)") }

    @discardableResult
    func addCustomerPayment(customerId: Int, _ input: CustomerPaymentInput) async throws -> CustomerPaymentResult {
        try await post("customers/\(customerId)/payments", body: input)
    }

    func originals() async throws -> [OriginalRow] { try await get("originals") }
    func original(id: Int) async throws -> OriginalFull { try await get("originals/\(id)") }

    func createOriginal(_ input: OriginalInvoiceInput) async throws -> OriginalFull {
        try await post("originals", body: input)
    }

    @discardableResult
    func attachPDF(originalId: Int, pdf: Data, filename: String) async throws -> OriginalFull {
        try await upload("originals/\(originalId)/pdf", file: pdf, filename: filename)
    }

    @discardableResult
    func markPaid(originalId: Int, on day: String) async throws -> OriginalFull {
        try await post("originals/\(originalId)/paid", body: PaidBody(paidOn: day))
    }

    @discardableResult
    func markUnpaid(originalId: Int) async throws -> OriginalFull {
        try await post("originals/\(originalId)/unpaid")
    }

    /// `key` is the `pdfFile` or `logoFile` value from another response. Files are only ever
    /// reached through this authenticated route.
    func file(key: String) async throws -> Data { try await data("files/\(key)") }

    /// `environment` is "sandbox" for Xcode builds and "production" for TestFlight.
    func registerDevice(token: String, environment: String) async throws {
        struct Body: Encodable {
            let token: String
            let environment: String
        }
        let _: OkResponse = try await post(
            "devices",
            body: Body(token: token, environment: environment)
        )
    }

    func reminders() async throws -> [Reminder] { try await get("reminders") }

    func markReminderRead(id: Int) async throws {
        let _: OkResponse = try await post("reminders/\(id)/read")
    }
}
