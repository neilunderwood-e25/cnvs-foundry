import SwiftUI

struct AgentFleetSidebar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AGENTS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.1)
                Spacer()
                Text("\(model.visibleSessions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: model.refreshAllGitSummaries) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh Git status")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Divider().opacity(0.45)

            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "terminal",
                    description: Text("Open Claude Code or Codex to begin.")
                )
            } else {
                List {
                    fleetSection("WORKING", sessions: workingSessions)
                    fleetSection("STOPPED", sessions: stoppedSessions)
                    fleetSection("COMPLETED", sessions: completedSessions)
                    fleetSection("FAILED", sessions: failedSessions)
                    fleetSection("ARCHIVED", sessions: archivedSessions, archived: true)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 238)
        .background(Color.black.opacity(0.14))
    }

    @ViewBuilder
    private func fleetSection(
        _ title: String,
        sessions: [AgentSession],
        archived: Bool = false
    ) -> some View {
        if !sessions.isEmpty {
            Section(title) {
                ForEach(sessions) { session in
                    FleetAgentRow(
                        session: session,
                        isArchived: archived,
                        onFocus: { model.focus(session) },
                        onRename: { model.rename(session, to: $0) },
                        onArchive: { model.archive(session) },
                        onRestore: { model.restore(session) },
                        onReview: { model.review(session) },
                        onOpenInIDE: { model.openAgentWorktree(session, in: $0) },
                        onPreparePullRequest: { model.preparePullRequest(session) },
                        onOpenPullRequest: { model.openPullRequest(session) },
                        onPushPullRequestUpdates: { model.pushPullRequestUpdates(session) },
                        onDelete: { model.prepareWorktreeDeletion(session) }
                    )
                }
            }
        }
    }

    private var workingSessions: [AgentSession] {
        activeSessions.filter { $0.status.isActive || isNeedsYou($0.status) }
    }

    private var stoppedSessions: [AgentSession] {
        activeSessions.filter { $0.status == .stopped }
    }

    private var completedSessions: [AgentSession] {
        activeSessions.filter { $0.status == .completed }
    }

    private var failedSessions: [AgentSession] {
        activeSessions.filter {
            if case .failed = $0.status { return true }
            return false
        }
    }

    private var archivedSessions: [AgentSession] {
        model.sessions.filter(\.isArchived)
    }

    private var activeSessions: [AgentSession] {
        model.sessions.filter { !$0.isArchived }
    }

    private func isNeedsYou(_ status: AgentStatus) -> Bool {
        if case .needsYou = status { return true }
        return false
    }
}

private struct FleetAgentRow: View {
    @ObservedObject var session: AgentSession
    let isArchived: Bool
    let onFocus: () -> Void
    let onRename: (String) -> Void
    let onArchive: () -> Void
    let onRestore: () -> Void
    let onReview: () -> Void
    let onOpenInIDE: (ProjectIDE) -> Void
    let onPreparePullRequest: () -> Void
    let onOpenPullRequest: () -> Void
    let onPushPullRequestUpdates: () -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.provider.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(providerColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Agent name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($isNameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                } else {
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(session.status.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 2)

            if let pullRequest = session.pullRequest {
                Text(pullRequest.queueState.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(pullRequestBadgeColor(pullRequest.queueState))
            }

            if session.gitSummary.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else if session.gitSummary.changedFileCount > 0 {
                Text("\(session.gitSummary.changedFileCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Menu {
                lifecycleMenu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isArchived && !isRenaming { onFocus() }
        }
        .onTapGesture(count: 2) {
            beginRename()
        }
        .contextMenu {
            lifecycleMenu
        }
    }

    @ViewBuilder
    private var lifecycleMenu: some View {
        Button("Rename", action: beginRename)
        if session.worktree != nil {
            Button("Review Git Changes", action: onReview)
            if session.isPublishingPullRequest {
                Button("Updating Pull Request…") {}
                    .disabled(true)
            } else if let pullRequest = session.pullRequest {
                Button("Open \(pullRequest.displayLabel)", action: onOpenPullRequest)
                if pullRequest.state == .open {
                    Button("Push PR Updates", action: onPushPullRequestUpdates)
                }
            } else {
                Button("Publish Draft PR", action: onPreparePullRequest)
            }
            ForEach(installedIDEs) { ide in
                Button("Open Worktree in \(ide.shortDisplayName)") {
                    onOpenInIDE(ide)
                }
            }
        }
        if isArchived {
            Button("Restore to Canvas", action: onRestore)
        } else {
            Button("Archive Agent", action: onArchive)
        }
        Divider()
        Button("Delete Agent and Worktree", role: .destructive, action: onDelete)
            .disabled(session.worktree == nil)
    }

    private func beginRename() {
        draftName = session.name
        isRenaming = true
        DispatchQueue.main.async { isNameFocused = true }
    }

    private func commitRename() {
        onRename(draftName)
        draftName = session.name
        isRenaming = false
    }

    private var providerColor: Color {
        session.provider == .claude ? .orange : .green
    }

    private var installedIDEs: [ProjectIDE] {
        ProjectIDE.allCases.filter { $0.applicationURL() != nil }
    }

    private var statusColor: Color {
        switch session.status {
        case .preparing: .yellow
        case .working: .green
        case .completed: .cyan
        case .needsYou: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    private func pullRequestBadgeColor(_ state: PullRequestQueueState) -> Color {
        switch state {
        case .readyToMerge, .merged: .green
        case .checksFailed, .changesRequested, .conflict: .red
        case .draft, .checksPending, .reviewRequired, .behind: .orange
        case .blocked, .closed: .secondary
        }
    }
}
