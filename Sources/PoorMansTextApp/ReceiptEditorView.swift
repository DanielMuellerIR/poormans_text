import AppKit
import PDFKit
import PoorMansTextCore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiptEditorInput: Codable, Hashable {
    let pdf: URL
    var mask: URL?
    var initialMask: ReceiptMask?
}

@MainActor
enum ReceiptFilePanels {
    static func open(_ type: UTType, title: String, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(title, comment: "")
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveJSON(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString(title, comment: "")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct ReceiptEditorView: View {
    let input: ReceiptEditorInput

    @State private var testPDFs: [URL] = []
    @State private var currentIndex = 0
    @State private var didLoadInitialMask = false
    @State private var document: ReceiptDocument?
    @State private var pdf: PDFDocument?
    @State private var prepared: ReceiptExtractor.Prepared?
    @State private var sourceIdentity: ConversionSourceIdentity?
    @State private var evaluationTask: Task<Void, Never>?
    @State private var evaluationError: String?
    @State private var isLoading = true
    @State private var mask = ReceiptMask()
    @State private var maskURL: URL?
    @State private var rawResult: ReceiptResult?
    @State private var result: ReceiptResult?
    @State private var availableSuggestions: [ReceiptField] = []
    @State private var suggestedValues: [ReceiptValue] = []
    @State private var corrections: [URL: SourceCorrections] = [:]
    @State private var rejectedRules: Set<ReceiptRule> = []
    @State private var selectedRegion: ReceiptPDFRegion?
    @State private var markedRegion: ReceiptPDFMark?
    @State private var zoom: ReceiptPDFZoom?
    @State private var error: String?
    @State private var loadError: String?
    @State private var sheet: EditorSheet?

    private struct SourceCorrections {
        let identity: ConversionSourceIdentity
        var values: [UUID: String] = [:]
    }

    private struct Correction {
        let field: UUID
        let source: URL
        let identity: ConversionSourceIdentity
        let name: String
        var value: String
    }

    private enum EditorSheet: Identifiable {
        case json(String)
        case correction(Correction)

        var id: String {
            switch self {
            case .json: "json"
            case .correction: "correction"
            }
        }
    }

    private var pdfs: [URL] { [input.pdf] + testPDFs }
    private var currentPDF: URL { pdfs[currentIndex] }

    private var suggestions: [ReceiptField] {
        let names = Set(mask.fields.map(\.name))
        let rules = Set(mask.fields.map(\.rule)).union(rejectedRules)
        return availableSuggestions.filter { !names.contains($0.name) && !rules.contains($0.rule) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: currentPDF.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(currentPDF.path)
                    Spacer(minLength: 4)
                    if pdf != nil {
                        Button { zoom = ReceiptPDFZoom(action: .outwards) } label: {
                            Image(systemName: "minus.magnifyingglass").accessibilityLabel("Zoom Out")
                        }
                        Button("Fit") { zoom = ReceiptPDFZoom(action: .fit) }
                            .help("Fits the PDF page in the preview.")
                        Button { zoom = ReceiptPDFZoom(action: .inwards) } label: {
                            Image(systemName: "plus.magnifyingglass").accessibilityLabel("Zoom In")
                        }
                    }
                }
                documentNavigation
                if let pdf, let document {
                    ReceiptPDFView(pdf: pdf, text: document, markedRegion: markedRegion, selectedRegion: selectedRegion, zoom: zoom) {
                        selectedRegion = $0
                    }
                    Text("Click a word or drag a rectangle to select a region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let loadError {
                    Text(verbatim: loadError)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView("Reading PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(minWidth: 360, idealWidth: 560)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        maskControls
                        if let selectedRegion { regionControls(selectedRegion) }
                        if !suggestions.isEmpty { suggestionControls }
                        fieldControls
                        if let evaluationError {
                            Text(verbatim: evaluationError).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Button("Preview JSON") { showPreview() }.disabled(result == nil)
                        .help("Shows values and review statuses for the current receipt before saving. Missing or ambiguous values appear as null.")
                    Spacer()
                    Button("Export JSON…") { exportResult() }.disabled(mask.fields.isEmpty || result == nil)
                        .help("Saves current values and review statuses, including corrections for this receipt, as JSON.")
                }
                .padding(16)
            }
            .frame(minWidth: 390, idealWidth: 470)
        }
        .frame(minWidth: 750, minHeight: 530)
        .task(id: currentPDF) { await loadDocument(currentPDF) }
        .onDisappear { evaluationTask?.cancel() }
        .alert("Receipt Data", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(verbatim: error ?? "")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .json(text):
                VStack(alignment: .leading, spacing: 14) {
                    Text("Preview JSON").font(.headline)
                    ScrollView {
                        Text(verbatim: text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(idealHeight: 400, maxHeight: 540)
                    HStack {
                        Spacer()
                        Button("Done") { self.sheet = nil }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(20)
                .frame(minWidth: 580, minHeight: 420)
            case let .correction(draft):
                ReceiptCorrectionView(name: draft.name, value: draft.value) { value in
                    if currentPDF == draft.source, sourceIdentity == draft.identity {
                        corrections[draft.source, default: SourceCorrections(identity: draft.identity)].values[draft.field] = value
                        refreshResult()
                    }
                    self.sheet = nil
                } cancel: {
                    self.sheet = nil
                }
            }
        }
    }

    private var documentNavigation: some View {
        HStack(spacing: 8) {
            Button("Add Test PDFs…", action: addTestPDFs)
                .help("Adds more receipts from the same business partner to test the same rules.")
            Spacer(minLength: 4)
            if pdfs.count > 1 {
                Button { showPDF(at: currentIndex - 1) } label: {
                    Image(systemName: "chevron.left").accessibilityLabel("Previous PDF")
                }
                .disabled(currentIndex == 0)
                .help("Tests the same mask against the previous PDF in the list.")
                Text(String(format: NSLocalizedString("PDF %lld of %lld", comment: ""),
                            Int64(currentIndex + 1), Int64(pdfs.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { showPDF(at: currentIndex + 1) } label: {
                    Image(systemName: "chevron.right").accessibilityLabel("Next PDF")
                }
                .disabled(currentIndex == pdfs.count - 1)
                .help("Tests the same mask against the next PDF in the list.")
            }
        }
    }

    private func addTestPDFs() {
        let urls = ReceiptFilePanels.open(.pdf, title: "Choose Test PDFs", multiple: true)
        var seen = Set(pdfs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let newPDFs = urls.map(\.standardizedFileURL).filter { seen.insert($0.resolvingSymlinksInPath()).inserted }
        guard !newPDFs.isEmpty else { return }
        let firstNewIndex = pdfs.count
        testPDFs.append(contentsOf: newPDFs)
        showPDF(at: firstNewIndex)
    }

    private func showPDF(at index: Int) {
        guard pdfs.indices.contains(index), currentIndex != index else { return }
        clearDocument()
        currentIndex = index
    }

    private var maskControls: some View {
        GroupBox("Extraction Mask") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Partner") {
                    TextField("Partner", text: Binding(get: { mask.partner }, set: { mask.partner = $0; refreshResult() }))
                        .labelsHidden()
                        .help("Name of the business partner whose receipts use this mask.")
                }
                LabeledContent("Document Type") {
                    TextField("Document Type", text: Binding(get: { mask.documentType }, set: { mask.documentType = $0; refreshResult() }))
                        .labelsHidden()
                        .help("Category of receipts covered by this mask, such as invoice or delivery note.")
                }
                if let maskURL {
                    Text(verbatim: maskURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Load Mask…") {
                        if let url = ReceiptFilePanels.open(.json, title: "Choose Extraction Mask").first { loadMask(url) }
                    }
                    .help("Opens a saved JSON mask and tests its rules against the current PDF.")
                    Button("Reload Mask") {
                        if let maskURL { loadMask(maskURL) }
                    }
                    .disabled(maskURL == nil)
                    .help("Reads the mask file again and discards unsaved mask changes.")
                    Spacer()
                    Button("Save Mask…") { saveMask() }.disabled(mask.fields.isEmpty)
                        .help("Saves the rules as a reusable JSON mask.")
                }
            }
            .padding(.top, 5)
        }
    }

    private func regionControls(_ region: ReceiptPDFRegion) -> some View {
        GroupBox("Selected Region") {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: NSLocalizedString("Page %lld", comment: ""), Int64(region.page)))
                    .foregroundStyle(.secondary)
                if case let .region(_, rectangle) = rule(for: region) {
                    Text(String(format: NSLocalizedString("x %.1f, y %.1f · %.1f × %.1f mm", comment: ""),
                                locale: Locale.current, rectangle.x, rectangle.y, rectangle.width, rectangle.height))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
                HStack {
                    Button("New Region Field") {
                        guard mask.fields.count < ReceiptMask.maximumFields, let rule = rule(for: region) else { return }
                        let existing = Set(mask.fields.map(\.name))
                        let format = NSLocalizedString("Field %lld", comment: "")
                        let name = (1...(existing.count + 1)).lazy
                            .map { String(format: format, Int64($0)) }
                            .first { !existing.contains($0) } ?? format
                        mask.fields.append(ReceiptField(name: name, rule: rule))
                        finishRegion()
                    }
                    .disabled(mask.fields.count >= ReceiptMask.maximumFields)
                    .help("Creates a field that reads text at the same position on this page.")
                    Menu("Replace Field Rule") {
                        ForEach(mask.fields) { field in
                            Button(field.name) {
                                guard let rule = rule(for: region),
                                      let index = mask.fields.firstIndex(where: { $0.id == field.id }) else { return }
                                mask.fields[index].rule = rule
                                discardCorrections(for: field.id)
                                finishRegion()
                            }
                        }
                    }
                    .disabled(mask.fields.isEmpty)
                    .help("Replaces the selected field’s extraction rule with the marked PDF region.")
                    Spacer()
                    Button("Clear") { selectedRegion = nil }
                }
            }
            .padding(.top, 5)
        }
    }

    private var suggestionControls: some View {
        GroupBox("Suggested Fields") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions) { field in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: field.name)
                            if let value = suggestedValues.first(where: { $0.id == field.id }) {
                                if let source = value.sources.first, let text = value.value {
                                    Button(text) { mark([source]) }.buttonStyle(.link)
                                } else {
                                    Text(statusDescription(value.status))
                                }
                            }
                        }
                        Spacer()
                        Button("Accept") { accept([field]) }
                            .disabled(mask.fields.count >= ReceiptMask.maximumFields)
                            .help("Adds the suggested extraction rule to the mask.")
                        Button("Reject") { reject([field]) }
                            .help("Dismisses the suggested extraction rule in this editor.")
                    }
                    .controlSize(.small)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Reject All") { reject(suggestions) }
                    Button("Accept All") { accept(suggestions) }
                        .disabled(mask.fields.count >= ReceiptMask.maximumFields)
                }
            }
            .padding(.top, 5)
        }
    }

