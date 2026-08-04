import AppKit
import SwiftUI

@main
struct CanvasFoundryApp: App {
    @NSApplicationDelegateAdaptor(CanvasFoundryAppDelegate.self) private var appDelegate
    /// Shared with the canvas through UserDefaults, so the menu item and the bar
    /// itself stay in step.
    @AppStorage(CommandBarVisibility.key) private var isCommandBarVisible = true

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
        .commands {
            // A real menu command rather than a hidden button: the shortcut works
            // regardless of what holds focus, and the binding is discoverable.
            CommandGroup(after: .sidebar) {
                Toggle("Command Bar", isOn: $isCommandBarVisible)
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

final class CanvasFoundryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        FoundryBrand.applyApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)
    }
}
