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
        didSet {
            if let projectURL, !isRestoring {
                rememberProject(projectURL)
                warmLocalPlanner()
            }
            schedulePersistence()
        }
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
    @Published var canvasBackground: CanvasBackground = .fallback {
        didSet { schedulePersistence() }
    }
    @Published var activeTool: CanvasTool = .select
    @Published var annotationColor: AnnotationColor = .chalk
    @Published private(set) var annotations: [CanvasAnnotation] = []
    @Published private(set) var selectedAnnotationIDs: Set<UUID> = []
    @Published var alertState: WorkspaceAlertState?
    @Published var reviewingSession: AgentSession?
    @Published private(set) var mergingSessionID: UUID?
    @Published private(set) var recentProjectURLs: [URL] = []
    @Published private(set) var isLocalPlannerWarm = false
    @Published private(set) var lastLocalPlannerMetrics: LocalPlannerMetrics?
    @Published var pendingConversationConfirmation: WorkspaceConversationConfirmation?
    @Published private(set) var recentConversation: [LocalFoundryConversationTurn] = []

    private let worktreeManager: GitWorktreeManager
    private let projectManager: GitProjectManager
    private let persistence: WorkspacePersistence
    let gitReviewService: GitReviewService
    private let pullRequestService: GitHubPullRequestService
    private let localActionPlanner: LocalActionPlanner
    private var viewportSize = CGSize(width: 1200, height: 760)
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var localPlannerWarmupTask: Task<Void, Never>?
    private var isRestoring = true
    /// Snapshots of `annotations` taken before each edit, newest last.
    private var annotationHistory: [[CanvasAnnotation]] = []
    private static let annotationHistoryLimit = 60
    private static let conversationHistoryLimit = 4
    /// Positions captured when a move begins, so every frame of the drag is
    /// applied to the original geometry instead of compounding deltas.
    private var selectionDragOrigin: [UUID: [CGPoint]] = [:]

    init(
        worktreeManager: GitWorktreeManager = GitWorktreeManager(),
        projectManager: GitProjectManager = GitProjectManager(),
        persistence: WorkspacePersistence = WorkspacePersistence(),
        gitReviewService: GitReviewService = GitReviewService(),
        pullRequestService: GitHubPullRequestService = GitHubPullRequestService(),
        localActionPlanner: LocalActionPlanner = LocalActionPlanner()
    ) {
        self.worktreeManager = worktreeManager
        self.projectManager = projectManager
        self.persistence = persistence
        self.gitReviewService = gitReviewService
        self.pullRequestService = pullRequestService
        self.localActionPlanner = localActionPlanner
        restoreWorkspace()
        isRestoring = false
        observeSessions()
        if projectURL != nil { warmLocalPlanner() }
    }

    var activeAgentCount: Int {
        sessions.filter { !$0.isArchived && $0.status.isActive }.count
    }

    var visibleSessions: [AgentSession] {
        sessions.filter { !$0.isArchived }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Any folder works now — repos open directly, everything else gets a
        // consented initialization — so creating one here is fine too.
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let selectedURL = panel.url {
            inspectProject(selectedURL)
        }
    }

    /// Names and creates a brand-new project folder, initialized and ready for
    /// agents in one step.
    func createNewProject() {
        let panel = NSSavePanel()
        panel.title = "Create a new project"
        panel.prompt = "Create Project"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            do {
                activateProject(try await projectManager.createProject(at: folderURL))
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func openRecentProject(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            recentProjectURLs.removeAll {
                $0.standardizedFileURL == normalizedURL
            }
            schedulePersistence()
            alertState = .message(
                "The recent project “\(url.lastPathComponent)” is no longer available at \(url.path)."
            )
            return
        }
        inspectProject(normalizedURL)
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
        createAgents(provider: provider, count: 1)
    }

    /// Opens `count` agents at once.
    ///
    /// Cards are staged synchronously so they all appear immediately and the
    /// placement engine sees each previous one, but the worktrees are attached
    /// one at a time: `GitWorktreeManager` is a plain struct, so several
    /// concurrent `git worktree add` calls would contend on the same repository.
    @discardableResult
    func createAgents(provider: AgentProvider, count: Int) -> Bool {
        createAgents(provider: provider, count: count, initialPrompt: nil)
    }

    @discardableResult
    func createAgent(provider: AgentProvider, initialPrompt: String) -> Bool {
        createAgents(provider: provider, count: 1, initialPrompt: initialPrompt)
    }

    private func createAgents(
        provider: AgentProvider,
        count: Int,
        initialPrompt: String?
    ) -> Bool {
        guard let projectURL else {
            alertState = .message("Choose a Git project before launching an agent.")
            return false
        }
        guard ExecutableResolver.resolve(provider.launchPlan().executable) != nil else {
            alertState = .message(
                AgentTerminalError.executableNotFound(provider.displayName).localizedDescription
            )
            return false
        }

        let staged = (0..<max(1, count)).map { _ in stageSession(provider: provider) }
        Task {
            for session in staged {
                await activateSession(
                    session,
                    projectURL: projectURL,
                    initialPrompt: initialPrompt
                )
            }
        }
        return true
    }

    private func stageSession(provider: AgentProvider) -> AgentSession {
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
        return session
    }

    private func activateSession(
        _ session: AgentSession,
        projectURL: URL,
        initialPrompt: String? = nil
    ) async {
        do {
            let normalizedPrompt = initialPrompt.map(AgentTerminalRuntime.normalizedPrompt)
            let worktreeTitle = normalizedPrompt.flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(session.name)-\(session.provider.rawValue)"
            let descriptor = try await worktreeManager.createWorktree(
                for: projectURL,
                sessionID: session.id,
                title: worktreeTitle
            )
            session.worktree = descriptor

            let runtime = try AgentTerminalRuntime(
                session: session,
                directory: descriptor.worktreeURL,
                initialPrompt: normalizedPrompt
            )
            session.runtime = runtime
            refreshGitSummary(session)
        } catch {
            session.status = .failed(error.localizedDescription)
        }
    }

    func openProject(in ide: ProjectIDE) {
        guard let projectURL else { return }
        Task {
            do {
                ensureEditorSeesWorktrees(projectURL)
                try await IDEProjectOpener.open(projectURL: projectURL, in: ide)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    /// The editor only discovers in-repo worktrees if its repository scan depth
    /// reaches them, and it reads that setting at window load. Writing it just
    /// before launch covers projects whose worktrees predate the setting.
    private func ensureEditorSeesWorktrees(_ projectRoot: URL) {
        do {
            try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: projectRoot)
        } catch {
            NSLog(
                "Canvas Foundry could not update .vscode/settings.json: %@",
                error.localizedDescription
            )
        }
    }

    func openAgentWorktree(_ session: AgentSession, in ide: ProjectIDE) {
        guard let descriptor = session.worktree else { return }
        Task {
            do {
                try await IDEProjectOpener.open(
                    projectURL: descriptor.worktreeURL,
                    in: ide
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    /// Publishes the reviewed branch without exposing the push/preflight steps
    /// as separate product actions. A branch with an existing PR is simply
    /// reconciled back into the agent state.
    func shipPullRequest(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                let preflight = try await pullRequestService.preflight(descriptor)
                if let existing = preflight.existingPullRequest {
                    session.pullRequest = existing
                    return
                }
                guard !preflight.hasUncommittedChanges else {
                    alertState = .message(
                        "Review and commit \(session.name)’s remaining changes before creating the pull request."
                    )
                    return
                }
                session.pullRequest = try await pullRequestService.publishDraft(
                    descriptor,
                    agentName: session.name,
                    testStatus: session.testStatus
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func pushPullRequestUpdates(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                session.pullRequest = try await pullRequestService.pushUpdates(descriptor)
                alertState = .message(
                    "Pushed the latest \(session.name) commits to PR #\(session.pullRequest?.number ?? 0)."
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func openPullRequest(_ session: AgentSession) {
        guard let url = session.pullRequest?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshPullRequest(_ session: AgentSession, reportErrors: Bool = false) {
        guard session.pullRequest != nil,
              let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                let wasMerged = session.pullRequest?.state == .merged
                let refreshed = try await pullRequestService.refresh(descriptor)
                session.pullRequest = refreshed
                // A user or reviewer merging on GitHub ends this branch's work
                // just as much as Foundry's own merge button does.
                if !wasMerged, refreshed.state == .merged, !session.isArchived {
                    await cleanUpMergedSession(session)
                }
            } catch {
                if reportErrors {
                    alertState = .message(error.localizedDescription)
                }
            }
        }
    }

    func refreshAllPullRequests() {
        for session in sessions where session.pullRequest != nil {
            refreshPullRequest(session)
        }
    }

    func markPullRequestReady(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                session.pullRequest = try await pullRequestService.markReady(descriptor)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func syncPullRequestWithBase(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                session.pullRequest = try await pullRequestService.syncWithBase(descriptor)
                refreshGitSummary(session)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func squashMergePullRequest(_ session: AgentSession) {
        guard mergingSessionID == nil,
              let descriptor = session.worktree,
              session.pullRequest?.isReadyToMerge == true else {
            return
        }
        mergingSessionID = session.id
        session.isPublishingPullRequest = true
        Task {
            defer {
                session.isPublishingPullRequest = false
                mergingSessionID = nil
            }
            do {
                let merged = try await pullRequestService.squashMerge(descriptor)
                session.pullRequest = merged
                guard merged.state == .merged else {
                    alertState = .message(
                        "GitHub accepted PR #\(merged.number) for its merge queue. The agent will remain available until GitHub finishes."
                    )
                    return
                }
                await cleanUpMergedSession(session)

                for candidate in sessions where candidate.id != session.id
                    && !candidate.isArchived && candidate.pullRequest?.state == .open {
                    refreshPullRequest(candidate)
                }
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    /// A merged PR ends the branch's life: one branch, one PR, one unit of
    /// work. Reusing the branch after a squash merge would make the next PR
    /// re-show already-merged changes, so the runtime stops and — when the
    /// worktree is clean — the worktree is deleted and the agent archived.
    /// Uncommitted leftovers are never destroyed silently; the agent flips to
    /// "needs you" instead, and deletion stays behind the guarded confirm.
    func cleanUpMergedSession(_ session: AgentSession) async {
        guard let descriptor = session.worktree,
              let pullRequest = session.pullRequest,
              pullRequest.state == .merged else {
            return
        }
        session.runtime?.stop(preservingSessionStatus: true)

        let hasChanges = (try? await worktreeManager.hasUncommittedChanges(descriptor)) ?? true
        guard !hasChanges else {
            session.status = .needsYou("PR merged; uncommitted work remains")
            alertState = .message(
                "PR #\(pullRequest.number) merged, but \(session.name) still has local changes. The agent was preserved so nothing is lost."
            )
            return
        }

        do {
            try await worktreeManager.removeWorktree(descriptor, force: false)
            session.status = .completed
            session.isArchived = true
            if selectedSessionID == session.id {
                select(nil)
            }
            if reviewingSession?.id == session.id {
                reviewingSession = nil
            }
        } catch {
            session.status = .completed
            alertState = .message(
                "PR #\(pullRequest.number) merged, but the agent workspace could not be cleaned up: \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func relaunch(_ session: AgentSession) -> Bool {
        guard session.runtime?.terminalView.process.running != true else {
            alertState = .message("\(session.name) is already running.")
            return false
        }
        guard let descriptor = session.worktree else {
            session.status = .failed("This agent does not have an isolated workspace.")
            return false
        }
        guard FileManager.default.fileExists(atPath: descriptor.worktreeURL.path) else {
            session.status = .failed("The agent workspace no longer exists on disk.")
            return false
        }
        guard ExecutableResolver.resolve(session.provider.launchPlan().executable) != nil else {
            session.status = .failed(
                AgentTerminalError.executableNotFound(session.provider.displayName).localizedDescription
            )
            return false
        }

        do {
            session.runtime = try AgentTerminalRuntime(
                session: session,
                directory: descriptor.worktreeURL,
                resumeConversation: true
            )
            select(session)
            return true
        } catch {
            session.status = .failed(error.localizedDescription)
            return false
        }
    }

    func focus(_ session: AgentSession) {
        guard !session.isArchived else { return }
        select(session)
        centerViewport(on: session)
        refreshGitSummary(session)
    }

    /// Brings an agent's terminal card back into view, restoring it from the
    /// archive first when needed, and parks it in the middle of the canvas.
    func revealTerminal(_ session: AgentSession) {
        if session.isArchived {
            session.isArchived = false
        }
        select(session)
        centerViewport(on: session)
    }

    private func centerViewport(on session: AgentSession) {
        pan = CGSize(
            width: viewportSize.width / 2 - session.position.x * zoom,
            height: viewportSize.height / 2 - session.position.y * zoom
        )
    }

    // MARK: - Command bar

    func planLocalActions(for input: String) async throws -> LocalFoundryActionPlan {
        var handleToSessionID: [String: UUID] = [:]
        let allAgents = sessions.enumerated().map { index, session in
            let handle = "agent_\(index + 1)"
            handleToSessionID[handle] = session.id
            return LocalFoundryAgentContext(
                id: handle,
                name: session.name,
                provider: session.provider.rawValue,
                status: session.status.label,
                isRunning: session.runtime?.terminalView.process.running == true,
                isArchived: session.isArchived,
                changedFileCount: session.gitSummary.changedFileCount,
                commitCount: session.gitSummary.commitCount,
                pullRequestNumber: session.pullRequest?.number
            )
        }
        let selectedHandle = handleToSessionID.first { $0.value == selectedSessionID }?.key
        let relevantAgents = LocalFoundryContextFilter.agents(
            for: input,
            selectedAgentID: selectedHandle,
            from: allAgents
        )
        let context = LocalFoundryWorkspaceContext(
            projectName: projectURL?.lastPathComponent,
            selectedAgentID: selectedHandle,
            agents: relevantAgents,
            recentConversation: recentConversation
        )
        let result = try await localActionPlanner.planWithMetrics(input: input, context: context)
        lastLocalPlannerMetrics = result.metrics
        isLocalPlannerWarm = true
        var resolvedPlan = result.plan
        for index in resolvedPlan.actions.indices {
            guard let handle = resolvedPlan.actions[index].agentID,
                  let sessionID = handleToSessionID[handle] else { continue }
            resolvedPlan.actions[index].agentID = sessionID.uuidString
        }
        return resolvedPlan
    }

    private func warmLocalPlanner() {
        guard localPlannerWarmupTask == nil else { return }
        localPlannerWarmupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localPlannerWarmupTask = nil }
            do {
                try await self.localActionPlanner.warmUp()
                self.isLocalPlannerWarm = true
            } catch {
                self.isLocalPlannerWarm = false
            }
        }
    }

    /// Validates every model-proposed capability against current workspace
    /// state immediately before execution. Invalid IDs and malformed arguments
    /// are ignored rather than guessed.
    @discardableResult
    func run(_ plan: LocalFoundryActionPlan) -> LocalFoundryActionExecution {
        var acknowledgements: [String] = []
        var didPrepareRemoval = false
        var createdAgentCount = 0

        for action in plan.actions {
            switch action.type {
            case .createAgent:
                guard let providerName = action.provider?.lowercased(),
                      let provider = AgentProvider(rawValue: providerName) else { continue }
                let count = action.count ?? 1
                guard (1...WorkspaceCommandParser.maximumAgentsPerCommand).contains(count) else {
                    continue
                }
                guard createdAgentCount + count <= WorkspaceCommandParser.maximumAgentsPerCommand else {
                    continue
                }
                let prompt = action.prompt?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let prompt, !prompt.isEmpty {
                    guard count == 1, createAgent(provider: provider, initialPrompt: prompt) else {
                        continue
                    }
                } else if !createAgents(provider: provider, count: count) {
                    continue
                }
                createdAgentCount += count
                acknowledgements.append(
                    "Opening \(count == 1 ? "one" : String(count)) \(provider.shortName) agent\(count == 1 ? "" : "s") now."
                )

            case .sendPrompt:
                guard let session = session(withModelID: action.agentID),
                      let prompt = action.prompt?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !prompt.isEmpty,
                      run(.sendPrompt(name: session.name, prompt: prompt)) else { continue }
                acknowledgements.append("Sending that to \(session.name).")

            case .focusAgent:
                guard let session = session(withModelID: action.agentID) else { continue }
                revealTerminal(session)
                acknowledgements.append("Bringing \(session.name) into view.")

            case .stopAgent:
                guard let session = session(withModelID: action.agentID),
                      run(.stopAgent(name: session.name)) else { continue }
                acknowledgements.append("Stopping \(session.name) now.")

            case .resumeAgent:
                guard let session = session(withModelID: action.agentID),
                      run(.resumeAgent(name: session.name)) else { continue }
                acknowledgements.append("Resuming \(session.name) now.")

            case .prepareRemoveAgent:
                guard !didPrepareRemoval,
                      let session = session(withModelID: action.agentID) else { continue }
                didPrepareRemoval = true
                prepareConversationRemoval(session)
                acknowledgements.append("Checking \(session.name)’s workspace before removal.")

            case .noAction:
                continue
            }
        }

        let modelResponse = String(
            plan.response
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(200)
        )
        let isInformational = plan.actions.isEmpty
            || plan.actions.allSatisfy { $0.type == .noAction }
        let message = acknowledgements.isEmpty && isInformational
            ? modelResponse
            : acknowledgements.joined(separator: " ")
        return LocalFoundryActionExecution(
            wasHandled: !acknowledgements.isEmpty || (isInformational && !modelResponse.isEmpty),
            message: message
        )
    }

    private func session(withModelID value: String?) -> AgentSession? {
        guard let value, let id = UUID(uuidString: value) else { return nil }
        return sessions.first { $0.id == id }
    }

    func runConversationControl(
        _ control: WorkspaceConversationControl
    ) -> LocalFoundryActionExecution {
        switch control {
        case .confirm, .doThat:
            guard let pending = pendingConversationConfirmation else {
                return LocalFoundryActionExecution(
                    wasHandled: true,
                    message: "There’s nothing waiting for confirmation."
                )
            }
            pendingConversationConfirmation = nil
            switch pending.action {
            case .removeAgent(let request):
                deleteWorktree(request)
                return LocalFoundryActionExecution(
                    wasHandled: true,
                    message: "Removing \(request.agentName) now."
                )
            }

        case .cancel:
            guard pendingConversationConfirmation != nil else {
                return LocalFoundryActionExecution(
                    wasHandled: true,
                    message: "There’s nothing waiting to cancel."
                )
            }
            pendingConversationConfirmation = nil
            return LocalFoundryActionExecution(
                wasHandled: true,
                message: "Cancelled. Nothing was changed."
            )
        }
    }

    func rememberConversation(
        userRequest: String,
        assistantResult: String,
        referencedAgentIDs: [String],
        didExecuteAction: Bool
    ) {
        let referencedNames = referencedAgentIDs.compactMap { value -> String? in
            guard let id = UUID(uuidString: value) else { return nil }
            return sessions.first(where: { $0.id == id })?.name
        }
        recentConversation.append(
            LocalFoundryConversationTurn(
                userRequest: String(userRequest.prefix(500)),
                assistantResult: String(assistantResult.prefix(300)),
                referencedAgentNames: Array(Set(referencedNames)).sorted(),
                didExecuteAction: didExecuteAction
            )
        )
        if recentConversation.count > Self.conversationHistoryLimit {
            recentConversation.removeFirst(
                recentConversation.count - Self.conversationHistoryLimit
            )
        }
    }

    func rememberConversation(
        userRequest: String,
        assistantResult: String,
        commandPlan: WorkspaceCommandPlan
    ) {
        let names = commandPlan.commands.compactMap { command -> String? in
            switch command {
            case .focusAgent(let name), .stopAgent(let name), .resumeAgent(let name):
                return name
            case .sendPrompt(let name, _):
                return name
            default:
                return nil
            }
        }
        let ids = names.compactMap { session(named: $0)?.id.uuidString }
        rememberConversation(
            userRequest: userRequest,
            assistantResult: assistantResult,
            referencedAgentIDs: ids,
            didExecuteAction: !commandPlan.commands.isEmpty
        )
    }

    private func prepareConversationRemoval(_ session: AgentSession) {
        // A newly requested destructive action supersedes any older one. This
        // prevents a late "confirm" from approving the wrong removal while the
        // worktree status check is in flight.
        pendingConversationConfirmation = nil
        guard let descriptor = session.worktree else {
            pendingConversationConfirmation = WorkspaceConversationConfirmation(
                action: .removeAgent(
                    WorktreeDeletionRequest(
                        sessionID: session.id,
                        agentName: session.name,
                        hasUncommittedChanges: false
                    )
                )
            )
            return
        }

        Task {
            do {
                let hasChanges = try await worktreeManager.hasUncommittedChanges(descriptor)
                guard sessions.contains(where: { $0.id == session.id }) else { return }
                pendingConversationConfirmation = WorkspaceConversationConfirmation(
                    action: .removeAgent(
                        WorktreeDeletionRequest(
                            sessionID: session.id,
                            agentName: session.name,
                            hasUncommittedChanges: hasChanges
                        )
                    )
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    /// Runs a parsed line. Returns the plan so the caller can echo what happened.
    @discardableResult
    func run(_ plan: WorkspaceCommandPlan) -> WorkspaceCommandPlan {
        var executed = plan
        executed.commands = []
        for command in plan.commands {
            if run(command) {
                executed.commands.append(command)
            }
        }
        return executed
    }

    @discardableResult
    func run(_ command: WorkspaceCommand) -> Bool {
        switch command {
        case .createAgents(let provider, let count):
            return createAgents(provider: provider, count: count)
        case .createAgentWithPrompt(let provider, let prompt):
            return createAgent(provider: provider, initialPrompt: prompt)
        case .focusAgent(let name):
            guard let session = sessions.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                alertState = .message("No agent named “\(name)” is on this canvas.")
                return false
            }
            revealTerminal(session)
            return true
        case .sendPrompt(let name, let prompt):
            guard let session = sessions.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                alertState = .message("No agent named “\(name)” is on this canvas.")
                return false
            }
            guard let runtime = session.runtime else {
                alertState = .message(
                    "\(session.name) isn't running. Relaunch the agent before sending it a prompt."
                )
                return false
            }
            do {
                try runtime.submitPrompt(prompt)
                revealTerminal(session)
                return true
            } catch {
                alertState = .message(error.localizedDescription)
                return false
            }
        case .stopAgent(let name):
            guard let session = session(named: name) else {
                alertState = .message("No agent named “\(name)” is on this canvas.")
                return false
            }
            guard session.runtime?.stop() == true else {
                alertState = .message("\(session.name) is already stopped.")
                return false
            }
            revealTerminal(session)
            return true
        case .resumeAgent(let name):
            guard let session = session(named: name) else {
                alertState = .message("No agent named “\(name)” is on this canvas.")
                return false
            }
            let resumed = relaunch(session)
            if resumed { revealTerminal(session) }
            return resumed
        case .setBackground(let background):
            canvasBackground = background
            return true
        case .selectTool(let tool):
            activeTool = tool
            return true
        case .clearDrawings:
            clearAnnotations()
            return true
        case .resetView:
            resetView()
            return true
        }
    }

    private func session(named name: String) -> AgentSession? {
        sessions.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    // MARK: - Canvas annotations

    func addAnnotation(_ annotation: CanvasAnnotation) {
        guard !annotation.points.isEmpty else { return }
        switch annotation.kind {
        case .text, .freehand:
            // Valid even as a single point: a note anchor, or a dotted tap.
            break
        case .rectangle, .ellipse, .line, .arrow:
            // A click without a drag yields two near-identical corners, which
            // would leave an invisible shape on the canvas.
            let box = annotation.boundingBox
            guard box.width > 2 || box.height > 2 else { return }
        }
        recordAnnotationHistory()
        annotations.append(annotation)
        schedulePersistence()
    }

    func updateAnnotationText(_ id: UUID, to text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty note would be an invisible, un-erasable hit box.
        guard !trimmed.isEmpty else {
            annotations.remove(at: index)
            schedulePersistence()
            return
        }
        annotations[index].text = trimmed
        schedulePersistence()
    }

    /// Removes every annotation touching `point`. Returns true if anything went.
    @discardableResult
    func eraseAnnotations(near point: CGPoint, tolerance: CGFloat) -> Bool {
        let survivors = annotations.filter { !$0.hitTest(point, tolerance: tolerance) }
        guard survivors.count != annotations.count else { return false }
        recordAnnotationHistory()
        annotations = survivors
        pruneAnnotationSelection()
        schedulePersistence()
        return true
    }

    func undoAnnotationEdit() {
        guard let previous = annotationHistory.popLast() else { return }
        annotations = previous
        pruneAnnotationSelection()
        schedulePersistence()
    }

    /// Drops ids that no longer exist, so a stale selection can't be moved or
    /// grouped after an undo or erase.
    private func pruneAnnotationSelection() {
        let living = Set(annotations.map(\.id))
        selectedAnnotationIDs.formIntersection(living)
    }

    var canUndoAnnotationEdit: Bool { !annotationHistory.isEmpty }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        recordAnnotationHistory()
        annotations = []
        selectedAnnotationIDs = []
        schedulePersistence()
    }

    // MARK: - Annotation selection

    /// Topmost annotation under `point`, matching the draw order.
    func annotation(at point: CGPoint, tolerance: CGFloat) -> CanvasAnnotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    /// Grows a set of ids to include every sibling of any grouped member.
    func expandingGroups(of ids: Set<UUID>) -> Set<UUID> {
        let groupIDs = Set(annotations.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groupIDs.isEmpty else { return ids }
        return ids.union(
            annotations
                .filter { $0.groupID.map(groupIDs.contains) ?? false }
                .map(\.id)
        )
    }

    func selectAnnotation(_ id: UUID, additive: Bool) {
        let target = expandingGroups(of: [id])
        if additive {
            // Toggling a group toggles all of it.
            if target.isSubset(of: selectedAnnotationIDs) {
                selectedAnnotationIDs.subtract(target)
            } else {
                selectedAnnotationIDs.formUnion(target)
            }
        } else {
            selectedAnnotationIDs = target
        }
    }

    func selectAnnotations(in rect: CGRect, additive: Bool) {
        let hits = Set(
            annotations
                .filter { rect.intersects($0.boundingBox.insetBy(dx: -1, dy: -1)) }
                .map(\.id)
        )
        let target = expandingGroups(of: hits)
        selectedAnnotationIDs = additive ? selectedAnnotationIDs.union(target) : target
    }

    func selectAllAnnotations() {
        selectedAnnotationIDs = Set(annotations.map(\.id))
    }

    func clearAnnotationSelection() {
        selectedAnnotationIDs = []
    }

    func deleteSelectedAnnotations() {
        guard !selectedAnnotationIDs.isEmpty else { return }
        recordAnnotationHistory()
        annotations.removeAll { selectedAnnotationIDs.contains($0.id) }
        selectedAnnotationIDs = []
        schedulePersistence()
    }

    var canGroupSelection: Bool {
        // Two distinct items are needed before grouping means anything.
        selectedAnnotationIDs.count > 1
    }

    var canUngroupSelection: Bool {
        annotations.contains { selectedAnnotationIDs.contains($0.id) && $0.groupID != nil }
    }

    func groupSelection() {
        guard canGroupSelection else { return }
        recordAnnotationHistory()
        let newGroupID = UUID()
        for index in annotations.indices where selectedAnnotationIDs.contains(annotations[index].id) {
            annotations[index].groupID = newGroupID
        }
        schedulePersistence()
    }

    func ungroupSelection() {
        guard canUngroupSelection else { return }
        recordAnnotationHistory()
        for index in annotations.indices where selectedAnnotationIDs.contains(annotations[index].id) {
            annotations[index].groupID = nil
        }
        schedulePersistence()
    }

    // MARK: - Moving a selection

    func beginSelectionDrag() {
        guard !selectedAnnotationIDs.isEmpty else { return }
        recordAnnotationHistory()
        selectionDragOrigin = Dictionary(
            uniqueKeysWithValues: annotations
                .filter { selectedAnnotationIDs.contains($0.id) }
                .map { ($0.id, $0.points) }
        )
    }

    func updateSelectionDrag(translation: CGSize) {
        guard !selectionDragOrigin.isEmpty else { return }
        for index in annotations.indices {
            guard let origin = selectionDragOrigin[annotations[index].id] else { continue }
            annotations[index].points = origin.map {
                CGPoint(x: $0.x + translation.width, y: $0.y + translation.height)
            }
        }
    }

    func endSelectionDrag() {
        guard !selectionDragOrigin.isEmpty else { return }
        selectionDragOrigin = [:]
        schedulePersistence()
    }

    /// Combined bounding box of the current selection, in world space.
    var selectionBounds: CGRect? {
        let selected = annotations.filter { selectedAnnotationIDs.contains($0.id) }
        guard let first = selected.first else { return nil }
        return selected.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
    }

    private func recordAnnotationHistory() {
        annotationHistory.append(annotations)
        if annotationHistory.count > Self.annotationHistoryLimit {
            annotationHistory.removeFirst(annotationHistory.count - Self.annotationHistoryLimit)
        }
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
            alertState = .deleteWorktree(
                WorktreeDeletionRequest(
                    sessionID: session.id,
                    agentName: session.name,
                    hasUncommittedChanges: false
                )
            )
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
        if pendingConversationConfirmation?.sessionID == request.sessionID {
            pendingConversationConfirmation = nil
        }
        guard let session = sessions.first(where: { $0.id == request.sessionID }) else { return }

        session.runtime?.stop()
        guard let descriptor = session.worktree else {
            sessions.removeAll { $0.id == request.sessionID }
            if selectedSessionID == request.sessionID { select(nil) }
            return
        }
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
        pendingConversationConfirmation = nil
        recentConversation = []
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
        // One selection domain at a time, so Command-Delete can't remove ink
        // while the user is working inside a terminal card.
        if session != nil { selectedAnnotationIDs = [] }
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

    func panBy(_ delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    /// Zooms about a point on screen, keeping whatever sits under the cursor
    /// exactly where it is — otherwise scroll-zoom drifts the canvas away from
    /// what the user is pointing at.
    func zoom(by factor: CGFloat, anchoredAt screenPoint: CGPoint) {
        let newZoom = min(1.8, max(0.45, zoom * factor))
        guard abs(newZoom - zoom) > 0.0001 else { return }

        let anchor = CGPoint(
            x: (screenPoint.x - pan.width) / zoom,
            y: (screenPoint.y - pan.height) / zoom
        )
        zoom = newZoom
        pan = CGSize(
            width: screenPoint.x - anchor.x * newZoom,
            height: screenPoint.y - anchor.y * newZoom
        )
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

        recentProjectURLs = (snapshot.recentProjectPaths ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        // Restored ahead of the project guard so the backdrop survives even when
        // the saved project is gone.
        canvasBackground = snapshot.canvasBackground
            .flatMap(CanvasBackground.init(rawValue:)) ?? .fallback
        annotations = (snapshot.annotations ?? []).compactMap(CanvasAnnotation.init(persisted:))

        guard let projectPath = snapshot.projectPath,
              FileManager.default.fileExists(atPath: projectPath) else {
            return
        }

        let restoredProjectURL = URL(
            fileURLWithPath: projectPath,
            isDirectory: true
        ).standardizedFileURL
        projectURL = restoredProjectURL
        recentProjectURLs.removeAll { $0 == restoredProjectURL }
        recentProjectURLs.insert(restoredProjectURL, at: 0)
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
        if let pullRequest = stored.pullRequest {
            session.pullRequest = AgentPullRequest(
                number: pullRequest.number,
                url: pullRequest.url,
                state: PullRequestState(rawValue: pullRequest.state) ?? .unknown,
                isDraft: pullRequest.isDraft,
                headBranch: pullRequest.headBranch,
                baseBranch: pullRequest.baseBranch,
                updatedAt: pullRequest.updatedAt,
                title: pullRequest.title ?? "",
                mergeability: PullRequestMergeability(
                    rawValue: pullRequest.mergeability ?? ""
                ) ?? .unknown,
                mergeStateStatus: pullRequest.mergeStateStatus ?? "UNKNOWN",
                checksStatus: PullRequestChecksStatus(
                    rawValue: pullRequest.checksStatus ?? ""
                ) ?? .noChecks,
                reviewDecision: PullRequestReviewDecision(
                    rawValue: pullRequest.reviewDecision ?? ""
                ) ?? .none,
                headCommitOID: pullRequest.headCommitOID,
                changedFiles: pullRequest.changedFiles ?? 0,
                additions: pullRequest.additions ?? 0,
                deletions: pullRequest.deletions ?? 0,
                checks: (pullRequest.checks ?? []).map {
                    PullRequestCheck(
                        name: $0.name,
                        workflow: $0.workflow,
                        state: $0.state,
                        bucket: $0.bucket,
                        link: $0.link
                    )
                }
            )
        }
        if let worktree = stored.worktree {
            session.worktree = WorktreeDescriptor(
                projectRoot: URL(fileURLWithPath: worktree.projectRootPath, isDirectory: true),
                worktreeURL: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                branchName: worktree.branchName,
                baseRevision: worktree.baseRevision
            )
            session.status = FileManager.default.fileExists(atPath: worktree.worktreePath)
                ? .stopped
                : (session.isArchived && session.pullRequest?.state == .merged
                    ? .completed
                    : .failed("The agent workspace no longer exists on disk."))
        } else {
            session.status = .failed("This agent does not have an isolated workspace.")
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
                    },
                    pullRequest: session.pullRequest.map { pullRequest in
                        PersistedPullRequest(
                            number: pullRequest.number,
                            url: pullRequest.url,
                            state: pullRequest.state.rawValue,
                            isDraft: pullRequest.isDraft,
                            headBranch: pullRequest.headBranch,
                            baseBranch: pullRequest.baseBranch,
                            updatedAt: pullRequest.updatedAt,
                            title: pullRequest.title,
                            mergeability: pullRequest.mergeability.rawValue,
                            mergeStateStatus: pullRequest.mergeStateStatus,
                            checksStatus: pullRequest.checksStatus.rawValue,
                            reviewDecision: pullRequest.reviewDecision.rawValue,
                            headCommitOID: pullRequest.headCommitOID,
                            changedFiles: pullRequest.changedFiles,
                            additions: pullRequest.additions,
                            deletions: pullRequest.deletions,
                            checks: pullRequest.checks.map {
                                PersistedPullRequestCheck(
                                    name: $0.name,
                                    workflow: $0.workflow,
                                    state: $0.state,
                                    bucket: $0.bucket,
                                    link: $0.link
                                )
                            }
                        )
                    }
                )
            },
            recentProjectPaths: recentProjectURLs.map(\.path),
            canvasBackground: canvasBackground.rawValue,
            annotations: annotations.map { annotation in
                PersistedAnnotation(
                    id: annotation.id,
                    kind: annotation.kind.rawValue,
                    pointsX: annotation.points.map { Double($0.x) },
                    pointsY: annotation.points.map { Double($0.y) },
                    color: annotation.color.rawValue,
                    lineWidth: Double(annotation.lineWidth),
                    text: annotation.text.isEmpty ? nil : annotation.text,
                    groupID: annotation.groupID
                )
            }
        )
    }

    private func rememberProject(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        recentProjectURLs.removeAll { $0.standardizedFileURL == normalizedURL }
        recentProjectURLs.insert(normalizedURL, at: 0)
        if recentProjectURLs.count > 8 {
            recentProjectURLs.removeLast(recentProjectURLs.count - 8)
        }
        schedulePersistence()
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
