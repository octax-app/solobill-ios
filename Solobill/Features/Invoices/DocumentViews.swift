import SwiftUI

/// A status word coloured the same way for every document list.
struct StatusText: View {
    private var label: String
    private var color: Color

    init(_ status: DocumentStatus) {
        label = status.label
        switch status {
        case .paid: color = .green
        case .issued: color = .blue
        case .draft, .converted: color = .secondary
        case .void: color = .red
        }
    }

    /// A customer invoice, which can read "Partially paid" while its status is still issued.
    init(_ invoice: some PaymentBalance) {
        self.init(invoice.status)
        if invoice.isPartiallyPaid { (label, color) = (invoice.displayStatus, .orange) }
    }

    /// Original invoices have no status field, so it comes from their dates, as on the web.
    init(paidOn: String?, dueOn: String?) {
        if paidOn != nil {
            (label, color) = ("Paid", .green)
        } else if let dueOn, dueOn < ISODay.today {
            (label, color) = ("Overdue", .red)
        } else {
            (label, color) = ("Unpaid", .orange)
        }
    }

    var body: some View {
        Text(label).font(.caption.weight(.medium)).foregroundStyle(color)
    }
}

/// The row used wherever a list shows a customer invoice, proforma or original invoice.
struct DocumentRowLabel: View {
    let title: String
    let subtitle: String
    let detail: String
    let amount: String
    let status: StatusText?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(amount).font(.subheadline).monospacedDigit().fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                status
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One invoice line. `caption` carries the quantity and unit price, and any internal cost.
struct LineRow: View {
    let description: String
    let caption: [String]
    let amount: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(description)
                Spacer()
                Text(amount).monospacedDigit().fixedSize()
            }
            ForEach(caption, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
