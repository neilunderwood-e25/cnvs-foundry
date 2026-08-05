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

    func launchPlan(
        resuming: Bool = false,
        initialPrompt: String? = nil
    ) -> AgentLaunchPlan {
        let promptArguments = initialPrompt.map { [$0] } ?? []
        return switch (self, resuming) {
        case (.claude, false):
            AgentLaunchPlan(executable: "claude", arguments: promptArguments)
        case (.claude, true):
            AgentLaunchPlan(executable: "claude", arguments: ["--continue"])
        case (.codex, false):
            AgentLaunchPlan(executable: "codex", arguments: promptArguments)
        case (.codex, true):
            AgentLaunchPlan(executable: "codex", arguments: ["resume", "--last"])
        }
    }
}

struct AgentLaunchPlan: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}
