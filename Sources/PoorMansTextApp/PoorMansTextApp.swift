import PoorMansTextAppSupport
import SwiftUI

@main
struct PoorMansTextDesktopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 620, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open RTFD…") {
                    model.chooseDocument()
                }
                .keyboardShortcut("o")
                .disabled(model.isConverting)
            }
        }
    }
}
