import Foundation

/// What the invoice and proforma form needs from the server before it can show anything.
struct DocumentCatalog: Sendable {
    let baseCurrency: String
    let customers: [Customer]
    let providers: [Provider]
    let services: [Service]
    let templates: [Template]

    /// Archived customers are left out, except `customerID`, which a draft may already use.
    static func load(from api: APIClient, keeping customerID: Int? = nil) async throws -> DocumentCatalog {
        async let settings = api.settings()
        async let customers = api.customers()
        async let providers = api.providers()
        async let services = api.services()
        async let templates = api.templates()
        return try await DocumentCatalog(
            baseCurrency: settings.baseCurrency,
            customers: customers.filter { $0.status != .archived || $0.id == customerID },
            providers: providers,
            services: services,
            templates: templates
        )
    }
}

/// One editable line. Numbers stay as typed text until `DocumentForm.input` parses them.
struct DocumentLine: Identifiable {
    /// A price from the catalog. It is in its own currency, and this line is in the form's.
    struct DefaultPrice {
        let amount: Int
        let currency: String
        let name: String
    }

    let id = UUID()
    var subscriptionId: Int?
    var subscriptionLineId: Int?
    var periodStart: String?
    var originalInvoiceLineId: Int?
    var amountConfirmed = true
    var description = ""
    var quantity = "1"
    var unitPrice = ""
    var costAmount = "0"
    var costCurrency: String
    var costFxRate = ""
    var defaultPrice: DefaultPrice?
    /// The price this line was prefilled with, to tell it apart from one the owner typed.
    var prefilledPrice = ""

    init(costCurrency: String) {
        self.costCurrency = costCurrency
    }

    init(service: Service, formCurrency: String) {
        description = service.name
        costAmount = Money.amountInput(service.defaultCost)
        costCurrency = service.currency
        if service.defaultPrice > 0 {
            defaultPrice = DefaultPrice(amount: service.defaultPrice, currency: service.currency, name: "default price")
        }
        applyDefaultPrice(formCurrency: formCurrency)
    }

    init(subscription: Subscription, line: SubscriptionLine, formCurrency: String) {
        subscriptionId = subscription.id
        subscriptionLineId = line.id
        // A subscription line may have no description, but an invoice line must.
        description = line.description.isEmpty ? subscription.serviceName : line.description
        costAmount = Money.amountInput(line.costAmount)
        costCurrency = subscription.costCurrency
        defaultPrice = DefaultPrice(
            amount: line.priceAmount,
            currency: subscription.priceCurrency,
            name: "subscription price"
        )
        applyDefaultPrice(formCurrency: formCurrency)
    }

    /// A saved line. The references the form never shows go back to the server unchanged.
    init(saved line: InvoiceLine) {
        subscriptionId = line.subscriptionId
        subscriptionLineId = line.subscriptionLineId
        periodStart = line.periodStart
        originalInvoiceLineId = line.originalInvoiceLineId
        amountConfirmed = line.amountConfirmed
        description = line.description
        quantity = Money.amountInput(line.quantity)
        unitPrice = Money.amountInput(line.unitPrice)
        costAmount = Money.amountInput(line.costAmount)
        costCurrency = line.costCurrency
        costFxRate = line.costFxRate > 0 ? Money.fxRateInput(line.costFxRate) : ""
    }

    /// The app cannot convert a price, so it only prefills when the two currencies match.
    mutating func applyDefaultPrice(formCurrency: String) {
        guard let defaultPrice, unitPrice == prefilledPrice else { return }
        prefilledPrice = defaultPrice.currency == formCurrency ? Money.amountInput(defaultPrice.amount) : ""
        unitPrice = prefilledPrice
    }

    func priceHint(formCurrency: String) -> String? {
        guard let defaultPrice, defaultPrice.currency != formCurrency else { return nil }
        let price = Money.format(defaultPrice.amount, defaultPrice.currency)
        return "The \(defaultPrice.name) is \(price). Enter the price in \(formCurrency)."
    }
}

struct DocumentFormError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// The form's values. It holds no totals: those come back from the server after saving.
struct DocumentForm {
    let type: DocumentType
    var providerID: Int?
    var customerID: Int?
    /// Shown as the invoice type. With the provider, it picks the template.
    var serviceID: Int?
    /// Nil until the server has resolved it, and the server then picks the same one on save.
    var templateID: Int?
    var currency = ""
    var fxRate = ""
    var number = ""
    var hasIssueDate = false
    var issueDate = Date.now
    var hasDueOn = false
    var dueOn = Self.defaultDay
    var hasValidUntil = false
    var validUntil = Self.defaultDay
    var taxEnabled = false
    var taxRate = ""
    var notes = ""
    var customValues: [String: String] = [:]
    var lines: [DocumentLine] = []

