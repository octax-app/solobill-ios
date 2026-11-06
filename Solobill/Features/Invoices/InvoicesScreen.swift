import SwiftUI

/// Customer invoices and original invoices. Proformas have their own tab.
struct InvoicesScreen: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case customer = "Customer"
        case original = "Original"
        var id: Self { self }
    }

    @State private var kind = Kind.customer
    @State private var addingOriginal = false
    @State private var addingInvoice = false
    /// Set after issuing, to open the issued invoice.
    @State private var issuedID: Int?
    /// Changing these reloads the lists.
    @State private var originalsVersion = 0
    @State private var invoicesVersion = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Invoices", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("invoices.kind")

                switch kind {
                case .customer: CustomerInvoiceList(version: invoicesVersion)
                case .original: OriginalList(version: originalsVersion)
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                switch kind {
                case .customer:
                    Button("New invoice", systemImage: "plus") { addingInvoice = true }
                        .accessibilityIdentifier("invoices.new")
                case .original:
                    Button("Add original invoice", systemImage: "plus") { addingOriginal = true }
                        .accessibilityIdentifier("originals.add")
                }
            }
            .navigationDestination(item: $issuedID) { id in
                InvoiceDetailScreen(invoiceID: id)
            }
            .sheet(isPresented: $addingInvoice, onDismiss: { invoicesVersion += 1 }) {
                DocumentEditorSheet(mode: .new(.invoice)) { issued in
                    addingInvoice = false
                    issuedID = issued.id
                }
            }
            .sheet(isPresented: $addingOriginal) {
                OriginalFormScreen(onSaved: { _ in
                    addingOriginal = false
                    originalsVersion += 1
                })
            }
        }
    }
}
