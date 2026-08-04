import Foundation

/// An action the command bar can perform. Parsing produces these; the model
/// executes them. Keeping them as data makes the whole language testable
/// without a microphone, a canvas, or a git repository.
enum WorkspaceCommand: Equatable {
    case createAgents(provider: AgentProvider, count: Int)
    case focusAgent(name: String)
    case setBackground(CanvasBackground)
    case selectTool(CanvasTool)
    case clearDrawings
    case resetView

    /// Short chip text shown back to the user before or after running.
    var summary: String {
        switch self {
        case .createAgents(let provider, let count):
            "\(count) × \(provider.shortName)"
        case .focusAgent(let name):
            "Find \(name)"
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
}
