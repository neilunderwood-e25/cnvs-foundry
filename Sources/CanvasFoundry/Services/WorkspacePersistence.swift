import Foundation

struct WorkspaceSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let projectPath: String?
    let zoom: Double
    let panX: Double
    let panY: Double
    let selectedSessionID: UUID?
    let sessions: [PersistedAgentSession]

    init(
        version: Int = currentVersion,
        projectPath: String?,
        zoom: Double,
        panX: Double,
        panY: Double,
        selectedSessionID: UUID?,
        sessions: [PersistedAgentSession]
    ) {
        self.version = version
        self.projectPath = projectPath
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
        self.selectedSessionID = selectedSessionID
        self.sessions = sessions
    }
}

struct PersistedAgentSession: Codable, Equatable {
    let id: UUID
    let provider: String
    let name: String
    let positionX: Double
    let positionY: Double
    let width: Double
    let height: Double
    let isArchived: Bool?
    let worktree: PersistedWorktree?
    let pullRequest: PersistedPullRequest?
}

struct PersistedWorktree: Codable, Equatable {
    let projectRootPath: String
    let worktreePath: String
    let branchName: String
    let baseRevision: String?
}

struct PersistedPullRequest: Codable, Equatable {
    let number: Int
    let url: URL
    let state: String
    let isDraft: Bool
    let headBranch: String
    let baseBranch: String
    let updatedAt: Date
}

struct WorkspacePersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        guard snapshot.version == WorkspaceSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("CanvasFoundry", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }
}
