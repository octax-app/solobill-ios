import UIKit
import UniformTypeIdentifiers

/// Copies shared PDFs into the App Group inbox, then tries to open the app. It holds no token and
/// makes no API calls. If the app cannot be opened, the inbox still has the PDF, and the app finds
/// it the next time it becomes active.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let done = UIButton(configuration: .borderedProminent())
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.numberOfLines = 0
        message.textAlignment = .center
        message.text = "Saving to Solobill"
        message.accessibilityIdentifier = "share.message"
        done.setTitle("Done", for: .normal)
        done.isHidden = true
        done.accessibilityIdentifier = "share.done"
        done.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, message, done])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await capture() }
    }

    private func capture() async {
        do {
            guard let inbox = CaptureInbox.shared else { throw ShareError.noInbox }
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let pdfs = items.flatMap { $0.attachments ?? [] }.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            }
            guard !pdfs.isEmpty else { throw CapturedPDFError.notPDF }
            for pdf in pdfs { try await copy(pdf, to: inbox) }
        } catch {
            finish(saying: error.localizedDescription)
            return
        }
        if await openApp() {
            close()
        } else {
            finish(saying: "Saved. Open Solobill to finish adding this invoice.")
        }
    }

    private func copy(_ provider: NSItemProvider, to inbox: CaptureInbox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The system deletes this file when the closure returns, so copy it inside.
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? CapturedPDFError.notPDF }
                    try inbox.add(try CapturedPDF.read(url))
                })
            }
        }
    }

    /// Extensions have no supported way to open their app, so this walks to `UIApplication` and
    /// calls `open` through the runtime, because it is unavailable to extensions at compile time.
    /// It may stop working in a later iOS, which is why the inbox is the reliable path.
    private func openApp() async -> Bool {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let url = NSURL(string: "solobill://capture") else { return false }
        var responder: UIResponder? = self
        while let next = responder {
            if next is UIApplication, next.responds(to: selector) {
                let open = unsafeBitCast(next.method(for: selector), to: Open.self)
                return await withCheckedContinuation { continuation in
                    open(next, selector, url, [:]) { continuation.resume(returning: $0) }
                }
            }
            responder = next.next
        }
        return false
    }

    private func finish(saying text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        message.text = text
        done.isHidden = false
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private enum ShareError: LocalizedError {
    case noInbox

    var errorDescription: String? { "Solobill could not save this PDF." }
}
