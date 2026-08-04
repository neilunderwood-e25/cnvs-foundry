import AppKit
import Foundation

enum ProjectIDE: String, CaseIterable, Identifiable {
    case cursor
    case visualStudioCode

    var id: String { rawValue }

    var buttonTitle: String {
        switch self {
        case .cursor: "Open in Cursor IDE"
        case .visualStudioCode: "Open in VS Code"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .cursor: "Cursor"
        case .visualStudioCode: "VS Code"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .visualStudioCode: "com.microsoft.VSCode"
        }
    }

    var fallbackApplicationNames: [String] {
        switch self {
        case .cursor: ["Cursor.app"]
        case .visualStudioCode: ["Visual Studio Code.app", "Code.app"]
        }
    }

    /// Name of the launcher bundled at `Contents/Resources/app/bin`.
    var commandLineToolName: String {
        switch self {
        case .cursor: "cursor"
        case .visualStudioCode: "code"
        }
    }

    /// Arguments that force a full editor window onto `path`.
    ///
    /// Cursor's launcher routes on its first argument: `agent` goes to
    /// cursor-agent and `editor` goes to the IDE. Naming `editor` explicitly
    /// keeps a project from landing in the standalone agent window.
    func editorLaunchArguments(forPath path: String) -> [String] {
        switch self {
        case .cursor: ["editor", "--new-window", path]
        case .visualStudioCode: ["--new-window", path]
        }
    }

    @MainActor
    func commandLineToolURL(workspace: NSWorkspace = .shared) -> URL? {
        guard let applicationURL = applicationURL(workspace: workspace) else { return nil }
        let toolURL = applicationURL
            .appendingPathComponent("Contents/Resources/app/bin", isDirectory: true)
            .appendingPathComponent(commandLineToolName, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else { return nil }
        return toolURL
    }

    @MainActor
    func applicationURL(workspace: NSWorkspace = .shared) -> URL? {
        if let registeredURL = workspace.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            return registeredURL
        }

        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        for root in searchRoots {
            for applicationName in fallbackApplicationNames {
                let candidate = root.appendingPathComponent(applicationName, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

enum IDEProjectOpener {
    struct WorkspaceFolder: Equatable {
        let name: String
        let url: URL
    }

    @MainActor
    static func open(
        projectURL: URL,
        in ide: ProjectIDE,
        workspace: NSWorkspace = .shared
    ) async throws {
        guard let applicationURL = ide.applicationURL(workspace: workspace) else {
            throw IDEProjectOpeningError.applicationNotInstalled(ide.buttonTitle)
        }

        // Preferred path: the bundled launcher, which can be told to open an
        // editor window rather than letting the app decide what to restore.
        if let toolURL = ide.commandLineToolURL(workspace: workspace) {
            try await launch(
                toolURL: toolURL,
                arguments: ide.editorLaunchArguments(forPath: projectURL.path),
                ide: ide
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            workspace.open(
                [projectURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func launch(
        toolURL: URL,
        arguments: [String],
        ide: ProjectIDE
    ) async throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finishedProcess in
                guard finishedProcess.terminationStatus != 0 else {
                    continuation.resume(returning: ())
                    return
                }
                let details = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(
                    throwing: IDEProjectOpeningError.launchFailed(
                        ide.shortDisplayName,
                        details
                    )
                )
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func makeMultiRootWorkspace(
        projectURL: URL,
        folders: [WorkspaceFolder],
        storageRoot: URL = defaultWorkspaceStorageRoot()
    ) throws -> URL {
        var seenPaths: Set<String> = []
        let uniqueFolders = folders.filter { folder in
            seenPaths.insert(folder.url.standardizedFileURL.path).inserted
        }
        let document = IDEWorkspaceDocument(
            folders: uniqueFolders.map {
                IDEWorkspaceFolderDocument(name: $0.name, path: $0.url.path)
            }
        )

        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        let repositoryKey = "\(GitWorktreeManager.slug(projectURL.lastPathComponent))-\(GitWorktreeManager.fnv1a(projectURL.standardizedFileURL.path))"
        let workspaceURL = storageRoot
            .appendingPathComponent(repositoryKey, isDirectory: false)
            .appendingPathExtension("code-workspace")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: workspaceURL, options: .atomic)
        return workspaceURL
    }

    static func defaultWorkspaceStorageRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("CanvasFoundry", isDirectory: true)
            .appendingPathComponent("IDEWorkspaces", isDirectory: true)
    }
}

private struct IDEWorkspaceDocument: Codable {
    let folders: [IDEWorkspaceFolderDocument]
}

private struct IDEWorkspaceFolderDocument: Codable {
    let name: String
    let path: String
}

enum IDEProjectOpeningError: LocalizedError {
    case applicationNotInstalled(String)
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .applicationNotInstalled(let applicationName):
            "\(applicationName) is not installed on this Mac."
        case .launchFailed(let ideName, let details):
            details.isEmpty
                ? "\(ideName) could not open the project."
                : "\(ideName) could not open the project: \(details)"
        }
    }
}
