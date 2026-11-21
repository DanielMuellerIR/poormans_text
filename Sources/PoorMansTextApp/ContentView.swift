import PoorMansTextCore
import PoorMansTextAppSupport
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("CLIInstallDeclined") private var cliInstallDeclined = false
    @AppStorage("PandocInstallDeclined") private var pandocInstallDeclined = false
    @State private var activeSheet: Sheet?
    @State private var previewPresentationID: UUID?
    @State private var activeOffer: InstallOffer?
    @State private var activeAlert: InstallAlert?
    @State private var isDropTargeted = false
    @State private var collectionQuery = ""

    private enum PreviewMode {
        case preview
        case comparison
    }

    private enum Sheet: Identifiable {
        case preview(PreviewMode, UUID)
        case contentSelection(ContentSelectionTicket)

        var id: UUID {
            switch self {
            case .preview(_, let id): id
            case .contentSelection(let ticket): ticket.id
            }
        }
    }

    private enum InstallOffer {
        case pandoc(PandocInstaller.Offer)
        case commandLine

        var title: LocalizedStringKey {
            switch self {
            case .pandoc(.manualGuidance): "Pandoc Required"
            case .pandoc(.homebrewInstall): "Install Pandoc?"
            case .commandLine: "Install Command-Line Tool?"
            }
        }
    }

    private enum InstallAlert {
        case pandocInstalled
        case pandocFailed(String)
        case commandLineFailed(String)

        var title: LocalizedStringKey {
            switch self {
            case .pandocInstalled: "Pandoc Installed"
            case .pandocFailed: "Pandoc Installation Failed"
            case .commandLineFailed: "Command-Line Installation Failed"
            }
        }
    }

    private var previewAvailable: Bool { model.preview != nil || model.isLoadingPreview }

    private var isShowingInstallOffer: Binding<Bool> {
        Binding(get: { activeOffer != nil }, set: { if !$0 { activeOffer = nil } })
    }

    private var isShowingInstallAlert: Binding<Bool> {
        Binding(get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                ProfileControls(model: model)
                ConversionOptionsView(
                    settings: model.settings,
                    acceptsNewDocuments: model.acceptsNewDocuments,
                    chooseDestinationFolder: model.chooseDestinationFolder
                )
                dropArea
                footer
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.06),
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        )
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview(let mode, let id):
                previewSheet(mode, id: id)
                    .onDisappear { closePreview(id: id) }
            case .contentSelection(let ticket):
                ContentSelectionView(input: ticket.input).environmentObject(model).id(ticket.id)
            }
        }
        .onChange(of: previewAvailable) { available in
            if !available, !previewAvailable, case .preview = activeSheet { activeSheet = nil }
        }
        .task {
            preparePandocOffer()
            // Pro Start erscheint nur ein Angebot. Wenn Pandoc fehlt, hat es Vorrang.
            if activeOffer == nil { prepareCLIInstallationOffer() }
        }
        .confirmationDialog(
            activeOffer?.title ?? "",
            isPresented: isShowingInstallOffer,
            titleVisibility: .visible,
            presenting: activeOffer
        ) { offer in
            switch offer {
            case .pandoc(.homebrewInstall(let brewExecutable)):
                Button("Install with Homebrew") { installPandoc(brewExecutable: brewExecutable) }
            case .pandoc(.manualGuidance):
                Button("Show Install Help") {
                    NSWorkspace.shared.open(PandocInstaller.installationHelpURL)
                }
            case .commandLine:
                Button("Install") { installCLI() }
            }
            Button("Later", role: .cancel) { activeOffer = nil }
            Button("Don't Ask Again") {
                switch offer {
                case .pandoc: pandocInstallDeclined = true
                case .commandLine: cliInstallDeclined = true
                }
                activeOffer = nil
            }
        } message: { offer in
            switch offer {
            case .pandoc(let installation):
                Text(verbatim: pandocOfferMessage(installation))
            case .commandLine:
                Text(
                    "Make poormans-text available in Terminal by linking it to the copy embedded in this app."
                )
            }
        }
        .alert(activeAlert?.title ?? "", isPresented: isShowingInstallAlert, presenting: activeAlert) {
            alert in
            switch alert {
            case .pandocInstalled: Button("OK") { activeAlert = nil }
            case .pandocFailed, .commandLineFailed: Button("OK", role: .cancel) { activeAlert = nil }
            }
        } message: { alert in
            switch alert {
            case .pandocInstalled:
                Text("Pandoc is ready to use.")
            case .pandocFailed(let message), .commandLineFailed(let message):
                Text(message)
            }
        }
    }

    private func pandocOfferMessage(_ installation: PandocInstaller.Offer) -> String {
        let formats = String(
            localized:
                "Pandoc is required for word-processing documents, HTML, e-books, text markups, ODM master documents, ENEX, and the HTML parts of email. Spreadsheets, CSV, PDF, and images work without it."
        )
        let guidance: String
        switch installation {
        case .homebrewInstall:
            guidance = String(localized: "Installing with Homebrew can take a few minutes.")
        case .manualGuidance:
            guidance = String(localized: "The Pandoc website offers an official installer.")
        }
        return formats + "\n\n" + guidance
    }

    private func previewSheet(_ mode: PreviewMode, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(mode == .comparison ? "Compare source and result" : "Preview").font(.headline)
                if let result = model.selectedResult {
                    Text(verbatim: result.inputURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let preview = model.preview, let result = model.selectedOutput {
                switch mode {
                case .preview: MarkdownPreviewPane(preview: preview, result: result)
                case .comparison: ConversionComparisonPane(preview: preview, result: result)
                }
            } else {
                ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismissPreview(id: id)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(
            minWidth: 760, idealWidth: mode == .comparison ? 1080 : 800,
            minHeight: 560, idealHeight: mode == .comparison ? 760 : 560
        )
    }

    private func presentPreview(_ mode: PreviewMode) {
        model.loadPreview()
        guard previewAvailable else { return }
        let id = UUID()
        previewPresentationID = id
        activeSheet = .preview(mode, id)
    }

    private func closePreview(id: UUID) {
        // Das Ende einer älteren Sheet-Animation darf eine neue Vorschau nicht schließen.
        guard previewPresentationID == id else { return }
        previewPresentationID = nil
        model.closePreview()
    }

    private func dismissPreview(id: UUID) {
        guard activeSheet?.id == id else { return }
        activeSheet = nil
        closePreview(id: id)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(ProductInfo.name)
                    .font(.title.bold())
                Text("Convert files to Markdown")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var dropArea: some View {
        VStack(spacing: 18) {
            stateContent
            // Dateien aus Dock oder Doppelklick, die wegen laufender Arbeit
            // nicht angenommen wurden: sichtbar in jedem Zustand, nicht nur
            // bei einem Ergebnis.
            if let message = model.openRejectionMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if model.isConverting {
                if let progress = model.conversionProgress {
                    if let completed = progress.completed, let total = progress.total,
                        let unit = progress.unit
                    {
                        ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        Text(
                            String(
                                format: NSLocalizedString("%@ %d of %d", comment: ""),
                                NSLocalizedString(unit.rawValue, comment: ""), min(completed + 1, total),
                                total))
                    } else {
                        Text(LocalizedStringKey(progress.phase.rawValue))
                    }
                }
                Button(model.cancellationRequested ? "Cancelling…" : "Cancel Conversion") {
                    model.cancelConversion()
                }
                .disabled(model.cancellationRequested)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 7])
                )
        )
        .animation(.easeInOut(duration: 0.16), value: isDropTargeted)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted
        ) { providers in
            model.acceptDrop(providers)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle:
            // Während der Pandoc-Installation nimmt das Modell keine Dokumente
            // an. Das muss man sehen, sonst wirkt die Drop-Zone nur kaputt.
            if model.isInstallingPandoc {
                ProgressView()
                    .controlSize(.large)
                Text("Installing Pandoc…")
                    .font(.title3.bold())
                Text("Files are accepted again once the installation has finished.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 390)
                // Derselbe Weg wie beim Abbruch einer Umwandlung: Der Knopf
                // fordert den Abbruch an und sperrt sich, bis Homebrew weg ist.
                Button(model.isCancellingPandocInstallation ? "Cancelling…" : "Cancel Installation") {
                    model.cancelPandocInstallation()
                }
                .disabled(model.isCancellingPandocInstallation)
            } else {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 45, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Drop documents, spreadsheets, PDFs, images, or a folder here")
                    .font(.title3.bold())
                Text(
                    "A new folder with Markdown and assets is created at the selected destination. A dropped folder is searched for supported documents."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 390)
                HStack(spacing: 12) {
                    Button("Choose Document…") { model.chooseDocument() }
                        .keyboardShortcut(.defaultAction)
                    Button("Select Content…") {
                        guard model.acceptsNewDocuments, let input = AppModel.chooseSelectionDocument() else {
                            return
                        }
                        activeSheet = .contentSelection(ContentSelectionTicket(input: input))
                    }
                    .accessibilityLabel("Select Content…").accessibilityIdentifier("selectionChoose")
                }.controlSize(.large)
                HStack(spacing: 12) {
                    Button("Extract Receipt Data…") { chooseReceiptPDF(openWindow: openWindow) }
                    Button("Apply Mask…") { openWindow(id: "receipt-batch") }
                }
                pasteControls
            }

        case .converting(let inputURL):
            ProgressView()
                .controlSize(.large)
            Text("Converting \(inputURL.lastPathComponent)…")
                .font(.title3.bold())
                .lineLimit(2)
            Text("The source document is left unchanged.")
                .foregroundStyle(.secondary)

        case .succeeded(let result):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(
                LocalizedStringKey(
                    model.clipboardDraft == nil
                        ? "Markdown created"
                        : model.clipboardDraft?.source.isImage == true
                            ? "Image ready to preview" : "Rich text ready to preview")
            )
            .font(.title3.bold())
            Text(
                model.clipboardDraft == nil
                    ? result.outputDirectory.lastPathComponent
                    : NSLocalizedString("Temporary result — choose how to keep it", comment: "")
            )
            .font(.body.monospaced())
            .lineLimit(2)
            .textSelection(.enabled)
            Text(assetSummary(result))
                .foregroundStyle(.secondary)
            let warningMessages = result.warnings
            if !warningMessages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(warningMessages.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            if model.clipboardDraft != nil {
                Button("Preview") { presentPreview(.preview) }
                    .accessibilityIdentifier("clipboardPreview")
                HStack(spacing: 12) {
                    Button("Save Markdown and Assets…") { model.chooseClipboardDestination() }
                        .keyboardShortcut(.defaultAction)
                    Button(
                        LocalizedStringKey(
                            model.clipboardDraft?.source.isImage == true
                                ? "Copy Recognized Text" : "Copy Markdown Only")
                    ) { model.copyMarkdown() }
                }.controlSize(.large)
                Text(
                    LocalizedStringKey(
                        model.clipboardDraft?.source.isImage == true
                            ? "Copying keeps recognized text only and omits the image."
                            : "Copying keeps text only. Image links need a saved result with its assets.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                Button("Discard") { model.reset() }.keyboardShortcut(.cancelAction)
                if let message = model.actionMessage { Text(message).font(.callout).textSelection(.enabled) }
            } else {
                resultActions
                HStack {
                    Button("Show in Finder") { model.revealResult() }
                        .keyboardShortcut(.defaultAction)
                    Button("Convert Another") { model.reset() }
                }.controlSize(.large)
            }

        case .convertingBatch(let progress):
            ProgressView(
                value: Double(progress.completed),
                total: Double(max(progress.total, 1))
            )
            .frame(maxWidth: 320)
            Text(
                String(
                    format: NSLocalizedString("Completed %d of %d documents", comment: ""),
                    progress.completed, progress.total))
            ForEach(model.runningJobs) { job in
                HStack {
                    Text(job.input.lastPathComponent).lineLimit(1)
                    if let value = job.progress, let unit = value.unit, let completed = value.completed,
                        let total = value.total
                    {
                        Text(
                            String(
                                format: NSLocalizedString("%@ %d of %d", comment: ""),
                                NSLocalizedString(unit.rawValue, comment: ""), min(completed + 1, total),
                                total))
                    } else if let value = job.progress {
                        Text(LocalizedStringKey(value.phase.rawValue))
                    }
                }
                .font(.caption)
            }
            Text(progress.current.lastPathComponent)
                .font(.title3.bold())
                .lineLimit(2)
            Text("The source documents are left unchanged.")
                .foregroundStyle(.secondary)
            if !progress.finished.isEmpty {
                batchList(progress.finished)
            }

        case .batchFinished(let items):
            let succeeded = items.filter { $0.result != nil }.count
            Image(
                systemName: succeeded == items.count
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 48))
            .foregroundStyle(succeeded == items.count ? .green : .orange)
            .accessibilityHidden(true)
            Text(batchSummary(succeeded: succeeded, total: items.count))
                .font(.title3.bold())
            batchList(items)
            if !model.failedInputs.isEmpty {
                Button("Retry Failed Inputs") { model.retryFailed() }
            }
            resultActions
            HStack {
                Button("Show in Finder") {
                    model.revealResult()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedResult == nil)
                Button("Convert More") {
                    model.reset()
                }
            }
            .controlSize(.large)

        case .copiedToClipboard(let outcome):
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Markdown copied to the clipboard")
                .font(.title3.bold())
            Text(clipboardSummary(outcome))
                .foregroundStyle(.secondary)
            if !outcome.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(outcome.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            Button("Done") {
                model.reset()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            pasteControls

        case .failed(let input, let message):
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 46))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            if let input {
                HStack {
                    Button("Retry") { model.retryFailed() }
                    Button("Choose Another Name or Destination…") {
                        model.chooseAlternativeDestination(for: input)
                    }
                }
            }
            Text("Conversion failed")
                .font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
            HStack {
                Button("Choose Document…") {
                    model.chooseDocument()
                }
                .keyboardShortcut(.defaultAction)
                // Solange Pandoc installiert wird, nimmt das Modell nichts an.
                .disabled(model.isInstallingPandoc)
                Button("Back") {
                    model.reset()
                }
            }
            .controlSize(.large)
            pasteControls
        }
    }

    private var pasteControls: some View {
        VStack(spacing: 6) {
            Button("Paste Text or Image") { model.pasteRichText() }
                .help("Imports text, rich text, or an image from the clipboard for conversion.")
                .disabled(!model.acceptsNewDocuments)
                .accessibilityIdentifier("clipboardPaste")
            Text("⌘V · Rich text, images and screenshots")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.actionMessage, model.clipboardDraft == nil {
                Text(message).font(.callout).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var resultActions: some View {
        if let result = model.selectedResult {
            if result.isCollection { collectionSelection(result).id(result.outputDirectory) }
            ViewThatFits(in: .horizontal) {
                HStack {
                    openResultButtons
                    inspectResultButtons
                }
                VStack(spacing: 8) {
                    HStack { openResultButtons }
                    HStack { inspectResultButtons }
                }
            }
        }
        if let message = model.actionMessage {
            Text(message).font(.callout).textSelection(.enabled)
        }
    }

    private func collectionSelection(_ result: ConversionResult) -> some View {
        let documents = result.documents.filter {
            collectionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(collectionQuery)
                || String($0.sourceIndex) == collectionQuery
        }
        let countText =
            result.format == .enex && result.documents.count == 1
            ? NSLocalizedString("1 note", comment: "")
            : String(
                format: NSLocalizedString(
                    result.format == .mbox
                        ? "%d messages" : result.format == .enex ? "%d notes" : "%d documents", comment: ""),
                result.documents.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(countText).font(.headline)
                Spacer()
                Button("Overview") { model.selectCollectionDocument(nil) }
                    .accessibilityIdentifier("collectionOverview")
            }
            TextField(
                LocalizedStringKey(
                    result.format == .mbox
                        ? "Find a message" : result.format == .enex ? "Find a note" : "Find a document"),
                text: $collectionQuery
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("collectionSearch")
            .help("Press Return to select the first match.")
            .onSubmit {
                if !collectionQuery.isEmpty, let document = documents.first {
                    model.selectCollectionDocument(document.sourceIndex)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(documents, id: \.sourceIndex) { document in
                        Button {
                            model.selectCollectionDocument(document.sourceIndex)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(document.sourceIndex).").monospacedDigit().foregroundStyle(.secondary)
                                Text(verbatim: document.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if model.selectedDocumentIndex == document.sourceIndex {
                                    Image(systemName: "checkmark")
                                }
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                                Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            model.selectedDocumentIndex == document.sourceIndex
                                ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("collectionDocument-\(document.sourceIndex)")
                    }
                    if documents.isEmpty { Text("No matching documents.").foregroundStyle(.secondary) }
                }
            }.frame(height: 110)
            Text(
                model.selectedDocument.map { "\($0.sourceIndex). \($0.title)" }
                    ?? NSLocalizedString("Overview", comment: "")
            )
            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            .accessibilityIdentifier("collectionSelected")
        }
        .frame(maxWidth: 520)
        .onAppear { collectionQuery = "" }
    }

    @ViewBuilder private var openResultButtons: some View {
        Button("Open Markdown") { model.openResult() }
        Button("Open in Fastra") { model.openResultInFastra() }
    }
    @ViewBuilder private var inspectResultButtons: some View {
        Button("Copy Markdown") { model.copyMarkdown() }
            .help("Copies the entire selected Markdown file to the clipboard.")
        Button("Preview") { presentPreview(.preview) }
        if !model.isClipboardResult, model.selectedResult?.isCollection != true {
            Button("Compare") { presentPreview(.comparison) }
                .help("Opens the selected Markdown output beside its source.")
        }
        if model.selectedResult?.reportFile != nil { Button("Open Report") { model.openReport() } }
    }

    private var footer: some View {
        HStack {
            Text("Version \(ProductInfo.version)")
            Spacer()
            if model.isInstallingPandoc {
                ProgressView()
                    .controlSize(.small)
                Text("Installing Pandoc…")
            } else {
                Text("Pandoc for text documents, mail, and ENEX")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    /// Eine Zeile je Eingabe: Häkchen mit Ergebnisordner oder Kreuz mit
    /// Fehlertext. Die Liste bleibt scrollbar, damit ein großer Ordner das
    /// Fenster nicht sprengt.
    private func batchList(_ items: [BatchItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch item.outcome {
                        case .succeeded(let result):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Converted")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.input.lastPathComponent)
                                    .lineLimit(1)
                                Text(result.outputDirectory.lastPathComponent + " · " + assetSummary(result))
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        case .failed(let message):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Failed")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.input.lastPathComponent)
                                    .lineLimit(1)
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(5)
                    .background(
                        model.selectedInput == item.id ? Color.accentColor.opacity(0.15) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectResult(item) }
                    .accessibilityAction { model.selectResult(item) }
                    if item.result == nil && !model.isConverting {
                        Button("Choose Another Name or Destination…") {
                            model.chooseAlternativeDestination(for: item.input)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 170)
    }

    private func clipboardSummary(_ outcome: ClipboardOutcome) -> String {
        let lines = outcome.markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .count
        return lines == 1
            ? NSLocalizedString("1 line, ready to paste", comment: "")
            : String(format: NSLocalizedString("%d lines, ready to paste", comment: ""), lines)
    }

    private func batchSummary(succeeded: Int, total: Int) -> String {
        if succeeded == total {
            return total == 1
                ? NSLocalizedString("Markdown created", comment: "")
                : String(format: NSLocalizedString("%d documents converted", comment: ""), total)
        }
        return String(
            format: NSLocalizedString("%d of %d documents converted", comment: ""), succeeded, total)
    }

    private func assetSummary(_ result: ConversionResult) -> String {
        switch result.assets.count {
        case 0:
            NSLocalizedString("No asset files", comment: "")
        case 1:
            NSLocalizedString("1 asset file", comment: "")
        default:
            String(format: NSLocalizedString("%d asset files", comment: ""), result.assets.count)
        }
    }

    private func preparePandocOffer() {
        let offer = PandocInstaller.offer(
            pandocIsAvailable: ExternalToolResolver().isAvailable(.pandoc),
            installDeclined: pandocInstallDeclined,
            brewExecutable: PandocInstaller.resolveHomebrew()
        )
        activeOffer = offer.map(InstallOffer.pandoc)
    }

    private func installPandoc(brewExecutable: URL) {
        activeOffer = nil

        // Der Installationszustand gehört ins Modell: nur dort können Drop-Zone,
        // Dateiauswahl und `onOpenURL` gemeinsam gesperrt werden.
        Task {
            do {
                // Nur der Aufruf, der die Installation wirklich ausgeführt hat,
                // darf Erfolg melden. Ein paralleler zweiter Aufruf läuft in die
                // Sperre des Modells und kehrt ohne Ergebnis zurück.
                if try await model.installPandoc(brewExecutable: brewExecutable) {
                    activeAlert = .pandocInstalled
                }
            } catch {
                activeAlert = .pandocFailed(AppErrorMessage.describe(error))
            }
        }
    }

    private func prepareCLIInstallationOffer() {
        guard !cliInstallDeclined,
            Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
                == "/Applications"
        else {
            return
        }

        let sourceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/poormans-text")
        let statuses = CLIInstaller.standardTargetURLs.map {
            CLIInstaller.status(sourceURL: sourceURL, targetURL: $0)
        }
        if statuses.contains(.installed) || statuses.contains(.conflict) {
            return
        }

        guard
            CLIInstaller.status(
                sourceURL: sourceURL,
                targetURL: CLIInstaller.defaultTargetURL
            ) == .available
        else {
            return
        }
        activeOffer = .commandLine
    }

    private func installCLI() {
        activeOffer = nil
        let sourceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/poormans-text")
        let targetURL = CLIInstaller.defaultTargetURL

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CLIInstaller.install(sourceURL: sourceURL, targetURL: targetURL)
                }.value
            } catch {
                activeAlert = .commandLineFailed(AppErrorMessage.describe(error))
            }
        }
    }
}
