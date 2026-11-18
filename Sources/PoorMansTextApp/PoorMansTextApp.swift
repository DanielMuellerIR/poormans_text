import AppKit
import PoorMansTextAppSupport
import SwiftUI

@main
struct PoorMansTextDesktopApp: App {
    @NSApplicationDelegateAdaptor(OpenedDocumentsRelay.self) private var openedDocuments
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    /// Muss die App überleben: `NSApp.servicesProvider` hält nur eine schwache
    /// Referenz.
    @State private var services: ServicesProvider?

    init() {
        DocumentShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    let model = model
                    openedDocuments.handler = { urls in
                        model.openDocuments(urls)
                    }
                    openedDocuments.terminationHandler = { model.prepareToTerminate() }
                    openedDocuments.configurePaste(
                        handler: { model.pasteRichText() },
                        canPaste: { model.acceptsNewDocuments }
                    )
                    if services == nil {
                        let provider = ServicesProvider(model: model)
                        services = provider
                        NSApp.servicesProvider = provider
                        // Nach einem App-Tausch den Dienstkatalog ohne neue Anmeldung aktualisieren.
                        NSUpdateDynamicServices()
                    }
                }
        }
        .defaultSize(width: 620, height: 480)
        .commands {
            // Der Updater-Eintrag gehört unter „Über Poor Man's Text" ins
            // App-Menü. Er bleibt ausgegraut, solange Sparkle selbst sucht
            // oder gerade installiert.
            CommandGroup(after: .appInfo) {
                Button(LocalizedStringKey(UpdateController.menuTitle)) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Documents…") {
                    model.chooseDocument()
                }
                .keyboardShortcut("o")
                // Dieselbe Sperre wie Drop-Zone und Knopf: Während der
                // Pandoc-Installation war ⌘O aktiv, aber wirkungslos
                // (Roadmap-Punkt, 2026-09-10).
                .disabled(!model.acceptsNewDocuments)
                Divider()
                Button("Extract Receipt Data…") { chooseReceiptPDF(openWindow: openWindow) }
                Button("Apply Mask…") { openWindow(id: "receipt-batch") }
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste Text or Image") { model.pasteRichText() }
                    .disabled(!model.acceptsNewDocuments)
            }
        }
        WindowGroup("Receipt Data", for: ReceiptEditorInput.self) { $input in
            if let input { ReceiptEditorView(input: input) }
        }
        .defaultSize(width: 1100, height: 720)
        Window("Apply Mask", id: "receipt-batch") {
            ReceiptBatchView()
        }
        .defaultSize(width: 810, height: 580)
    }
}

@MainActor
func chooseReceiptPDF(openWindow: OpenWindowAction) {
    guard let pdf = ReceiptFilePanels.open(.pdf, title: "Choose Receipt PDF").first else { return }
    openWindow(value: ReceiptEditorInput(pdf: pdf))
}
