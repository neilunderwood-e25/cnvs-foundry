import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WorkspaceModel()
    @State private var isReviewQueuePresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if model.projectURL != nil {
                    AgentFleetSidebar(model: model)
                    Divider().opacity(0.55)
                }
                InfiniteCanvasView(model: model)
                    .overlay {
                        if model.projectURL == nil {
                            EmptyWorkspaceView {
                                model.chooseProject()
                            }
                        }
                    }
            }
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .onDisappear {
            model.persistWorkspace()
        }
        .task {
            model.refreshAllGitSummaries()
            model.refreshAllPullRequests()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.persistWorkspace()
            }
        }
        .alert(item: $model.alertState) { state in
            switch state {
            case .message(let message):
                Alert(
                    title: Text("Canvas Foundry"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .bootstrap(let request):
                Alert(
                    title: Text(
                        request.shouldInitializeGit
                            ? "Initialize Git Repository?"
                            : "Create Initial Commit?"
                    ),
                    message: Text(
                        request.shouldInitializeGit
                            ? "Canvas Foundry will initialize this empty folder locally and create the first commit required for isolated worktrees."
                            : "This repository has no commits. Canvas Foundry can create an empty initial commit so agents can use isolated worktrees."
                    ),
                    primaryButton: .default(
                        Text(request.shouldInitializeGit ? "Initialize Locally" : "Create Commit")
                    ) {
                        model.initializeRepository(request)
                    },
                    secondaryButton: .cancel()
                )
            case .deleteWorktree(let request):
                Alert(
                    title: Text("Delete \(request.agentName)?"),
                    message: Text(
                        request.hasUncommittedChanges
                            ? "This worktree contains uncommitted changes. Deleting it will permanently discard those changes. The Git branch will be kept."
                            : "This removes the agent card and its worktree. The Git branch and its commits will be kept."
                    ),
                    primaryButton: .destructive(Text("Delete Worktree")) {
                        model.deleteWorktree(request)
                    },
                    secondaryButton: .cancel()
                )
            case .switchProject(let request):
                Alert(
                    title: Text("Switch Projects?"),
                    message: Text(
                        "This replaces the current canvas containing \(request.existingAgentCount) agent\(request.existingAgentCount == 1 ? "" : "s"). Running agents will stop, but every branch and worktree will remain on disk."
                    ),
                    primaryButton: .destructive(Text("Switch Project")) {
                        model.switchProject(request)
                    },
                    secondaryButton: .cancel()
                )
            case .publishPullRequest(let request):
                Alert(
                    title: Text("Publish \(request.agentName) as a Draft PR?"),
                    message: Text(pullRequestConfirmationMessage(request)),
                    primaryButton: .default(Text("Publish Draft PR")) {
                        model.publishPullRequest(request)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .sheet(item: $model.reviewingSession) { session in
            AgentGitReviewView(
                session: session,
                service: model.gitReviewService,
                onRepositoryChanged: model.refreshAllGitSummaries,
                onPreparePullRequest: {
                    model.reviewingSession = nil
                    model.preparePullRequest(session)
                },
                onOpenPullRequest: { model.openPullRequest(session) },
                onPushPullRequestUpdates: { model.pushPullRequestUpdates(session) }
            )
            .frame(minWidth: 940, minHeight: 680)
        }
        .sheet(isPresented: $isReviewQueuePresented) {
            PullRequestReviewQueueView(model: model)
        }
    }

    private func pullRequestConfirmationMessage(
        _ request: PullRequestPublishRequest
    ) -> String {
        var lines = [
            "“\(request.suggestedTitle)”",
            "\(request.commitCount) commit\(request.commitCount == 1 ? "" : "s") will be pushed to origin and opened against \(request.baseBranch)."
        ]
        if request.hasUncommittedChanges {
            lines.append("Warning: uncommitted worktree changes will not be included.")
        }
        if request.testStatus != .passed {
            lines.append("Warning: tests are currently \(request.testStatus.label.lowercased()).")
        }
        return lines.joined(separator: "\n\n")
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                FoundryMarkView(size: 20)
                Text("CANVAS FOUNDRY")
                    .font(.foundry(size: 13, weight: .bold))
                    .tracking(1.4)
            }

            Divider().frame(height: 22)

            Button {
                model.chooseProject()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(model.projectURL?.lastPathComponent ?? "Choose project")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if model.projectURL != nil {
                IDELaunchButtons(model: model)
                Button {
                    isReviewQueuePresented = true
                } label: {
                    Label(
                        model.openPullRequestCount == 0
                            ? "Review Queue"
                            : "Review Queue (\(model.openPullRequestCount))",
                        systemImage: "arrow.triangle.pull"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if !model.sessions.isEmpty {
                Label("\(model.activeAgentCount) working", systemImage: "circle.hexagongrid.fill")
                    .font(.foundry(size: 11, weight: .medium))
                    .foregroundStyle(model.activeAgentCount > 0 ? .green : .secondary)
            }

            HStack(spacing: 4) {
                Button(action: model.zoomOut) { Image(systemName: "minus") }
                Text("\(Int(model.zoom * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 45)
                Button(action: model.zoomIn) { Image(systemName: "plus") }
                Button(action: model.resetView) { Image(systemName: "scope") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if model.projectURL != nil {
                Menu {
                    ForEach(AgentProvider.allCases) { provider in
                        Button {
                            model.openTerminal(provider: provider)
                        } label: {
                            Label("Open \(provider.launchName)", systemImage: provider.symbolName)
                        }
                    }
                } label: {
                    Label("New Agent", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }
}

private struct IDELaunchButtons: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ForEach(installedIDEs, id: \.ide.id) { application in
            Menu {
                Button {
                    model.openProject(in: application.ide)
                } label: {
                    Label("Open Main Project", systemImage: "folder")
                }
                if !model.availableIDEWorktreeSessions.isEmpty {
                    Button {
                        model.openAllActiveWorktrees(in: application.ide)
                    } label: {
                        Label(
                            "Open Main + \(model.availableIDEWorktreeSessions.count) Agent Worktree\(model.availableIDEWorktreeSessions.count == 1 ? "" : "s")",
                            systemImage: "square.3.layers.3d"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: application.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(application.ide.buttonTitle)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Choose which worktrees to open in \(application.ide.buttonTitle)")
        }
    }

    private var installedIDEs: [(ide: ProjectIDE, icon: NSImage)] {
        ProjectIDE.allCases.compactMap { ide in
            guard let applicationURL = ide.applicationURL() else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            return (ide, icon)
        }
    }
}

private struct EmptyWorkspaceView: View {
    let onChooseProject: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            FoundryMarkView(size: 56)
            Text("Your agents need a place to build")
                .font(.foundry(size: 24, weight: .semibold))
            Text("Choose a Git project or an empty folder to initialize locally. Every CLI agent gets its own branch and worktree.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 510)
                .lineSpacing(4)
            Button("Choose Git Project", action: onChooseProject)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
        }
        .padding(38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.09))
        }
    }
}
