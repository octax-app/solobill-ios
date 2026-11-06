import Foundation
import Observation
import UIKit

/// What the form needs from the server before it can show its fields.
struct OriginalFormOptions: Sendable {
    let baseCurrency: String
    let providers: [Provider]
    let services: [Service]

    static func load(_ api: APIClient) async throws -> OriginalFormOptions {
        async let settings = api.settings()
        async let providers = api.providers()
        async let services = api.services()
        return try await OriginalFormOptions(
            baseCurrency: settings.baseCurrency,
            providers: providers,
            services: services
        )
    }
}

/// The state of one original invoice being entered. It lives outside the screen so a form from
/// the inbox survives the app locking, including the fact that the original was already created.
@MainActor
@Observable
final class OriginalFormModel {
    struct Line: Identifiable {
        let id = UUID()
        var description = ""
        var quantity = "1"
        var unitPrice = ""
    }

    private struct InputError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var providerId: Int? {
        didSet { if providerId != oldValue { serviceId = nil } }
    }
    var serviceId: Int?
    var number = ""
    var issuedOn = Date.now
    var hasDueDate = false
    var dueOn = Date.now
    var currency = "USD" {
        didSet { if currency != oldValue { fxRate = "" } }
    }
    var fxRate = ""
    var tax = "0"
    var notes = ""
    var lines = [Line()]

    private(set) var pdf: Data?
    private(set) var isPreparingPDF = false
    private(set) var isSaving = false
    private(set) var baseCurrency: String?
    /// Set once `createOriginal` succeeds. Saving again never creates a second original.
    private(set) var created: OriginalFull?
    /// Set when everything is done.
    private(set) var finished: OriginalFull?
    /// The original exists but its PDF did not reach the server.
    private(set) var uploadError: String?
    var errorMessage: String?

    #if DEBUG
    private var failedUploadForTest = false
    #endif

    init(pdf: Data? = nil) { self.pdf = pdf }

    var isReady: Bool { baseCurrency != nil }
    var usesRate: Bool { baseCurrency != nil && currency != baseCurrency }
    var hasEntries: Bool { pdf != nil || providerId != nil || !number.isEmpty }

    func prepare(_ options: OriginalFormOptions) {
        guard baseCurrency == nil else { return }
        baseCurrency = options.baseCurrency
        currency = options.baseCurrency
    }

    /// Fills in the last rate used for this currency, keeping anything already typed.
    func prefillRate(api: APIClient) async {
        guard usesRate, fxRate.isEmpty else { return }
        let code = currency
        guard let rate = try? await api.lastFxRate(currency: code), currency == code, fxRate.isEmpty else { return }
        fxRate = Money.fxRateInput(rate)
    }

    func attach(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pdf = try CapturedPDF.read(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attach(scan pages: [UIImage]) async {
        isPreparingPDF = true
        defer { isPreparingPDF = false }
        do {
            pdf = try await Task.detached { try ScannedPDF.make(from: pages) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePDF() { pdf = nil }

    /// Saving is two calls. If the upload fails, calling this again retries only the upload.
    func save(api: APIClient) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let original: OriginalFull
        if let created {
            original = created
        } else {
            do {
                original = try await api.createOriginal(try makeInput())
                created = original
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        guard let pdf else {
            finished = original
            return
        }
        do {
            try failUploadForUITest()
            finished = try await api.attachPDF(originalId: original.id, pdf: pdf, filename: "original-invoice.pdf")
            uploadError = nil
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// The owner chose to keep the saved original and go without its PDF.
    func leaveWithoutPDF() { finished = created }

    func makeInput(locale: Locale = .current) throws -> OriginalInvoiceInput {
        guard let providerId else { throw InputError("Choose a provider.") }
        var rate = Money.fxScale
        if usesRate {
            guard let typed = Money.parseFxRate(Self.plain(fxRate, locale)), typed > 0 else {
                throw InputError("Enter the exchange rate for \(currency).")
            }
            rate = typed
        }
        guard let taxAmount = Money.parseAmount(Self.plain(tax, locale)), taxAmount >= 0 else {
            throw InputError("Enter a valid tax amount.")
        }
        guard !lines.isEmpty else { throw InputError("Add at least one line.") }
        let inputs = try lines.enumerated().map { index, line in
            guard let quantity = Money.parseAmount(Self.plain(line.quantity, locale)), quantity > 0 else {
                throw InputError("Line \(index + 1): enter a valid quantity.")
            }
            guard let unitPrice = Money.parseAmount(Self.plain(line.unitPrice, locale)) else {
                throw InputError("Line \(index + 1): enter a valid unit price.")
            }
            return OriginalInvoiceInput.Line(description: line.description, quantity: quantity, unitPrice: unitPrice)
        }
        return OriginalInvoiceInput(
            providerId: providerId,
            serviceId: serviceId,
            number: number,
            issuedOn: ISODay.string(from: issuedOn),
            dueOn: hasDueDate ? ISODay.string(from: dueOn) : nil,
            currency: currency,
            fxRate: rate,
            tax: taxAmount,
            notes: notes,
            lines: inputs
        )
    }

    /// The decimal pad types the region's separator. `Money` drops commas as thousands
    /// separators, so without this "1,5" on a comma region would become 15.
    private static func plain(_ text: String, _ locale: Locale) -> String {
        guard let separator = locale.decimalSeparator, separator != "." else { return text }
        return text.replacingOccurrences(of: separator, with: ".")
    }

    private func failUploadForUITest() throws {
        #if DEBUG
        // The only way a UI test can reach the upload retry. This is not in Release builds.
        if UserDefaults.standard.bool(forKey: "failFirstPDFUpload"), !failedUploadForTest {
            failedUploadForTest = true
            throw APIError.offline
        }
        #endif
    }
}
