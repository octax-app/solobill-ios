import Foundation
import Testing

@testable import Solobill

/// Decodes real server responses, written to `Fixtures` by `pnpm ios:fixtures` in `web/`.
/// Regenerate them after any change to the response schemas.
@Suite struct DecodingTests {
    private final class Marker {}

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let bundle = Bundle(for: Marker.self)
        let url = try #require(bundle.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    @Test func decodesEveryResponseTheAppReads() throws {
        _ = try decode(Me.self, "me")
        _ = try decode(AppSettings.self, "settings")
        _ = try decode(Customer.self, "customer")
        _ = try decode(CustomerSummary.self, "customerSummary")
        _ = try decode([Customer].self, "customerList")
        _ = try decode([Provider].self, "providerList")
        _ = try decode([Service].self, "serviceList")
        _ = try decode([Subscription].self, "subscriptionList")
        _ = try decode([Template].self, "templateList")
        _ = try decode(Invoice.self, "invoice")
        _ = try decode(InvoiceFull.self, "invoiceFull")
        _ = try decode(CustomerPaymentResult.self, "customerPayment")
        _ = try decode([InvoiceRow].self, "invoiceRowList")
        _ = try decode(OriginalFull.self, "originalFull")
        _ = try decode([OriginalRow].self, "originalRowList")
        _ = try decode([Reminder].self, "reminderList")
        _ = try decode(AuthProviders.self, "authProviders")
        _ = try decode([Identity].self, "identityList")
        _ = try decode(Workspace.self, "workspace")
    }

    @Test func meCarriesTheSignInDetails() throws {
        let me = try decode(Me.self, "me")
        #expect(me.hasPassword)
        let identities = try decode([Identity].self, "identityList")
        #expect(identities.first?.provider == .apple)
    }

    @Test func overviewKeepsAmountsAsIntegers() throws {
        let overview = try decode(Overview.self, "overview")
        #expect(!overview.toCollect.isEmpty)
        #expect(!overview.toPay.isEmpty)
        #expect(overview.trend.count == 12)
        #expect(overview.toCollectTotal == overview.toCollect.map { $0.baseDue ?? $0.baseTotal }.reduce(0, +))
    }

    /// A fixture as a dictionary, with the plan 15 fields set or removed, so these hold both before
    /// and after the fixtures are regenerated.
    private func edited<T: Decodable>(
        _ type: T.Type,
        _ name: String,
        change: (inout [String: Any]) -> Void
    ) throws -> T {
        let bundle = Bundle(for: Marker.self)
        let url = try #require(bundle.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var object = try #require((raw as? [[String: Any]])?.first ?? raw as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static let paymentFields = ["paidAmount", "discountAmount", "revenueAdjustBase", "payments"]

    @Test func anInvoiceFromAnOlderServerStillDecodes() throws {
        let full = try edited(InvoiceFull.self, "invoiceFull") { object in
            Self.paymentFields.forEach { object[$0] = nil }
            object["status"] = "issued"
        }
        #expect(full.paidAmount == 0)
        #expect(full.discountAmount == 0)
        #expect(full.revenueAdjustBase == 0)
        #expect(full.payments.isEmpty)
        #expect(full.due == full.total)
        #expect(full.displayStatus == "Issued")

        let row = try edited(InvoiceRow.self, "invoiceRowList") { object in
            Self.paymentFields.forEach { object[$0] = nil }
        }
        #expect(row.paidAmount == 0)
        #expect(row.due == row.total)
    }

    @Test func anInvoiceReadsPaymentsAndAmounts() throws {
        let payment: [String: Any] = [
            "id": 7, "invoiceId": 1, "kind": "discount", "amount": 1_500, "paidOn": "2026-03-01",
            "note": "Goodwill", "groupId": "abc", "createdAt": "2026-03-01", "updatedAt": "2026-03-01",
        ]
        let full = try edited(InvoiceFull.self, "invoiceFull") { object in
            object["status"] = "issued"
            object["paidAmount"] = 2_500
            object["discountAmount"] = 1_500
            object["revenueAdjustBase"] = -1_000
            object["payments"] = [payment]
        }
        #expect(full.paidAmount == 2_500)
        #expect(full.discountAmount == 1_500)
        #expect(full.revenueAdjustBase == -1_000)
        #expect(full.payments.first?.kind == .discount)
        #expect(full.payments.first?.groupId == "abc")
        #expect(full.isPartiallyPaid)
    }

    @Test func aReceivableFallsBackToItsTotalWithoutADue() throws {
        let base: [String: Any] = [
            "id": 1, "number": "INV-1", "dueOn": NSNull(), "issuedOn": "2026-01-01", "total": 100,
            "baseTotal": 100, "currency": "USD", "customerId": 1, "customerName": "A",
        ]
        func receivable(_ object: [String: Any]) throws -> Overview.Receivable {
            try JSONDecoder().decode(
                Overview.Receivable.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        #expect(try receivable(base).amountDue == 100)
        #expect(try receivable(base.merging(["due": 40, "baseDue": 40]) { $1 }).amountDue == 40)
    }

    @Test func draftCopyKeepsEveryFieldTheServerNeeds() throws {
        let saved = try decode(InvoiceFull.self, "invoiceFull")
        let input = InvoiceInput(draft: saved)
        #expect(input.lines.count == saved.lines.count)
        #expect(input.lines.first?.costAmount == saved.lines.first?.costAmount)
        #expect(input.lines.first?.subscriptionLineId == saved.lines.first?.subscriptionLineId)
        #expect(input.lines.first?.amountConfirmed == saved.lines.first?.amountConfirmed)
        #expect(input.taxRate == saved.taxRate)
    }

    @Test func currencyTableMatchesTheServer() throws {
        let settings = try decode(AppSettings.self, "settings")
        #expect(Set(settings.currencies.keys) == Set(Money.currencies.keys))
        for (code, info) in settings.currencies {
            #expect(Money.decimals(of: code) == info.decimals, "\(code)")
        }
    }
}
