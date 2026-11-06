import Foundation

// These follow `web/openapi.json`. The contract test keeps that file honest against the server,
// and `DecodingTests` decodes real server responses into these types.

/// A type with a value to use when the server leaves its key out.
protocol MissingDefault: Decodable, Hashable {
    static var missingDefault: Self { get }
}

extension Int: MissingDefault {
    static var missingDefault: Int { 0 }
}

extension Array: MissingDefault where Element: Decodable & Hashable {
    static var missingDefault: [Element] { [] }
}

/// A field the app must survive without, because it can run against a server that has not been
/// updated yet. A missing key decodes to zero or empty rather than failing the whole response.
@propertyWrapper
struct Defaulted<Value: MissingDefault>: Decodable, Hashable {
    var wrappedValue: Value

    init(wrappedValue: Value = .missingDefault) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try Value(from: decoder)
    }
}

extension Defaulted: Sendable where Value: Sendable {}

extension KeyedDecodingContainer {
    func decode<Value>(_ type: Defaulted<Value>.Type, forKey key: Key) throws -> Defaulted<Value> {
        try decodeIfPresent(type, forKey: key) ?? Defaulted()
    }
}

struct ApiToken: Decodable, Sendable {
    let id: Int
    let name: String
    let token: String
}

struct Me: Decodable, Sendable, Equatable {
    let email: String
    let name: String?
    let totpEnabled: Bool
    /// False for a user who only signs in with Google or Apple.
    let hasPassword: Bool
    let workspace: Workspace
    let role: WorkspaceRole
}

struct OkResponse: Decodable, Sendable {
    let ok: Bool
}

struct CurrencyInfo: Decodable, Sendable, Hashable {
    let decimals: Int
    let name: String
}

struct AppSettings: Decodable, Sendable {
    let id: Int
    let baseCurrency: String
    let renewalLeadDays: Int
    let invoicePrefix: String
    let proformaPrefix: String
    let baseCurrencyLocked: Bool
    let currencies: [String: CurrencyInfo]
}

struct ProfitSummary: Decodable, Sendable, Hashable {
    let revenue: Int
    let cost: Int
    let profit: Int
    /// A display percentage, such as 40.5. It is the one non-integer value in the API.
    let margin: Double
}

struct Overview: Decodable, Sendable {
    struct Receivable: Decodable, Sendable, Identifiable, Hashable {
        let id: Int
        let number: String?
        let dueOn: String?
        let issuedOn: String?
        let total: Int
        let baseTotal: Int
        /// Missing on a server that has not been updated, where `amountDue` falls back to the total.
        let due: Int?
        let baseDue: Int?
        let currency: String
        let customerId: Int
        let customerName: String

        var amountDue: Int { due ?? total }
    }

    struct Payable: Decodable, Sendable, Identifiable, Hashable {
        let id: Int
        let number: String
        let dueOn: String?
        let issuedOn: String
        let total: Int
        let baseTotal: Int
        let currency: String
        let providerId: Int
        let providerName: String
        let providerLogo: String?
    }

    struct Renewal: Decodable, Sendable, Identifiable, Hashable {
        let id: Int
        let label: String
        let nextRenewalOn: String?
        let priceAmount: Int
        let priceCurrency: String
        let customerId: Int
        let customerName: String
        let serviceName: String
    }

    struct TrendPoint: Decodable, Sendable, Identifiable, Hashable {
        let month: String
        let revenue: Int
        let cost: Int
        let profit: Int
        var id: String { month }
    }

    let baseCurrency: String
    let from: String
    let to: String
    let today: String
    let summary: ProfitSummary
    let toCollect: [Receivable]
    let toCollectTotal: Int
    let toPay: [Payable]
    let toPayTotal: Int
    let renewals: [Renewal]
    let trend: [TrendPoint]
    let unallocatedCost: Int
    let draftsToReview: Int
}

enum CustomerStatus: String, Codable, Sendable {
    case lead, active, archived
}

struct Customer: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let status: CustomerStatus
    let name: String
    let company: String
    let email: String
    let phone: String
    let address: String
    let taxNumber: String
    let currency: String
    let notes: String

    var displayName: String { company.isEmpty ? name : company }
}

