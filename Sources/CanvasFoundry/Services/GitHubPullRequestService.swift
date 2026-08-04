import Foundation

struct PullRequestPreflight: Equatable {
    let commitCount: Int
    let hasUncommittedChanges: Bool
    let baseBranch: String
    let suggestedTitle: String
    let existingPullRequest: AgentPullRequest?
}

enum GitHubPullRequestError: LocalizedError {
    case githubCLINotInstalled
    case githubCLIUnauthenticated(String)
    case missingOrigin
    case unsupportedRemote(String)
    case noAgentCommits
    case pullRequestNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .githubCLINotInstalled:
            "GitHub CLI is required to create pull requests. Install it with “brew install gh”, then run “gh auth login”."
        case .githubCLIUnauthenticated(let host):
            "GitHub CLI is not authenticated for \(host). Run “gh auth login --hostname \(host)” and try again."
        case .missingOrigin:
            "This repository does not have an origin remote. Add a GitHub origin before publishing a pull request."
        case .unsupportedRemote(let remote):
            "The origin remote is not a supported GitHub URL: \(remote)"
        case .noAgentCommits:
            "Commit the agent’s work before publishing a pull request. Uncommitted files cannot be included in a PR."
        case .pullRequestNotFound:
            "No pull request was found for this agent branch."
        case .commandFailed(let message):
            message
        }
    }
}

struct GitHubPullRequestService: Sendable {
    private let shell = ShellRunner()
    private let gitURL: URL
    private let ghURL: URL?

    init(
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        ghURL: URL? = ExecutableResolver.resolve("gh")
    ) {
        self.gitURL = gitURL
        self.ghURL = ghURL
    }

    func preflight(_ descriptor: WorktreeDescriptor) async throws -> PullRequestPreflight {
        let context = try await githubContext(descriptor)
        let baseRevision = try await resolveBaseRevision(
            descriptor,
            baseBranch: context.baseBranch
        )
        let countResult = try await runGit(
            ["rev-list", "--count", "\(baseRevision)..HEAD"],
            in: descriptor.worktreeURL
        )
        let commitCount = Int(
            countResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        guard commitCount > 0 else {
            throw GitHubPullRequestError.noAgentCommits
        }

        let statusResult = try await runGit(
            ["status", "--porcelain=v1"],
            in: descriptor.worktreeURL
        )
        let titleResult = try await runGit(
            ["log", "-1", "--format=%s"],
            in: descriptor.worktreeURL
        )
        let existing = try await findPullRequest(
            branchName: descriptor.branchName,
            host: context.host,
            in: descriptor.worktreeURL
        )
        return PullRequestPreflight(
            commitCount: commitCount,
            hasUncommittedChanges: !statusResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            baseBranch: context.baseBranch,
            suggestedTitle: titleResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines),
            existingPullRequest: existing
        )
    }

    func publishDraft(
        _ descriptor: WorktreeDescriptor,
        agentName: String,
        testStatus: AgentTestStatus
    ) async throws -> AgentPullRequest {
        let preflight = try await preflight(descriptor)
        if let existing = preflight.existingPullRequest {
            return existing
        }
        let context = try await githubContext(descriptor)
        try await pushBranch(descriptor)

        let body = Self.pullRequestBody(
            agentName: agentName,
            branchName: descriptor.branchName,
            testStatus: testStatus
        )
        let createResult = try await runGitHub(
            [
                "pr", "create",
                "--draft",
                "--base", preflight.baseBranch,
                "--head", descriptor.branchName,
                "--title", preflight.suggestedTitle,
                "--body", body
            ],
            in: descriptor.worktreeURL,
            requireSuccess: false
        )
        if createResult.exitCode != 0,
           let existing = try await findPullRequest(
               branchName: descriptor.branchName,
               host: context.host,
               in: descriptor.worktreeURL
           ) {
            return existing
        }
        guard createResult.exitCode == 0 else {
            throw GitHubPullRequestError.commandFailed(Self.commandDetails(createResult))
        }
        guard let created = try await findPullRequest(
            branchName: descriptor.branchName,
            host: context.host,
            in: descriptor.worktreeURL
        ) else {
            throw GitHubPullRequestError.pullRequestNotFound
        }
        return created
    }

    func pushUpdates(_ descriptor: WorktreeDescriptor) async throws -> AgentPullRequest {
        let context = try await githubContext(descriptor)
        try await pushBranch(descriptor)
        guard let pullRequest = try await findPullRequest(
            branchName: descriptor.branchName,
            host: context.host,
            in: descriptor.worktreeURL
        ) else {
            throw GitHubPullRequestError.pullRequestNotFound
        }
        return pullRequest
    }

    func refresh(_ descriptor: WorktreeDescriptor) async throws -> AgentPullRequest {
        let context = try await githubContext(descriptor)
        guard let pullRequest = try await findPullRequest(
            branchName: descriptor.branchName,
            host: context.host,
            in: descriptor.worktreeURL
        ) else {
            throw GitHubPullRequestError.pullRequestNotFound
        }
        return pullRequest
    }

