import SwiftUI

/// All customers, searched by the server on name, company and email.
struct CustomersScreen: View {
    @Environment(\.api) private var api
    @State private var text = ""
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Loadable(id: search) { [api, search] in
                try await api.customers(search: search.isEmpty ? nil : search)
            } content: { customers, reload in
                List(customers) { customer in
                    NavigationLink {
                        CustomerDetailScreen(customerID: customer.id)
                    } label: {
                        CustomerRow(customer: customer)
                    }
                    .accessibilityIdentifier("customer.row.\(customer.id)")
                }
                .overlay {
                    if customers.isEmpty {
                        if search.isEmpty {
                            ContentUnavailableView("No customers yet", systemImage: "person.2")
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
                .refreshable { await reload() }
            }
            .navigationTitle("Customers")
            .searchable(text: $text, prompt: "Name, company or email")
            .task(id: text) {
                // Waits for a pause in typing, so each key press is not a request.
                guard text != search else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { search = text }
            }
        }
    }
}

private struct CustomerRow: View {
    let customer: Customer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(customer.displayName).font(.headline)
                Spacer()
                if customer.status != .active {
                    Text(customer.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String? {
        let lines = [customer.company.isEmpty ? "" : customer.name, customer.email]
        let text = lines.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}
