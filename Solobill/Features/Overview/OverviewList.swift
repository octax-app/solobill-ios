import SwiftUI

/// What the mark as paid sheet is open for.
private enum PaidTarget: Identifiable {
    case invoice(Overview.Receivable)
    case original(Overview.Payable)

    var id: String {
        switch self {
        case .invoice(let row): "invoice-\(row.id)"
        case .original(let row): "original-\(row.id)"
        }
    }

    var title: String {
        switch self {
        case .invoice(let row): row.number ?? row.customerName
        case .original(let row): row.number.isEmpty ? row.providerName : "\(row.providerName) \(row.number)"
        }
    }

    var amount: String {
        switch self {
        case .invoice(let row): Money.format(row.amountDue, row.currency)
        case .original(let row): Money.format(row.total, row.currency)
        }
    }
}

struct OverviewList: View {
    let data: Overview
    let reload: @Sendable () async -> Void

    @Environment(\.api) private var api
    @State private var paying: PaidTarget?

    private func money(_ value: Int) -> String { Money.format(value, data.baseCurrency) }

    /// `margin` is a display percentage from the server. Printed like the web, so 40.0 reads "40%".
    private var margin: String {
        let text = String(data.summary.margin)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
    }

    var body: some View {
        List {
            notices
            figures
            toCollect
            toPay
            renewals
            Section {
                OverviewTrendChart(points: data.trend, currency: data.baseCurrency)
            } header: {
                Text("Profit by month")
            } footer: {
                Text("Last 12 months, in \(data.baseCurrency)")
            }
        }
        .refreshable { await reload() }
        .sheet(item: $paying) { target in
            MarkPaidSheet(title: target.title, amount: target.amount) { day in
                switch target {
                case .invoice(let row): try await api.markPaid(invoiceId: row.id, on: day)
                case .original(let row): try await api.markPaid(originalId: row.id, on: day)
                }
                await reload()
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if data.draftsToReview > 0 || data.unallocatedCost > 0 {
            Section {
                if data.draftsToReview > 0 {
                    let drafts = data.draftsToReview == 1 ? "1 renewal draft is" : "\(data.draftsToReview) renewal drafts are"
                    Label("\(drafts) waiting for review in the Renewals tab.", systemImage: "tray.full")
                        .accessibilityIdentifier("overview.drafts")
                }
                if data.unallocatedCost > 0 {
                    Label(
                        "\(money(data.unallocatedCost)) of provider invoices in this period is not linked to a customer line. It is not included in profit.",
                        systemImage: "link.badge.plus"
                    )
                    .accessibilityIdentifier("overview.unallocated")
                }
            }
        }
    }

    private var figures: some View {
        Section {
            OverviewFigure("Revenue", money(data.summary.revenue), note: "Excludes tax", id: "overview.revenue")
            OverviewFigure("Cost", money(data.summary.cost), id: "overview.cost")
            OverviewFigure("Profit", money(data.summary.profit), id: "overview.profit")
            OverviewFigure("Margin", margin, id: "overview.margin")
        } header: {
            Text("\(ISODay.display(data.from)) to \(ISODay.display(data.to))")
                .accessibilityIdentifier("overview.period")
        }
    }

    private var toCollect: some View {
        Section("To collect") {
            OverviewFigure("Unpaid by customers", money(data.toCollectTotal), id: "overview.toCollectTotal")
            if data.toCollect.isEmpty {
                OverviewEmpty("Customers have paid everything.")
            }
            ForEach(data.toCollect) { row in
                PendingRow(
                    route: .invoice(row.id),
                    id: "invoice.\(row.id)",
                    title: row.number ?? "No number",
                    subtitle: row.customerName,
                    amount: Money.format(row.amountDue, row.currency),
                    dueOn: row.dueOn,
                    today: data.today,
                    pay: { paying = .invoice(row) }
                )
            }
        }
    }

    private var toPay: some View {
        Section("To pay") {
            OverviewFigure("Unpaid to providers", money(data.toPayTotal), id: "overview.toPayTotal")
            if data.toPay.isEmpty {
                OverviewEmpty("You have paid all provider invoices.")
            }
            ForEach(data.toPay) { row in
                PendingRow(
                    route: .original(row.id),
                    id: "original.\(row.id)",
                    title: row.providerName,
                    subtitle: row.number.isEmpty ? "No number" : row.number,
                    amount: Money.format(row.total, row.currency),
                    dueOn: row.dueOn,
                    today: data.today,
                    pay: { paying = .original(row) }
                )
            }
        }
    }

    private var renewals: some View {
        Section("Renewals in the next 30 days") {
            if data.renewals.isEmpty {
                OverviewEmpty("Nothing renews in the next 30 days.")
            }
            ForEach(data.renewals) { row in
                NavigationLink(value: OverviewRoute.customer(row.customerId)) {
                    RenewalRow(row: row)
                }
            }
        }
    }
}