    private func githubContext(_ descriptor: WorktreeDescriptor) async throws -> GitHubContext {
        guard let ghURL else {
            throw GitHubPullRequestError.githubCLINotInstalled
        }
        let remoteResult = try await runGit(
            ["remote", "get-url", "origin"],
            in: descriptor.projectRoot,
            requireSuccess: false
        )
        guard remoteResult.exitCode == 0 else {
            throw GitHubPullRequestError.missingOrigin
        }
        let remote = remoteResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = Self.githubHost(from: remote) else {
            throw GitHubPullRequestError.unsupportedRemote(remote)
        }

        let authResult = try await shell.run(
            executableURL: ghURL,
            arguments: ["auth", "status", "--hostname", host],
            currentDirectoryURL: descriptor.projectRoot
        )
        guard authResult.exitCode == 0 else {
            throw GitHubPullRequestError.githubCLIUnauthenticated(host)
        }
        let repositoryResult = try await runGitHub(
            ["repo", "view", "--json", "defaultBranchRef"],
            in: descriptor.projectRoot
        )
        do {
            let repository = try JSONDecoder().decode(
                GitHubRepositoryResponse.self,
                from: Data(repositoryResult.standardOutput.utf8)
            )
            return GitHubContext(host: host, baseBranch: repository.defaultBranchRef.name)
        } catch {
            throw GitHubPullRequestError.commandFailed(
                "GitHub CLI returned an unreadable repository response."
            )
        }
    }

    private func resolveBaseRevision(
        _ descriptor: WorktreeDescriptor,
        baseBranch: String
    ) async throws -> String {
        if let baseRevision = descriptor.baseRevision, !baseRevision.isEmpty {
            let validation = try await runGit(
                ["cat-file", "-e", "\(baseRevision)^{commit}"],
                in: descriptor.worktreeURL,
                requireSuccess: false
            )
            if validation.exitCode == 0 {
                return baseRevision
            }
        }
        let mergeBase = try await runGit(
            ["merge-base", "HEAD", "origin/\(baseBranch)"],
            in: descriptor.worktreeURL
        )
        return mergeBase.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pushBranch(_ descriptor: WorktreeDescriptor) async throws {
        _ = try await runGit(
            ["push", "--set-upstream", "origin", descriptor.branchName],
            in: descriptor.worktreeURL
        )
    }

    private func findPullRequest(
        branchName: String,
        host: String,
        in directory: URL
    ) async throws -> AgentPullRequest? {
        let result = try await runGitHub(
            [
                "pr", "view", branchName,
                "--json", "number,url,state,isDraft,headRefName,baseRefName"
            ],
            in: directory,
            requireSuccess: false
        )
        guard result.exitCode == 0 else { return nil }
        do {
            let response = try JSONDecoder().decode(
                GitHubPullRequestResponse.self,
                from: Data(result.standardOutput.utf8)
            )
            return response.pullRequest
        } catch {
            throw GitHubPullRequestError.commandFailed(
                "GitHub CLI returned an unreadable pull request response."
            )
        }
    }

    private func runGit(
        _ arguments: [String],
        in directory: URL,
        requireSuccess: Bool = true
    ) async throws -> CommandResult {
        let result = try await shell.run(
            executableURL: gitURL,
            arguments: arguments,
            currentDirectoryURL: directory
        )
        if requireSuccess && result.exitCode != 0 {
            throw GitHubPullRequestError.commandFailed(Self.commandDetails(result))
        }
        return result
    }

    private func runGitHub(
        _ arguments: [String],
        in directory: URL,
        requireSuccess: Bool = true
    ) async throws -> CommandResult {
        guard let ghURL else {
            throw GitHubPullRequestError.githubCLINotInstalled
        }
        let result = try await shell.run(
            executableURL: ghURL,
            arguments: arguments,
            currentDirectoryURL: directory
        )
        if requireSuccess && result.exitCode != 0 {
            throw GitHubPullRequestError.commandFailed(Self.commandDetails(result))
        }
        return result
    }

    static func githubHost(from remote: String) -> String? {
        if remote.hasPrefix("git@") {
            return remote.dropFirst(4).split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        if let url = URL(string: remote),
           let host = url.host,
           url.scheme == "https" || url.scheme == "ssh" {
            return host
        }
        return nil
    }

    static func pullRequestBody(
        agentName: String,
        branchName: String,
        testStatus: AgentTestStatus
    ) -> String {
        """
        ## Canvas Foundry agent

        - Agent: \(agentName)
        - Branch: `\(branchName)`
        - Tests: \(testStatus.label)

        This draft pull request was published from an isolated Canvas Foundry worktree.
        """
    }

    private static func commandDetails(_ result: CommandResult) -> String {
        let details = result.standardError.isEmpty
            ? result.standardOutput
            : result.standardError
        return details.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitHubContext {
    let host: String
    let baseBranch: String
}

private struct GitHubRepositoryResponse: Decodable {
    struct DefaultBranch: Decodable {
        let name: String
    }

    let defaultBranchRef: DefaultBranch
}

private struct GitHubPullRequestResponse: Decodable {
    let number: Int
    let url: URL
    let state: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String

    var pullRequest: AgentPullRequest {
        AgentPullRequest(
            number: number,
            url: url,
            state: PullRequestState(rawValue: state.lowercased()) ?? .unknown,
            isDraft: isDraft,
            headBranch: headRefName,
            baseBranch: baseRefName,
            updatedAt: Date()
        )
    }
}
