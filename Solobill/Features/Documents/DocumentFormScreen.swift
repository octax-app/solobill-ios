import SwiftUI

/// The invoice and proforma editor: form, then review, then issue.
struct DocumentEditorSheet: View {
    enum Mode: Sendable {
        case new(DocumentType, customerID: Int? = nil)
        case edit(DocumentType, id: Int)

        var type: DocumentType {
            switch self {
            case .new(let type, _), .edit(let type, _): type
            }
        }

        var title: String {
            switch self {
            case .new(let type, _): "New \(type.word)"
            case .edit(let type, _): "Edit \(type.word)"
            }
        }
    }

    let mode: Mode
    let onIssued: (InvoiceFull) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    private struct Loaded: Sendable {
        let catalog: DocumentCatalog
        let draft: InvoiceFull?
    }

    var body: some View {
        let api = api
        let mode = mode
        NavigationStack {
            Loadable {
                try await Self.load(mode, from: api)
            } content: { loaded, _ in
                DocumentFormScreen(catalog: loaded.catalog, mode: mode, draft: loaded.draft, onIssued: onIssued)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("\(mode.type.rawValue).cancel")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private static func load(_ mode: Mode, from api: APIClient) async throws -> Loaded {
        switch mode {
        case .new(_, let customerID):
            return Loaded(catalog: try await DocumentCatalog.load(from: api, keeping: customerID), draft: nil)
        case .edit(_, let id):
            let draft = try await api.invoice(id: id)
            let catalog = try await DocumentCatalog.load(from: api, keeping: draft.customerId)
            return Loaded(catalog: catalog, draft: draft)
        }
    }
}

private struct DocumentFormScreen: View {
    let catalog: DocumentCatalog
    let onIssued: (InvoiceFull) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var form: DocumentForm
    /// Set once saved. Saving again updates this draft, so going back never creates a second one.
    @State private var draftID: Int?
    @State private var reviewID: Int?
    @State private var isSaving = false
    @State private var message: String?
    @State private var resolvedKey: TemplateKey?
    /// The rate last filled in from a template, to tell it apart from one the owner typed.
    @State private var templateTaxRate = ""
    @State private var subscriptions: [Subscription] = []

    private struct TemplateKey: Equatable {
        let serviceID: Int?
        let providerID: Int?
    }

    init(
        catalog: DocumentCatalog,
        mode: DocumentEditorSheet.Mode,
        draft: InvoiceFull?,
        onIssued: @escaping (InvoiceFull) -> Void
    ) {
        self.catalog = catalog
        self.onIssued = onIssued
        if let draft {
            _form = State(initialValue: DocumentForm(draft: draft))
            _draftID = State(initialValue: draft.id)
            // A saved draft keeps its template until the owner changes the provider or type.
            _resolvedKey = State(initialValue: TemplateKey(serviceID: draft.serviceId, providerID: draft.providerId))
            _templateTaxRate = State(initialValue: Money.percentText(draft.taxRate))
        } else if case .new(let type, let customerID) = mode {
            let customer = catalog.customers.first { $0.id == customerID }
            _form = State(initialValue: DocumentForm(type: type, customer: customer))
        } else {
            _form = State(initialValue: DocumentForm(type: mode.type))
        }
    }

    private var idPrefix: String { form.type.rawValue }
    private var word: String { form.type.word }

    private var availableServices: [Service] {
        catalog.services.filter { form.providerID == nil || $0.providerId == form.providerID }
    }

    private var offeredSubscriptions: [Subscription] {
        subscriptions.filter { subscription in
            subscription.status == .active && !form.lines.contains { $0.subscriptionId == subscription.id }
        }
    }

    private var customFields: [CustomField] {
        catalog.templates.first { $0.id == form.templateID }?.orderedFields ?? []
    }

    private var templateKey: TemplateKey {
        TemplateKey(serviceID: form.serviceID, providerID: form.providerID)
    }

    var body: some View {
        Form {
            partiesSection
            if !form.currency.isEmpty, form.currency != catalog.baseCurrency {
                rateSection
            }
            if !customFields.isEmpty {
                customItemsSection
            }
            ForEach($form.lines) { $line in
                DocumentLineSection(
                    line: $line,
                    idPrefix: idPrefix,
                    position: form.lines.firstIndex { $0.id == line.id } ?? 0,
                    formCurrency: form.currency,
                    baseCurrency: catalog.baseCurrency,
                    onRemove: { remove(line.id) }
                )
            }
            addLineSection
            detailsSection
            taxSection
            saveSection
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: form.customerID) { chooseCustomer() }
        .onChange(of: form.providerID) { chooseProvider() }
        .task(id: form.currency) { await prefillFormRate() }
        .task(id: templateKey) { await applyTemplate() }
        .task(id: form.customerID) { await loadSubscriptions() }
        .navigationDestination(item: $reviewID) { id in
            DocumentReviewScreen(invoiceID: id, onIssued: onIssued, onKeepDraft: { dismiss() })
        }
    }

    private var partiesSection: some View {
        Section {
            Picker("Provider", selection: $form.providerID) {
                Text("No provider").tag(Int?.none)
                ForEach(catalog.providers) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("\(idPrefix).provider")
            Picker("Customer", selection: $form.customerID) {
                Text("Choose a customer").tag(Int?.none)
                ForEach(catalog.customers) { customer in
                    Text(customer.status == .lead ? "\(customer.displayName) (lead)" : customer.displayName)
                        .tag(Int?.some(customer.id))
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("\(idPrefix).customer")
            Picker("Invoice type", selection: $form.serviceID) {
                Text("No type").tag(Int?.none)
                ForEach(availableServices) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("\(idPrefix).service")
            Picker("Template", selection: $form.templateID) {
                Text("Automatic").tag(Int?.none)
                ForEach(catalog.templates) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("\(idPrefix).template")
            if !form.currency.isEmpty {
                Picker("Currency", selection: Binding(get: { form.currency }, set: { chooseCurrency($0) })) {
                    ForEach(Money.currencyCodes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("\(idPrefix).currency")
            }
        } footer: {
            Text("The provider is internal. It picks the template and narrows the services.")
        }
    }

    private var rateSection: some View {
        Section {
            LabeledContent("1 \(form.currency) in \(catalog.baseCurrency)") {
                TextField("Type the rate", text: $form.fxRate)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("\(idPrefix).fxRate")
            }
        } footer: {
            if form.fxRate.isEmpty {
                Text("There is no rate for \(form.currency) yet. Type the rate.")
            } else {
                Text("This rate is locked on the \(word).")
            }
        }
    }

    private var customItemsSection: some View {
        Section("Custom items") {
            ForEach(customFields) { field in
                CustomItemField(
                    field: field,
                    value: Binding(
                        get: { form.customValues[field.id] ?? "" },
                        set: { form.customValues[field.id] = $0 }
                    ),
                    identifier: "\(idPrefix).custom.\(field.id)"
                )
            }
        }
    }

    private var addLineSection: some View {
        Section {
            NavigationLink("Add service") {
                ServiceLinePicker(services: availableServices, onPick: add)
            }
            .disabled(form.customerID == nil || availableServices.isEmpty)
            .accessibilityIdentifier("\(idPrefix).addService")
            NavigationLink("Add subscription") {
                SubscriptionLinePicker(subscriptions: offeredSubscriptions, onPick: add)
            }
            .disabled(form.customerID == nil || offeredSubscriptions.isEmpty)
            .accessibilityIdentifier("\(idPrefix).addSubscription")
            Button("Add line") {
                form.lines.append(DocumentLine(costCurrency: catalog.baseCurrency))
            }
            .disabled(form.customerID == nil)
            .accessibilityIdentifier("\(idPrefix).addLine")
        } footer: {
            if form.customerID == nil {
                Text("Choose a customer first, as lines use their currency.")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Number", text: $form.number)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(idPrefix).number")
            Toggle("Issue date", isOn: $form.hasIssueDate)
                .accessibilityIdentifier("\(idPrefix).hasIssueDate")
            if form.hasIssueDate {
                DatePicker("Date", selection: $form.issueDate, displayedComponents: .date)
                    .accessibilityIdentifier("\(idPrefix).issueDate")
            }
            if form.type == .invoice {
                Toggle("Due date", isOn: $form.hasDueOn)
                    .accessibilityIdentifier("\(idPrefix).hasDueOn")
                if form.hasDueOn {
                    DatePicker("Date", selection: $form.dueOn, displayedComponents: .date)
                        .accessibilityIdentifier("\(idPrefix).dueOn")
                }
            } else {
                Toggle("Valid until", isOn: $form.hasValidUntil)
                    .accessibilityIdentifier("\(idPrefix).hasValidUntil")
                if form.hasValidUntil {
                    DatePicker("Date", selection: $form.validUntil, displayedComponents: .date)
                        .accessibilityIdentifier("\(idPrefix).validUntil")
                }
            }
            TextField("Notes", text: $form.notes, axis: .vertical)
                .accessibilityIdentifier("\(idPrefix).notes")
        } footer: {
            Text("Leave the number empty to number it automatically, and the issue date off to use the day it is issued. Notes are printed on the document.")
        }
    }

    private var taxSection: some View {
        Section {
            Toggle("Add tax", isOn: $form.taxEnabled)
                .accessibilityIdentifier("\(idPrefix).taxEnabled")
            if form.taxEnabled {
                LabeledContent("Tax rate (%)") {
                    TextField("0", text: $form.taxRate)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("\(idPrefix).taxRate")
                }
            }
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save and review")
                }
            }
            .disabled(isSaving)
            .accessibilityIdentifier("\(idPrefix).save")
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(idPrefix).error")
            }
        } footer: {
            Text("The server calculates the totals, and you can check them before issuing.")
        }
    }

    private func chooseCustomer() {
        chooseCurrency(catalog.customers.first { $0.id == form.customerID }?.currency ?? "")
    }

    private func chooseCurrency(_ currency: String) {
        guard currency != form.currency else { return }
        form.currency = currency
        form.fxRate = ""
        for index in form.lines.indices {
            form.lines[index].applyDefaultPrice(formCurrency: currency)
        }
    }

    /// An invoice type from another provider no longer applies.
    private func chooseProvider() {
        let current = catalog.services.first { $0.id == form.serviceID }
        if let providerID = form.providerID, let current, current.providerId != providerID {
            form.serviceID = nil
        }
    }

    private func add(_ service: Service) {
        form.lines.append(DocumentLine(service: service, formCurrency: form.currency))
        if form.serviceID == nil { form.serviceID = service.id }
    }

    private func add(_ subscription: Subscription) {
        form.lines.append(contentsOf: subscription.billingLines.map { line in
            DocumentLine(subscription: subscription, line: line, formCurrency: form.currency)
        })
    }

    private func remove(_ id: DocumentLine.ID) {
        form.lines.removeAll { $0.id == id }
    }

    private func prefillFormRate() async {
        let currency = form.currency
        guard !currency.isEmpty, currency != catalog.baseCurrency, form.fxRate.isEmpty else { return }
        guard let rate = try? await api.lastFxRate(currency: currency) else { return }
        if form.currency == currency, form.fxRate.isEmpty {
            form.fxRate = Money.fxRateInput(rate)
        }
    }

    /// Follows the provider and invoice type, the same way the server resolves the template on
    /// save. A tax rate the owner typed is kept.
    private func applyTemplate() async {
        let key = templateKey
        guard key != resolvedKey else { return }
        do {
            let id = try await api.resolveTemplate(serviceId: key.serviceID, providerId: key.providerID)
            resolvedKey = key
            form.templateID = id
            guard form.taxRate == templateTaxRate,
                  let template = catalog.templates.first(where: { $0.id == id }) else { return }
            templateTaxRate = Money.percentText(template.defaultTaxRate)
            form.taxRate = templateTaxRate
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadSubscriptions() async {
        guard let customerID = form.customerID else {
            subscriptions = []
            return
        }
        do {
            let loaded = try await api.subscriptions(customerId: customerID)
            if form.customerID == customerID { subscriptions = loaded }
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() async {
        message = nil
        do {
            let input = try form.input(baseCurrency: catalog.baseCurrency)
            isSaving = true
            defer { isSaving = false }
            if let draftID {
                _ = try await api.updateDraft(id: draftID, input)
            } else {
                draftID = try await api.createDraft(input).id
            }
            reviewID = draftID
        } catch {
            message = error.localizedDescription
        }
    }
}

/// One item from the template. Its value is text, and a date is kept as a "YYYY-MM-DD" day.
private struct CustomItemField: View {
    let field: CustomField
    @Binding var value: String
    let identifier: String

    private var label: String { field.required ? "\(field.label) (required)" : field.label }

    private var hasDate: Binding<Bool> {
        Binding(
            get: { !value.isEmpty },
            set: { value = $0 ? ISODay.today : "" }
        )
    }

    private var date: Binding<Date> {
        Binding(
            get: { ISODay.date(from: value) ?? .now },
            set: { value = ISODay.string(from: $0) }
        )
    }

    var body: some View {
        switch field.type {
        case .date:
            Toggle(label, isOn: hasDate)
                .accessibilityIdentifier(identifier)
            if !value.isEmpty {
                DatePicker("Date", selection: date, displayedComponents: .date)
                    .accessibilityIdentifier("\(identifier).date")
            }
        case .number:
            TextField(label, text: $value)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier(identifier)
        case .text:
            TextField(label, text: $value)
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct ServiceLinePicker: View {
    let services: [Service]
    let onPick: (Service) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(services) { service in
            Button {
                onPick(service)
                dismiss()
            } label: {
                LabeledContent(service.name, value: Money.format(service.defaultPrice, service.currency))
            }
            .tint(.primary)
        }
        .navigationTitle("Add service")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SubscriptionLinePicker: View {
    let subscriptions: [Subscription]
    let onPick: (Subscription) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(subscriptions) { subscription in
            Button {
                onPick(subscription)
                dismiss()
            } label: {
                LabeledContent(
                    subscription.label.isEmpty ? subscription.serviceName : "\(subscription.serviceName), \(subscription.label)",
                    value: Money.format(subscription.priceAmount, subscription.priceCurrency)
                )
            }
            .tint(.primary)
        }
        .navigationTitle("Add subscription")
        .navigationBarTitleDisplayMode(.inline)
    }
}
