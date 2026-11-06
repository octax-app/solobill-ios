import Foundation
import PDFKit

// This file is compiled into the app and the Share Extension. Keep it free of API calls: the
// extension holds no token.

enum CapturedPDFError: LocalizedError, Equatable {
    case notPDF
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notPDF: "This file is not a PDF."
        case .tooLarge: "This PDF is larger than the 20 MB limit."
        }
    }
}

/// The server's rules for an original invoice PDF, checked here so a bad file fails early.
enum CapturedPDF {
    /// Matches `maxUploadBytes` on the server.
    static let maxBytes = 20 * 1024 * 1024

    static func validate(_ data: Data) throws {
        guard data.count <= maxBytes else { throw CapturedPDFError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)), PDFDocument(data: data) != nil else {
            throw CapturedPDFError.notPDF
        }
    }

    /// Checks the size first, so an oversized file is never loaded.
    static func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw CapturedPDFError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validate(data)
        return data
    }
}

/// PDFs waiting in the App Group. The extension adds them, and the app removes each one only
/// after it is saved or the owner cancels.
struct CaptureInbox: Sendable {
    static let appGroup = "group.dev.octax.mg"

    let folder: URL

    /// Nil if the App Group is missing from the build's entitlements.
    static var shared: CaptureInbox? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { CaptureInbox(folder: $0.appending(path: "inbox")) }
    }

    @discardableResult
    func add(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        let file = folder.appending(path: "\(stamp)-\(UUID().uuidString).pdf")
        // Atomic, so the app never sees half a file under a .pdf name.
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// Oldest first. The file names start with the time they were added.
    func waiting() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
