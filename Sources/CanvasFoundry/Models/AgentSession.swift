import Foundation

enum AgentNameGenerator {
    static let names = [
        "Ada", "Grace", "Alan", "Margaret", "Linus", "Katherine",
        "Dennis", "Barbara", "Ken", "Radia", "Edsger", "Frances",
        "Shannon", "Hedy", "Nikola", "Evelyn", "Donald", "Annie",
        "Tim", "Brendan", "Guido", "James", "John", "Leslie",
        "Sophie", "Karen", "Mary", "Jean", "Adele", "Dana",
        "Robin", "Morgan", "Riley", "Quinn", "Avery", "Jordan",
        "Casey", "Taylor", "Cameron", "Parker", "Rowan", "Reese",
        "Sydney", "Blair", "Drew", "Ellis", "Hayden", "Jules",
        "Remy", "Sasha"
    ]

    static func nextName(existingNames: Set<String>) -> String {
        let usedNames = Set(existingNames.map { $0.lowercased() })
        let availableNames = names.filter { !usedNames.contains($0.lowercased()) }
        if let availableName = availableNames.randomElement() {
            return availableName
        }

        var suffix = names.count + 1
        while usedNames.contains("agent \(suffix)") {
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

/// The user-facing lifecycle of an agent's work. Git branches, worktrees and
/// pull-request synchronization remain implementation details behind this one
/// delivery state.
enum AgentDeliveryState: Equatable {
    case preparing
    case working
    case changesReady
    case readyToPublish
    case publishing
    case draftPullRequest
    case checksRunning
    case readyToMerge
    case needsAttention
    case completed
    case idle

    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .working: "Working"
        case .changesReady: "Changes ready"
        case .readyToPublish: "Ready to publish"
        case .publishing: "Publishing"
        case .draftPullRequest: "Draft PR"
        case .checksRunning: "Checks running"
        case .readyToMerge: "Ready to merge"
        case .needsAttention: "Needs attention"
        case .completed: "Completed"
        case .idle: "Stopped"
        }
    }

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

enum PullRequestMergeability: String, Equatable {
    case mergeable
    case conflicting
    case unknown
}

enum PullRequestChecksStatus: String, Equatable {
    case noChecks
    case passed
    case pending
    case failed

    var label: String {
        switch self {
        case .noChecks: "No checks"
        case .passed: "Checks passed"
        case .pending: "Checks running"
        case .failed: "Checks failed"
        }
    }
}

enum PullRequestReviewDecision: String, Equatable {
    case approved
    case changesRequested
    case reviewRequired
    case none

    var label: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .none: "No review required"
        }
    }
}

struct PullRequestCheck: Equatable, Identifiable {
    let name: String
    let workflow: String?
    let state: String
    let bucket: String
    let link: URL?

    var id: String { "\(workflow ?? "")-\(name)-\(link?.absoluteString ?? "")" }
}

enum PullRequestQueueState: Equatable {
    case draft
    case checksPending
    case checksFailed
    case reviewRequired
    case changesRequested
    case behind
    case conflict
    case readyToMerge
    case blocked
    case merged
    case closed

    var label: String {
        switch self {
        case .draft: "Draft"
        case .checksPending: "Checks running"
        case .checksFailed: "Checks failed"
        case .reviewRequired: "Review required"
        case .changesRequested: "Changes requested"
        case .behind: "Behind base"
        case .conflict: "Conflict"
        case .readyToMerge: "Ready to merge"
        case .blocked: "Merge blocked"
        case .merged: "Merged"
        case .closed: "Closed"
        }
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
    let title: String
    let mergeability: PullRequestMergeability
    let mergeStateStatus: String
    let checksStatus: PullRequestChecksStatus
    let reviewDecision: PullRequestReviewDecision
    let headCommitOID: String?
    let changedFiles: Int
    let additions: Int
    let deletions: Int
    let checks: [PullRequestCheck]

    init(
        number: Int,
        url: URL,
        state: PullRequestState,
        isDraft: Bool,
        headBranch: String,
        baseBranch: String,
        updatedAt: Date,
        title: String = "",
        mergeability: PullRequestMergeability = .unknown,
        mergeStateStatus: String = "UNKNOWN",
        checksStatus: PullRequestChecksStatus = .noChecks,
        reviewDecision: PullRequestReviewDecision = .none,
        headCommitOID: String? = nil,
        changedFiles: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        checks: [PullRequestCheck] = []
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.updatedAt = updatedAt
        self.title = title
        self.mergeability = mergeability
        self.mergeStateStatus = mergeStateStatus
        self.checksStatus = checksStatus
        self.reviewDecision = reviewDecision
        self.headCommitOID = headCommitOID
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.checks = checks
    }

    var displayLabel: String {
        if state == .open && isDraft {
            return "Draft PR #\(number)"
        }
        return "\(state.label) PR #\(number)"
    }

    var queueState: PullRequestQueueState {
        if state == .merged { return .merged }
        if state == .closed { return .closed }
        if isDraft { return .draft }
        if mergeability == .conflicting || mergeStateStatus == "DIRTY" {
            return .conflict
        }
        if checksStatus == .failed { return .checksFailed }
        if checksStatus == .pending { return .checksPending }
        if reviewDecision == .changesRequested { return .changesRequested }
        if reviewDecision == .reviewRequired { return .reviewRequired }
        if mergeStateStatus == "BEHIND" { return .behind }
        if state == .open && mergeability == .mergeable && mergeStateStatus == "CLEAN" {
            return .readyToMerge
        }
        return .blocked
    }

    var isReadyToMerge: Bool {
        queueState == .readyToMerge
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

    var deliveryState: AgentDeliveryState {
        if isPublishingPullRequest { return .publishing }

        if let pullRequest {
            switch pullRequest.queueState {
            case .merged, .closed:
                return .completed
            case .draft:
                return .draftPullRequest
            case .checksPending, .reviewRequired, .behind:
                return .checksRunning
            case .readyToMerge:
                return .readyToMerge
            case .checksFailed, .changesRequested, .conflict, .blocked:
                return .needsAttention
            }
        }

        if status.isActive {
            return status == .preparing ? .preparing : .working
        }
        if gitSummary.changedFileCount > 0 { return .changesReady }
        if gitSummary.commitCount > 0 { return .readyToPublish }

        switch status {
        case .preparing: return .preparing
        case .working: return .working
        case .completed: return .completed
        case .needsYou, .failed: return .needsAttention
        case .stopped: return .idle
        }
    }

    var canReviewAndShip: Bool {
        pullRequest != nil
            || gitSummary.changedFileCount > 0
            || gitSummary.commitCount > 0
    }
}
