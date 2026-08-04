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
    case publishPullRequest(PullRequestPublishRequest)

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
        case .publishPullRequest(let request):
            "publish-pr-\(request.sessionID)-\(request.commitCount)-\(request.hasUncommittedChanges)"
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

struct PullRequestPublishRequest: Equatable {
    let sessionID: UUID
    let agentName: String
    let commitCount: Int
    let hasUncommittedChanges: Bool
    let baseBranch: String
    let suggestedTitle: String
    let testStatus: AgentTestStatus
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var projectURL: URL? {
        didSet {
            if let projectURL, !isRestoring {
                rememberProject(projectURL)
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
    @Published var reviewQueueNotice: String?
    @Published private(set) var mergingSessionID: UUID?
    @Published private(set) var recentProjectURLs: [URL] = []

    private let worktreeManager: GitWorktreeManager
    private let projectManager: GitProjectManager
    private let persistence: WorkspacePersistence
    let gitReviewService: GitReviewService
    private let pullRequestService: GitHubPullRequestService
    private var viewportSize = CGSize(width: 1200, height: 760)
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var isRestoring = true
    /// Snapshots of `annotations` taken before each edit, newest last.
    private var annotationHistory: [[CanvasAnnotation]] = []
    private static let annotationHistoryLimit = 60
    /// Positions captured when a move begins, so every frame of the drag is
    /// applied to the original geometry instead of compounding deltas.
    private var selectionDragOrigin: [UUID: [CGPoint]] = [:]

    init(
        worktreeManager: GitWorktreeManager = GitWorktreeManager(),
        projectManager: GitProjectManager = GitProjectManager(),
        persistence: WorkspacePersistence = WorkspacePersistence(),
        gitReviewService: GitReviewService = GitReviewService(),
        pullRequestService: GitHubPullRequestService = GitHubPullRequestService()
    ) {
        self.worktreeManager = worktreeManager
        self.projectManager = projectManager
        self.persistence = persistence
        self.gitReviewService = gitReviewService
        self.pullRequestService = pullRequestService
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

    var reviewQueueSessions: [AgentSession] {
        sessions
            .filter { $0.pullRequest != nil }
            .sorted { lhs, rhs in
                let lhsOpen = lhs.pullRequest?.state == .open
                let rhsOpen = rhs.pullRequest?.state == .open
                if lhsOpen != rhsOpen { return lhsOpen }
                return lhs.createdAt < rhs.createdAt
            }
    }

    var openPullRequestCount: Int {
        sessions.filter { $0.pullRequest?.state == .open }.count
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
    func createAgents(provider: AgentProvider, count: Int) {
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

        let staged = (0..<max(1, count)).map { _ in stageSession(provider: provider) }
        Task {
            for session in staged {
                await activateSession(session, projectURL: projectURL)
            }
        }
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

    private func activateSession(_ session: AgentSession, projectURL: URL) async {
        do {
            let descriptor = try await worktreeManager.createWorktree(
                for: projectURL,
                sessionID: session.id,
                title: "\(session.name)-\(session.provider.rawValue)"
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
        guard let descriptor = session.worktree else { return }
        Task {
            do {
                // Opened as one workspace holding the project and the agent's
                // branch, so the editor's source control panel can stage, commit
                // and open a PR on the branch without losing project context.
                let workspaceURL = try IDEProjectOpener.makeMultiRootWorkspace(
                    projectURL: descriptor.projectRoot,
                    folders: [
                        .init(
                            name: "Main — \(descriptor.projectRoot.lastPathComponent)",
                            url: descriptor.projectRoot
                        ),
                        .init(
                            name: "\(session.name) — \(session.provider.shortName)",
                            url: descriptor.worktreeURL
                        )
                    ],
                    variant: String(session.id.uuidString.lowercased().prefix(8))
                )
                try await IDEProjectOpener.open(projectURL: workspaceURL, in: ide)
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func preparePullRequest(_ session: AgentSession) {
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
                    openPullRequest(session)
                    return
                }
                alertState = .publishPullRequest(
                    PullRequestPublishRequest(
                        sessionID: session.id,
                        agentName: session.name,
                        commitCount: preflight.commitCount,
                        hasUncommittedChanges: preflight.hasUncommittedChanges,
                        baseBranch: preflight.baseBranch,
                        suggestedTitle: preflight.suggestedTitle,
                        testStatus: session.testStatus
                    )
                )
            } catch {
                alertState = .message(error.localizedDescription)
            }
        }
    }

    func publishPullRequest(_ request: PullRequestPublishRequest) {
        alertState = nil
        guard let session = sessions.first(where: { $0.id == request.sessionID }),
              let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                let pullRequest = try await pullRequestService.publishDraft(
                    descriptor,
                    agentName: session.name,
                    testStatus: session.testStatus
                )
                session.pullRequest = pullRequest
                NSWorkspace.shared.open(pullRequest.url)
                alertState = .message(
                    "Published draft PR #\(pullRequest.number) against \(pullRequest.baseBranch)."
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
                session.pullRequest = try await pullRequestService.refresh(descriptor)
            } catch {
                if reportErrors {
                    reviewQueueNotice = error.localizedDescription
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
        reviewQueueNotice = nil
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                session.pullRequest = try await pullRequestService.markReady(descriptor)
                reviewQueueNotice = "PR #\(session.pullRequest?.number ?? 0) is ready for review."
            } catch {
                reviewQueueNotice = error.localizedDescription
            }
        }
    }

    func syncPullRequestWithBase(_ session: AgentSession) {
        guard let descriptor = session.worktree,
              !session.isPublishingPullRequest else {
            return
        }
        reviewQueueNotice = nil
        session.isPublishingPullRequest = true
        Task {
            defer { session.isPublishingPullRequest = false }
            do {
                session.pullRequest = try await pullRequestService.syncWithBase(descriptor)
                refreshGitSummary(session)
                reviewQueueNotice = "Synced \(session.name) with \(session.pullRequest?.baseBranch ?? "the base branch")."
            } catch {
                reviewQueueNotice = error.localizedDescription
            }
        }
    }

    func squashMergePullRequest(_ session: AgentSession) {
        guard mergingSessionID == nil,
              let descriptor = session.worktree,
              session.pullRequest?.isReadyToMerge == true else {
            return
        }
        reviewQueueNotice = nil
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
                    reviewQueueNotice = "GitHub accepted PR #\(merged.number) for merging, but it is still open. The agent and worktree were preserved while GitHub finishes its merge queue."
                    return
                }
                session.runtime?.stop(preservingSessionStatus: true)

                let hasChanges = try await worktreeManager.hasUncommittedChanges(descriptor)
                if hasChanges {
                    session.status = .needsYou("PR merged; uncommitted work remains")
                    reviewQueueNotice = "Merged PR #\(merged.number). \(session.name)’s worktree was preserved because it still has uncommitted changes."
                } else {
                    do {
                        try await worktreeManager.removeWorktree(descriptor, force: false)
                        session.status = .completed
                        session.isArchived = true
                        if selectedSessionID == session.id {
                            select(nil)
                        }
                        reviewQueueNotice = "Merged PR #\(merged.number) and archived \(session.name). The Git branch was preserved."
                    } catch {
                        session.status = .completed
                        reviewQueueNotice = "Merged PR #\(merged.number), but the worktree could not be removed: \(error.localizedDescription)"
                    }
                }

                for candidate in sessions where candidate.id != session.id
                    && !candidate.isArchived && candidate.pullRequest?.state == .open {
                    refreshPullRequest(candidate)
                }
            } catch {
                reviewQueueNotice = error.localizedDescription
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

    /// Runs a parsed line. Returns the plan so the caller can echo what happened.
    @discardableResult
    func run(_ plan: WorkspaceCommandPlan) -> WorkspaceCommandPlan {
        for command in plan.commands {
            run(command)
        }
        return plan
    }

    func run(_ command: WorkspaceCommand) {
        switch command {
        case .createAgents(let provider, let count):
            createAgents(provider: provider, count: count)
        case .focusAgent(let name):
            guard let session = sessions.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                alertState = .message("No agent named “\(name)” is on this canvas.")
                return
            }
            revealTerminal(session)
        case .setBackground(let background):
            canvasBackground = background
        case .selectTool(let tool):
            activeTool = tool
        case .clearDrawings:
            clearAnnotations()
        case .resetView:
            resetView()
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
                    : .failed("The agent worktree no longer exists on disk."))
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
