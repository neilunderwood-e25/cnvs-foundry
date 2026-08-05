import Foundation

/// An action the command bar can perform. Parsing produces these; the model
/// executes them. Keeping them as data makes the whole language testable
/// without a microphone, a canvas, or a git repository.
enum WorkspaceCommand: Equatable {
    case createAgents(provider: AgentProvider, count: Int)
    case createAgentWithPrompt(provider: AgentProvider, prompt: String)
    case focusAgent(name: String)
    case sendPrompt(name: String, prompt: String)
    case stopAgent(name: String)
    case resumeAgent(name: String)
    case setBackground(CanvasBackground)
    case selectTool(CanvasTool)
    case clearDrawings
    case resetView

    /// Short chip text shown back to the user before or after running.
    var summary: String {
        switch self {
        case .createAgents(let provider, let count):
            "\(count) × \(provider.shortName)"
        case .createAgentWithPrompt(let provider, let prompt):
            "New \(provider.shortName): \(prompt)"
        case .focusAgent(let name):
            "Find \(name)"
        case .sendPrompt(let name, let prompt):
            "Tell \(name): \(prompt)"
        case .stopAgent(let name):
            "Stop \(name)"
        case .resumeAgent(let name):
            "Resume \(name)"
        case .setBackground(let background):
            "Background → \(background.displayName)"
        case .selectTool(let tool):
            "Tool → \(tool.title)"
        case .clearDrawings:
            "Clear drawings"
        case .resetView:
            "Reset view"
        }
    }

    /// Short, deterministic speech. A local model never gets to invent what
    /// happened, and confirmations are available without inference latency.
    var spokenAcknowledgement: String {
        switch self {
        case .createAgents(let provider, let count):
            let quantity = [
                1: "one", 2: "two", 3: "three", 4: "four",
                5: "five", 6: "six", 7: "seven", 8: "eight"
            ][count] ?? String(count)
            return "Opening \(quantity) \(provider.shortName) agent\(count == 1 ? "" : "s") now."
        case .createAgentWithPrompt(let provider, _):
            return "Opening a \(provider.shortName) agent for that now."
        case .focusAgent(let name):
            return "Bringing \(name) into view."
        case .sendPrompt(let name, _):
            return "Sending that to \(name)."
        case .stopAgent(let name):
            return "Stopping \(name) now."
        case .resumeAgent(let name):
            return "Resuming \(name) now."
        case .setBackground(let background):
            return "Changing the background to \(background.displayName)."
        case .selectTool(let tool):
            return "Switching to the \(tool.title) tool."
        case .clearDrawings:
            return "Clearing the drawings now."
        case .resetView:
            return "Resetting the canvas view."
        }
    }
}

/// The outcome of parsing one line of input.
struct WorkspaceCommandPlan: Equatable {
    var commands: [WorkspaceCommand] = []
    /// Clauses that matched nothing, echoed back so the user can see why.
    var unrecognized: [String] = []
    /// Adjustments worth mentioning, e.g. a clamped agent count.
    var notes: [String] = []

    var isEmpty: Bool { commands.isEmpty }

    var summary: String {
        commands.map(\.summary).joined(separator: ", ")
    }

    var spokenAcknowledgement: String {
        commands.map(\.spokenAcknowledgement).joined(separator: " ")
    }
}
