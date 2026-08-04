import AppKit
import SwiftUI

struct AgentCardView: View {
    @ObservedObject var session: AgentSession
    let zoom: CGFloat
    let onSelect: () -> Void

    @State private var dragOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            terminal
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(session.isSelected ? accentColor.opacity(0.9) : .white.opacity(0.11), lineWidth: session.isSelected ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 14)
        .onTapGesture(perform: onSelect)
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
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(session.provider.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusBadge

            Menu {
                if session.status.isActive {
                    Button("Stop Agent", role: .destructive) {
                        session.runtime?.stop()
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
        .gesture(cardDragGesture)
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.output.isEmpty ? "Creating isolated worktree…" : session.output)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(
                        session.output.isEmpty
                            ? Color.secondary
                            : Color.primary.opacity(0.88)
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .id("output-end")
            }
            .background(Color.black.opacity(0.26))
            .onChange(of: session.output) {
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo("output-end", anchor: .bottom)
                }
            }
        }
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
                .help("Stop agent")
            }
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
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

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = session.position }
                guard let dragOrigin else { return }
                session.position = CGPoint(
                    x: dragOrigin.x + value.translation.width / zoom,
                    y: dragOrigin.y + value.translation.height / zoom
                )
                onSelect()
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var accentColor: Color {
        switch session.provider {
        case .claude: Color(red: 0.91, green: 0.53, blue: 0.35)
        case .codex: Color(red: 0.30, green: 0.82, blue: 0.64)
        }
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
