import SwiftUI

extension View {
    /// Reloads when the view appears again, such as on Back from a screen that changed a document.
    /// The first appearance is skipped, because `Loadable` has just loaded.
    func reloadsOnReturn(_ reload: @escaping @Sendable () async -> Void) -> some View {
        modifier(ReloadOnReturn(reload: reload))
    }
}

private struct ReloadOnReturn: ViewModifier {
    let reload: @Sendable () async -> Void

    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content.onAppear {
            if hasAppeared { Task { await reload() } }
            hasAppeared = true
        }
    }
}
