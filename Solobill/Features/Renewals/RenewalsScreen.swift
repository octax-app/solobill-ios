import SwiftUI

/// A renewal draft and its line text, which the invoice list route does not include.
struct RenewalDraft: Identifiable, Hashable, Sendable {
    let row: InvoiceRow
    let description: String
    let needsAmount: Bool

    var id: Int { row.id }
}

extension APIClient {
    /// Soonest due first. Each draft is fetched for its lines, and there are only ever a few.
    func renewalDrafts() async throws -> [RenewalDraft] {
        let rows = try await invoices(type: .invoice, statuses: [.draft]).filter { $0.source == .renewal }
        let drafts = try await withThrowingTaskGroup(of: RenewalDraft.self) { group in
            for row in rows {
                group.addTask {
                    let lines = try await self.invoice(id: row.id).lines
                    return RenewalDraft(
                        row: row,
                        description: lines.map(\.description).joined(separator: ", "),
                        needsAmount: lines.contains { !$0.amountConfirmed }
                    )
                }
            }
            return try await group.reduce(into: [RenewalDraft]()) { $0.append($1) }
        }
        return drafts.sorted { ($0.row.dueOn ?? "9999", $0.id) < ($1.row.dueOn ?? "9999", $1.id) }
    }
}

struct RenewalsScreen: View {
    @Environment(\.api) private var api

    var body: some View {
        NavigationStack {
            // Loadable reloads whenever this appears, so returning from a review updates the list.
            Loadable(load: { [api] in try await api.renewalDrafts() }) { drafts, reload in
                List(drafts) { draft in
                    NavigationLink(value: draft) {
                        RenewalDraftRow(draft: draft)
                    }
                    .accessibilityIdentifier("renewals.row.\(draft.id)")
                }
                .overlay {
                    if drafts.isEmpty {
                        ContentUnavailableView(
                            "No renewals to review",
                            systemImage: "checkmark.circle",
                            description: Text("New drafts appear here before a subscription renews.")
                        )
                        .accessibilityIdentifier("renewals.empty")
                    }
                }
                .refreshable { await reload() }
            }
            .navigationTitle("Renewals")
            // Outside Loadable, so a draft that leaves the list keeps its open review.
            .navigationDestination(for: RenewalDraft.self) { draft in
                RenewalReviewScreen(invoiceID: draft.id, customerName: draft.row.displayCustomer)
            }
        }
    }
}

private struct RenewalDraftRow: View {
    let draft: RenewalDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.row.displayCustomer)
                .font(.headline)
            Text(draft.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text("Due \(ISODay.display(draft.row.dueOn))")
                Spacer()
                Text(Money.format(draft.row.total, draft.row.currency))
                    .monospacedDigit()
            }
            .font(.subheadline)
            if draft.needsAmount {
                Label("Amount to confirm", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
