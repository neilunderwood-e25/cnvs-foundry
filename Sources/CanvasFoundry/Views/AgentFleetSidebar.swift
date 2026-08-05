import SwiftUI

struct AgentFleetSidebar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.foundry(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.visibleSessions.count)")
                    .font(.foundry(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider().opacity(0.45)

            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No agents yet")
                        .font(.foundry(size: 12, weight: .medium))
                    Text("Open Claude Code or Codex to begin.")
                        .font(.foundry(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    fleetSection("NEEDS ATTENTION", sessions: attentionSessions)
                    fleetSection("READY TO SHIP", sessions: readyToShipSessions)
                    fleetSection("IN PROGRESS", sessions: inProgressSessions)
                    fleetSection("STOPPED", sessions: idleSessions)
                    fleetSection("DONE", sessions: completedSessions)
                    fleetSection("ARCHIVED", sessions: archivedSessions, archived: true)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 210)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func fleetSection(
        _ title: String,
        sessions: [AgentSession],
        archived: Bool = false
    ) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    FleetAgentRow(
                        session: session,
                        isArchived: archived,
                        onFocus: { model.focus(session) },
                        onFindInTerminal: { model.revealTerminal(session) },
                        onRename: { model.rename(session, to: $0) },
                        onArchive: { model.archive(session) },
                        onRestore: { model.restore(session) },
                        onReview: { model.review(session) },
                        onOpenInIDE: { model.openAgentWorktree(session, in: $0) },
                        onDelete: { model.prepareWorktreeDeletion(session) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(title)
                    .font(.foundry(size: 10, weight: .bold))
                    .tracking(0.8)
            }
        }
    }

    private var inProgressSessions: [AgentSession] {
        activeSessions.filter {
            $0.deliveryState == .preparing || $0.deliveryState == .working
        }
    }

    private var attentionSessions: [AgentSession] {
        activeSessions.filter { $0.deliveryState == .needsAttention }
    }

    private var readyToShipSessions: [AgentSession] {
        activeSessions.filter {
            switch $0.deliveryState {
            case .changesReady, .readyToPublish, .publishing, .draftPullRequest,
                 .checksRunning, .readyToMerge:
                true
            default:
                false
            }
        }
    }

    private var idleSessions: [AgentSession] {
        activeSessions.filter { $0.deliveryState == .idle }
    }

    private var completedSessions: [AgentSession] {
        activeSessions.filter { $0.deliveryState == .completed }
    }

    private var archivedSessions: [AgentSession] {
        model.sessions.filter(\.isArchived)
    }

    private var activeSessions: [AgentSession] {
        model.sessions.filter { !$0.isArchived }
    }

}

private struct FleetAgentRow: View {
    @ObservedObject var session: AgentSession
    let isArchived: Bool
    let onFocus: () -> Void
    let onFindInTerminal: () -> Void
    let onRename: (String) -> Void
    let onArchive: () -> Void
    let onRestore: () -> Void
    let onReview: () -> Void
    let onOpenInIDE: (ProjectIDE) -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var isMenuHovered = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 9) {
            ProviderLogo(provider: session.provider, size: 14)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Agent name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.foundry(size: 12, weight: .semibold))
                        .focused($isNameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                } else {
                    Text(session.name)
                        .font(.foundry(size: 12, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(session.deliveryState.label)
                        .font(.foundry(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 2)

            if session.gitSummary.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else if session.gitSummary.changedFileCount > 0 {
                Text("\(session.gitSummary.changedFileCount)")
                    .font(.foundry(size: 9, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Menu {
                lifecycleMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    // Explicit white: hierarchical styles like .secondary get
                    // dimmed again over the sidebar material and when the window
                    // is inactive, which washed the dots out.
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        isMenuHovered ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            // .borderlessButton hides its own label until the row is hovered;
            // .button + .plain keeps the glyph drawn at all times.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .layoutPriority(1)
            .onHover { isMenuHovered = $0 }
            .help("Agent actions")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            session.isSelected && !isArchived
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
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
        Button("Find Agent in Terminal", action: onFindInTerminal)
        Divider()
        Button("Rename", action: beginRename)
        if session.worktree != nil {
            Button("Review & Ship", action: onReview)
            ForEach(installedIDEs) { ide in
                Button("Open Agent in \(ide.shortDisplayName)") {
                    onOpenInIDE(ide)
                }
            }
        }
        Menu("Advanced") {
            if isArchived {
                Button("Restore to Canvas", action: onRestore)
            } else {
                Button("Archive Agent", action: onArchive)
            }
        }
        Divider()
        Button("Delete Agent", role: .destructive, action: onDelete)
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

    private var installedIDEs: [ProjectIDE] {
        ProjectIDE.allCases.filter { $0.applicationURL() != nil }
    }

    private var statusColor: Color {
        switch session.deliveryState {
        case .readyToMerge, .completed: .green
        case .needsAttention: .red
        case .changesReady, .readyToPublish, .draftPullRequest, .checksRunning: .orange
        case .preparing, .publishing: .yellow
        case .working: .cyan
        case .idle: .secondary
        }
    }
}
