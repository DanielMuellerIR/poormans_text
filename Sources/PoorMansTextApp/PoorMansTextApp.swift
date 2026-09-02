import PoorMansTextAppSupport
import SwiftUI

@main
struct PoorMansTextDesktopApp: App {
    @NSApplicationDelegateAdaptor(OpenedDocumentsRelay.self) private var openedDocuments
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    let model = model
                    openedDocuments.handler = { urls in
                        model.convert(urls)
                    }
                }
        }
        .defaultSize(width: 620, height: 480)
        .commands {
            // Der Updater-Eintrag gehört unter „Über Poor Man's Text" ins
            // App-Menü. Er bleibt ausgegraut, solange Sparkle selbst sucht
            // oder gerade installiert.
            CommandGroup(after: .appInfo) {
                Button(UpdateController.menuTitle) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Documents…") {
                    model.chooseDocument()
                }
                .keyboardShortcut("o")
                .disabled(model.isConverting)
            }
        }
    }
}
