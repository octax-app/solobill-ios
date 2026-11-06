import SwiftUI

struct ProformasScreen: View {
    private enum Route: Hashable {
        case review(Int)
        case detail(Int)
        case pdf(id: Int, number: String)
    }

    @Environment(\.api) private var api
    @State private var path: [Route] = []
    @State private var isCreating = false
    /// Bumped to reload the list after a proforma is created or issued.
    @State private var version = 0

    var body: some View {
        let api = api
        NavigationStack(path: $path) {
            Loadable(id: version) {
                try await api.invoices(type: .proforma)
            } content: { proformas, reload in
                list(proformas, reload: reload)
            }
            .navigationTitle("Proformas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New proforma", systemImage: "plus") { isCreating = true }
                        .accessibilityIdentifier("proformas.new")
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .sheet(isPresented: $isCreating, onDismiss: { version += 1 }) {
            DocumentEditorSheet(mode: .new(.proforma)) { issued in
                isCreating = false
                showPDF(of: issued)
            }
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if isEmpty { version += 1 }
        }
    }

    private func list(_ proformas: [InvoiceRow], reload: @escaping @Sendable () async -> Void) -> some View {
        List(proformas) { proforma in
            NavigationLink(value: route(for: proforma)) {
                ProformaRow(proforma: proforma)
            }
            .accessibilityIdentifier("proforma.row.\(proforma.id)")
        }
        .refreshable { await reload() }
        .overlay {
            if proformas.isEmpty {
                ContentUnavailableView("No proformas yet", systemImage: "doc.badge.plus")
            }
        }
    }

    /// A draft goes to review, the one place that can issue it, so a failed issue can be retried
    /// after leaving the form.
    private func route(for proforma: InvoiceRow) -> Route {
        proforma.status == .draft ? .review(proforma.id) : .detail(proforma.id)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .review(let id):
            DocumentReviewScreen(invoiceID: id, onIssued: showPDF)
        case .detail(let id):
            InvoiceDetailScreen(invoiceID: id)
        case .pdf(let id, let number):
            let api = api
            PDFScreen(title: number, filename: number) { try await api.invoicePDF(id: id) }
        }
    }

    /// Replaces the path, so Back goes to the list and not to a draft that is no longer one.
    private func showPDF(of issued: InvoiceFull) {
        path = [.pdf(id: issued.id, number: issued.number ?? "Proforma")]
    }
}

private struct ProformaRow: View {
    let proforma: InvoiceRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(proforma.number ?? "No number yet")
                    .font(.headline)
                Text(proforma.displayCustomer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Money.format(proforma.total, proforma.currency))
                    .monospacedDigit()
                Text(proforma.status.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }
}
