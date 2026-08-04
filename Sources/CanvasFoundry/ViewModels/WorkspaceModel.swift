import AppKit
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var sessions: [AgentSession] = []
    @Published var zoom: CGFloat = 1
    @Published var pan = CGSize(width: 180, height: 130)
    @Published var selectedSessionID: UUID?
    @Published var alertMessage: String?

    private let worktreeManager: GitWorktreeManager

    init(worktreeManager: GitWorktreeManager = GitWorktreeManager()) {
        self.worktreeManager = worktreeManager
    }

    var activeAgentCount: Int {
        sessions.filter { $0.status.isActive }.count
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Git project"
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            projectURL = panel.url
        }
    }

    func spawn(provider: AgentProvider, prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectURL else {
            alertMessage = "Choose a Git project before launching an agent."
            return
        }
        guard !trimmedPrompt.isEmpty else { return }

        let index = sessions.count
        let position = CGPoint(
            x: 260 + CGFloat(index % 3) * 460,
            y: 220 + CGFloat(index / 3) * 340
        )
        let session = AgentSession(provider: provider, prompt: trimmedPrompt, position: position)
        sessions.append(session)
        select(session)

        Task {
            do {
                let descriptor = try await worktreeManager.createWorktree(
                    for: projectURL,
                    sessionID: session.id,
                    title: session.title
                )
                session.worktree = descriptor

                let runtime = AgentProcessController(session: session)
                session.runtime = runtime
                try runtime.start(in: descriptor.worktreeURL)
            } catch {
                session.status = .failed(error.localizedDescription)
                session.appendOutput("[Canvas Foundry] \(error.localizedDescription)\n")
            }
        }
    }

    func select(_ session: AgentSession?) {
        selectedSessionID = session?.id
        for candidate in sessions {
            candidate.isSelected = candidate.id == session?.id
        }
    }

    func resetView() {
        zoom = 1
        pan = CGSize(width: 180, height: 130)
    }

    func zoomIn() {
        zoom = min(1.8, zoom + 0.1)
    }

    func zoomOut() {
        zoom = max(0.45, zoom - 0.1)
    }
}
