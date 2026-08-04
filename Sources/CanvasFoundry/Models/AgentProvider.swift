import Foundation

enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "OpenAI Codex"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var launchName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "cube.transparent"
        }
    }

    func launchPlan() -> AgentLaunchPlan {
        switch self {
        case .claude:
            AgentLaunchPlan(executable: "claude", arguments: [])
        case .codex:
            AgentLaunchPlan(executable: "codex", arguments: [])
        }
    }
}

struct AgentLaunchPlan: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}
