import PoorMansTextCore
import PoorMansTextAppSupport
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("CLIInstallDeclined") private var cliInstallDeclined = false
    @State private var showsCLIInstallOffer = false
    @State private var cliInstallError: String?

    var body: some View {
        VStack(spacing: 24) {
            header
            dropArea
            footer
        }
        .padding(32)
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
        .onOpenURL { url in
            model.convert(url)
        }
        .task {
            prepareCLIInstallationOffer()
        }
        .confirmationDialog(
            "Install Command-Line Tool?",
            isPresented: $showsCLIInstallOffer,
            titleVisibility: .visible
        ) {
            Button("Install") {
                installCLI()
            }
            Button("Later", role: .cancel) {
                showsCLIInstallOffer = false
            }
            Button("Don't Ask Again") {
                cliInstallDeclined = true
                showsCLIInstallOffer = false
            }
        } message: {
            Text("Make poormans-text available in Terminal by linking it to the copy embedded in this app.")
        }
        .alert(
            "Command-Line Installation Failed",
            isPresented: Binding(
                get: { cliInstallError != nil },
                set: { if !$0 { cliInstallError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                cliInstallError = nil
            }
        } message: {
            Text(cliInstallError ?? "Unknown error")
        }
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
                Text("Word-processing documents to Markdown, with images kept in place")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var dropArea: some View {
        VStack(spacing: 18) {
            stateContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(model.isDropTargeted ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 7])
                )
        )
        .animation(.easeInOut(duration: 0.16), value: model.isDropTargeted)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $model.isDropTargeted
        ) { providers in
            model.acceptDrop(providers)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle:
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 45, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Drop an RTF, RTFD, DOCX, ODT, or DOC document here")
                .font(.title3.bold())
            Text("A new folder with Markdown and an images directory will be created next to it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 390)
            Button("Choose Document…") {
                model.chooseDocument()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

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
            Text("Markdown created")
                .font(.title3.bold())
            Text(result.outputDirectory.lastPathComponent)
                .font(.body.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
            Text(assetSummary(result))
                .foregroundStyle(.secondary)
            let warningMessages = WarningPresentation(warnings: result.warnings).messages
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
            HStack {
                Button("Show in Finder") {
                    model.revealResult()
                }
                .keyboardShortcut(.defaultAction)
                Button("Convert Another") {
                    model.reset()
                }
            }
            .controlSize(.large)

        case .failed(_, let message):
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 46))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("Conversion failed")
                .font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 430)
            HStack {
                Button("Choose Document…") {
                    model.chooseDocument()
                }
                .keyboardShortcut(.defaultAction)
                Button("Back") {
                    model.reset()
                }
            }
            .controlSize(.large)
        }
    }

    private var footer: some View {
        HStack {
            Text("Version \(ProductInfo.version)")
            Spacer()
            Text("Requires Pandoc")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func assetSummary(_ result: ConversionResult) -> String {
        switch result.assets.count {
        case 0:
            "No image assets"
        case 1:
            "1 image asset"
        default:
            "\(result.assets.count) image assets"
        }
    }

    private func prepareCLIInstallationOffer() {
        guard !cliInstallDeclined,
              Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
                == "/Applications" else {
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

        guard CLIInstaller.status(
            sourceURL: sourceURL,
            targetURL: CLIInstaller.defaultTargetURL
        ) == .available else {
            return
        }
        showsCLIInstallOffer = true
    }

    private func installCLI() {
        showsCLIInstallOffer = false
        let sourceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/poormans-text")
        let targetURL = CLIInstaller.defaultTargetURL

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CLIInstaller.install(sourceURL: sourceURL, targetURL: targetURL)
                }.value
            } catch {
                cliInstallError = error.localizedDescription
            }
        }
    }
}
