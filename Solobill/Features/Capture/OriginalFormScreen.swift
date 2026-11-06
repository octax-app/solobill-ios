import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Adds an original invoice. It has its own navigation stack, so present it as a sheet. Details
/// are entered by hand, and totals come from the server after saving.
struct OriginalFormScreen: View {
    private let onSaved: (OriginalFull) -> Void
    private let onCancel: () -> Void

    @State private var model: OriginalFormModel
    @State private var confirmingCancel = false
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// `pdf` is a PDF that is already captured, or nil to let the owner scan or pick one.
    init(
        pdf: Data? = nil,
        onSaved: @escaping (OriginalFull) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.init(model: OriginalFormModel(pdf: pdf), onSaved: onSaved, onCancel: onCancel)
    }

    /// Reopens a form the app kept while it was locked.
    init(
        model: OriginalFormModel,
        onSaved: @escaping (OriginalFull) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add original invoice")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .interactiveDismissDisabled()
                .alert(
                    "Could not save",
                    isPresented: Binding(
                        get: { model.errorMessage != nil },
                        set: { if !$0 { model.errorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
        // A sheet sits above the cover in `RootView`, so it keeps figures out of the app switcher
        // snapshot itself.
        .overlay {
            if scenePhase != .active {
                Color(.systemBackground).ignoresSafeArea().accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let original = model.created, let error = model.uploadError {
            UploadRetryView(
                original: original,
                error: error,
                isSaving: model.isSaving,
                retry: { save() },
                leave: {
                    model.leaveWithoutPDF()
                    finish()
                }
            )
        } else {
            let api = self.api
            let model = self.model
            Loadable {
                let options = try await OriginalFormOptions.load(api)
                await model.prepare(options)
                return options
            } content: { options, _ in
                OriginalFormFields(model: model, options: options)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.uploadError == nil {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if model.hasEntries { confirmingCancel = true } else { cancel() }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier("capture.cancel")
                .confirmationDialog(
                    "Discard this invoice?",
                    isPresented: $confirmingCancel,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) { cancel() }
                        .accessibilityIdentifier("capture.discard")
                } message: {
                    Text("Nothing has been saved. A shared PDF is removed from the app.")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(!model.isReady || model.providerId == nil || model.isPreparingPDF)
                        .accessibilityIdentifier("capture.save")
                }
            }
        }
    }

    private func save() {
        Task {
            await model.save(api: api)
            if model.finished != nil { finish() }
        }
    }

    private func finish() {
        if let original = model.finished { onSaved(original) }
        dismiss()
    }

    private func cancel() {
        onCancel()
        dismiss()
    }
}

/// The original is on the server, so only the upload can be retried from here.
private struct UploadRetryView: View {
    let original: OriginalFull
    let error: String
    let isSaving: Bool
    let retry: () -> Void
    let leave: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("PDF not uploaded", systemImage: "exclamationmark.icloud")
        } description: {
            VStack(spacing: 8) {
                Text("The original invoice is saved, for \(Money.format(original.total, original.currency)), but its PDF did not upload.")
                Text(error).accessibilityIdentifier("capture.uploadError")
            }
        } actions: {
            Button("Retry upload", action: retry)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .accessibilityIdentifier("capture.retryUpload")
            Button("Leave without PDF", action: leave)
                .disabled(isSaving)
                .accessibilityIdentifier("capture.leaveWithoutPDF")
            if isSaving { ProgressView() }
        }
    }
}

private struct OriginalFormFields: View {
    @Bindable var model: OriginalFormModel
    let options: OriginalFormOptions

    @State private var scanning = false
    @State private var picking = false
    @Environment(\.api) private var api

    private var providerServices: [Service] {
        options.services.filter { $0.providerId == model.providerId }
    }

    var body: some View {
        Form {
            pdfSection
            detailsSection
            linesSection
            Section {
                TextField("Tax amount", text: $model.tax)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("capture.tax")
            } header: {
                Text("Tax amount")
            } footer: {
                Text("Totals are calculated by the server when you save.")
            }
            Section("Notes") {
                TextField("Notes", text: $model.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("capture.notes")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.isSaving)
        .task(id: model.currency) { await model.prefillRate(api: api) }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner(
                onScan: { pages in
                    scanning = false
                    Task { await model.attach(scan: pages) }
                },
                onFailure: { error in
                    scanning = false
                    model.errorMessage = error.localizedDescription
                },
                onCancel: { scanning = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): model.attach(file: url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    private var pdfSection: some View {
        Section("PDF") {
            if let pdf = model.pdf {
                let data = pdf
                NavigationLink {
                    PDFScreen(title: "Invoice PDF", filename: "original-invoice") { data }
                } label: {
                    LabeledContent("PDF attached", value: Self.describe(data))
                }
                .accessibilityIdentifier("capture.pdfAttached")
                Button("Remove PDF", role: .destructive) { model.removePDF() }
                    .accessibilityIdentifier("capture.removePDF")
            }
            if model.isPreparingPDF {
                LabeledContent("Preparing the scan") { ProgressView() }
            }
            Button("Scan paper invoice", systemImage: "doc.viewfinder") { scanning = true }
                .disabled(!VNDocumentCameraViewController.isSupported)
                .accessibilityIdentifier("capture.scan")
            Button("Choose PDF file", systemImage: "folder") { picking = true }
                .accessibilityIdentifier("capture.pick")
        }
    }

    private var detailsSection: some View {
        Section {
            Picker("Provider", selection: $model.providerId) {
                Text("Choose").tag(Int?.none)
                ForEach(options.providers) { provider in
                    Text(provider.name).tag(Int?.some(provider.id))
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("capture.provider")

            Picker("Invoice type", selection: $model.serviceId) {
                Text("No type").tag(Int?.none)
                ForEach(providerServices) { service in
                    Text(service.name).tag(Int?.some(service.id))
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(model.providerId == nil)
            .accessibilityIdentifier("capture.service")

            TextField("Invoice number", text: $model.number)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("capture.number")

            Picker("Currency", selection: $model.currency) {
                ForEach(Money.currencyCodes, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("capture.currency")

            if model.usesRate, let base = model.baseCurrency {
                LabeledContent("Rate: 1 \(model.currency) in \(base)") {
                    TextField("Rate", text: $model.fxRate)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("capture.rate")
                }
            }

            DatePicker("Invoice date", selection: $model.issuedOn, displayedComponents: .date)
                .accessibilityIdentifier("capture.issuedOn")
            Toggle("Has a due date", isOn: $model.hasDueDate)
                .accessibilityIdentifier("capture.hasDueDate")
            if model.hasDueDate {
                DatePicker("Due date", selection: $model.dueOn, displayedComponents: .date)
                    .accessibilityIdentifier("capture.dueOn")
            }
        }
    }

    private var linesSection: some View {
        Section("Lines") {
            ForEach($model.lines) { $line in
                let index = model.lines.firstIndex { $0.id == line.id } ?? 0
                VStack(spacing: 8) {
                    TextField("Description", text: $line.description, axis: .vertical)
                        .accessibilityIdentifier("capture.line\(index).description")
                    HStack {
                        TextField("Quantity", text: $line.quantity)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("capture.line\(index).quantity")
                        TextField("Unit price", text: $line.unitPrice)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("capture.line\(index).unitPrice")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .deleteDisabled(model.lines.count == 1)
            }
            .onDelete { model.lines.remove(atOffsets: $0) }

            Button("Add line", systemImage: "plus") { model.lines.append(.init()) }
                .accessibilityIdentifier("capture.addLine")
        }
    }

    private static func describe(_ data: Data) -> String {
        let pages = PDFDocument(data: data)?.pageCount ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        return "\(pages) \(pages == 1 ? "page" : "pages"), \(size)"
    }
}
