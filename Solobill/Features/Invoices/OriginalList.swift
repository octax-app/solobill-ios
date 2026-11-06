import SwiftUI

/// What providers charge the owner. Internal only, and never shown to customers.
struct OriginalList: View {
    /// Reloads the list when it changes, such as after adding an original invoice.
    let version: Int

    @Environment(\.api) private var api

    var body: some View {
        Loadable(id: version) { [api] in
            try await api.originals()
        } content: { originals, reload in
            List(originals) { original in
                NavigationLink {
                    OriginalDetailScreen(originalID: original.id)
                } label: {
                    DocumentRowLabel(
                        title: original.providerName,
                        subtitle: original.number,
                        detail: dates(of: original),
                        amount: Money.format(original.total, original.currency),
                        status: StatusText(paidOn: original.paidOn, dueOn: original.dueOn)
                    )
                }
                .accessibilityIdentifier("original.row.\(original.id)")
            }
            .overlay {
                if originals.isEmpty {
                    ContentUnavailableView("No original invoices yet", systemImage: "doc")
                }
            }
            .refreshable { await reload() }
        }
    }

    private func dates(of original: OriginalRow) -> String {
        let issued = ISODay.display(original.issuedOn)
        guard let due = original.dueOn else { return issued }
        return "\(issued), due \(ISODay.display(due))"
    }
}