struct CustomerSummary: Decodable, Sendable {
    struct LinkedOriginal: Decodable, Sendable, Identifiable, Hashable {
        let id: Int
        let number: String
        let issuedOn: String
        let total: Int
        let currency: String
        let providerName: String
    }

    let baseCurrency: String
    let summary: ProfitSummary
    let pending: Int
    let linkedOriginals: [LinkedOriginal]
}

enum Cycle: String, Codable, Sendable {
    case monthly, quarterly, yearly, once

    var label: String {
        switch self {
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        case .once: "One time"
        }
    }
}

enum Pricing: String, Codable, Sendable {
    case fixed, metered
}

struct Provider: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let logoFile: String?
    let defaultTemplateId: Int?
}

struct Service: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let providerId: Int
    let name: String
    let pricing: Pricing
    let cycle: Cycle
    let defaultCost: Int
    let defaultPrice: Int
    let currency: String
    let defaultTemplateId: Int?
    let providerName: String
}

enum SubscriptionStatus: String, Codable, Sendable {
    case active, paused, cancelled
}

struct SubscriptionLine: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let subscriptionId: Int
    let position: Int
    let description: String
    let costAmount: Int
    let priceAmount: Int
}

struct Subscription: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let customerId: Int
    let serviceId: Int
    let label: String
    let cycle: Cycle
    let startedOn: String
    let nextRenewalOn: String?
    let costAmount: Int
    let costCurrency: String
    let priceAmount: Int
    let priceCurrency: String
    let status: SubscriptionStatus
    let customerName: String
    let serviceName: String
    let providerName: String
    let pricing: Pricing
    /// Missing on a server that has not been updated. Use `billingLines`.
    let lines: [SubscriptionLine]?

    var billingLines: [SubscriptionLine] { lines ?? [] }
}

/// An item the owner types on each invoice, set on the template.
struct CustomField: Decodable, Sendable, Identifiable, Hashable {
    enum Kind: String, Decodable, Sendable {
        case text, number, date
    }

    let id: String
    let label: String
    let type: Kind
    let required: Bool
    let order: Int
}

struct Template: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let isDefault: Bool
    let defaultTaxRate: Int
    let ready: Bool
    let problems: [String]
    /// Missing on a server that has not been updated. Use `orderedFields`.
    let customFields: [CustomField]?

    var orderedFields: [CustomField] { (customFields ?? []).sorted { $0.order < $1.order } }
}

enum DocumentType: String, Codable, Sendable, Identifiable {
    case invoice, proforma

    var id: Self { self }
    /// The lowercase word used in titles and buttons.
    var word: String { rawValue }
}

enum DocumentStatus: String, Codable, Sendable {
    case draft, issued, paid, converted, void

    var label: String { rawValue.capitalized }
}

enum DocumentSource: String, Codable, Sendable {
    case manual, renewal
}

/// The amounts behind what a customer still owes, ported from `web/src/shared/payments.ts`.
protocol PaymentBalance {
    var status: DocumentStatus { get }
    var total: Int { get }
    var paidAmount: Int { get }
    var discountAmount: Int { get }
}

extension PaymentBalance {
    /// What the customer still owes. Never below zero.
    var due: Int { max(0, total - paidAmount - discountAmount) }

    /// What the customer paid beyond the total. This is profit.
    var overpaid: Int { max(0, paidAmount + discountAmount - total) }

    /// Only a label. There is no partial status, so `status` stays `issued` until settled.
    var isPartiallyPaid: Bool {
        status == .issued && (paidAmount > 0 || discountAmount > 0)
    }

    var displayStatus: String { isPartiallyPaid ? "Partially paid" : status.label }
}

enum PaymentKind: String, Codable, Sendable, Identifiable {
    case payment, discount

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

struct Payment: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let invoiceId: Int
    let kind: PaymentKind
    let amount: Int
    let paidOn: String
    let note: String
    /// Shared by every row of one customer payment, which are removed together.
    let groupId: String?
}

