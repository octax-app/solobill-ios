import Foundation
import Testing

@testable import Solobill

@Suite struct DocumentFormTests {
    private final class Marker {}

    private func savedInvoice() throws -> InvoiceFull {
        let bundle = Bundle(for: Marker.self)
        let url = try #require(bundle.url(forResource: "Fixtures/invoiceFull", withExtension: "json"))
        return try JSONDecoder().decode(InvoiceFull.self, from: Data(contentsOf: url))
    }

    private func subscription(priceCurrency: String, lineDescription: String = "Seats") throws -> Subscription {
        let json = """
        {"id":1,"customerId":2,"serviceId":3,"label":"","cycle":"monthly","startedOn":"2026-10-01",
        "nextRenewalOn":null,"costAmount":100000,"costCurrency":"USD","priceAmount":300000,
        "priceCurrency":"\(priceCurrency)","status":"active","customerName":"A","serviceName":"Backup",
        "providerName":"P","pricing":"fixed","lines":[{"id":9,"subscriptionId":1,"position":0,
        "description":"\(lineDescription)","costAmount":100000,"priceAmount":300000}]}
        """
        return try JSONDecoder().decode(Subscription.self, from: Data(json.utf8))
    }

    @Test func aDraftGoesBackUnchanged() throws {
        let saved = try savedInvoice()
        let input = try DocumentForm(draft: saved).input(baseCurrency: "USD")
        #expect(input.type == saved.type)
        #expect(input.customerId == saved.customerId)
        #expect(input.providerId == saved.providerId)
        #expect(input.serviceId == saved.serviceId)
        #expect(input.templateId == saved.templateId)
        #expect(input.taxEnabled == saved.taxEnabled)
        #expect(input.taxRate == saved.taxRate)
        #expect(input.notes == saved.notes)
        #expect(input.customValues == (saved.customValues ?? [:]))
        #expect(input.lines.count == saved.lines.count)
        for (sent, line) in zip(input.lines, saved.lines) {
            #expect(sent.description == line.description)
            #expect(sent.quantity == line.quantity)
            #expect(sent.unitPrice == line.unitPrice)
            #expect(sent.costAmount == line.costAmount)
            #expect(sent.costCurrency == line.costCurrency)
            #expect(sent.subscriptionId == line.subscriptionId)
            #expect(sent.subscriptionLineId == line.subscriptionLineId)
            #expect(sent.periodStart == line.periodStart)
            #expect(sent.originalInvoiceLineId == line.originalInvoiceLineId)
            #expect(sent.amountConfirmed == line.amountConfirmed)
        }
    }

    @Test func aDueDateOnlyGoesOnAnInvoice() throws {
        var form = DocumentForm(type: .invoice)
        form.customerID = 1
        form.currency = "USD"
        form.lines = [DocumentLine(costCurrency: "USD")]
        form.lines[0].description = "Setup"
        form.lines[0].unitPrice = "10"
        form.hasDueOn = true
        form.hasValidUntil = true
        let input = try form.input(baseCurrency: "USD")
        #expect(input.type == .invoice)
        #expect(input.dueOn != nil)
        #expect(input.validUntil == nil)
    }

    @Test func aSubscriptionPriceFillsInOnlyInItsOwnCurrency() throws {
        let plan = try subscription(priceCurrency: "USD")
        let lineItem = try #require(plan.billingLines.first)
        var line = DocumentLine(subscription: plan, line: lineItem, formCurrency: "USD")
        #expect(line.unitPrice == "30")
        #expect(line.subscriptionId == 1)
        #expect(line.subscriptionLineId == 9)
        #expect(line.priceHint(formCurrency: "USD") == nil)

        line.applyDefaultPrice(formCurrency: "OMR")
        #expect(line.unitPrice.isEmpty)
        #expect(line.priceHint(formCurrency: "OMR")?.contains("subscription price") == true)
    }

    @Test func aPriceTheOwnerTypedSurvivesACurrencyChange() throws {
        let plan = try subscription(priceCurrency: "USD")
        let lineItem = try #require(plan.billingLines.first)
        var line = DocumentLine(subscription: plan, line: lineItem, formCurrency: "USD")
        line.unitPrice = "12"
        line.applyDefaultPrice(formCurrency: "OMR")
        #expect(line.unitPrice == "12")
    }

    @Test func aBlankSubscriptionLineUsesTheServiceName() throws {
        let plan = try subscription(priceCurrency: "USD", lineDescription: "")
        let lineItem = try #require(plan.billingLines.first)
        let line = DocumentLine(subscription: plan, line: lineItem, formCurrency: "USD")
        #expect(line.description == "Backup")
    }

