import Foundation

struct GitChangedFile: Equatable, Identifiable {
    let status: String
    let path: String

    var id: String { path }
}

struct GitCommitSummary: Equatable, Identifiable {
    let hash: String
    let shortHash: String
    let subject: String

    var id: String { hash }
}

/// One entry of `git status --porcelain`, keeping both status columns so the
/// review UI can stage and unstage like a Git client.
struct GitWorkingFile: Equatable, Identifiable, Sendable {
    /// Index (staged) column of the porcelain output.
    let indexStatus: Character
    /// Worktree (unstaged) column of the porcelain output.
    let worktreeStatus: Character
    let path: String

    var id: String { path }

    var isUntracked: Bool { indexStatus == "?" }
    var hasStagedChanges: Bool {
        indexStatus != " " && indexStatus != "?"
    }
    var hasUnstagedChanges: Bool {
        worktreeStatus != " " || isUntracked
    }
    /// Fully staged: nothing left in the worktree column.
    var isFullyStaged: Bool { hasStagedChanges && worktreeStatus == " " }

    var statusLabel: String {
        switch (indexStatus, worktreeStatus) {
        case ("?", _): "untracked"
        case ("A", _): "added"
        case ("D", _), (_, "D"): "deleted"
        case ("R", _): "renamed"
        default: "modified"
        }
    }
}

struct GitReviewSnapshot: Equatable {
    let baseRevision: String
    let files: [GitChangedFile]
    /// Uncommitted files, with staging state.
    var workingFiles: [GitWorkingFile] = []
    let commits: [GitCommitSummary]
    let diff: String

    var summary: AgentGitSummary {
        AgentGitSummary(
            changedFileCount: files.count,
            commitCount: commits.count,
            isRefreshing: false,
            errorMessage: nil
        )
    }
}

struct AgentTestResult: Equatable {
    let passed: Bool
    let command: String
    let output: String
}

enum GitReviewError: LocalizedError {
    case commandFailed(String)
    case projectHasChanges
    case testsUnsupported

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .projectHasChanges:
            "The main project has uncommitted changes. Commit or stash them before integrating agent work."
        case .testsUnsupported:
            "Automatic tests are not configured for this project yet."
        }
    }
}

struct GitReviewService: Sendable {
    private let shell = ShellRunner()
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    func summary(_ descriptor: WorktreeDescriptor) async throws -> AgentGitSummary {
        let baseRevision = try await resolveBaseRevision(descriptor)
        let statusResult = try await runGit(
            ["status", "--porcelain=v1"],
            in: descriptor.worktreeURL
        )
        let committedFilesResult = try await runGit(
            ["diff", "--name-only", baseRevision, "HEAD"],
            in: descriptor.worktreeURL
        )
        let commitCountResult = try await runGit(
            ["rev-list", "--count", "\(baseRevision)..HEAD"],
            in: descriptor.worktreeURL
        )
        let files = Self.combinedFiles(
            statusOutput: statusResult.standardOutput,
            committedFilesOutput: committedFilesResult.standardOutput
        )
        let commitCount = Int(
            commitCountResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        return AgentGitSummary(
            changedFileCount: files.count,
            commitCount: commitCount,
            isRefreshing: false,
            errorMessage: nil
        )
    }

    func inspect(_ descriptor: WorktreeDescriptor) async throws -> GitReviewSnapshot {
        let baseRevision = try await resolveBaseRevision(descriptor)
        let statusResult = try await runGit(
            ["status", "--porcelain=v1"],
            in: descriptor.worktreeURL
        )
        let committedFilesResult = try await runGit(
            ["diff", "--name-only", baseRevision, "HEAD"],
            in: descriptor.worktreeURL
        )
        let logResult = try await runGit(
            ["log", "--format=%H%x09%h%x09%s", "\(baseRevision)..HEAD"],
            in: descriptor.worktreeURL
        )
        let diffResult = try await runGit(
            ["diff", "--no-ext-diff", "--no-color", baseRevision],
            in: descriptor.worktreeURL
        )

        let workingFiles = Self.parseStatus(statusResult.standardOutput)
        let files = Self.combinedFiles(
            statusOutput: statusResult.standardOutput,
            committedFilesOutput: committedFilesResult.standardOutput
        )

        let untrackedPaths = workingFiles
            .filter { $0.status == "??" }
            .map(\.path)
        var diff = Self.truncated(
            diffResult.standardOutput,
            maximumCharacters: 2_000_000,
            label: "Patch"
        )
        if !untrackedPaths.isEmpty {
            let note = untrackedPaths
                .map { "  • \($0)" }
                .joined(separator: "\n")
            diff += "\n\nUntracked files (content is not included in the Git patch):\n\(note)\n"
        }
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diff = "No textual changes relative to the agent's base commit."
        }

        return GitReviewSnapshot(
            baseRevision: baseRevision,
            files: files,
            workingFiles: Self.parseWorkingFiles(statusResult.standardOutput),
            commits: Self.parseCommits(logResult.standardOutput),
            diff: diff
        )
    }

