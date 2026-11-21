import AppKit
import PoorMansTextCore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiptBatchView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var inputs: [URL] = []
    @State private var items: [String: ReceiptBatchItem] = [:]
    @State private var loadedMask: ReceiptMask?
    @State private var maskURL: URL?
    @State private var outputDirectory: URL?
    @State private var cancellation: ConversionCancellationToken?
    @State private var dropTargeted = false
    @State private var pendingDrops = 0
    @State private var wasCancelled = false
    @State private var isCancelling = false
    @State private var completed = 0
    @State private var error: String?

    private var isRunning: Bool { cancellation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Extraction Mask") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            verbatim: maskURL?.lastPathComponent
                                ?? NSLocalizedString("No mask selected", comment: "")
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(maskURL == nil ? .secondary : .primary)
                        if let loadedMask {
                            Text(verbatim: "\(loadedMask.partner) · \(loadedMask.documentType)")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Choose Mask…") { chooseMask() }
                        .help("Selects the saved JSON mask for all PDFs in the list.")
                }
                .padding(.top, 5)
            }
            .disabled(isRunning)

            HStack {
                Text("PDF Documents").font(.headline)
                Spacer()
                Button("Choose Files…") {
                    add(ReceiptFilePanels.open(.pdf, title: "Choose PDF Documents", multiple: true))
                }
                .help("Adds PDF receipts that will use the same mask.")
                .disabled(isRunning)
            }

            VStack(spacing: 0) {
                if inputs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.title2).accessibilityHidden(true)
                        Text("Drop PDF documents here")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(inputs, id: \.path) { input in
                                if input != inputs.first { Divider() }
                                inputRow(input)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    if !isRunning {
                        Label("Drop PDF documents here", systemImage: "arrow.down.doc")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(9)
                    }
                }
            }
            .frame(minHeight: 180)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: dropTargeted ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: acceptDrop)

            GroupBox("JSON Destination") {
                Picker(
                    "JSON Destination",
                    selection: Binding(
                        get: { outputDirectory != nil },
                        set: { custom in
                            if custom {
                                chooseOutputDirectory()
                            } else {
                                outputDirectory = nil
                                resetResults()
                            }
                        })
                ) {
                    Text("Beside Each PDF").tag(false)
                    Text("Chosen Folder").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .help("Saves each JSON beside its PDF or saves all JSON files in one shared folder.")
                if let outputDirectory {
                    HStack {
                        Text(verbatim: outputDirectory.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Change Folder…") { chooseOutputDirectory() }
                    }
                }
            }
            .disabled(isRunning)

            HStack {
                if isRunning || !items.isEmpty || wasCancelled {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: Double(completed), total: Double(max(inputs.count, 1)))
                            .accessibilityLabel("Batch Progress")
                        if wasCancelled {
                            Text("Batch cancelled").foregroundStyle(.secondary)
                        } else {
                            Text(
                                String(
                                    format: NSLocalizedString(
                                        "%lld of %lld documents processed", comment: ""),
                                    Int64(completed), Int64(inputs.count))
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: 240)
                }
                Spacer()
                if isRunning {
                    Button(isCancelling ? "Cancelling…" : "Cancel Batch") {
                        isCancelling = true
                        cancellation?.cancel()
                    }
                    .disabled(isCancelling)
                } else {
                    Button("Apply Mask") { run() }
                        .help(
                            "Applies the mask and writes one JSON file per receipt. Existing files are protected."
                        )
                        .keyboardShortcut(.defaultAction)
                        .disabled(inputs.isEmpty || loadedMask == nil || pendingDrops > 0)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 630, minHeight: 460)
        .onDisappear { cancellation?.cancel() }
        .alert("Apply Mask", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(verbatim: error ?? "")
        }
    }

    private func inputRow(_ input: URL) -> some View {
        let item = items[input.path]
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: input.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(
                    .middle)
                Spacer()
                if let item {
                    statusLabel(item)
                    if let output = item.output {
                        Button("Reveal JSON") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
                        }
                    }
                    if item.status == .reviewRequired {
                        Button("Review…") {
                            openWindow(
                                value: ReceiptEditorInput(pdf: input, mask: maskURL, initialMask: loadedMask))
                        }
                        .help("Opens the receipt with the same mask for review and correction.")
                    }
                } else {
                    Text(isRunning ? "Waiting" : "Ready").foregroundStyle(.secondary)
                }
                Button {
                    inputs.removeAll { $0 == input }
                    resetResults()
                } label: {
                    Image(systemName: "minus.circle").accessibilityLabel("Remove PDF")
                }
                .help("Remove PDF")
                .disabled(isRunning)
            }
            .buttonStyle(.borderless)
            Text(verbatim: input.deletingLastPathComponent().path)
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).font(.caption)
            if let diagnostic = item?.diagnostic {
                Text(verbatim: diagnostic).font(.caption).textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusLabel(_ item: ReceiptBatchItem) -> some View {
        switch item.status {
        case .success: Label("Exported", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .reviewRequired:
            Label("Review Required", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .failed: Label("Failed", systemImage: "xmark.circle").foregroundStyle(.red)
        case .cancelled: Label("Cancelled", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func chooseMask() {
        guard let url = ReceiptFilePanels.open(.json, title: "Choose Extraction Mask").first else { return }
        do {
            loadedMask = try ReceiptMask.load(from: url)
            maskURL = url
            resetResults()
        } catch { self.error = error.localizedDescription }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose JSON Destination", comment: "")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        resetResults()
    }

    private func add(_ urls: [URL]) {
        guard !isRunning else { return }
        var paths = Set(inputs.map(\.path))
        let new = urls.map(\.standardizedFileURL).filter {
            $0.isFileURL && $0.pathExtension.lowercased() == "pdf" && paths.insert($0.path).inserted
        }
        if new.isEmpty && urls.contains(where: { $0.pathExtension.lowercased() != "pdf" }) {
            error = NSLocalizedString("Choose or drop PDF files.", comment: "")
        }
        if !new.isEmpty {
            inputs.append(contentsOf: new)
            resetResults()
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning else { return false }
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        pendingDrops += 1
        // Die Ladevorgänge müssen beginnen, solange SwiftUI den Drop-Zugriff hält.
        let pending = providers.map { provider in
            AsyncStream<URL?> { continuation in
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.yield((object as? NSURL).map { $0 as URL })
                    continuation.finish()
                }
            }
        }
        Task {
            defer { pendingDrops -= 1 }
            var urls: [URL] = []
            for stream in pending {
                for await url in stream {
                    if let url { urls.append(url) }
                }
            }
            if urls.isEmpty {
                error = NSLocalizedString("Choose or drop PDF files.", comment: "")
            } else {
                add(urls)
            }
        }
        return true
    }

    private func resetResults() {
        items = [:]
        completed = 0
        wasCancelled = false
    }

    private func run() {
        guard let mask = loadedMask, !inputs.isEmpty, !isRunning, pendingDrops == 0 else { return }
        resetResults()
        let inputs = inputs
        let directory = outputDirectory
        let token = ConversionCancellationToken()
        cancellation = token
        Task {
            defer {
                cancellation = nil
                isCancelling = false
            }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try ReceiptBatch.run(
                        inputs: inputs, mask: mask, outputDirectory: directory, cancellation: token
                    ) { count, _, item in
                        Task { @MainActor in
                            guard cancellation === token else { return }
                            items[item.source] = item
                            completed = max(completed, count)
                        }
                    }
                }.value
                items = Dictionary(
                    summary.items.map { ($0.source, $0) }, uniquingKeysWith: { _, latest in latest })
                wasCancelled = summary.cancelled
                completed = summary.items.filter { $0.status != .cancelled }.count
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
