import Foundation

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

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let provider: AgentProvider
    let prompt: String
    let createdAt: Date

    @Published var title: String
    @Published var status: AgentStatus = .preparing
    @Published var output = ""
    @Published var position: CGPoint
    @Published var worktree: WorktreeDescriptor?
    @Published var isSelected = false

    var runtime: AgentProcessController?

    init(
        id: UUID = UUID(),
        provider: AgentProvider,
        prompt: String,
        position: CGPoint
    ) {
        self.id = id
        self.provider = provider
        self.prompt = prompt
        self.position = position
        self.createdAt = Date()
        self.title = Self.makeTitle(from: prompt)
    }

    func appendOutput(_ text: String) {
        output += text
        let maximumCharacters = 160_000
        if output.count > maximumCharacters {
            output.removeFirst(output.count - maximumCharacters)
        }
    }

    private static func makeTitle(from prompt: String) -> String {
        let compact = prompt
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
        guard compact.count > 48 else { return compact }
        return String(compact.prefix(47)) + "…"
    }
}
