import SwiftUI

struct OverviewFigure: View {
    private let label: String
    private let value: String
    private let note: String?
    private let id: String

    init(_ label: String, _ value: String, note: String? = nil, id: String) {
        self.label = label
        self.value = value
        self.note = note
        self.id = id
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}

struct OverviewEmpty: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }
}

/// A row in To collect or To pay. Tapping it opens the invoice, and its button marks it as paid.
struct PendingRow: View {
    let route: OverviewRoute
    /// Such as "invoice.12", so a UI test can find this row.
    let id: String
    let title: String
    let subtitle: String
    let amount: String
    let dueOn: String?
    /// The server's day, so overdue agrees with the server whatever the phone's clock says.
    let today: String
    let pay: () -> Void

    private var overdue: Bool {
        guard let dueOn else { return false }
        return dueOn < today
    }

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(amount).monospacedDigit()
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dueOn == nil ? "No due date" : "Due \(ISODay.display(dueOn))")
                        if overdue {
                            Text("Overdue")
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("overview.overdue.\(id)")
                        }
                    }
                    .font(.footnote)
                    Spacer()
                    Button("Mark as paid", action: pay)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("overview.pay.\(id)")
                }
            }
        }
        .accessibilityIdentifier("overview.row.\(id)")
    }
}

struct RenewalRow: View {
    let row: Overview.Renewal

    private var service: String {
        row.label.isEmpty ? row.serviceName : "\(row.serviceName), \(row.label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.customerName).font(.headline)
                Spacer()
                Text(Money.format(row.priceAmount, row.priceCurrency)).monospacedDigit()
            }
            Text(service)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Renews \(ISODay.display(row.nextRenewalOn))")
                .font(.footnote)
        }
    }
}
