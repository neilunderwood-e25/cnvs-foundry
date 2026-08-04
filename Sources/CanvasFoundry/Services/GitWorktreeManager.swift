import Foundation

struct WorktreeDescriptor: Equatable, Sendable {
    let projectRoot: URL
    let worktreeURL: URL
    let branchName: String
    let baseRevision: String?

    init(
        projectRoot: URL,
        worktreeURL: URL,
        branchName: String,
        baseRevision: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.worktreeURL = worktreeURL
        self.branchName = branchName
        self.baseRevision = baseRevision
    }
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
    /// Explicit location, used by tests. When nil, worktrees are created beside
    /// the project.
    let storageRootOverride: URL?
    private let shell = ShellRunner()

    init(storageRoot: URL? = nil) {
        self.storageRootOverride = storageRoot
    }

    /// `<parent>/<project>-worktrees`: beside the project so branches are easy to
    /// find and open next to the code, but outside it so they never appear in
    /// `git status` and no linter, test runner or file watcher inside the project
    /// ever walks into a second copy of the repository.
    static func siblingContainer(forProjectRoot projectRoot: URL) -> URL {
        projectRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(projectRoot.lastPathComponent)-worktrees",
                isDirectory: true
            )
    }

    private func container(forProjectRoot projectRoot: URL) -> URL {
        if let storageRootOverride {
            return storageRootOverride
                .appendingPathComponent(Self.repositoryKey(projectRoot), isDirectory: true)
        }

        let sibling = Self.siblingContainer(forProjectRoot: projectRoot)
        // A project in a read-only or otherwise unwritable parent still needs
        // somewhere to keep its branches.
        if FileManager.default.isWritableFile(atPath: sibling.deletingLastPathComponent().path) {
            return sibling
        }
        return Self.applicationSupportStorageRoot()
            .appendingPathComponent(Self.repositoryKey(projectRoot), isDirectory: true)
    }

    static func repositoryKey(_ projectRoot: URL) -> String {
        "\(slug(projectRoot.lastPathComponent))-\(fnv1a(projectRoot.standardizedFileURL.path))"
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
        let baseResult = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "HEAD"],
            currentDirectoryURL: projectRoot
        )
        guard baseResult.exitCode == 0 else {
            throw WorktreeError.commandFailed(Self.commandDetails(baseResult))
        }
        let baseRevision = baseResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortID = sessionID.uuidString.lowercased().prefix(8)
        let branchName = "canvas/\(Self.slug(title))-\(shortID)"
        let container = container(forProjectRoot: projectRoot)

        // Named after the agent rather than a hash, so the folder is recognisable
        // in Finder and in an editor's window title.
        let folderName = Self.slug(title)
        var worktreeURL = container.appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            // A reused call sign or a leftover directory must not collide.
            worktreeURL = container.appendingPathComponent(
                "\(folderName)-\(shortID)",
                isDirectory: true
            )
        }

        try FileManager.default.createDirectory(
            at: container,
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
            branchName: branchName,
            baseRevision: baseRevision
        )
    }

    func hasUncommittedChanges(_ descriptor: WorktreeDescriptor) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: descriptor.worktreeURL.path) else {
            return false
        }
        let result = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["status", "--porcelain=v1"],
            currentDirectoryURL: descriptor.worktreeURL
        )
        guard result.exitCode == 0 else {
            throw WorktreeError.commandFailed(Self.commandDetails(result))
        }
        return !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func removeWorktree(
        _ descriptor: WorktreeDescriptor,
        force: Bool
    ) async throws {
        guard FileManager.default.fileExists(atPath: descriptor.worktreeURL.path) else {
            return
        }
        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(descriptor.worktreeURL.path)

        let result = try await shell.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: descriptor.projectRoot
        )
        guard result.exitCode == 0 else {
            throw WorktreeError.commandFailed(Self.commandDetails(result))
        }
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

    /// Fallback for projects whose parent directory cannot be written to.
    static func applicationSupportStorageRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("CanvasFoundry", isDirectory: true)
            .appendingPathComponent("Worktrees", isDirectory: true)
    }

    private static func commandDetails(_ result: CommandResult) -> String {
        let details = result.standardError.isEmpty
            ? result.standardOutput
            : result.standardError
        return details.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