/// The body of `POST /invoices/{id}/payments`.
struct PaymentInput: Encodable, Sendable {
    var kind: PaymentKind
    var amount: Int
    var paidOn: String
    var note: String
}

/// The body of `POST /customers/{id}/payments`. Discounts are not offered here.
struct CustomerPaymentInput: Encodable, Sendable {
    var currency: String
    var amount: Int
    var paidOn: String
    var note: String
}

struct CustomerPaymentResult: Decodable, Sendable, Hashable {
    struct Allocation: Decodable, Sendable, Hashable {
        let invoiceId: Int
        let number: String
        let amount: Int
    }

    let allocations: [Allocation]
    let excess: Int
}

struct InvoiceRow: Decodable, Sendable, Identifiable, Hashable, PaymentBalance {
    let id: Int
    let type: DocumentType
    let status: DocumentStatus
    let source: DocumentSource
    let number: String?
    let customerId: Int
    let providerId: Int?
    let serviceId: Int?
    let issuedOn: String?
    let dueOn: String?
    let validUntil: String?
    let currency: String
    let total: Int
    let baseTotal: Int
    @Defaulted var paidAmount: Int
    @Defaulted var discountAmount: Int
    @Defaulted var revenueAdjustBase: Int
    let paidOn: String?
    let customerName: String
    let customerCompany: String
    let providerName: String?

    var displayCustomer: String { customerCompany.isEmpty ? customerName : customerCompany }
}

struct Invoice: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let type: DocumentType
    let status: DocumentStatus
    let number: String?
    let paidOn: String?
}

struct InvoiceLine: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let invoiceId: Int
    let position: Int
    let subscriptionId: Int?
    let subscriptionLineId: Int?
    let periodStart: String?
    let description: String
    let quantity: Int
    let unitPrice: Int
    let net: Int
    let tax: Int
    let total: Int
    let costAmount: Int
    let costCurrency: String
    let costFxRate: Int
    let costBase: Int
    let originalInvoiceLineId: Int?
    let amountConfirmed: Bool
}

struct InvoiceFull: Decodable, Sendable, Identifiable, Hashable, PaymentBalance {
    let id: Int
    let type: DocumentType
    let status: DocumentStatus
    let source: DocumentSource
    let number: String?
    let customerId: Int
    let providerId: Int?
    let serviceId: Int?
    let templateId: Int
    let issuedOn: String?
    let dueOn: String?
    let validUntil: String?
    let currency: String
    let fxRate: Int
    let taxEnabled: Bool
    let taxRate: Int
    let subtotal: Int
    let tax: Int
    let total: Int
    let baseSubtotal: Int
    let baseTotal: Int
    @Defaulted var paidAmount: Int
    @Defaulted var discountAmount: Int
    @Defaulted var revenueAdjustBase: Int
    let notes: String
    let paidOn: String?
    let convertedFromId: Int?
    /// Custom item id to the text typed on this invoice. Missing on a server not yet updated.
    let customValues: [String: String]?
    /// The date chosen on a draft. Empty means the day it is issued. Missing on an older server.
    let issueDate: String?
    let lines: [InvoiceLine]
    @Defaulted var payments: [Payment]
}

/// A day that encodes as null when empty, for a field where leaving the key out means something
/// else: absent keeps what is stored, and null clears it.
struct ClearableDay: Encodable, Sendable {
    let day: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(day)
    }
}

/// The body of `POST /invoices` and `PUT /invoices/{id}`. Totals are never sent: the server
/// calculates them.
struct InvoiceInput: Encodable, Sendable {
    struct Line: Encodable, Sendable {
        var subscriptionId: Int?
        var subscriptionLineId: Int?
        var periodStart: String?
        var description: String
        var quantity: Int
        var unitPrice: Int
        var costAmount: Int
        var costCurrency: String
        var costFxRate: Int
        var originalInvoiceLineId: Int?
        var amountConfirmed: Bool = true
    }

