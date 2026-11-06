import Foundation
import PDFKit
import Synchronization
import Testing
import UIKit

@testable import Solobill

/// A stub of its own, because Swift Testing runs suites in parallel and `StubProtocol` is shared.
private final class CaptureStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)?
    static let handler = Mutex<Handler?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let (status, data) = Self.handler.withLock({ $0 })?(request),
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubbedAPI() -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CaptureStub.self]
    return APIClient(
        baseURL: { URL(string: "https://example.test")! },
        session: URLSession(configuration: configuration),
        tokens: MemoryTokenStore(StoredToken(id: 1, token: "secret"))
    )
}

private func page(_ color: UIColor, size: CGSize = CGSize(width: 300, height: 400)) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

private func samplePDF() throws -> Data {
    try ScannedPDF.make(from: [page(.white)])
}

private func temporaryInbox() -> CaptureInbox {
    CaptureInbox(folder: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)"))
}

@Suite struct ScannedPDFTests {
    @Test func makesOnePagePerImage() throws {
        let data = try ScannedPDF.make(from: [page(.white), page(.gray), page(.black)])
        #expect(data.starts(with: Data("%PDF-".utf8)))
        #expect(PDFDocument(data: data)?.pageCount == 3)
    }

    @Test func keepsThePageShapeOfTheScan() throws {
        let data = try ScannedPDF.make(from: [page(.white, size: CGSize(width: 300, height: 600))])
        let bounds = try #require(PDFDocument(data: data)?.page(at: 0)?.bounds(for: .mediaBox))
        #expect(bounds.height == bounds.width * 2)
    }

    @Test func refusesAnEmptyScan() {
        #expect(throws: CapturedPDFError.notPDF) { try ScannedPDF.make(from: []) }
    }

