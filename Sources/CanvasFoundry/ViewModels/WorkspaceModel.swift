import AppKit
import Combine
import Foundation

enum CanvasPlacementEngine {
    static func nextCenter(
        existingRects: [CGRect],
        viewportSize: CGSize,
        itemSize: CGSize,
        margin: CGFloat = 36
    ) -> CGPoint {
        let viewport = CGSize(
            width: max(viewportSize.width, itemSize.width + margin * 2),
            height: max(viewportSize.height, itemSize.height + margin * 2)
        )
        let columns = max(
            1,
            Int((viewport.width - margin) / (itemSize.width + margin))
        )

        for index in 0..<500 {
            let column = index % columns
            let row = index / columns
            let center = CGPoint(
                x: margin + itemSize.width / 2 + CGFloat(column) * (itemSize.width + margin),
                y: margin + itemSize.height / 2 + CGFloat(row) * (itemSize.height + margin)
            )
            let proposedRect = CGRect(
                x: center.x - itemSize.width / 2,
                y: center.y - itemSize.height / 2,
                width: itemSize.width,
                height: itemSize.height
            ).insetBy(dx: -margin / 2, dy: -margin / 2)

            if existingRects.allSatisfy({ !$0.intersects(proposedRect) }) {
                return center
            }
        }

        return CGPoint(
            x: margin + itemSize.width / 2,
            y: margin + itemSize.height / 2 + CGFloat(existingRects.count) * (itemSize.height + margin)
        )
    }
}

enum WorkspaceAlertState: Identifiable, Equatable {
    case message(String)
    case bootstrap(RepositoryBootstrapRequest)
    case deleteWorktree(WorktreeDeletionRequest)
    case switchProject(ProjectSwitchRequest)

    var id: String {
        switch self {
        case .message(let message):
            "message-\(message)"
        case .bootstrap(let request):
            "bootstrap-\(request.folderURL.path)-\(request.shouldInitializeGit)"
        case .deleteWorktree(let request):
            "delete-worktree-\(request.sessionID)-\(request.hasUncommittedChanges)"
        case .switchProject(let request):
            "switch-project-\(request.projectURL.path)"
        }
    }
}

struct WorktreeDeletionRequest: Equatable {
    let sessionID: UUID
    let agentName: String
    let hasUncommittedChanges: Bool
}

struct ProjectSwitchRequest: Equatable {
    let projectURL: URL
    let existingAgentCount: Int
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var projectURL: URL? {
        didSet { schedulePersistence() }
    }
    @Published var sessions: [AgentSession] = [] {
        didSet {
            observeSessions()
            schedulePersistence()
        }
    }
    @Published var zoom: CGFloat = 1 {
        didSet { schedulePersistence() }
    }
    @Published var pan = CGSize(width: 180, height: 130) {
        didSet { schedulePersistence() }
    }
    @Published var selectedSessionID: UUID? {
        didSet { schedulePersistence() }
    }
    @Published var alertState: WorkspaceAlertState?
    @Published var reviewingSession: AgentSession?

    private let worktreeManager: GitWorktreeManager
    private let projectManager: GitProjectManager
    private let persistence: WorkspacePersistence
    let gitReviewService: GitReviewService
    private var viewportSize = CGSize(width: 1200, height: 760)
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var isRestoring = true

    init(
        worktreeManager: GitWorktreeManager = GitWorktreeManager(),
        projectManager: GitProjectManager = GitProjectManager(),
        persistence: WorkspacePersistence = WorkspacePersistence(),
        gitReviewService: GitReviewService = GitReviewService()
    ) {
        self.worktreeManager = worktreeManager
        self.projectManager = projectManager
        self.persistence = persistence
        self.gitReviewService = gitReviewService
        restoreWorkspace()
        isRestoring = false
        observeSessions()
    }

    var activeAgentCount: Int {
        sessions.filter { !$0.isArchived && $0.status.isActive }.count
    }

