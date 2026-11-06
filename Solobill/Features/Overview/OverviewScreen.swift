import SwiftUI

enum OverviewRoute: Hashable {
    case invoice(Int)
    case original(Int)
    case customer(Int)
}

/// Mirrors `web/src/client/pages/overview.tsx`. Every figure comes from `GET /overview`.
struct OverviewScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.api) private var api

    @State private var period = OverviewPeriod.month
    @State private var showingSettings = false
    @State private var customFrom = ISODay.date(from: OverviewPeriod.month.dates(today: OverviewPeriod.today).from) ?? .now
    @State private var customTo = ISODay.date(from: OverviewPeriod.today) ?? .now

    private var dates: PeriodDates {
        guard period == .custom else { return period.dates(today: OverviewPeriod.today) }
        return PeriodDates(from: ISODay.string(from: customFrom), to: ISODay.string(from: customTo))
    }

    var body: some View {
        NavigationStack {
            let dates = dates
            // The period stays outside Loadable, so it can still be changed from the error screen.
            // It sits above the content rather than in a safe area inset, where the large title
            // would slide underneath it.
            VStack(spacing: 0) {
                periodControl
                Loadable { [api] in
                    try await api.overview(from: dates.from, to: dates.to)
                } content: { data, reload in
                    OverviewList(data: data, reload: reload)
                }
                // A new identity rather than Loadable's `id`, which would keep showing the old
                // period's figures under the new choice until the new ones arrive.
                .id(dates)
            }
            .navigationTitle("Overview")
            .navigationDestination(for: OverviewRoute.self) { route in
                switch route {
                case .invoice(let id): InvoiceDetailScreen(invoiceID: id)
                case .original(let id): OriginalDetailScreen(originalID: id)
                case .customer(let id): CustomerDetailScreen(customerID: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                    .accessibilityIdentifier("signOut")
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsScreen() }
        }
    }

    private var periodControl: some View {
        VStack(spacing: 8) {
            Picker("Period", selection: $period) {
                ForEach(OverviewPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if period == .custom {
                DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
