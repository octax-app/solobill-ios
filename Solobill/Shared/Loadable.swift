import SwiftUI

/// Loads a value and shows a spinner, an error with Retry, or the content.
/// Every main screen uses this, because the app is online only.
///
/// `id` reloads when it changes. `content` receives a closure that reloads on demand, for use
/// after a change such as mark as paid. Pull to refresh is up to the content.
struct Loadable<Value: Sendable, ID: Equatable, Content: View>: View {
    private enum Phase {
        case loading
        case loaded(Value)
        case failed(String)
    }

    private let id: ID
    private let load: @Sendable () async throws -> Value
    private let content: (Value, @escaping @Sendable () async -> Void) -> Content

    @State private var phase = Phase.loading
    @State private var attempt = 0

    init(
        id: ID,
        load: @escaping @Sendable () async throws -> Value,
        @ViewBuilder content: @escaping (Value, @escaping @Sendable () async -> Void) -> Content
    ) {
        self.id = id
        self.load = load
        self.content = content
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        phase = .loading
                        attempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retry")
                }
            case .loaded(let value):
                content(value, { await refresh() })
            }
        }
        .task(id: LoadKey(id: id, attempt: attempt)) {
            await refresh()
        }
    }

    private struct LoadKey: Equatable {
        let id: ID
        let attempt: Int
    }

    /// A failed reload shows the error and Retry, so stale figures are never passed off as current.
    @MainActor
    private func refresh() async {
        do {
            let value = try await load()
            phase = .loaded(value)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

extension Loadable where ID == Int {
    init(
        load: @escaping @Sendable () async throws -> Value,
        @ViewBuilder content: @escaping (Value, @escaping @Sendable () async -> Void) -> Content
    ) {
        self.init(id: 0, load: load, content: content)
    }
}
