import Observation
import SwiftUI

/// Presents PDFs waiting in the inbox. This check, and not the extension's attempt to open the
/// app, is what makes sharing reliable.
@MainActor
@Observable
final class CaptureCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        /// The inbox file, removed when the form finishes. Nil for a blank form.
        let file: URL?
        let model: OriginalFormModel
    }

    private(set) var request: Request?

    @ObservationIgnored private let inbox: CaptureInbox?
    #if DEBUG
    @ObservationIgnored private var openedBlankForm = false
    #endif

    init(inbox: CaptureInbox? = .shared) { self.inbox = inbox }

    /// Takes the oldest waiting PDF. Does nothing while a form is open, and the same form comes
    /// back after a lock, so an original that was already created is never saved twice.
    func check() {
        guard request == nil else { return }
        #if DEBUG
        // UI tests reach the blank form this way. This is not in Release builds.
        if UserDefaults.standard.bool(forKey: "openOriginalForm"), !openedBlankForm {
            openedBlankForm = true
            request = Request(file: nil, model: OriginalFormModel())
            return
        }
        #endif
        guard let inbox else { return }
        for file in inbox.waiting() {
            // A failed read may be temporary, so that file stays and is tried on the next check.
            guard let data = try? Data(contentsOf: file) else { continue }
            guard (try? CapturedPDF.validate(data)) != nil else {
                // The extension checks files first, so this one was damaged and can never open.
                inbox.remove(file)
                continue
            }
            request = Request(file: file, model: OriginalFormModel(pdf: data))
            return
        }
    }

    /// The form was saved or cancelled. Moves on to the next waiting PDF, if there is one.
    func finish() {
        if let file = request?.file { inbox?.remove(file) }
        request = nil
        check()
    }
}

private struct CaptureInboxPresenter: ViewModifier {
    let isActive: Bool

    @State private var coordinator = CaptureCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    private var visibleRequest: Binding<CaptureCoordinator.Request?> {
        // Closing the form always goes through `finish`. The sheet hides while locked, and the
        // request stays, so the same form returns after unlock.
        Binding(get: { isActive ? coordinator.request : nil }, set: { _ in })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { check() }
            }
            .onChange(of: isActive) { _, _ in check() }
            .onOpenURL { url in
                if url.scheme == "solobill", url.host() == "capture" { check() }
            }
            .sheet(item: visibleRequest) { request in
                OriginalFormScreen(
                    model: request.model,
                    onSaved: { _ in coordinator.finish() },
                    onCancel: { coordinator.finish() }
                )
            }
    }

    private func check() {
        if isActive { coordinator.check() }
    }
}

extension View {
    /// Shows waiting PDFs in the original invoice form. `isActive` is false until the session is
    /// unlocked, and nothing is shown or read before then.
    func captureInbox(isActive: Bool) -> some View {
        modifier(CaptureInboxPresenter(isActive: isActive))
    }
}
