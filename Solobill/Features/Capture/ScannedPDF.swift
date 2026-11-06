import PDFKit
import UIKit

enum ScannedPDF {
    /// Makes one PDF page per scanned image.
    static func make(from pages: [UIImage]) throws -> Data {
        let document = PDFDocument()
        for image in pages {
            guard let page = PDFPage(image: image, options: [.compressionQuality: 0.6]) else {
                throw CapturedPDFError.notPDF
            }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, let data = document.dataRepresentation() else {
            throw CapturedPDFError.notPDF
        }
        try CapturedPDF.validate(data)
        return data
    }
}
