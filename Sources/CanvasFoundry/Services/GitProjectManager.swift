import Foundation

struct RepositoryBootstrapRequest: Equatable, Sendable {
    let folderURL: URL
    let shouldInitializeGit: Bool
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
                    shouldInitializeGit: false
                )
            )
        }

        if Self.isEffectivelyEmpty(folderURL) {
            return .needsBootstrap(
                RepositoryBootstrapRequest(
                    folderURL: folderURL,
                    shouldInitializeGit: true
                )
            )
        }

        return .unsupported(
            "Choose an existing Git repository or an empty folder that Canvas Foundry can initialize."
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
            let commitResult = try await shell.run(
                executableURL: git,
                arguments: [
                    "-c", "user.name=Canvas Foundry",
                    "-c", "user.email=canvas-foundry@localhost",
                    "commit", "--allow-empty", "-m", "Initialize repository"
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
