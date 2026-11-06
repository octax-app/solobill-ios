import Foundation

/// How one customer payment spreads over their open invoices. Ported from `allocatePayment` in
/// `web/src/shared/payments.ts`, so the preview matches what the server will do.
struct PaymentSplit: Sendable, Hashable {
    struct OpenInvoice: Sendable, Hashable {
        let id: Int
        let issuedOn: String?
        let due: Int
    }

    struct Allocation: Sendable, Hashable {
        let invoiceId: Int
        var amount: Int
    }

    var allocations: [Allocation]
    /// Already included in the last allocation.
    var excess: Int

    /// Fills open invoices oldest first. Anything left stays on the last one as an overpayment.
    static func allocate(_ amount: Int, open: [OpenInvoice]) -> PaymentSplit {
        let oldestFirst = open
            .filter { $0.due > 0 }
            .sorted { ($0.issuedOn ?? "", $0.id) < ($1.issuedOn ?? "", $1.id) }
        var allocations: [Allocation] = []
        var left = amount
        for invoice in oldestFirst {
            if left <= 0 { break }
            let applied = min(left, invoice.due)
            allocations.append(Allocation(invoiceId: invoice.id, amount: applied))
            left -= applied
        }
        guard let last = allocations.indices.last else {
            return PaymentSplit(allocations: [], excess: 0)
        }
        allocations[last].amount += left
        return PaymentSplit(allocations: allocations, excess: left)
    }
}
