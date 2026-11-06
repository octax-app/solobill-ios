import Foundation

/// What a discount can be on one invoice, ported from `web/src/shared/payments.ts`, so the sheet
/// matches what the server will do. A discount is typed before tax and comes off the due with its
/// tax.
struct DiscountTerms: Sendable, Hashable {
    let due: Int
    let subtotal: Int
    let total: Int
    let taxEnabled: Bool
    let taxRate: Int
    let currency: String

    /// The most that can be given, before tax.
    var limit: Int { Money.netShare(due, subtotal: subtotal, total: total, currency: currency) }

    /// What comes off the due. The full limit, or the due itself, closes the invoice with no
    /// rounding left over.
    func withTax(_ amount: Int) -> Int {
        if amount == due || amount == limit { return due }
        return amount + (taxEnabled ? Money.taxOf(amount, percent: taxRate, currency: currency) : 0)
    }
}

/// The figures after any discount, as printed on the PDF. Stored `tax` and `total` stay as issued
/// and discounts are stored with their tax, so these always add up to what the customer owes.
struct DiscountedTotals: Sendable, Hashable {
    let discount: Int
    let tax: Int
    let total: Int
}

extension InvoiceFull {
    var discountTerms: DiscountTerms {
        DiscountTerms(
            due: due,
            subtotal: subtotal,
            total: total,
            taxEnabled: taxEnabled,
            taxRate: taxRate,
            currency: currency
        )
    }

    var discountedTotals: DiscountedTotals {
        let discount = Money.netShare(discountAmount, subtotal: subtotal, total: total, currency: currency)
        return DiscountedTotals(
            discount: discount,
            tax: tax - (discountAmount - discount),
            total: total - discountAmount
        )
    }
}
