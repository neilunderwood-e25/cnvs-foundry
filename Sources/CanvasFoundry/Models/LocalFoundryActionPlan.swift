import Foundation

/// A deliberately small capability set exposed to the local language model.
/// The model can propose Foundry actions, but it never receives a shell or a
/// terminal handle. Every target is resolved again against live workspace state.
struct LocalFoundryActionPlan: Codable, Equatable {
    var response: String
    var actions: [LocalFoundryAction]
}

struct LocalFoundryAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case createAgent = "create_agent"
        case sendPrompt = "send_prompt"
        case focusAgent = "focus_agent"
        case stopAgent = "stop_agent"
        case resumeAgent = "resume_agent"
        /// The wire name is intentionally natural for small local models. The
        /// executor still only prepares Foundry's guarded confirmation.
        case prepareRemoveAgent = "remove_agent"
        case noAction = "no_action"
    }

    var type: Kind
    var agentID: String? = nil
    var provider: String? = nil
    var count: Int? = nil
    var prompt: String? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case agentID = "agent_id"
        case provider
        case count
        case prompt
    }
}

struct LocalFoundryAgentContext: Codable, Equatable {
    let id: String
    let name: String
    let provider: String
    let status: String
    let isRunning: Bool
    let isArchived: Bool
    let changedFileCount: Int
    let commitCount: Int
    let pullRequestNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, status
        case isRunning = "is_running"
        case isArchived = "is_archived"
        case changedFileCount = "changed_file_count"
        case commitCount = "commit_count"
        case pullRequestNumber = "pull_request_number"
    }
}

struct LocalFoundryWorkspaceContext: Codable, Equatable {
    let projectName: String?
    let selectedAgentID: String?
    let agents: [LocalFoundryAgentContext]
    var recentConversation: [LocalFoundryConversationTurn] = []

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case selectedAgentID = "selected_agent_id"
        case agents
        case recentConversation = "recent_conversation"
    }
}

struct LocalFoundryConversationTurn: Codable, Equatable {
    let userRequest: String
    let assistantResult: String
    let referencedAgentNames: [String]
    let didExecuteAction: Bool

    enum CodingKeys: String, CodingKey {
        case userRequest = "user_request"
        case assistantResult = "assistant_result"
        case referencedAgentNames = "referenced_agent_names"
        case didExecuteAction = "did_execute_action"
    }
}

struct WorkspaceConversationConfirmation: Equatable, Identifiable {
    enum Action: Equatable {
        case removeAgent(WorktreeDeletionRequest)
    }

    let id = UUID()
    let action: Action

    var sessionID: UUID {
        switch action {
        case .removeAgent(let request): request.sessionID
        }
    }

    var prompt: String {
        switch action {
        case .removeAgent(let request):
            if request.hasUncommittedChanges {
                return "\(request.agentName) has uncommitted changes. Remove the agent and discard them?"
            }
            return "Remove \(request.agentName) and its isolated workspace?"
        }
    }
}

enum WorkspaceConversationControl: Equatable {
    case confirm
    case cancel
    case doThat
}

enum WorkspaceConversationControlParser {
    static func parse(_ input: String) -> WorkspaceConversationControl? {
        let normalized = input.lowercased()
            .split { !$0.isLetter }
            .joined(separator: " ")
        let confirmations: Set<String> = [
            "confirm", "yes confirm", "yes do it", "go ahead", "proceed", "do it"
        ]
        let cancellations: Set<String> = [
            "cancel", "no cancel", "never mind", "nevermind", "don t do it", "stop that"
        ]
        if confirmations.contains(normalized) { return .confirm }
        if cancellations.contains(normalized) { return .cancel }
        if normalized == "do that" { return .doThat }
        return nil
    }
}

struct LocalFoundryActionExecution: Equatable {
    let wasHandled: Bool
    let message: String
}

struct LocalPlannerMetrics: Equatable {
    let totalDuration: TimeInterval
    let loadDuration: TimeInterval
    let promptEvaluationDuration: TimeInterval
    let generationDuration: TimeInterval
    let promptTokenCount: Int
    let generatedTokenCount: Int

    var warmExecutionDuration: TimeInterval {
        max(0, totalDuration - loadDuration)
    }
}

struct LocalFoundryPlanningResult: Equatable {
    let plan: LocalFoundryActionPlan
    let metrics: LocalPlannerMetrics
}

enum LocalFoundryContextFilter {
    /// Named and selected-agent requests should not pay prompt cost for the
    /// entire fleet. Fleet-wide/status language intentionally keeps all agents.
    static func agents(
        for input: String,
        selectedAgentID: String?,
        from agents: [LocalFoundryAgentContext]
    ) -> [LocalFoundryAgentContext] {
        let normalized = " " + input.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ") + " "
        let named = agents.filter { agent in
            let candidate = " " + agent.name.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ") + " "
            return normalized.contains(candidate)
        }
        if !named.isEmpty { return named }

        let selectedReferences = [
            " selected agent ", " currently selected ", " current agent ",
            " this agent ", " that agent "
        ]
        if selectedReferences.contains(where: normalized.contains),
           let selectedAgentID,
           let selected = agents.first(where: { $0.id == selectedAgentID }) {
            return [selected]
        }
        return agents
    }
}
