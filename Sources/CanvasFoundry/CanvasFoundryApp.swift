import SwiftUI

@main
struct CanvasFoundryApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
