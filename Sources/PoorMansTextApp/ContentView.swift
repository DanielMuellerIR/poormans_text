import PoorMansTextCore
import PoorMansTextAppSupport
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("CLIInstallDeclined") private var cliInstallDeclined = false
    @AppStorage("PandocInstallDeclined") private var pandocInstallDeclined = false
    @State private var showsCLIInstallOffer = false
    @State private var cliInstallError: String?
    @State private var pandocOffer: PandocInstaller.Offer?
    @State private var showsPandocInstallSuccess = false
    @State private var pandocInstallError: String?

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
            preparePandocOffer()
            // Höchstens ein Start-Dialog pro Start: Solange Pandoc fehlt, hat
            // dessen Angebot Vorrang; das CLI-Angebot kommt beim nächsten Start.
            if pandocOffer == nil {
                prepareCLIInstallationOffer()
            }
        }
        .confirmationDialog(
            pandocOffer == .manualGuidance ? "Pandoc Required" : "Install Pandoc?",
            isPresented: Binding(
                get: { pandocOffer != nil },
                set: { if !$0 { pandocOffer = nil } }
            ),
            titleVisibility: .visible
        ) {
            if case .homebrewInstall(let brewExecutable) = pandocOffer {
                Button("Install with Homebrew") {
                    installPandoc(brewExecutable: brewExecutable)
                }
            } else {
                Button("Show Install Help") {
                    NSWorkspace.shared.open(PandocInstaller.installationHelpURL)
                }
            }
            Button("Later", role: .cancel) {
                pandocOffer = nil
            }
            Button("Don't Ask Again") {
                pandocInstallDeclined = true
                pandocOffer = nil
            }
        } message: {
            if case .homebrewInstall = pandocOffer {
                Text("Pandoc is required to convert documents. Install it now with Homebrew? This can take a few minutes.")
            } else {
                Text("Pandoc is required to convert documents, but neither Pandoc nor Homebrew was found. The Pandoc website offers an official installer.")
            }
        }
        .alert("Pandoc Installed", isPresented: $showsPandocInstallSuccess) {
            Button("OK") {
                showsPandocInstallSuccess = false
            }
        } message: {
            Text("Pandoc is now available. You can start converting documents.")
        }
        .alert(
            "Pandoc Installation Failed",
            isPresented: Binding(
                get: { pandocInstallError != nil },
                set: { if !$0 { pandocInstallError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                pandocInstallError = nil
            }
        } message: {
            Text(pandocInstallError ?? "Unknown error")
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
            // Während der Pandoc-Installation nimmt das Modell keine Dokumente
            // an. Das muss man sehen, sonst wirkt die Drop-Zone nur kaputt.
            if model.isInstallingPandoc {
                ProgressView()
                    .controlSize(.large)
                Text("Installing Pandoc…")
                    .font(.title3.bold())
                Text("Documents are accepted again once the installation has finished.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 390)
            } else {
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
                // Solange Pandoc installiert wird, nimmt das Modell nichts an.
                .disabled(model.isInstallingPandoc)
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
            if model.isInstallingPandoc {
                ProgressView()
                    .controlSize(.small)
                Text("Installing Pandoc…")
            } else {
                Text("Requires Pandoc")
            }
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

    private func preparePandocOffer() {
        pandocOffer = PandocInstaller.offer(
            pandocIsAvailable: ExternalToolResolver().isAvailable(.pandoc),
            installDeclined: pandocInstallDeclined,
            brewExecutable: PandocInstaller.resolveHomebrew()
        )
    }

    private func installPandoc(brewExecutable: URL) {
        pandocOffer = nil

        // Der Installationszustand gehört ins Modell: nur dort können Drop-Zone,
        // Dateiauswahl und `onOpenURL` gemeinsam gesperrt werden.
        Task {
            do {
                try await model.installPandoc(brewExecutable: brewExecutable)
                showsPandocInstallSuccess = true
            } catch {
                pandocInstallError = error.localizedDescription
            }
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
