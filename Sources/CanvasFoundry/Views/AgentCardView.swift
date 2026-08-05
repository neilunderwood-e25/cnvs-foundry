import AppKit
import SwiftUI

struct AgentCardView: View {
    @ObservedObject var session: AgentSession
    let onSelect: () -> Void
    let onRelaunch: () -> Void
    let onReview: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onOpenInIDE: (ProjectIDE) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            terminal
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.045, green: 0.052, blue: 0.072),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    session.isSelected ? accentColor.opacity(0.88) : .white.opacity(0.075),
                    lineWidth: session.isSelected ? 1.25 : 0.75
                )
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accentColor.opacity(0.13))
                ProviderLogo(provider: session.provider, size: 13)
            }
            .frame(width: 23, height: 23)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.foundry(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(agentSubtitle)
                    .font(.foundry(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            statusBadge

            Menu {
                if session.status.isActive {
                    Button("Stop Terminal", role: .destructive) {
                        session.runtime?.stop()
                    }
                } else if session.worktree != nil {
                    Button("Resume Agent") {
                        onRelaunch()
                    }
                }
                if let worktree = session.worktree {
                    Button("Review & Ship") {
                        onReview()
                    }
                    ForEach(installedIDEs) { ide in
                        Button("Open Agent in \(ide.shortDisplayName)") {
                            onOpenInIDE(ide)
                        }
                    }
                    Menu("Advanced") {
                        Button("Reveal Workspace in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([worktree.worktreeURL])
                        }
                        Button("Open Workspace in Terminal") {
                            let terminal = URL(
                                fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
                                isDirectory: true
                            )
                            NSWorkspace.shared.open(
                                [worktree.worktreeURL],
                                withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                        Button("Archive Agent", action: onArchive)
                    }
                }
                Divider()
                Button("Delete Agent", role: .destructive, action: onDelete)
                    .disabled(session.worktree == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    private var terminal: some View {
        Group {
            if let runtime = session.runtime {
                AgentTerminalView(runtime: runtime, onInteraction: onSelect)
            } else {
                ZStack {
                    Color.black.opacity(0.42)
                    VStack(spacing: 10) {
                        switch session.status {
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        case .stopped, .completed:
                            Image(systemName: "terminal")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(accentColor)
                            Text("Ready to continue in the existing workspace")
                                .foregroundStyle(.secondary)
                            Button("Resume \(session.name)", action: onRelaunch)
                                .buttonStyle(.borderedProminent)
                                .tint(accentColor)
                        case .preparing, .working, .needsYou:
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing an isolated workspace…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.foundry(size: 11))
                    .padding(20)
                }
            }
        }
        .background(Color.black.opacity(0.42))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: deliverySymbol)
            Text(session.deliveryState.label)
                .lineLimit(1)
            Spacer()
            if session.canReviewAndShip {
                Button(action: onReview) {
                    Text("Review & Ship")
                        .font(.foundry(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(deliveryColor)
                .help("Review changes and deliver this agent's work")
            }
            if session.status.isActive {
                Button {
                    session.runtime?.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop terminal")
            } else if session.worktree != nil {
                Button(action: onRelaunch) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Resume this agent and its conversation")
            }
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.trailing, 14)
        .frame(height: 27)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(session.deliveryState.label)
        }
        .font(.foundry(size: 9, weight: .semibold))
        .foregroundStyle(statusColor)
        .help(statusHelp)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .help("Resize terminal")
    }

    private var accentColor: Color {
        switch session.provider {
        case .claude: Color(red: 0.91, green: 0.53, blue: 0.35)
        case .codex: Color(red: 0.30, green: 0.82, blue: 0.64)
        }
    }

    private var agentSubtitle: String {
        guard let terminalTitle = session.terminalTitle,
              !terminalTitle.isEmpty,
              terminalTitle != session.name else {
            return session.provider.displayName
        }
        return "\(session.provider.displayName) · \(terminalTitle)"
    }

    private var installedIDEs: [ProjectIDE] {
        ProjectIDE.allCases.filter { $0.applicationURL() != nil }
    }

    private var statusColor: Color {
        deliveryColor
    }

    private var deliveryColor: Color {
        switch session.deliveryState {
        case .readyToMerge, .completed: .green
        case .needsAttention: .red
        case .changesReady, .readyToPublish, .draftPullRequest, .checksRunning: .orange
        case .preparing, .publishing: .yellow
        case .working: .cyan
        case .idle: .secondary
        }
    }

    private var deliverySymbol: String {
        switch session.deliveryState {
        case .preparing: "gearshape.2"
        case .working: "bolt.fill"
        case .changesReady: "doc.badge.ellipsis"
        case .readyToPublish: "arrow.up.circle.fill"
        case .publishing: "arrow.triangle.2.circlepath"
        case .draftPullRequest: "doc.text"
        case .checksRunning: "clock.fill"
        case .readyToMerge: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .completed: "checkmark.seal.fill"
        case .idle: "pause.circle"
        }
    }

    private var statusHelp: String {
        switch session.status {
        case .needsYou(let reason), .failed(let reason): reason
        default: session.status.label
        }
    }
}
