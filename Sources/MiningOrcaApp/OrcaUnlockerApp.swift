import AppKit
import SwiftUI

@main
@MainActor
struct OrcaUnlockerApp: App {
    @StateObject private var model = LauncherAppModel()

    init() {
        // A SwiftUI executable launched directly by SwiftPM is not wrapped in a
        // normal macOS .app bundle, so AppKit may not activate it as a regular
        // foreground application automatically.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            if let window = NSApp.windows.first {
                window.title = AppText.Common.appName
                window.titleVisibility = .visible
                window.toolbar = nil
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup(AppText.Common.appName) {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 760)
        }
        .defaultSize(width: 1420, height: 960)
    }
}