    private var fieldControls: some View {
        GroupBox("Fields and Current Results") {
            VStack(alignment: .leading, spacing: 12) {
                if mask.fields.isEmpty {
                    Text("Accept a suggestion or select a PDF region to add a field.").foregroundStyle(.secondary)
                }
                ForEach(mask.fields) { field in
                    fieldRow(field)
                    if field.id != mask.fields.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        }
    }

    private func fieldRow(_ field: ReceiptField) -> some View {
        let value = result?.fields.first { $0.id == field.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Field Name", text: Binding(get: {
                    mask.fields.first { $0.id == field.id }?.name ?? field.name
                }, set: { name in
                    guard let index = mask.fields.firstIndex(where: { $0.id == field.id }) else { return }
                    mask.fields[index].name = name
                    refreshResult()
                }))
                .accessibilityLabel("Field Name")
                .help("Names this result field in the mask and the JSON output.")
                Button(role: .destructive) {
                    mask.fields.removeAll { $0.id == field.id }
                    discardCorrections(for: field.id)
                    evaluate()
                } label: {
                    Image(systemName: "trash").accessibilityLabel("Remove Field")
                }
                .help("Remove Field")
            }
            Text(ruleDescription(field.rule)).font(.caption).foregroundStyle(.secondary)
            if let value {
                Text(verbatim: value.value ?? "—")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        if value.status != .ambiguous { mark(value.sources) }
                    }
                HStack {
                    Text(statusDescription(value.status)).font(.caption).foregroundStyle(.secondary)
                    if !value.sources.isEmpty, value.status != .ambiguous {
                        Button {
                            mark(value.sources)
                        } label: {
                            Label("Show Source", systemImage: "scope")
                        }
                        .buttonStyle(.link)
                    }
                    if value.sources.count > 1, value.status == .ambiguous {
                        Menu("Show Source") {
                            ForEach(Array(value.sources.enumerated()), id: \.offset) { _, source in
                                Button("\(source.page + 1) · \(source.text)") { mark([source]) }
                            }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    Button("Correct Value…") {
                        guard let sourceIdentity else { return }
                        sheet = .correction(Correction(field: value.id, source: currentPDF, identity: sourceIdentity,
                                                       name: value.name, value: value.value ?? ""))
                    }
                    .help("Changes the value for this receipt only. The mask’s rule stays the same.")
                }
                if let diagnostic = value.diagnostic {
                    Text(verbatim: diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func ruleDescription(_ rule: ReceiptRule) -> String {
        switch rule {
        case .region(let page, _):
            String(format: NSLocalizedString("Region on page %lld", comment: ""), Int64(page + 1))
        case .rightOf(let label, let kind):
            String(format: NSLocalizedString("Search to the right of “%@” (%@)", comment: ""), label,
                   NSLocalizedString(kind == .date ? "Date" : "Identifier", comment: ""))
        }
    }

    private func statusDescription(_ status: ReceiptValueStatus) -> String {
        switch status {
        case .confirmed: NSLocalizedString("Confirmed", comment: "")
        case .corrected: NSLocalizedString("Corrected", comment: "")
        case .missing: NSLocalizedString("Missing", comment: "")
        case .ambiguous: NSLocalizedString("Ambiguous", comment: "")
        }
    }

    private func clearDocument() {
        isLoading = true
        loadError = nil
        evaluationTask?.cancel()
        evaluationError = nil
        document = nil
        pdf = nil
        prepared = nil
        sourceIdentity = nil
        availableSuggestions = []
        suggestedValues = []
        rawResult = nil
        result = nil
        markedRegion = nil
        selectedRegion = nil
        zoom = nil
    }

    private func loadDocument(_ url: URL) async {
        if !didLoadInitialMask {
            didLoadInitialMask = true
            if let initialMask = input.initialMask {
                mask = initialMask
                maskURL = input.mask
            } else if let maskURL = input.mask {
                loadMask(maskURL)
            }
        }
        do {
            let loaded = try await Self.runWorker { try Self.readPDF(url) }
            guard !Task.isCancelled, currentPDF == url else { return }
            if corrections[url]?.identity != loaded.identity { corrections.removeValue(forKey: url) }
            sourceIdentity = loaded.identity
            document = loaded.document
            pdf = loaded.pdf
            prepared = loaded.prepared
            availableSuggestions = loaded.suggestions
            suggestedValues = loaded.suggestedValues
            evaluate()
        } catch {
            guard !Task.isCancelled, currentPDF == url else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // PDFKit bleibt bis zur Übergabe beim Worker und wird danach nur im Editor verwendet.
    private struct LoadedPDF: @unchecked Sendable {
        let pdf: PDFDocument
        let identity: ConversionSourceIdentity
        let document: ReceiptDocument
        let prepared: ReceiptExtractor.Prepared
        let suggestions: [ReceiptField]
        let suggestedValues: [ReceiptValue]
    }

    private nonisolated static func readPDF(_ url: URL) throws -> LoadedPDF {
        let (pdf, identity) = try ReceiptPDF.openWithIdentity(at: url)
        let document = try ReceiptPDF.read(pdf)
        let prepared = try ReceiptExtractor.Prepared(document)
        let suggestions = try prepared.suggestions()
        let suggestedValues = try? prepared.evaluate(ReceiptMask(fields: suggestions)).fields
        try Task.checkCancellation()
        return LoadedPDF(pdf: pdf, identity: identity, document: document, prepared: prepared,
                         suggestions: suggestions, suggestedValues: suggestedValues ?? [])
    }

    private nonisolated static func runWorker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func rule(for region: ReceiptPDFRegion) -> ReceiptRule? {
        guard let document, document.pages.indices.contains(region.page - 1) else { return nil }
        let scale = document.pages[region.page - 1].pointsPerMillimeter
        let bounds = region.bounds
        let rectangle = ReceiptRectangle(x: bounds.minX / scale, y: bounds.minY / scale,
                                         width: bounds.width / scale, height: bounds.height / scale)
        return .region(page: region.page - 1, rectangle: rectangle)
    }

    private func mark(_ sources: [ReceiptEvidence]) {
        guard let document else { return }
        let regions = sources.compactMap { source -> ReceiptPDFRegion? in
            guard document.pages.indices.contains(source.page) else { return nil }
            let scale = document.pages[source.page].pointsPerMillimeter
            let bounds = source.rectangle.cgRect.applying(CGAffineTransform(scaleX: scale, y: scale))
            return ReceiptPDFRegion(page: source.page + 1, bounds: bounds)
        }
        markedRegion = ReceiptPDFMark(regions: regions)
    }

    private func finishRegion() {
        selectedRegion = nil
        evaluate()
    }

    private func accept(_ fields: [ReceiptField]) {
        let visible = Set(suggestions.map(\.id))
        var names = Set(mask.fields.map(\.name))
        var rules = Set(mask.fields.map(\.rule))
        let previousCount = mask.fields.count
        for field in fields where visible.contains(field.id) {
            guard mask.fields.count < ReceiptMask.maximumFields else { break }
            guard !names.contains(field.name), !rules.contains(field.rule) else { continue }
            mask.fields.append(field)
            names.insert(field.name)
            rules.insert(field.rule)
        }
        if mask.fields.count != previousCount { evaluate() }
    }

    private func reject(_ fields: [ReceiptField]) {
        rejectedRules.formUnion(fields.map(\.rule))
    }

    private func discardCorrections(for field: UUID) {
        for source in Array(corrections.keys) {
            corrections[source]?.values.removeValue(forKey: field)
        }
    }

    private func evaluate() {
        evaluationTask?.cancel()
        evaluationError = nil
        rawResult = nil
        result = nil
        guard let prepared else { return }
        let draft = mask
        evaluationTask = Task {
            do {
                let evaluated = try await Self.runWorker { try prepared.evaluate(draft) }
                guard !Task.isCancelled else { return }
                rawResult = evaluated
                refreshResult()
            } catch {
                guard !Task.isCancelled else { return }
                evaluationError = error.localizedDescription
            }
        }
    }

    private func refreshResult() {
        guard var evaluated = rawResult?.withMetadata(from: mask) else { return }
        if let corrected = corrections[currentPDF], corrected.identity == sourceIdentity {
            for (field, value) in corrected.values { evaluated.correct(field: field, value: value) }
        }
        result = evaluated
    }

    private func loadMask(_ url: URL) {
        do {
            mask = try ReceiptMask.load(from: url)
            maskURL = url
            corrections = [:]
            selectedRegion = nil
            markedRegion = nil
            evaluate()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveMask() {
        guard let url = ReceiptFilePanels.saveJSON(title: "Save Extraction Mask", name: "receipt-mask.json") else { return }
        do {
            try mask.save(to: url)
            maskURL = url
        } catch { self.error = error.localizedDescription }
    }

    private func exportResult() {
        let name = ReceiptBatch.destination(for: currentPDF).lastPathComponent
        guard let result, let url = ReceiptFilePanels.saveJSON(title: "Export Receipt Data", name: name) else { return }
        do { try result.write(to: url) }
        catch { self.error = error.localizedDescription }
    }

    private func showPreview() {
        guard let result else { return }
        do {
            sheet = .json(String(decoding: try result.jsonData(), as: UTF8.self))
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReceiptCorrectionView: View {
    let name: String
    @State var value: String
    let apply: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct Current Value").font(.headline)
            Text(verbatim: name)
            Text("This correction applies only to the current result.").foregroundStyle(.secondary)
            TextField("Value", text: $value)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Correction") { apply(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
    }
}
