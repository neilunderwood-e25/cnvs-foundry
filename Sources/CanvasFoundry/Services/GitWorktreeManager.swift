import Foundation

struct WorktreeDescriptor: Equatable, Sendable {
    let projectRoot: URL
    let worktreeURL: URL
    let branchName: String
}

enum WorktreeError: LocalizedError {
    case notGitRepository(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository(let path):
            "The selected folder is not a Git repository: \(path)"
        case .commandFailed(let message):
            message
        }
    }
}

struct GitWorktreeManager: Sendable {
    let storageRoot: URL
    private let shell = ShellRunner()

    init(storageRoot: URL = GitWorktreeManager.defaultStorageRoot()) {
        self.storageRoot = storageRoot
    }

    func createWorktree(
        for selectedProject: URL,
        sessionID: UUID,
        title: String
    ) async throws -> WorktreeDescriptor {
        let rootResult = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectoryURL: selectedProject
        )

        guard rootResult.exitCode == 0 else {
            throw WorktreeError.notGitRepository(selectedProject.path)
        }

        let rootPath = rootResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let shortID = sessionID.uuidString.lowercased().prefix(8)
        let branchName = "canvas/\(Self.slug(title))-\(shortID)"
        let repositoryKey = "\(Self.slug(projectRoot.lastPathComponent))-\(Self.fnv1a(projectRoot.path))"
        let worktreeURL = storageRoot
            .appendingPathComponent(repositoryKey, isDirectory: true)
            .appendingPathComponent(String(shortID), isDirectory: true)

        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let result = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["worktree", "add", "-b", branchName, worktreeURL.path, "HEAD"],
            currentDirectoryURL: projectRoot
        )

        guard result.exitCode == 0 else {
            let details = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw WorktreeError.commandFailed(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return WorktreeDescriptor(
            projectRoot: projectRoot,
            worktreeURL: worktreeURL,
            branchName: branchName
        )
    }

    static func slug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let joined = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((joined.isEmpty ? "agent-task" : joined).prefix(36))
    }

    static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func defaultStorageRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("CanvasFoundry", isDirectory: true)
            .appendingPathComponent("Worktrees", isDirectory: true)
    }
}
