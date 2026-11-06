import PDFKit
import SwiftUI

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// Shows a PDF with a share button. Push this onto a navigation stack.
struct PDFScreen: View {
    let title: String
    /// The file name offered when sharing, without the extension.
    let filename: String
    let load: @Sendable () async throws -> Data

    var body: some View {
        Loadable(load: load) { data, _ in
            PDFContent(data: data, filename: filename)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PDFContent: View {
    let data: Data
    let filename: String

    @State private var shareURL: URL?

    var body: some View {
        PDFKitView(data: data)
            .ignoresSafeArea(edges: .bottom)
            .accessibilityIdentifier("pdf.view")
            .toolbar {
                if let shareURL {
                    ShareLink(item: shareURL)
                        .accessibilityIdentifier("pdf.share")
                }
            }
            .task { shareURL = writeTemporaryFile() }
            .onDisappear {
                if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
            }
    }

    /// The share sheet needs a file on disk, and a real name makes the attachment readable.
    private func writeTemporaryFile() -> URL? {
        let safeName = filename.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = folder.appending(path: "\(safeName).pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}
