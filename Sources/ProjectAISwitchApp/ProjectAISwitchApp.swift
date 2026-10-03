import AppKit
import SwiftUI

@main
struct ProjectAISwitchApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("ProjectAISwitch") {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 500)
                .onAppear {
                    // Needed when started as a bare SwiftPM binary instead of an .app bundle.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }
        }
    }
}

/// Uses SwiftUI's `State` property wrapper directly. The `@State` macro needs the SwiftUIMacros plugin,
/// which ships with Xcode only; this keeps the app buildable with the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
