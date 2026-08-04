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
            branchName: "canvas/grace-codex-12345678"
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
        XCTAssertEqual(restored.status, .stopped)
        XCTAssertTrue(restored.isSelected)
        XCTAssertNil(restored.runtime)
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
