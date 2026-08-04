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
    let recentProjectPaths: [String]?
    /// Absent in snapshots written before backdrops were selectable.
    let canvasBackground: String?
    /// Absent in snapshots written before the canvas was drawable.
    let annotations: [PersistedAnnotation]?

    init(
        version: Int = currentVersion,
        projectPath: String?,
        zoom: Double,
        panX: Double,
        panY: Double,
        selectedSessionID: UUID?,
        sessions: [PersistedAgentSession],
        recentProjectPaths: [String]? = nil,
        canvasBackground: String? = nil,
        annotations: [PersistedAnnotation]? = nil
    ) {
        self.version = version
        self.projectPath = projectPath
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
        self.selectedSessionID = selectedSessionID
        self.sessions = sessions
        self.recentProjectPaths = recentProjectPaths
        self.canvasBackground = canvasBackground
        self.annotations = annotations
    }
}

struct PersistedAnnotation: Codable, Equatable {
    let id: UUID
    let kind: String
    /// Parallel coordinate arrays, kept flat so the JSON stays readable.
    let pointsX: [Double]
    let pointsY: [Double]
    let color: String
    let lineWidth: Double
    let text: String?
    /// Absent for ungrouped items and for snapshots predating grouping.
    let groupID: UUID?
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
    let title: String?
    let mergeability: String?
    let mergeStateStatus: String?
    let checksStatus: String?
    let reviewDecision: String?
    let headCommitOID: String?
    let changedFiles: Int?
    let additions: Int?
    let deletions: Int?
    let checks: [PersistedPullRequestCheck]?
}

struct PersistedPullRequestCheck: Codable, Equatable {
    let name: String
    let workflow: String?
    let state: String
    let bucket: String
    let link: URL?
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
