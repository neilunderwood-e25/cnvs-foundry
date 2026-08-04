import AppKit
import SwiftUI

@main
struct CanvasFoundryApp: App {
    @NSApplicationDelegateAdaptor(CanvasFoundryAppDelegate.self) private var appDelegate

    init() {
        FoundryBrand.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .font(.foundry(size: 13))
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
    }
}

final class CanvasFoundryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        FoundryBrand.applyApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)
    }
}