    var visibleSessions: [AgentSession] {
        sessions.filter { !$0.isArchived }
    }

    var availableIDEWorktreeSessions: [AgentSession] {
        visibleSessions.filter { session in
            guard let path = session.worktree?.worktreeURL.path else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Git project"
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let selectedURL = panel.url {
            inspectProject(selectedURL)
        }
    }

    func initializeRepository(_ request: RepositoryBootstrapRequest) {
        alertState = nil
        Task {
            do {
                activateProject(try await projectManager.bootstrap(request))
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func openTerminal(provider: AgentProvider) {
        guard let projectURL else {
            alertState = .message("Choose a Git project before launching an agent.")
            return
        }
        guard ExecutableResolver.resolve(provider.launchPlan().executable) != nil else {
            alertState = .message(
                AgentTerminalError.executableNotFound(provider.displayName).localizedDescription
            )
            return
        }

        let terminalSize = CGSize(width: 520, height: 360)
        let occupiedRects = sessions.map { session in
            CGRect(
                x: session.position.x * zoom + pan.width - session.size.width / 2,
                y: session.position.y * zoom + pan.height - session.size.height / 2,
                width: session.size.width,
                height: session.size.height
            )
        }
        let screenCenter = CanvasPlacementEngine.nextCenter(
            existingRects: occupiedRects,
            viewportSize: viewportSize,
            itemSize: terminalSize
        )
        let position = CGPoint(
            x: (screenCenter.x - pan.width) / zoom,
            y: (screenCenter.y - pan.height) / zoom
        )
        let name = AgentNameGenerator.nextName(
            existingNames: Set(sessions.map(\.name))
        )
        let session = AgentSession(
            provider: provider,
            name: name,
            position: position
        )
        sessions.append(session)
        select(session)

        Task {
            do {
                let descriptor = try await worktreeManager.createWorktree(
                    for: projectURL,
                    sessionID: session.id,
                    title: "\(name)-\(provider.rawValue)"
                )
                session.worktree = descriptor

                let runtime = try AgentTerminalRuntime(
                    session: session,
                    directory: descriptor.worktreeURL
                )
                session.runtime = runtime
                refreshGitSummary(session)
            } catch {
                session.status = .failed(error.localizedDescription)
            }
        }
    }

    func openProject(in ide: ProjectIDE) {
        guard let projectURL else { return }
        Task {
            do {
                try await IDEProjectOpener.open(projectURL: projectURL, in: ide)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func openAllActiveWorktrees(in ide: ProjectIDE) {
        guard let projectURL else { return }
        let agentFolders = availableIDEWorktreeSessions.compactMap {
            session -> IDEProjectOpener.WorkspaceFolder? in
            guard let worktreeURL = session.worktree?.worktreeURL else { return nil }
            return IDEProjectOpener.WorkspaceFolder(
                name: "\(session.name) — \(session.provider.shortName)",
                url: worktreeURL
            )
        }
        let folders = [
            IDEProjectOpener.WorkspaceFolder(
                name: "Main — \(projectURL.lastPathComponent)",
                url: projectURL
            )
        ] + agentFolders

        Task {
            do {
                let workspaceURL = try IDEProjectOpener.makeMultiRootWorkspace(
                    projectURL: projectURL,
                    folders: folders
                )
                try await IDEProjectOpener.open(projectURL: workspaceURL, in: ide)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func openAgentWorktree(_ session: AgentSession, in ide: ProjectIDE) {
        guard let worktreeURL = session.worktree?.worktreeURL else { return }
        Task {
            do {
                try await IDEProjectOpener.open(projectURL: worktreeURL, in: ide)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func relaunch(_ session: AgentSession) {
        guard !session.status.isActive else { return }
        guard let descriptor = session.worktree else {
            session.status = .failed("This agent does not have an assigned worktree.")
            return
        }
        guard FileManager.default.fileExists(atPath: descriptor.worktreeURL.path) else {
            session.status = .failed("The agent worktree no longer exists on disk.")
            return
        }
        guard ExecutableResolver.resolve(session.provider.launchPlan().executable) != nil else {
            session.status = .failed(
                AgentTerminalError.executableNotFound(session.provider.displayName).localizedDescription
            )
            return
        }

        do {
            session.runtime = try AgentTerminalRuntime(
                session: session,
                directory: descriptor.worktreeURL
            )
            select(session)
        } catch {
            session.status = .failed(error.localizedDescription)
        }
    }

    func focus(_ session: AgentSession) {
        guard !session.isArchived else { return }
        select(session)
        pan = CGSize(
            width: viewportSize.width / 2 - session.position.x * zoom,
            height: viewportSize.height / 2 - session.position.y * zoom
        )
        refreshGitSummary(session)
    }

    func rename(_ session: AgentSession, to proposedName: String) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let occupiedNames = Set(
            sessions
                .filter { $0.id != session.id }
                .map { $0.name.lowercased() }
        )
        var resolvedName = trimmed
        var suffix = 2
        while occupiedNames.contains(resolvedName.lowercased()) {
            resolvedName = "\(trimmed) \(suffix)"
            suffix += 1
        }
        session.name = resolvedName
    }

    func archive(_ session: AgentSession) {
        session.runtime?.stop()
        session.isArchived = true
        if selectedSessionID == session.id {
            select(nil)
        }
    }

    func restore(_ session: AgentSession) {
        session.isArchived = false
        focus(session)
    }

    func prepareWorktreeDeletion(_ session: AgentSession) {
        guard let descriptor = session.worktree else {
            sessions.removeAll { $0.id == session.id }
            return
        }

        Task {
            do {
                let hasChanges = try await worktreeManager.hasUncommittedChanges(descriptor)
                alertState = .deleteWorktree(
                    WorktreeDeletionRequest(
                        sessionID: session.id,
                        agentName: session.name,
                        hasUncommittedChanges: hasChanges
                    )
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func review(_ session: AgentSession) {
        reviewingSession = session
        refreshGitSummary(session)
    }

    func refreshGitSummary(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              FileManager.default.fileExists(atPath: descriptor.worktreeURL.path),
              !session.gitSummary.isRefreshing else {
            return
        }

        session.gitSummary.isRefreshing = true
        session.gitSummary.errorMessage = nil
        Task {
            do {
                session.gitSummary = try await gitReviewService.summary(descriptor)
            } catch {
                session.gitSummary = AgentGitSummary(errorMessage: error.localizedDescription)
            }
        }
    }

    func refreshAllGitSummaries() {
        for session in sessions where !session.isArchived {
            refreshGitSummary(session)
        }
    }

    func deleteWorktree(_ request: WorktreeDeletionRequest) {
        alertState = nil
        guard let session = sessions.first(where: { $0.id == request.sessionID }),
              let descriptor = session.worktree else {
            return
        }

        session.runtime?.stop()
        Task {
            do {
                try await worktreeManager.removeWorktree(
                    descriptor,
                    force: request.hasUncommittedChanges
                )
                sessions.removeAll { $0.id == request.sessionID }
                if selectedSessionID == request.sessionID {
                    select(nil)
                }
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func switchProject(_ request: ProjectSwitchRequest) {
        alertState = nil
        for session in sessions {
            session.runtime?.stop()
        }
        reviewingSession = nil
        sessions = []
        selectedSessionID = nil
        zoom = 1
        pan = CGSize(width: 180, height: 130)
        projectURL = request.projectURL
    }

    func select(_ session: AgentSession?) {
        guard selectedSessionID != session?.id else { return }
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

    func updateViewport(_ size: CGSize) {
        viewportSize = size
    }

    func persistWorkspace() {
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            try persistence.save(makeSnapshot())
        } catch {
            NSLog("Canvas Foundry could not persist the workspace: %@", error.localizedDescription)
        }
    }

    private func inspectProject(_ selectedURL: URL) {
        Task {
            do {
                switch try await projectManager.inspect(selectedURL) {
                case .ready(let rootURL):
                    activateProject(rootURL)
                case .needsBootstrap(let request):
                    alertState = .bootstrap(request)
                case .unsupported(let message):
                    alertState = .message(message)
                }
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    private func activateProject(_ rootURL: URL) {
        let normalizedRoot = rootURL.standardizedFileURL
        if projectURL?.standardizedFileURL == normalizedRoot {
            projectURL = normalizedRoot
        } else if sessions.isEmpty {
            projectURL = normalizedRoot
        } else {
            alertState = .switchProject(
                ProjectSwitchRequest(
                    projectURL: normalizedRoot,
                    existingAgentCount: sessions.count
                )
            )
        }
    }

    private func restoreWorkspace() {
        let snapshot: WorkspaceSnapshot
        do {
            guard let storedSnapshot = try persistence.load() else { return }
            snapshot = storedSnapshot
        } catch {
            alertState = .message("The saved workspace could not be restored: \(error.localizedDescription)")
            return
        }

        guard let projectPath = snapshot.projectPath,
              FileManager.default.fileExists(atPath: projectPath) else {
            return
        }

        projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        zoom = min(1.8, max(0.45, CGFloat(snapshot.zoom)))
        pan = CGSize(width: snapshot.panX, height: snapshot.panY)
        sessions = snapshot.sessions.compactMap(restoreSession)

        if let selectedID = snapshot.selectedSessionID,
           let selectedSession = sessions.first(where: { $0.id == selectedID && !$0.isArchived }) {
            selectedSessionID = selectedID
            selectedSession.isSelected = true
        }
    }

    private func restoreSession(_ stored: PersistedAgentSession) -> AgentSession? {
        guard let provider = AgentProvider(rawValue: stored.provider) else { return nil }

        let session = AgentSession(
            id: stored.id,
            provider: provider,
            name: stored.name,
            position: CGPoint(x: stored.positionX, y: stored.positionY)
        )
        session.size = CGSize(
            width: max(420, stored.width),
            height: max(280, stored.height)
        )
        session.isArchived = stored.isArchived ?? false
        if let worktree = stored.worktree {
            session.worktree = WorktreeDescriptor(
                projectRoot: URL(fileURLWithPath: worktree.projectRootPath, isDirectory: true),
                worktreeURL: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                branchName: worktree.branchName,
                baseRevision: worktree.baseRevision
            )
            session.status = FileManager.default.fileExists(atPath: worktree.worktreePath)
                ? .stopped
                : .failed("The agent worktree no longer exists on disk.")
        } else {
            session.status = .failed("This agent does not have an assigned worktree.")
        }
        return session
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            projectPath: projectURL?.path,
            zoom: Double(zoom),
            panX: Double(pan.width),
            panY: Double(pan.height),
            selectedSessionID: selectedSessionID,
            sessions: sessions.map { session in
                PersistedAgentSession(
                    id: session.id,
                    provider: session.provider.rawValue,
                    name: session.name,
                    positionX: Double(session.position.x),
                    positionY: Double(session.position.y),
                    width: Double(session.size.width),
                    height: Double(session.size.height),
                    isArchived: session.isArchived,
                    worktree: session.worktree.map { worktree in
                        PersistedWorktree(
                            projectRootPath: worktree.projectRoot.path,
                            worktreePath: worktree.worktreeURL.path,
                            branchName: worktree.branchName,
                            baseRevision: worktree.baseRevision
                        )
                    }
                )
            }
        )
    }

    private func observeSessions() {
        guard !isRestoring else { return }
        let activeIDs = Set(sessions.map(\.id))
        sessionObservers = sessionObservers.filter { activeIDs.contains($0.key) }

        for session in sessions where sessionObservers[session.id] == nil {
            sessionObservers[session.id] = session.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.schedulePersistence()
                }
            }
        }
    }

    private func schedulePersistence() {
        guard !isRestoring else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.persistWorkspace()
        }
    }
}