    var type: DocumentType
    var number: String?
    var customerId: Int
    var providerId: Int?
    var serviceId: Int?
    var templateId: Int?
    var dueOn: String?
    var validUntil: String?
    var currency: String
    var fxRate: Int
    var taxEnabled: Bool
    var taxRate: Int
    var notes: String = ""
    /// Nil is left out of the body, and the server then keeps what is stored.
    var customValues: [String: String]?
    /// Nil is left out of the body, and the server then keeps what is stored.
    var issueDate: ClearableDay?
    var lines: [Line]
}

extension InvoiceInput {
    /// A copy of a saved draft, so one field can change and the rest go back unchanged.
    init(draft: InvoiceFull) {
        self.init(
            type: draft.type,
            number: draft.number,
            customerId: draft.customerId,
            providerId: draft.providerId,
            serviceId: draft.serviceId,
            templateId: draft.templateId,
            dueOn: draft.dueOn,
            validUntil: draft.validUntil,
            currency: draft.currency,
            fxRate: draft.fxRate,
            taxEnabled: draft.taxEnabled,
            taxRate: draft.taxRate,
            notes: draft.notes,
            lines: draft.lines.map { line in
                Line(
                    subscriptionId: line.subscriptionId,
                    subscriptionLineId: line.subscriptionLineId,
                    periodStart: line.periodStart,
                    description: line.description,
                    quantity: line.quantity,
                    unitPrice: line.unitPrice,
                    costAmount: line.costAmount,
                    costCurrency: line.costCurrency,
                    costFxRate: line.costFxRate,
                    originalInvoiceLineId: line.originalInvoiceLineId,
                    amountConfirmed: line.amountConfirmed
                )
            }
        )
    }
}

/// The body of `PATCH /invoices/{id}/lines/{lineId}/cost`.
struct LineCostInput: Encodable, Sendable {
    var costAmount: Int
    var costCurrency: String
    var costFxRate: Int
    /// Sent as null to unlink, so it cannot be left out.
    var originalInvoiceLineId: Int?

    private enum CodingKeys: String, CodingKey {
        case costAmount, costCurrency, costFxRate, originalInvoiceLineId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(costAmount, forKey: .costAmount)
        try container.encode(costCurrency, forKey: .costCurrency)
        try container.encode(costFxRate, forKey: .costFxRate)
        try container.encode(originalInvoiceLineId, forKey: .originalInvoiceLineId)
    }
}

/// An original invoice line that a customer invoice line can be linked to.
struct OriginalLineOption: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let description: String
    let total: Int
    let currency: String
    let number: String
    let issuedOn: String
    let providerName: String

    var label: String { "\(providerName) \(number): \(description)" }
}

struct OriginalRow: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let providerId: Int
    let serviceId: Int?
    let number: String
    let issuedOn: String
    let dueOn: String?
    let currency: String
    let total: Int
    let baseTotal: Int
    let paidOn: String?
    let pdfFile: String?
    let providerName: String
}

struct OriginalLine: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let originalInvoiceId: Int
    let description: String
    let quantity: Int
    let unitPrice: Int
    let total: Int
}

struct OriginalFull: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let providerId: Int
    let serviceId: Int?
    let number: String
    let issuedOn: String
    let dueOn: String?
    let currency: String
    let fxRate: Int
    let subtotal: Int
    let tax: Int
    let total: Int
    let baseSubtotal: Int
    let baseTotal: Int
    let paidOn: String?
    let pdfFile: String?
    let notes: String
    let lines: [OriginalLine]
}

/// The body of `POST /originals`.
struct OriginalInvoiceInput: Encodable, Sendable {
    struct Line: Encodable, Sendable {
        var description: String
        var quantity: Int
        var unitPrice: Int
    }

    var providerId: Int
    var serviceId: Int?
    var number: String = ""
    var issuedOn: String
    var dueOn: String?
    var currency: String
    var fxRate: Int
    var tax: Int = 0
    var notes: String = ""
    var lines: [Line]
}

enum ReminderKind: String, Codable, Sendable {
    case renewalDraft = "renewal_draft"
    case invoiceOverdue = "invoice_overdue"
    case originalDue = "original_due"
}

struct Reminder: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let kind: ReminderKind
    let refId: Int
    let message: String
    let link: String
    let readAt: String?
}