    private static var defaultDay: Date {
        Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    }

    init(type: DocumentType, customer: Customer? = nil) {
        self.type = type
        customerID = customer?.id
        currency = customer?.currency ?? ""
    }

    init(draft: InvoiceFull) {
        type = draft.type
        providerID = draft.providerId
        customerID = draft.customerId
        serviceID = draft.serviceId
        templateID = draft.templateId
        currency = draft.currency
        fxRate = draft.fxRate > 0 ? Money.fxRateInput(draft.fxRate) : ""
        number = draft.number ?? ""
        hasIssueDate = draft.issueDate != nil
        issueDate = draft.issueDate.flatMap(ISODay.date) ?? .now
        hasDueOn = draft.dueOn != nil
        dueOn = draft.dueOn.flatMap(ISODay.date) ?? Self.defaultDay
        hasValidUntil = draft.validUntil != nil
        validUntil = draft.validUntil.flatMap(ISODay.date) ?? Self.defaultDay
        taxEnabled = draft.taxEnabled
        taxRate = Money.percentText(draft.taxRate)
        notes = draft.notes
        customValues = draft.customValues ?? [:]
        lines = draft.lines.map(DocumentLine.init(saved:))
    }

    func input(baseCurrency: String) throws -> InvoiceInput {
        guard let customerID else { throw DocumentFormError("Choose a customer") }
        guard !lines.isEmpty else { throw DocumentFormError("Add at least one line") }
        let parsedLines = try lines.enumerated().map { index, line in
            try parse(line, position: index + 1, baseCurrency: baseCurrency)
        }
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        return InvoiceInput(
            type: type,
            number: number.isEmpty ? nil : number,
            customerId: customerID,
            providerId: providerID,
            serviceId: serviceID,
            templateId: templateID,
            dueOn: type == .invoice && hasDueOn ? ISODay.string(from: dueOn) : nil,
            validUntil: type == .proforma && hasValidUntil ? ISODay.string(from: validUntil) : nil,
            currency: currency,
            fxRate: try rate(fxRate, currency: currency, baseCurrency: baseCurrency),
            taxEnabled: taxEnabled,
            taxRate: try parsedTaxRate(),
            notes: notes,
            customValues: customValues,
            issueDate: ClearableDay(day: hasIssueDate ? ISODay.string(from: issueDate) : nil),
            lines: parsedLines
        )
    }

    private func parsedTaxRate() throws -> Int {
        guard let value = Money.parsePercent(taxRate) else {
            if !taxEnabled { return 0 }
            throw DocumentFormError("Enter the tax rate")
        }
        return value
    }

    private func rate(_ text: String, currency: String, baseCurrency: String) throws -> Int {
        if currency == baseCurrency { return Money.fxScale }
        guard let value = Money.parseFxRate(text), value > 0 else {
            throw DocumentFormError("Enter the exchange rate for \(currency)")
        }
        return value
    }

    private func parse(_ line: DocumentLine, position: Int, baseCurrency: String) throws -> InvoiceInput.Line {
        let prefix = "Line \(position):"
        guard !line.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentFormError("\(prefix) enter a description")
        }
        guard let quantity = Money.parseAmount(line.quantity), quantity > 0 else {
            throw DocumentFormError("\(prefix) enter a quantity")
        }
        guard let unitPrice = Money.parseAmount(line.unitPrice), unitPrice >= 0 else {
            throw DocumentFormError("\(prefix) enter a unit price")
        }
        guard let costAmount = Money.parseAmount(line.costAmount), costAmount >= 0 else {
            throw DocumentFormError("\(prefix) enter your cost")
        }
        return InvoiceInput.Line(
            subscriptionId: line.subscriptionId,
            subscriptionLineId: line.subscriptionLineId,
            periodStart: line.periodStart,
            description: line.description,
            quantity: quantity,
            unitPrice: unitPrice,
            costAmount: costAmount,
            costCurrency: line.costCurrency,
            costFxRate: try rate(line.costFxRate, currency: line.costCurrency, baseCurrency: baseCurrency),
            originalInvoiceLineId: line.originalInvoiceLineId,
            amountConfirmed: line.amountConfirmed
        )
    }
}
