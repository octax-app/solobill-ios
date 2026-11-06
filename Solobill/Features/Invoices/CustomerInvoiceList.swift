import SwiftUI

/// Customer invoices with the same status filter as the web list.
struct CustomerInvoiceList: View {
    /// Changing this reloads the list.
    var version = 0

    @Environment(\.api) private var api
    @State private var filter: DocumentStatus?

    private static let filters: [DocumentStatus] = [.draft, .issued, .paid, .void]

    private struct LoadKey: Equatable {
        let filter: DocumentStatus?
        let version: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status", selection: $filter) {
                Text("All").tag(DocumentStatus?.none)
                ForEach(Self.filters, id: \.self) { Text($0.label).tag(DocumentStatus?.some($0)) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("invoices.status")

            Loadable(id: LoadKey(filter: filter, version: version)) { [api, filter] in
                try await api.invoices(type: .invoice, statuses: filter.map { [$0] } ?? [])
            } content: { invoices, reload in
                List(invoices) { invoice in
                    NavigationLink {
                        InvoiceDetailScreen(invoiceID: invoice.id)
                    } label: {
                        DocumentRowLabel(
                            title: invoice.number ?? "Draft",
                            subtitle: invoice.displayCustomer,
                            detail: dates(of: invoice),
                            amount: Money.format(invoice.total, invoice.currency),
                            status: StatusText(invoice)
                        )
                    }
                    .accessibilityIdentifier("invoice.row.\(invoice.id)")
                }
                .overlay {
                    if invoices.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "doc.text")
                    }
                }
                .refreshable { await reload() }
                .reloadsOnReturn(reload)
            }
        }
    }

    private func dates(of invoice: InvoiceRow) -> String {
        let issued = invoice.issuedOn.map(ISODay.display) ?? "Not issued"
        guard let due = invoice.dueOn else { return issued }
        return "\(issued), due \(ISODay.display(due))"
    }
}
