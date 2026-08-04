import XCTest
import SwiftUI
@testable import CanvasFoundry

final class CanvasFoundryTests: XCTestCase {
    func testProviderLaunchPlansOpenInteractiveCLIs() {
        XCTAssertEqual(
            AgentProvider.claude.launchPlan(),
            AgentLaunchPlan(executable: "claude", arguments: [])
        )
        XCTAssertEqual(
            AgentProvider.codex.launchPlan(),
            AgentLaunchPlan(executable: "codex", arguments: [])
        )
    }

    func testBranchSlugIsSafeAndBounded() {
        let slug = GitWorktreeManager.slug("  Build OAuth 2.0 / Login!!! with a deliberately very long title  ")

        XCTAssertEqual(slug, "build-oauth-2-0-login-with-a-deliber")
        XCTAssertLessThanOrEqual(slug.count, 36)
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains(" "))
    }

    func testRepositoryHashIsStable() {
        XCTAssertEqual(
            GitWorktreeManager.fnv1a("/tmp/example"),
            GitWorktreeManager.fnv1a("/tmp/example")
        )
        XCTAssertNotEqual(
            GitWorktreeManager.fnv1a("/tmp/example"),
            GitWorktreeManager.fnv1a("/tmp/another")
        )
    }

    func testExecutableResolverFindsAKnownCLI() {
        let result = ExecutableResolver.resolve(
            "sh",
            in: [URL(fileURLWithPath: "/bin", isDirectory: true)]
        )

        XCTAssertEqual(result?.path, "/bin/sh")
    }

    func testGeneratedIDEWorkspaceContainsDistinctLabeledRoots() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canvas Foundry IDE-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let project = scratch.appendingPathComponent("Main Project", isDirectory: true)
        let ada = scratch.appendingPathComponent("Ada Worktree", isDirectory: true)
        let grace = scratch.appendingPathComponent("Grace Worktree", isDirectory: true)
        let storage = scratch.appendingPathComponent("Generated Workspaces", isDirectory: true)
        for directory in [project, ada, grace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let workspaceURL = try IDEProjectOpener.makeMultiRootWorkspace(
            projectURL: project,
            folders: [
                .init(name: "Main — Main Project", url: project),
                .init(name: "Ada — Claude", url: ada),
                .init(name: "Grace — Codex", url: grace),
                .init(name: "Duplicate Ada", url: ada)
            ],
            storageRoot: storage
        )

        XCTAssertEqual(workspaceURL.pathExtension, "code-workspace")
        XCTAssertEqual(workspaceURL.deletingLastPathComponent(), storage)

        let data = try Data(contentsOf: workspaceURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let folders = try XCTUnwrap(json["folders"] as? [[String: String]])
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(folders.compactMap { $0["name"] }, [
            "Main — Main Project", "Ada — Claude", "Grace — Codex"
        ])
        XCTAssertEqual(folders.compactMap { $0["path"] }, [
            project.path, ada.path, grace.path
        ])
    }

    func testCanvasPlacementAvoidsExistingTerminalFrames() {
        let itemSize = CGSize(width: 520, height: 360)
        let firstCenter = CanvasPlacementEngine.nextCenter(
            existingRects: [],
            viewportSize: CGSize(width: 1400, height: 800),
            itemSize: itemSize
        )
        let firstRect = CGRect(
            x: firstCenter.x - itemSize.width / 2,
            y: firstCenter.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )
        let secondCenter = CanvasPlacementEngine.nextCenter(
            existingRects: [firstRect],
            viewportSize: CGSize(width: 1400, height: 800),
            itemSize: itemSize
        )
        let secondRect = CGRect(
            x: secondCenter.x - itemSize.width / 2,
            y: secondCenter.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )

        XCTAssertFalse(firstRect.intersects(secondRect))
        XCTAssertNotEqual(firstCenter, secondCenter)
    }

    func testAgentNamesAreUniqueAndFallBackAfterCallSignsAreUsed() {
        let firstName = AgentNameGenerator.nextName(existingNames: [])
        let secondName = AgentNameGenerator.nextName(existingNames: [firstName])

        XCTAssertEqual(firstName, "Ada")
        XCTAssertEqual(secondName, "Grace")
        XCTAssertNotEqual(firstName, secondName)

        let usedNames = Set([
            "Ada", "Grace", "Alan", "Margaret", "Linus", "Katherine",
            "Dennis", "Barbara", "Ken", "Radia", "Edsger", "Frances"
        ])
        XCTAssertEqual(
            AgentNameGenerator.nextName(existingNames: usedNames),
            "Agent 13"
        )
    }

    @MainActor
    func testWorkspaceRestoresAgentLayoutWithoutLaunchingAProcess() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let sessionID = UUID()
        let persistence = WorkspacePersistence(
            fileURL: scratch.appendingPathComponent("workspace.json")
        )
        let sourceModel = WorkspaceModel(persistence: persistence)
        sourceModel.projectURL = project
        sourceModel.zoom = 1.25
        sourceModel.pan = CGSize(width: 240, height: 160)

        let sourceSession = AgentSession(
            id: sessionID,
            provider: .codex,
            name: "Grace",
            position: CGPoint(x: 510, y: 420)
        )
        sourceSession.size = CGSize(width: 680, height: 440)
        sourceSession.worktree = WorktreeDescriptor(
            projectRoot: project,
            worktreeURL: worktree,
            branchName: "canvas/grace-codex-12345678",
            baseRevision: "deadbeef"
        )
        let pullRequestDate = Date(timeIntervalSince1970: 1_700_000_000)
        sourceSession.pullRequest = AgentPullRequest(
            number: 42,
            url: URL(string: "https://github.com/example/project/pull/42")!,
            state: .open,
            isDraft: true,
            headBranch: "canvas/grace-codex-12345678",
            baseBranch: "main",
            updatedAt: pullRequestDate
        )
        sourceModel.sessions = [sourceSession]
        sourceModel.select(sourceSession)
        sourceModel.persistWorkspace()

        let model = WorkspaceModel(persistence: persistence)

        XCTAssertEqual(model.projectURL?.standardizedFileURL, project.standardizedFileURL)
        XCTAssertEqual(model.zoom, 1.25)
        XCTAssertEqual(model.pan, CGSize(width: 240, height: 160))
        XCTAssertEqual(model.selectedSessionID, sessionID)
        XCTAssertEqual(model.sessions.count, 1)

        let restored = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(restored.name, "Grace")
        XCTAssertEqual(restored.provider, .codex)
        XCTAssertEqual(restored.position, CGPoint(x: 510, y: 420))
        XCTAssertEqual(restored.size, CGSize(width: 680, height: 440))
        XCTAssertEqual(restored.worktree?.branchName, "canvas/grace-codex-12345678")
        XCTAssertEqual(restored.worktree?.baseRevision, "deadbeef")
        XCTAssertEqual(restored.pullRequest?.number, 42)
        XCTAssertEqual(restored.pullRequest?.state, .open)
        XCTAssertEqual(restored.pullRequest?.isDraft, true)
        XCTAssertEqual(restored.pullRequest?.updatedAt, pullRequestDate)
        XCTAssertEqual(restored.status, .stopped)
        XCTAssertTrue(restored.isSelected)
        XCTAssertNil(restored.runtime)
    }

    @MainActor
    func testFleetRenameArchiveAndRestoreLifecycle() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryFleet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let persistence = WorkspacePersistence(
            fileURL: scratch.appendingPathComponent("workspace.json")
        )
        let model = WorkspaceModel(persistence: persistence)
        model.projectURL = scratch

        let ada = AgentSession(provider: .claude, name: "Ada", position: .zero)
        let grace = AgentSession(provider: .codex, name: "Grace", position: .zero)
        ada.status = .stopped
        grace.status = .stopped
        model.sessions = [ada, grace]

        model.rename(grace, to: "Ada")
        XCTAssertEqual(grace.name, "Ada 2")

        model.archive(ada)
        XCTAssertTrue(ada.isArchived)
        XCTAssertEqual(model.visibleSessions.map(\.id), [grace.id])

        model.restore(ada)
        XCTAssertFalse(ada.isArchived)
        XCTAssertEqual(model.selectedSessionID, ada.id)
        XCTAssertEqual(model.visibleSessions.count, 2)

        model.archive(ada)
        model.persistWorkspace()
        let restoredModel = WorkspaceModel(persistence: persistence)
        XCTAssertTrue(try XCTUnwrap(restoredModel.sessions.first { $0.id == ada.id }).isArchived)
        XCTAssertFalse(restoredModel.visibleSessions.contains { $0.id == ada.id })

        let nextProject = scratch.appendingPathComponent("next-project", isDirectory: true)
        try FileManager.default.createDirectory(at: nextProject, withIntermediateDirectories: true)
        restoredModel.switchProject(
            ProjectSwitchRequest(
                projectURL: nextProject,
                existingAgentCount: restoredModel.sessions.count
            )
        )
        XCTAssertEqual(restoredModel.projectURL, nextProject)
        XCTAssertTrue(restoredModel.sessions.isEmpty)
        XCTAssertNil(restoredModel.selectedSessionID)
    }

    @MainActor
    func testInteractiveTerminalKeepsAgentNameWhenShellSetsATitle() async throws {
        let session = AgentSession(
            provider: .claude,
            name: "Ada",
            position: .zero
        )
        let runtime = try AgentTerminalRuntime(
            session: session,
            directory: FileManager.default.temporaryDirectory,
            executableOverride: URL(fileURLWithPath: "/bin/cat"),
            argumentsOverride: []
        )

        XCTAssertTrue(runtime.terminalView.process.running)
        XCTAssertEqual(session.status, .working)

        runtime.setTerminalTitle(
            source: runtime.terminalView,
            title: "claude — project/worktree"
        )
        await Task.yield()

        XCTAssertEqual(session.name, "Ada")
        XCTAssertEqual(session.terminalTitle, "claude — project/worktree")

        runtime.stop()
        XCTAssertEqual(session.status, .stopped)
    }

    func testCreatesARealIsolatedGitWorktree() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        let worktreeStorage = scratch.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let initResult = try await shell.run(
            executableURL: git,
            arguments: ["init", "-b", "main"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initResult.exitCode, 0)

        let commitResult = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(commitResult.exitCode, 0, commitResult.standardError)

        let manager = GitWorktreeManager(storageRoot: worktreeStorage)
        let descriptor = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
            title: "Implement settings"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        XCTAssertEqual(descriptor.branchName, "canvas/implement-settings-12345678")
        XCTAssertNotNil(descriptor.baseRevision)

        let branchResult = try await shell.run(
            executableURL: git,
            arguments: ["branch", "--show-current"],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(
            branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptor.branchName
        )
    }

    func testGitReviewMergeAndGuardedWorktreeRemoval() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        let worktreeStorage = scratch.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let initResult = try await shell.run(
            executableURL: git,
            arguments: ["init", "-b", "main"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initResult.exitCode, 0)
        let initialCommit = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initialCommit.exitCode, 0, initialCommit.standardError)

        let manager = GitWorktreeManager(storageRoot: worktreeStorage)
        let descriptor = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Grace Codex"
        )

        try Data("reviewed feature\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("feature.txt")
        )
        let featureCommit = try await shell.run(
            executableURL: git,
            arguments: [
                "add", "feature.txt"
            ],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(featureCommit.exitCode, 0, featureCommit.standardError)
        let commitResult = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Grace",
                "-c", "user.email=grace@canvas.invalid",
                "commit", "-m", "Add reviewed feature"
            ],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(commitResult.exitCode, 0, commitResult.standardError)
        try Data("uncommitted note\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("notes.txt")
        )

        let reviewService = GitReviewService()
        let review = try await reviewService.inspect(descriptor)
        XCTAssertEqual(Set(review.files.map(\.path)), ["feature.txt", "notes.txt"])
        XCTAssertEqual(review.commits.count, 1)
        XCTAssertEqual(review.commits.first?.subject, "Add reviewed feature")
        XCTAssertTrue(review.diff.contains("reviewed feature"))
        XCTAssertTrue(review.diff.contains("notes.txt"))

        let summary = try await reviewService.summary(descriptor)
        XCTAssertEqual(summary.changedFileCount, 2)
        XCTAssertEqual(summary.commitCount, 1)

        try await reviewService.mergeAgentBranch(descriptor)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repository.appendingPathComponent("feature.txt").path
            )
        )

        let hasUncommittedChanges = try await manager.hasUncommittedChanges(descriptor)
        XCTAssertTrue(hasUncommittedChanges)
        do {
            try await manager.removeWorktree(descriptor, force: false)
            XCTFail("A dirty worktree must not be removed without force")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        }

        try await manager.removeWorktree(descriptor, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        let branchResult = try await shell.run(
            executableURL: git,
            arguments: ["show-ref", "--verify", "refs/heads/\(descriptor.branchName)"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(branchResult.exitCode, 0, "Removing a worktree must preserve its branch")
    }

    func testDraftPullRequestWorkflowPushesAndCreatesPR() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryPR-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let pullRequestState = scratch.appendingPathComponent("pr-created")
        let gitLog = scratch.appendingPathComponent("git.log")
        let ghLog = scratch.appendingPathComponent("gh.log")
        let fakeGit = scratch.appendingPathComponent("git")
        let fakeGitHub = scratch.appendingPathComponent("gh")

        let gitScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(gitLog.path)"
        if [ "$1" = "remote" ]; then
          echo 'git@github.com:example/project.git'
        elif [ "$1" = "rev-list" ]; then
          echo '2'
        elif [ "$1" = "status" ]; then
          echo ' M Sources/Feature.swift'
        elif [ "$1" = "log" ]; then
          echo 'Add agent feature'
        fi
        exit 0
        """
        let ghScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(ghLog.path)"
        if [ "$1" = "auth" ]; then
          exit 0
        elif [ "$1" = "repo" ]; then
          echo '{"defaultBranchRef":{"name":"main"}}'
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
          if [ -f "\(pullRequestState.path)" ]; then
            echo '{"number":17,"url":"https://github.com/example/project/pull/17","state":"OPEN","isDraft":true,"headRefName":"canvas/ada-claude-12345678","baseRefName":"main"}'
            exit 0
          fi
          exit 1
        elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
          touch "\(pullRequestState.path)"
          echo 'https://github.com/example/project/pull/17'
          exit 0
        fi
        exit 1
        """
        try Data(gitScript.utf8).write(to: fakeGit)
        try Data(ghScript.utf8).write(to: fakeGitHub)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGitHub.path
        )

        let descriptor = WorktreeDescriptor(
            projectRoot: project,
            worktreeURL: worktree,
            branchName: "canvas/ada-claude-12345678",
            baseRevision: "abc123"
        )
        let service = GitHubPullRequestService(gitURL: fakeGit, ghURL: fakeGitHub)
        let preflight = try await service.preflight(descriptor)
        XCTAssertEqual(preflight.commitCount, 2)
        XCTAssertEqual(preflight.baseBranch, "main")
        XCTAssertEqual(preflight.suggestedTitle, "Add agent feature")
        XCTAssertTrue(preflight.hasUncommittedChanges)
        XCTAssertNil(preflight.existingPullRequest)

        let pullRequest = try await service.publishDraft(
            descriptor,
            agentName: "Ada",
            testStatus: .passed
        )
        XCTAssertEqual(pullRequest.number, 17)
        XCTAssertEqual(pullRequest.state, .open)
        XCTAssertTrue(pullRequest.isDraft)
        XCTAssertEqual(pullRequest.baseBranch, "main")

        let recordedGitCommands = try String(contentsOf: gitLog, encoding: .utf8)
        XCTAssertTrue(
            recordedGitCommands.contains(
                "push --set-upstream origin canvas/ada-claude-12345678"
            )
        )
        let recordedGitHubCommands = try String(contentsOf: ghLog, encoding: .utf8)
        XCTAssertTrue(recordedGitHubCommands.contains("pr create --draft"))
        XCTAssertTrue(recordedGitHubCommands.contains("--base main"))
        XCTAssertTrue(recordedGitHubCommands.contains("--title Add agent feature"))
    }

    func testPullRequestWorkflowExplainsMissingGitHubCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
        let descriptor = WorktreeDescriptor(
            projectRoot: scratch,
            worktreeURL: scratch,
            branchName: "canvas/test",
            baseRevision: "abc123"
        )
        let service = GitHubPullRequestService(ghURL: nil)

        do {
            _ = try await service.preflight(descriptor)
            XCTFail("Expected a missing GitHub CLI error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("brew install gh"))
            XCTAssertTrue(error.localizedDescription.contains("gh auth login"))
        }
    }

    func testEmptyFolderCanBeInitializedForAgentWorktrees() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryBootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let manager = GitProjectManager()
        let inspection = try await manager.inspect(scratch)
        guard case .needsBootstrap(let request) = inspection else {
            return XCTFail("Expected an empty folder to offer local Git initialization")
        }
        XCTAssertTrue(request.shouldInitializeGit)

        let repositoryRoot = try await manager.bootstrap(request)
        XCTAssertEqual(repositoryRoot.standardizedFileURL, scratch.standardizedFileURL)

        let readyInspection = try await manager.inspect(scratch)
        XCTAssertEqual(readyInspection, .ready(repositoryRoot))

        let headResult = try await ShellRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--verify", "HEAD"],
            currentDirectoryURL: scratch
        )
        XCTAssertEqual(headResult.exitCode, 0)
    }

    func testNonGitFolderWithFilesIsNotSilentlyInitialized() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryNonGit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("existing work".utf8).write(
            to: scratch.appendingPathComponent("notes.txt")
        )

        let inspection = try await GitProjectManager().inspect(scratch)
        guard case .unsupported = inspection else {
            return XCTFail("Expected a non-empty, non-Git folder to be rejected")
        }
    }

    @MainActor
    func testNativeCardDragMovesHostedLayerWithoutMovingLayoutContainer() {
        let host = NativeTerminalCardHost(rootView: Color.clear)
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 360)
        host.layoutSubtreeIfNeeded()

        host.applyMove(CGSize(width: 80, height: 45))

        XCTAssertEqual(host.frame.origin, .zero)
        XCTAssertEqual(host.hostingView.frame.origin, CGPoint(x: 80, y: -45))
        XCTAssertEqual(host.hostingView.frame.size, CGSize(width: 520, height: 360))
    }
}
