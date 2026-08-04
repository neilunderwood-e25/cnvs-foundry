import Foundation

struct RepositoryBootstrapRequest: Equatable, Sendable {
    let folderURL: URL
    let shouldInitializeGit: Bool
    /// Whether the folder already holds files that the initial commit will
    /// include. Only drives the consent copy — the commit always adds
    /// everything, so agent worktrees branch from the actual code.
    var hasExistingFiles: Bool = false
}

enum ProjectInspection: Equatable, Sendable {
    case ready(URL)
    case needsBootstrap(RepositoryBootstrapRequest)
    case unsupported(String)
}

enum GitProjectError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

struct GitProjectManager: Sendable {
    private let shell = ShellRunner()
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    func inspect(_ folderURL: URL) async throws -> ProjectInspection {
        let rootResult = try await shell.run(
            executableURL: git,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectoryURL: folderURL
        )

        if rootResult.exitCode == 0 {
            let rootPath = rootResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let headResult = try await shell.run(
                executableURL: git,
                arguments: ["rev-parse", "--verify", "HEAD"],
                currentDirectoryURL: rootURL
            )

            if headResult.exitCode == 0 {
                return .ready(rootURL)
            }
            return .needsBootstrap(
                RepositoryBootstrapRequest(
                    folderURL: rootURL,
                    shouldInitializeGit: false,
                    hasExistingFiles: !Self.isEffectivelyEmpty(rootURL)
                )
            )
        }

        // Unreadable folders are the only remaining rejection; anything else —
        // empty, dotfiles-only, or a full codebase — can be initialized with
        // the user's consent.
        guard Self.isReadable(folderURL) else {
            return .unsupported(
                "Canvas Foundry cannot read this folder. Check its permissions and try again."
            )
        }

        return .needsBootstrap(
            RepositoryBootstrapRequest(
                folderURL: folderURL,
                shouldInitializeGit: true,
                hasExistingFiles: !Self.isEffectivelyEmpty(folderURL)
            )
        )
    }

    func bootstrap(_ request: RepositoryBootstrapRequest) async throws -> URL {
        if request.shouldInitializeGit {
            let initResult = try await shell.run(
                executableURL: git,
                arguments: ["init", "-b", "main"],
                currentDirectoryURL: request.folderURL
            )
            try Self.requireSuccess(initResult)
        }

        let headResult = try await shell.run(
            executableURL: git,
            arguments: ["rev-parse", "--verify", "HEAD"],
            currentDirectoryURL: request.folderURL
        )

        if headResult.exitCode != 0 {
            // Stage whatever the folder holds before the first commit: agent
            // worktrees branch from this commit, so an empty one would hand
            // every agent an empty copy of the project.
            let addResult = try await shell.run(
                executableURL: git,
                arguments: ["add", "-A"],
                currentDirectoryURL: request.folderURL
            )
            try Self.requireSuccess(addResult)

            let commitResult = try await shell.run(
                executableURL: git,
                arguments: [
                    "-c", "user.name=Canvas Foundry",
                    "-c", "user.email=canvas-foundry@localhost",
                    "commit", "--allow-empty", "-m", "Initial commit"
                ],
                currentDirectoryURL: request.folderURL
            )
            try Self.requireSuccess(commitResult)
        }

        let rootResult = try await shell.run(
            executableURL: git,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectoryURL: request.folderURL
        )
        try Self.requireSuccess(rootResult)

        let rootPath = rootResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    /// Creates a brand-new project folder and initializes it in one step, for
    /// the New Project flow.
    func createProject(at folderURL: URL) async throws -> URL {
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        return try await bootstrap(
            RepositoryBootstrapRequest(
                folderURL: folderURL,
                shouldInitializeGit: true,
                hasExistingFiles: false
            )
        )
    }

    static func isReadable(_ folderURL: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )) != nil
    }

    static func isEffectivelyEmpty(_ folderURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return contents.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    private static func requireSuccess(_ result: CommandResult) throws {
        guard result.exitCode == 0 else {
            let details = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw GitProjectError.commandFailed(
                details.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
