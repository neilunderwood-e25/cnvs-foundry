import SwiftUI
import SwiftTerm

struct AgentTerminalView: NSViewRepresentable {
    let runtime: AgentTerminalRuntime
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = runtime.terminalView
        terminal.onInteraction = onInteraction
        DispatchQueue.main.async {
            runtime.focus()
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        runtime.terminalView.onInteraction = onInteraction
    }
}
