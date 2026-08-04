import Foundation

enum AgentNameGenerator {
    private static let callSigns = [
        "Ada", "Grace", "Alan", "Margaret", "Linus", "Katherine",
        "Dennis", "Barbara", "Ken", "Radia", "Edsger", "Frances"
    ]

    static func nextName(existingNames: Set<String>) -> String {
        if let availableName = callSigns.first(where: { !existingNames.contains($0) }) {
            return availableName
        }

        var suffix = callSigns.count + 1
        while existingNames.contains("Agent \(suffix)") {
            suffix += 1
        }
        return "Agent \(suffix)"
    }
}

enum AgentStatus: Equatable {
    case preparing
    case working
    case completed
    case needsYou(String)
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .working: "Working"
        case .completed: "Completed"
        case .needsYou: "Needs you"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var isActive: Bool {
        self == .preparing || self == .working
    }
}

struct AgentGitSummary: Equatable {
    var changedFileCount = 0
    var commitCount = 0
    var isRefreshing = false
    var errorMessage: String?
}

enum AgentTestStatus: Equatable {
    case notRun
    case running
    case passed
    case failed(String)

    var label: String {
        switch self {
        case .notRun: "Not run"
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        }
    }
}

enum PullRequestState: String, Equatable {
    case open
    case closed
    case merged
    case unknown

    var label: String {
        rawValue.capitalized
    }
}

struct AgentPullRequest: Equatable {
    let number: Int
    let url: URL
    let state: PullRequestState
    let isDraft: Bool
    let headBranch: String
    let baseBranch: String
    let updatedAt: Date

    var displayLabel: String {
        if state == .open && isDraft {
            return "Draft PR #\(number)"
        }
        return "\(state.label) PR #\(number)"
    }
}

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let provider: AgentProvider
    let createdAt: Date

    @Published var name: String
    @Published var terminalTitle: String?
    @Published var status: AgentStatus = .preparing
    @Published var position: CGPoint
    @Published var size = CGSize(width: 520, height: 360)
    @Published var worktree: WorktreeDescriptor?
    @Published var isSelected = false
    @Published var isArchived = false
    @Published var gitSummary = AgentGitSummary()
    @Published var testStatus: AgentTestStatus = .notRun
    @Published var pullRequest: AgentPullRequest?
    @Published var isPublishingPullRequest = false

    @Published var runtime: AgentTerminalRuntime?

    init(
        id: UUID = UUID(),
        provider: AgentProvider,
        name: String,
        position: CGPoint
    ) {
        self.id = id
        self.provider = provider
        self.position = position
        self.createdAt = Date()
        self.name = name
    }
}
