import SwiftUI

/// Matches the web customer page. Other features push this to show one customer.
struct CustomerDetailScreen: View {
    let customerID: Int

    @Environment(\.api) private var api
    @State private var creating: DocumentType?
    /// Set after issuing, to open the issued document.
    @State private var issuedID: Int?
    @State private var addingPayment = false

    private struct Details: Sendable {
        let customer: Customer
        let summary: CustomerSummary
        let subscriptions: [Subscription]
        let invoices: [InvoiceRow]
    }

    var body: some View {
        Loadable(id: customerID) { [api, customerID] in
            async let customer = api.customer(id: customerID)
            async let summary = api.customerSummary(id: customerID)
            async let subscriptions = api.subscriptions(customerId: customerID)
            async let invoices = api.invoices(customerId: customerID)
            return try await Details(
                customer: customer,
                summary: summary,
                subscriptions: subscriptions,
                invoices: invoices
            )
        } content: { details, reload in
            content(details, reload: reload)
                .refreshable { await reload() }
                .reloadsOnReturn(reload)
                .navigationTitle(details.customer.displayName)
                .sheet(item: $creating, onDismiss: { Task { await reload() } }) { type in
                    DocumentEditorSheet(mode: .new(type, customerID: customerID)) { issued in
                        creating = nil
                        issuedID = issued.id
                    }
                }
        }
        .navigationDestination(item: $issuedID) { id in
            InvoiceDetailScreen(invoiceID: id)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ details: Details, reload: @escaping @Sendable () async -> Void) -> some View {
        List {
            contactSection(details.customer)
            figuresSection(details.summary)
            Section {
                Button("Add payment") { addingPayment = true }
                    .accessibilityIdentifier("customer.addPayment")
            }
            subscriptionsSection(details.subscriptions)
            invoicesSection(details.invoices)
            originalsSection(details.summary.linkedOriginals)
        }
        .sheet(isPresented: $addingPayment) {
            CustomerPaymentSheet(customer: details.customer, invoices: details.invoices) { input in
                try await api.addCustomerPayment(customerId: details.customer.id, input)
                await reload()
            }
        }
    }

    private func contactSection(_ customer: Customer) -> some View {
        Section("Details") {
            LabeledContent("Name", value: customer.name)
            if !customer.company.isEmpty { LabeledContent("Company", value: customer.company) }
            LabeledContent("Status", value: customer.status.rawValue.capitalized)
            if !customer.email.isEmpty { LabeledContent("Email", value: customer.email) }
            if !customer.phone.isEmpty { LabeledContent("Phone", value: customer.phone) }
            if !customer.address.isEmpty { LabeledContent("Address", value: customer.address) }
            if !customer.taxNumber.isEmpty { LabeledContent("Tax number", value: customer.taxNumber) }
            LabeledContent("Currency", value: customer.currency)
            if !customer.notes.isEmpty { Text(customer.notes).foregroundStyle(.secondary) }
        }
    }

    private func figuresSection(_ summary: CustomerSummary) -> some View {
        Section("Figures in \(summary.baseCurrency)") {
            figure("Total billed", summary.summary.revenue, summary.baseCurrency, id: "billed")
            figure("Original cost", summary.summary.cost, summary.baseCurrency, id: "cost")
            figure("Profit", summary.summary.profit, summary.baseCurrency, id: "profit")
            figure("Pending", summary.pending, summary.baseCurrency, id: "pending")
        }
    }

    private func figure(_ label: String, _ amount: Int, _ currency: String, id: String) -> some View {
        LabeledContent(label, value: Money.format(amount, currency))
            .monospacedDigit()
            .accessibilityIdentifier("customer.\(id)")
    }

    private func subscriptionsSection(_ subscriptions: [Subscription]) -> some View {
        Section("Subscriptions") {
            if subscriptions.isEmpty {
                Text("No subscriptions yet.").foregroundStyle(.secondary)
            }
            ForEach(subscriptions) { subscription in
                SubscriptionRow(subscription: subscription)
            }
        }
    }

    private func invoicesSection(_ invoices: [InvoiceRow]) -> some View {
        Section("Invoices and proformas") {
            Button("New invoice") { creating = .invoice }
                .accessibilityIdentifier("customer.newInvoice")
            Button("New proforma") { creating = .proforma }
                .accessibilityIdentifier("customer.newProforma")
            if invoices.isEmpty {
                Text("No invoices yet.").foregroundStyle(.secondary)
            }
            ForEach(invoices) { invoice in
                NavigationLink {
                    InvoiceDetailScreen(invoiceID: invoice.id)
                } label: {
                    DocumentRowLabel(
                        title: invoice.number ?? "Draft",
                        subtitle: invoice.type.rawValue.capitalized,
                        detail: invoice.issuedOn.map(ISODay.display) ?? "Not issued",
                        amount: Money.format(invoice.status == .issued ? invoice.due : invoice.total, invoice.currency),
                        status: StatusText(invoice)
                    )
                }
                .accessibilityIdentifier("customer.invoice.\(invoice.id)")
            }
        }
    }

    private func originalsSection(_ originals: [CustomerSummary.LinkedOriginal]) -> some View {
        Section("Linked original invoices") {
            if originals.isEmpty {
                Text("No original invoices are linked to this customer.").foregroundStyle(.secondary)
            }
            ForEach(originals) { original in
                NavigationLink {
                    OriginalDetailScreen(originalID: original.id)
                } label: {
                    DocumentRowLabel(
                        title: original.number,
                        subtitle: original.providerName,
                        detail: ISODay.display(original.issuedOn),
                        amount: Money.format(original.total, original.currency),
                        status: nil
                    )
                }
                .accessibilityIdentifier("customer.original.\(original.id)")
            }
        }
    }
}

private struct SubscriptionRow: View {
    let subscription: Subscription

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(subscription.serviceName).font(.headline)
                Spacer()
                Text(subscription.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(subscription.status == .active ? .green : .secondary)
            }
            Text(providerAndLabel).font(.subheadline).foregroundStyle(.secondary)
            LabeledContent("Price", value: Money.format(subscription.priceAmount, subscription.priceCurrency))
            LabeledContent("Cost", value: Money.format(subscription.costAmount, subscription.costCurrency))
            LabeledContent(subscription.cycle.label, value: "Next: \(ISODay.display(subscription.nextRenewalOn))")
        }
        .font(.subheadline)
    }

    private var providerAndLabel: String {
        [subscription.providerName, subscription.label].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
