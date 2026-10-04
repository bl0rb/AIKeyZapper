import AppKit
import SwiftUI

@main
struct KeyZapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("KeyZapper") {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 500)
                .onAppear {
                    // Needed when started as a bare SwiftPM binary instead of an .app bundle.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }
        }
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Backup exportieren …") { model.backupSheet = .export }.disabled(model.state.profiles.isEmpty)
                Button("Backup importieren …") { model.backupSheet = .import }
            }
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") { Task { await model.checkForUpdates(userInitiated: true) } }
                    .disabled(!model.config.updateCheckEnabled)
            }
        }
    }
}

/// Single-window tool: quit when the window closes (like System Settings). Otherwise the app keeps running
/// without a window and a Dock click does not bring one back. The key helper works without the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Uses SwiftUI's `State` property wrapper directly. The `@State` macro needs the SwiftUIMacros plugin,
/// which ships with Xcode only; this keeps the app buildable with the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