    @Test func aPhoneSizedScanStaysWellInsideTheLimit() throws {
        // Noise is the worst case for compression, so a real page is smaller than this.
        let size = CGSize(width: 2500, height: 3500)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let noisy = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in stride(from: 0, to: 2500, by: 8) {
                for y in stride(from: 0, to: 3500, by: 8) {
                    UIColor(white: CGFloat((x &* 7 ^ y &* 13) % 97) / 97, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let data = try ScannedPDF.make(from: [noisy])
        #expect(data.count < 2_500_000)
    }
}

@Suite struct CapturedPDFTests {
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test func acceptsARealPDF() throws {
        let data = try samplePDF()
        #expect(try CapturedPDF.read(try file(data)) == data)
    }

    @Test func refusesAFileThatOnlyHasAPDFName() throws {
        let url = try file(Data("this is not a pdf".utf8))
        #expect(throws: CapturedPDFError.notPDF) { try CapturedPDF.read(url) }
    }

    @Test func refusesAFileThatOnlyStartsLikeAPDF() throws {
        let url = try file(Data("%PDF-1.7 and then nothing useful".utf8))
        #expect(throws: CapturedPDFError.notPDF) { try CapturedPDF.read(url) }
    }

    @Test func refusesAFileOverTheServerLimit() throws {
        let url = try file(Data(count: CapturedPDF.maxBytes + 1))
        #expect(throws: CapturedPDFError.tooLarge) { try CapturedPDF.read(url) }
    }

    @Test func theLimitMatchesTheServer() {
        #expect(CapturedPDF.maxBytes == 20 * 1024 * 1024)
    }
}

@MainActor
@Suite struct CaptureInboxTests {
    @Test func aMissingFolderIsAnEmptyInbox() {
        #expect(temporaryInbox().waiting().isEmpty)
    }

    @Test func readsOldestFirstAndRemovesOneFile() throws {
        let inbox = temporaryInbox()
        let first = try inbox.add(Data("one".utf8))
        Thread.sleep(forTimeInterval: 0.01)
        let second = try inbox.add(Data("two".utf8))
        #expect(inbox.waiting().map(\.lastPathComponent) == [first, second].map(\.lastPathComponent))
        inbox.remove(first)
        #expect(inbox.waiting().map(\.lastPathComponent) == [second.lastPathComponent])
    }

    @Test func ignoresAnythingThatIsNotAFinishedPDF() throws {
        let inbox = temporaryInbox()
        try inbox.add(Data("one".utf8))
        try Data().write(to: inbox.folder.appending(path: ".dat.nosync1234"))
        #expect(inbox.waiting().count == 1)
    }

    @Test func keepsTheFileUntilTheFormFinishes() throws {
        let inbox = temporaryInbox()
        let pdf = try samplePDF()
        try inbox.add(pdf)
        let coordinator = CaptureCoordinator(inbox: inbox)

        coordinator.check()
        let request = try #require(coordinator.request)
        #expect(request.model.pdf == pdf)
        #expect(inbox.waiting().count == 1)

        // Becoming active again keeps the same form, so nothing typed into it is lost.
        coordinator.check()
        #expect(coordinator.request?.id == request.id)
        #expect(inbox.waiting().count == 1)

        coordinator.finish()
        #expect(coordinator.request == nil)
        #expect(inbox.waiting().isEmpty)
    }

    @Test func movesOnToTheNextWaitingPDF() throws {
        let inbox = temporaryInbox()
        let first = try samplePDF()
        let second = try ScannedPDF.make(from: [page(.white), page(.black)])
        try inbox.add(first)
        Thread.sleep(forTimeInterval: 0.01)
        try inbox.add(second)
        let coordinator = CaptureCoordinator(inbox: inbox)

        coordinator.check()
        #expect(coordinator.request?.model.pdf == first)
        coordinator.finish()
        #expect(coordinator.request?.model.pdf == second)
        coordinator.finish()
        #expect(coordinator.request == nil)
    }

    @Test func dropsADamagedFileRatherThanOpeningItForever() throws {
        let inbox = temporaryInbox()
        try inbox.add(Data("not a pdf".utf8))
        let coordinator = CaptureCoordinator(inbox: inbox)
        coordinator.check()
        #expect(coordinator.request == nil)
        #expect(inbox.waiting().isEmpty)
    }

    @Test func anEmptyInboxOpensNothing() {
        let coordinator = CaptureCoordinator(inbox: temporaryInbox())
        coordinator.check()
        #expect(coordinator.request == nil)
    }
}

@MainActor
@Suite struct OriginalFormInputTests {
    private func ready() -> OriginalFormModel {
        let model = OriginalFormModel()
        model.prepare(OriginalFormOptions(baseCurrency: "USD", providers: [], services: []))
        model.providerId = 3
        model.lines = [.init(description: "Hosting", quantity: "2", unitPrice: "12.345")]
        return model
    }

    private let dotted = Locale(identifier: "en_US")
    private let comma = Locale(identifier: "de_DE")

    @Test func usesScaledIntegersAndTheBaseRate() throws {
        let model = ready()
        model.tax = "1.5"
        let input = try model.makeInput(locale: dotted)
        #expect(input.providerId == 3)
        #expect(input.currency == "USD")
        #expect(input.fxRate == Money.fxScale)
        #expect(input.tax == 15_000)
        #expect(input.lines[0].quantity == 20_000)
        #expect(input.lines[0].unitPrice == 123_450)
        #expect(input.dueOn == nil)
    }

    @Test func sendsTheTypedRateForAnotherCurrency() throws {
        let model = ready()
        model.currency = "OMR"
        model.fxRate = "2.6"
        #expect(try model.makeInput(locale: dotted).fxRate == 260_000_000)
    }

    @Test func refusesAMissingRate() {
        let model = ready()
        model.currency = "OMR"
        #expect(throws: (any Error).self) { try model.makeInput(locale: dotted) }
    }

    @Test func aCommaDecimalIsNotReadAsAThousandsSeparator() throws {
        let model = ready()
        model.lines = [.init(description: "Hosting", quantity: "1", unitPrice: "1,5")]
        #expect(try model.makeInput(locale: comma).lines[0].unitPrice == 15_000)
    }

    @Test func namesTheLineThatIsWrong() {
        let model = ready()
        model.lines.append(.init(description: "Second", quantity: "1", unitPrice: "abc"))
        #expect {
            try model.makeInput(locale: dotted)
        } throws: { $0.localizedDescription == "Line 2: enter a valid unit price." }
    }

    @Test func changingProviderClearsTheInvoiceType() {
        let model = ready()
        model.serviceId = 9
        model.providerId = 4
        #expect(model.serviceId == nil)
    }

    @Test func changingCurrencyClearsTheRate() {
        let model = ready()
        model.currency = "OMR"
        model.fxRate = "2.6"
        model.currency = "EUR"
        #expect(model.fxRate.isEmpty)
    }
}

@MainActor
@Suite(.serialized) struct OriginalFormSaveTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle(for: FixtureAnchor.self).url(forResource: "originalFull", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func ready(pdf: Data?) -> OriginalFormModel {
        let model = OriginalFormModel(pdf: pdf)
        model.prepare(OriginalFormOptions(baseCurrency: "USD", providers: [], services: []))
        model.providerId = 3
        model.lines = [.init(description: "Hosting", quantity: "1", unitPrice: "5")]
        return model
    }

    private final class Calls: Sendable {
        let creates = Mutex(0)
        let uploads = Mutex(0)
        let failuresLeft: Mutex<Int>
        init(failures: Int) { failuresLeft = Mutex(failures) }
    }

    private func install(_ calls: Calls) throws {
        let body = try fixture()
        CaptureStub.handler.withLock {
            $0 = { request in
                if request.url?.path.hasSuffix("/pdf") == true {
                    calls.uploads.withLock { $0 += 1 }
                    let failing = calls.failuresLeft.withLock { left -> Bool in
                        guard left > 0 else { return false }
                        left -= 1
                        return true
                    }
                    return failing ? nil : (200, body)
                }
                calls.creates.withLock { $0 += 1 }
                return (201, body)
            }
        }
    }

    @Test func aRetryUploadsAgainWithoutCreatingADuplicate() async throws {
        let calls = Calls(failures: 2)
        try install(calls)
        let api = stubbedAPI()
        let model = ready(pdf: try samplePDF())

        await model.save(api: api)
        #expect(model.created != nil)
        #expect(model.finished == nil)
        #expect(model.uploadError != nil)

        await model.save(api: api)
        #expect(model.finished == nil)

        await model.save(api: api)
        #expect(model.finished != nil)
        #expect(model.uploadError == nil)
        #expect(calls.creates.withLock { $0 } == 1)
        #expect(calls.uploads.withLock { $0 } == 3)
    }

    @Test func aFailedCreateKeepsTheFormAndUploadsNothing() async throws {
        CaptureStub.handler.withLock {
            $0 = { _ in (422, Data(#"{"error":"Enter a description"}"#.utf8)) }
        }
        let model = ready(pdf: try samplePDF())
        await model.save(api: stubbedAPI())
        #expect(model.created == nil)
        #expect(model.uploadError == nil)
        #expect(model.errorMessage == "Enter a description")
    }

    @Test func withNoPDFThereIsNoUpload() async throws {
        let calls = Calls(failures: 0)
        try install(calls)
        let model = ready(pdf: nil)
        await model.save(api: stubbedAPI())
        #expect(model.finished != nil)
        #expect(calls.creates.withLock { $0 } == 1)
        #expect(calls.uploads.withLock { $0 } == 0)
    }

    @Test func leavingWithoutThePDFKeepsTheSavedOriginal() async throws {
        let calls = Calls(failures: 1)
        try install(calls)
        let model = ready(pdf: try samplePDF())
        await model.save(api: stubbedAPI())
        model.leaveWithoutPDF()
        #expect(model.finished == model.created)
    }

    @Test func prefillsTheLastRateButKeepsWhatWasTyped() async throws {
        CaptureStub.handler.withLock { $0 = { _ in (200, Data(#"{"rate":260000000}"#.utf8)) } }
        let api = stubbedAPI()
        let model = ready(pdf: nil)
        model.currency = "OMR"
        await model.prefillRate(api: api)
        #expect(model.fxRate == "2.6")

        model.fxRate = "2.5"
        await model.prefillRate(api: api)
        #expect(model.fxRate == "2.5")
    }

    @Test func noRateIsNeededForTheBaseCurrency() async throws {
        CaptureStub.handler.withLock { $0 = { _ in (200, Data(#"{"rate":260000000}"#.utf8)) } }
        let model = ready(pdf: nil)
        await model.prefillRate(api: stubbedAPI())
        #expect(model.fxRate.isEmpty)
    }
}

private final class FixtureAnchor {}