    @Test func customValuesAreLeftOutUnlessTheFormSendsThem() throws {
        let saved = try savedInvoice()
        let copied = try JSONEncoder().encode(InvoiceInput(draft: saved))
        let copiedBody = try #require(JSONSerialization.jsonObject(with: copied) as? [String: Any])
        #expect(copiedBody["customValues"] == nil)

        let typed = try JSONEncoder().encode(DocumentForm(draft: saved).input(baseCurrency: "USD"))
        let typedBody = try #require(JSONSerialization.jsonObject(with: typed) as? [String: Any])
        #expect(typedBody["customValues"] != nil)
    }

    @Test func theIssueDateIsLeftOutOnCopiesAndClearedByTheForm() throws {
        let saved = try savedInvoice()
        let copied = try JSONEncoder().encode(InvoiceInput(draft: saved))
        let copiedBody = try #require(JSONSerialization.jsonObject(with: copied) as? [String: Any])
        #expect(copiedBody["issueDate"] == nil)

        var form = DocumentForm(draft: saved)
        form.hasIssueDate = false
        let cleared = try JSONEncoder().encode(form.input(baseCurrency: "USD"))
        let clearedBody = try #require(JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        #expect(clearedBody["issueDate"] is NSNull)

        form.hasIssueDate = true
        form.issueDate = try #require(ISODay.date(from: "2026-10-15"))
        let dated = try JSONEncoder().encode(form.input(baseCurrency: "USD"))
        let datedBody = try #require(JSONSerialization.jsonObject(with: dated) as? [String: Any])
        #expect(datedBody["issueDate"] as? String == "2026-10-15")
    }

    /// Expected values come from running `web/src/shared/payments.ts`.
    @Test func discountMathMatchesTheServer() {
        let taxed = DiscountTerms(due: 1_050_000, subtotal: 1_000_000, total: 1_050_000, taxEnabled: true, taxRate: 50_000, currency: "USD")
        #expect(taxed.limit == 1_000_000)
        #expect(taxed.withTax(100_000) == 105_000)
        #expect(taxed.withTax(1_000_000) == 1_050_000)
        #expect(taxed.withTax(1_050_000) == 1_050_000)

        let partly = DiscountTerms(due: 995_700, subtotal: 1_234_000, total: 1_295_700, taxEnabled: true, taxRate: 50_000, currency: "OMR")
        #expect(partly.limit == 948_290)
        #expect(partly.withTax(100_000) == 105_000)
        #expect(partly.withTax(948_290) == 995_700)

        let rounded = DiscountTerms(due: 245_000, subtotal: 333_300, total: 350_000, taxEnabled: true, taxRate: 50_000, currency: "USD")
        #expect(rounded.limit == 233_300)
        #expect(rounded.withTax(233_300) == 245_000)

        let untaxed = DiscountTerms(due: 875_000, subtotal: 1_000_000, total: 1_000_000, taxEnabled: false, taxRate: 0, currency: "KWD")
        #expect(untaxed.limit == 875_000)
        #expect(untaxed.withTax(100_000) == 100_000)
    }

    @Test func aLargeAmountDoesNotOverflow() {
        let huge = 90_000_000_000_000
        #expect(Money.netShare(huge, subtotal: huge, total: huge, currency: "USD") == huge)
    }

    @Test func aDiscountIsCheckedAgainstTheLimitBeforeTax() {
        let terms = DiscountTerms(due: 1_050_000, subtotal: 1_000_000, total: 1_050_000, taxEnabled: true, taxRate: 50_000, currency: "USD")
        #expect(PaymentEntry("100", kind: .discount, due: terms.due, currency: "USD", discount: terms).amount == 1_000_000)
        let over = PaymentEntry("100.01", kind: .discount, due: terms.due, currency: "USD", discount: terms)
        #expect(over.amount == nil)
        #expect(over.problem == "The discount cannot be more than 100.00 USD before tax.")
    }

    @Test func unlinkingACostSendsNull() throws {
        let input = LineCostInput(costAmount: 1, costCurrency: "USD", costFxRate: 100_000_000, originalInvoiceLineId: nil)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        #expect(body["originalInvoiceLineId"] is NSNull)
    }

    @Test func templateFieldsComeInOrderAndMayBeMissing() throws {
        let json = """
        [{"id":1,"name":"A","isDefault":true,"defaultTaxRate":0,"ready":true,"problems":[]},
         {"id":2,"name":"B","isDefault":false,"defaultTaxRate":0,"ready":true,"problems":[],"customFields":[
           {"id":"b","label":"Second","type":"date","required":false,"order":2,"region":"document_meta"},
           {"id":"a","label":"First","type":"text","required":true,"order":1,"region":"document_meta"}]}]
        """
        let templates = try JSONDecoder().decode([Template].self, from: Data(json.utf8))
        #expect(templates[0].orderedFields.isEmpty)
        #expect(templates[1].orderedFields.map(\.id) == ["a", "b"])
    }
}
