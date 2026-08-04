import AppKit
import SwiftUI

struct AgentCardView: View {
    @ObservedObject var session: AgentSession
    let onSelect: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            terminal
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.075, green: 0.08, blue: 0.10),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(session.isSelected ? accentColor.opacity(0.9) : .white.opacity(0.11), lineWidth: session.isSelected ? 1.5 : 1)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 7)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accentColor.opacity(0.17))
                Image(systemName: session.provider.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(agentSubtitle)
                    .font(.system(size: 10))
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
                    Button("Relaunch Agent") {
                        onRelaunch()
                    }
                }
                if let worktree = session.worktree {
                    Button("Reveal Worktree in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([worktree.worktreeURL])
                    }
                    Button("Open in Terminal") {
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
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
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
                            Text("Ready to relaunch in the existing worktree")
                                .foregroundStyle(.secondary)
                            Button("Relaunch \(session.name)", action: onRelaunch)
                                .buttonStyle(.borderedProminent)
                                .tint(accentColor)
                        case .preparing, .working, .needsYou:
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating isolated worktree…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(20)
                }
            }
        }
        .background(Color.black.opacity(0.42))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text(session.worktree?.branchName ?? "allocating worktree")
                .lineLimit(1)
            Spacer()
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
                .help("Relaunch agent")
            }
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.trailing, 14)
        .frame(height: 30)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(session.status.label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.11), in: Capsule())
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

    private var statusHelp: String {
        switch session.status {
        case .needsYou(let reason), .failed(let reason): reason
        default: session.status.label
        }
    }
}
