import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WorkspaceModel()
    @State private var isReviewQueuePresented = false
    @AppStorage("foundry.agentSidebarVisible") private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if model.projectURL != nil && isSidebarVisible {
                HStack(spacing: 0) {
                    AgentFleetSidebar(model: model)
                        .frame(width: 248)
                    Divider()
                        .opacity(0.45)
                }
                .frame(width: 249)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            InfiniteCanvasView(model: model)
                .overlay {
                    if model.projectURL == nil {
                        EmptyWorkspaceView {
                            model.chooseProject()
                        }
                    }
                }
                // Layered last so the control floats above both the canvas and
                // the empty state.
                .overlay(alignment: .top) {
                    CanvasProjectBar(model: model)
                        .padding(.top, 14)
                }
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
        .toolbar {
            workspaceToolbar
        }
        .background(model.canvasBackground.chromeColor)
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
            // Flexible upper bounds make the sheet resizable; ideal sizes open
            // it large enough to review a real diff without immediately
            // reaching for the resize handle.
            .frame(
                minWidth: 1000,
                idealWidth: 1360,
                maxWidth: .infinity,
                minHeight: 660,
                idealHeight: 880,
                maxHeight: .infinity
            )
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

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if model.projectURL != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible.toggle()
                    }
                } label: {
                    Label(
                        isSidebarVisible ? "Hide Agent Sidebar" : "Show Agent Sidebar",
                        systemImage: "sidebar.left"
                    )
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help(isSidebarVisible ? "Hide agent sidebar" : "Show agent sidebar")
            }
        }

        if model.projectURL != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isReviewQueuePresented = true
                } label: {
                    Label(
                        model.openPullRequestCount == 0
                            ? "Review Queue"
                            : "Review Queue, \(model.openPullRequestCount) open",
                        systemImage: "arrow.triangle.pull"
                    )
                }
                .help("Open review queue")

                IDELaunchToolbarMenu(model: model)

                Menu {
                    ForEach(AgentProvider.allCases) { provider in
                        Button {
                            model.openTerminal(provider: provider)
                        } label: {
                            Label {
                                Text("Open \(provider.launchName)")
                            } icon: {
                                provider.menuIcon
                            }
                        }
                    }
                } label: {
                    Label("New Agent", systemImage: "plus")
                }
                .help("Open a new CLI agent")
            }
        }
    }
}

private struct IDELaunchToolbarMenu: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Menu {
            if installedIDEs.isEmpty {
                Text("No supported IDE is installed")
            }
            ForEach(installedIDEs) { ide in
                Section(ide.buttonTitle) {
                    Button {
                        model.openProject(in: ide)
                    } label: {
                        Label("Open Main Project", systemImage: "folder")
                    }
                    if !model.availableIDEWorktreeSessions.isEmpty {
                        Button {
                            model.openAllActiveWorktrees(in: ide)
                        } label: {
                            Label(
                                "Open Main + \(model.availableIDEWorktreeSessions.count) Agent Worktree\(model.availableIDEWorktreeSessions.count == 1 ? "" : "s")",
                                systemImage: "square.3.layers.3d"
                            )
                        }
                    }
                }
            }
        } label: {
            Label("Open in IDE", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .help("Open project or worktrees in an IDE")
    }

    private var installedIDEs: [ProjectIDE] {
        ProjectIDE.allCases.filter { $0.applicationURL() != nil }
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
