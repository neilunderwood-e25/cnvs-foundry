import XCTest
@testable import CanvasFoundry

final class CanvasFoundryTests: XCTestCase {
    func testProviderLaunchPlansUseNonInteractiveAgentModes() {
        XCTAssertEqual(
            AgentProvider.claude.launchPlan(prompt: "Fix tests"),
            AgentLaunchPlan(executable: "claude", arguments: ["--print", "Fix tests"])
        )
        XCTAssertEqual(
            AgentProvider.codex.launchPlan(prompt: "Fix tests"),
            AgentLaunchPlan(executable: "codex", arguments: ["exec", "Fix tests"])
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
}
