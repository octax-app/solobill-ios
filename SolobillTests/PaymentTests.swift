import Testing

@testable import Solobill

private struct Balance: PaymentBalance {
    var status: DocumentStatus = .issued
    var total = 100
    var paidAmount = 0
    var discountAmount = 0
}

/// Mirrors `web/src/shared/payments.test.ts`.
@Suite struct PaymentTests {
    @Test func neverShowsANegativeDue() {
        let paid = Balance(paidAmount: 130)
        #expect(paid.due == 0)
        #expect(paid.overpaid == 30)
    }

    @Test func dueCountsPaymentsAndDiscounts() {
        let started = Balance(paidAmount: 40, discountAmount: 10)
        #expect(started.due == 50)
        #expect(started.overpaid == 0)
    }

    @Test func labelsAStartedInvoiceAsPartialOnlyWhileIssued() {
        #expect(Balance(paidAmount: 40).displayStatus == "Partially paid")
        #expect(Balance(discountAmount: 40).displayStatus == "Partially paid")
        #expect(Balance(status: .void, paidAmount: 40).displayStatus == "Void")
        #expect(Balance(status: .paid, paidAmount: 100).displayStatus == "Paid")
        #expect(Balance().displayStatus == "Issued")
        #expect(!Balance().isPartiallyPaid)
    }

    private let open: [PaymentSplit.OpenInvoice] = [
        .init(id: 3, issuedOn: "2026-03-01", due: 300),
        .init(id: 1, issuedOn: "2026-01-01", due: 100),
        .init(id: 2, issuedOn: "2026-01-01", due: 200),
    ]

    @Test func fillsTheOldestFirstByDateThenId() {
        let split = PaymentSplit.allocate(250, open: open)
        #expect(split.allocations == [.init(invoiceId: 1, amount: 100), .init(invoiceId: 2, amount: 150)])
        #expect(split.excess == 0)
    }

    @Test func stopsExactlyAtASettledInvoice() {
        #expect(PaymentSplit.allocate(100, open: open).allocations == [.init(invoiceId: 1, amount: 100)])
    }

    @Test func leavesTheExcessOnTheLastInvoice() {
        let split = PaymentSplit.allocate(650, open: open)
        #expect(split.excess == 50)
        #expect(split.allocations.last == .init(invoiceId: 3, amount: 350))
    }

    @Test func hasNothingToFillWithNoOpenInvoices() {
        #expect(PaymentSplit.allocate(100, open: []) == PaymentSplit(allocations: [], excess: 0))
    }

    @Test func skipsInvoicesWithNothingDue() {
        let split = PaymentSplit.allocate(10, open: [
            .init(id: 1, issuedOn: "2026-01-01", due: 0),
            .init(id: 2, issuedOn: "2026-02-01", due: 50),
        ])
        #expect(split.allocations == [.init(invoiceId: 2, amount: 10)])
    }

    @Test func aPaymentAboveTheDueShowsTheExtra() {
        let entry = PaymentEntry("120", kind: .payment, due: 1_000_000, currency: "USD")
        #expect(entry.amount == 1_200_000)
        #expect(entry.extra == 200_000)
        #expect(entry.problem == nil)
    }

    @Test func aDiscountCannotGoAboveTheDue() {
        let over = PaymentEntry("120", kind: .discount, due: 1_000_000, currency: "USD")
        #expect(over.amount == nil)
        #expect(over.problem == "The discount cannot be more than 100.00 USD.")
        #expect(PaymentEntry("100", kind: .discount, due: 1_000_000, currency: "USD").amount == 1_000_000)
    }

    @Test func anAmountMustFitTheCurrency() {
        #expect(PaymentEntry("1.234", kind: .payment, due: 100, currency: "OMR").amount == 12_340)
        #expect(PaymentEntry("1.234", kind: .payment, due: 100, currency: "USD").amount == nil)
        #expect(PaymentEntry("1.234", kind: .payment, due: 100, currency: "USD").problem != nil)
    }

    @Test func emptyTextHasNoProblemButCannotSave() {
        let empty = PaymentEntry(" ", kind: .payment, due: 100, currency: "USD")
        #expect(empty.amount == nil)
        #expect(empty.problem == nil)
    }

    @Test func zeroAndNegativeAmountsAreRefused() {
        #expect(PaymentEntry("0", kind: .payment, due: 100, currency: "USD").amount == nil)
        #expect(PaymentEntry("-1", kind: .payment, due: 100, currency: "USD").amount == nil)
    }
}
