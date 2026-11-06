import SwiftUI

/// Chooses between login, the lock screen and the app, and locks when the app is backgrounded.
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch session.state {
            case .signedOut:
                LoginScreen()
            case .locked:
                LockScreen()
            case .active:
                MainTabs()
            }
            // Keeps figures out of the app switcher snapshot.
            if scenePhase != .active {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.lock() }
        }
        .captureInbox(isActive: session.state == .active)
    }
}

struct MainTabs: View {
    private enum AppTab {
        case overview, customers, invoices, proformas, renewals
    }

    @Environment(PushCenter.self) private var push
    @State private var tab = AppTab.overview

    var body: some View {
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "chart.bar", value: .overview) { OverviewScreen() }
            Tab("Customers", systemImage: "person.2", value: .customers) { CustomersScreen() }
            Tab("Invoices", systemImage: "doc.text", value: .invoices) { InvoicesScreen() }
            Tab("Proformas", systemImage: "doc.badge.plus", value: .proformas) { ProformasScreen() }
            Tab("Renewals", systemImage: "arrow.clockwise", value: .renewals) { RenewalsScreen() }
        }
        .task { await push.start() }
        // Runs on appear too, so a notification tapped while locked opens after unlocking.
        .onChange(of: push.route, initial: true) { _, route in
            if route == .renewals {
                tab = .renewals
                push.route = nil
            }
        }
        .sheet(item: documentRoute) { route in
            NavigationStack {
                document(for: route)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { push.route = nil }
                        }
                    }
            }
        }
    }

    private var documentRoute: Binding<PushRoute?> {
        Binding(
            get: { push.route == .renewals ? nil : push.route },
            set: { push.route = $0 }
        )
    }

    @ViewBuilder
    private func document(for route: PushRoute) -> some View {
        switch route {
        case .invoice(let id): InvoiceDetailScreen(invoiceID: id)
        case .original(let id): OriginalDetailScreen(originalID: id)
        case .renewals: EmptyView()
        }
    }
}

struct LockScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Solobill is locked")
                .font(.headline)
            Button("Unlock") {
                Task { await session.unlock() }
            }
            .buttonStyle(.borderedProminent)
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await session.unlockAutomatically() }
        }
    }
}