    // MARK: - Staging and committing

    func stage(_ paths: [String], in descriptor: WorktreeDescriptor) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runGit(["add", "--"] + paths, in: descriptor.worktreeURL)
    }

    func unstage(_ paths: [String], in descriptor: WorktreeDescriptor) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runGit(
            ["restore", "--staged", "--"] + paths,
            in: descriptor.worktreeURL
        )
    }

    func stageAll(in descriptor: WorktreeDescriptor) async throws {
        _ = try await runGit(["add", "-A"], in: descriptor.worktreeURL)
    }

    /// Commits the staged changes in the agent worktree, falling back to a
    /// placeholder identity when the repository has none configured.
    func commit(message: String, in descriptor: WorktreeDescriptor) async throws {
        let identityArguments = await gitIdentityArguments(descriptor.worktreeURL)
        let result = try await shell.run(
            executableURL: git,
            arguments: identityArguments + ["commit", "-m", message],
            currentDirectoryURL: descriptor.worktreeURL
        )
        guard result.exitCode == 0 else {
            throw GitReviewError.commandFailed(Self.commandDetails(result))
        }
    }

    /// Patch for a single file so the review pane can focus like a Git client.
    /// Committed and unstaged changes are combined relative to the base;
    /// untracked files are diffed against /dev/null so their content shows too.
    func fileDiff(
        _ descriptor: WorktreeDescriptor,
        baseRevision: String,
        file: GitWorkingFile?
    ) async throws -> String {
        guard let file else {
            let result = try await runGit(
                ["diff", "--no-ext-diff", "--no-color", baseRevision],
                in: descriptor.worktreeURL
            )
            return result.standardOutput
        }

        if file.isUntracked {
            // `diff --no-index` exits 1 when the files differ, which is the
            // expected case here — only >1 is a real failure.
            let result = try await shell.run(
                executableURL: git,
                arguments: [
                    "diff", "--no-ext-diff", "--no-color", "--no-index",
                    "--", "/dev/null", file.path
                ],
                currentDirectoryURL: descriptor.worktreeURL
            )
            guard result.exitCode <= 1 else {
                throw GitReviewError.commandFailed(Self.commandDetails(result))
            }
            return result.standardOutput
        }

        let result = try await runGit(
            ["diff", "--no-ext-diff", "--no-color", baseRevision, "--", file.path],
            in: descriptor.worktreeURL
        )
        return result.standardOutput
    }

    func runTests(_ descriptor: WorktreeDescriptor) async throws -> AgentTestResult {
        let packageManifest = descriptor.worktreeURL.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packageManifest.path) else {
            throw GitReviewError.testsUnsupported
        }

        let result = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swift", "test"],
            currentDirectoryURL: descriptor.worktreeURL
        )
        let combinedOutput = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return AgentTestResult(
            passed: result.exitCode == 0,
            command: "xcrun swift test",
            output: combinedOutput
        )
    }

    func mergeAgentBranch(_ descriptor: WorktreeDescriptor) async throws {
        try await requireCleanProject(descriptor.projectRoot)
        let identityArguments = await gitIdentityArguments(descriptor.projectRoot)
        let result = try await shell.run(
            executableURL: git,
            arguments: identityArguments + [
                "merge", "--no-ff", "--no-edit", descriptor.branchName
            ],
            currentDirectoryURL: descriptor.projectRoot
        )
        guard result.exitCode == 0 else {
            _ = try? await shell.run(
                executableURL: git,
                arguments: ["merge", "--abort"],
                currentDirectoryURL: descriptor.projectRoot
            )
            throw GitReviewError.commandFailed(Self.commandDetails(result))
        }
    }

    func cherryPick(
        _ commit: GitCommitSummary,
        from descriptor: WorktreeDescriptor
    ) async throws {
        try await requireCleanProject(descriptor.projectRoot)
        let identityArguments = await gitIdentityArguments(descriptor.projectRoot)
        let result = try await shell.run(
            executableURL: git,
            arguments: identityArguments + ["cherry-pick", commit.hash],
            currentDirectoryURL: descriptor.projectRoot
        )
        guard result.exitCode == 0 else {
            _ = try? await shell.run(
                executableURL: git,
                arguments: ["cherry-pick", "--abort"],
                currentDirectoryURL: descriptor.projectRoot
            )
            throw GitReviewError.commandFailed(Self.commandDetails(result))
        }
    }

    private func resolveBaseRevision(_ descriptor: WorktreeDescriptor) async throws -> String {
        if let storedBase = descriptor.baseRevision, !storedBase.isEmpty {
            let validation = try await shell.run(
                executableURL: git,
                arguments: ["cat-file", "-e", "\(storedBase)^{commit}"],
                currentDirectoryURL: descriptor.worktreeURL
            )
            if validation.exitCode == 0 {
                return storedBase
            }
        }

        let projectHead = try await runGit(
            ["rev-parse", "HEAD"],
            in: descriptor.projectRoot
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await runGit(
            ["merge-base", projectHead, "HEAD"],
            in: descriptor.worktreeURL
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireCleanProject(_ projectRoot: URL) async throws {
        let status = try await runGit(["status", "--porcelain=v1"], in: projectRoot)
        guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitReviewError.projectHasChanges
        }
    }

    private func gitIdentityArguments(_ projectRoot: URL) async -> [String] {
        let name = try? await shell.run(
            executableURL: git,
            arguments: ["config", "--get", "user.name"],
            currentDirectoryURL: projectRoot
        )
        let email = try? await shell.run(
            executableURL: git,
            arguments: ["config", "--get", "user.email"],
            currentDirectoryURL: projectRoot
        )

        var arguments: [String] = []
        let hasName = name.map {
            $0.exitCode == 0 && !$0.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        let hasEmail = email.map {
            $0.exitCode == 0 && !$0.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if !hasName {
            arguments += ["-c", "user.name=Canvas Foundry"]
        }
        if !hasEmail {
            arguments += ["-c", "user.email=canvas-foundry@localhost"]
        }
        return arguments
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws -> CommandResult {
        let result = try await shell.run(
            executableURL: git,
            arguments: arguments,
            currentDirectoryURL: directory
        )
        guard result.exitCode == 0 else {
            throw GitReviewError.commandFailed(Self.commandDetails(result))
        }
        return result
    }

    static func parseWorkingFiles(_ output: String) -> [GitWorkingFile] {
        nonemptyLines(output).compactMap { line in
            guard line.count >= 4 else { return nil }
            let statusChars = Array(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let renameRange = path.range(of: " -> ") {
                path = String(path[renameRange.upperBound...])
            }
            return GitWorkingFile(
                indexStatus: statusChars[0],
                worktreeStatus: statusChars[1],
                path: path
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parseStatus(_ output: String) -> [GitChangedFile] {
        nonemptyLines(output).compactMap { line in
            guard line.count >= 4 else { return nil }
            let status = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let renameRange = path.range(of: " -> ") {
                path = String(path[renameRange.upperBound...])
            }
            return GitChangedFile(status: status, path: path)
        }
    }

    private static func parseCommits(_ output: String) -> [GitCommitSummary] {
        nonemptyLines(output).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return GitCommitSummary(
                hash: String(parts[0]),
                shortHash: String(parts[1]),
                subject: String(parts[2])
            )
        }
    }

    private static func combinedFiles(
        statusOutput: String,
        committedFilesOutput: String
    ) -> [GitChangedFile] {
        let workingFiles = parseStatus(statusOutput)
        var filesByPath: [String: GitChangedFile] = [:]
        for file in workingFiles {
            filesByPath[file.path] = file
        }
        for path in nonemptyLines(committedFilesOutput) where filesByPath[path] == nil {
            filesByPath[path] = GitChangedFile(status: "committed", path: path)
        }
        return filesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func nonemptyLines(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func truncated(
        _ output: String,
        maximumCharacters: Int,
        label: String
    ) -> String {
        guard output.count > maximumCharacters else { return output }
        return String(output.prefix(maximumCharacters))
            + "\n\n[\(label) truncated after \(maximumCharacters) characters]\n"
    }

    private static func commandDetails(_ result: CommandResult) -> String {
        let details = result.standardError.isEmpty
            ? result.standardOutput
            : result.standardError
        return details.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
