import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WorkspaceModel()
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
                        EmptyWorkspaceView(
                            onCreateProject: { model.createNewProject() },
                            onChooseProject: { model.chooseProject() }
                        )
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
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
                guard scenePhase == .active else { continue }
                model.refreshAllGitSummaries()
                model.refreshAllPullRequests()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshAllGitSummaries()
                model.refreshAllPullRequests()
            } else {
                model.persistWorkspace()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .foundryNewProject)) { _ in
            model.createNewProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .foundryOpenProject)) { _ in
            model.chooseProject()
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
                    message: Text(bootstrapConfirmationMessage(request)),
                    primaryButton: .default(Text(bootstrapButtonTitle(request))) {
                        model.initializeRepository(request)
                    },
                    secondaryButton: .cancel()
                )
            case .deleteWorktree(let request):
                Alert(
                    title: Text("Delete \(request.agentName)?"),
                    message: Text(
                        request.hasUncommittedChanges
                            ? "This agent has uncommitted changes. Deleting it will permanently discard those changes."
                            : "This removes the agent and its isolated workspace. Published work and Git commits are preserved."
                    ),
                    primaryButton: .destructive(Text("Delete Agent")) {
                        model.deleteWorktree(request)
                    },
                    secondaryButton: .cancel()
                )
            case .switchProject(let request):
                Alert(
                    title: Text("Switch Projects?"),
                    message: Text(
                        "This replaces the current canvas containing \(request.existingAgentCount) agent\(request.existingAgentCount == 1 ? "" : "s"). Running agents will stop, but their work will remain on disk."
                    ),
                    primaryButton: .destructive(Text("Switch Project")) {
                        model.switchProject(request)
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
                onPublishPullRequest: { model.shipPullRequest(session) },
                onOpenPullRequest: { model.openPullRequest(session) },
                onPushPullRequestUpdates: { model.pushPullRequestUpdates(session) },
                onMarkPullRequestReady: { model.markPullRequestReady(session) },
                onSyncPullRequest: { model.syncPullRequestWithBase(session) },
                onMergePullRequest: { model.squashMergePullRequest(session) },
                onRefreshPullRequest: { model.refreshPullRequest(session) },
                onDelete: { model.prepareWorktreeDeletion(session) }
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
    }

    private func bootstrapConfirmationMessage(_ request: RepositoryBootstrapRequest) -> String {
        switch (request.shouldInitializeGit, request.hasExistingFiles) {
        case (true, true):
            "This folder isn't a Git repository yet. Canvas Foundry will run git init and commit the existing files as “Initial commit”, so agents branch from your code."
        case (true, false):
            "Canvas Foundry will initialize this empty folder locally and create the first commit required for isolated agents."
        case (false, true):
            "This repository has no commits. Canvas Foundry will commit the existing files as “Initial commit” so agents can work independently."
        case (false, false):
            "This repository has no commits. Canvas Foundry can create an empty initial commit so agents can work independently."
        }
    }

    private func bootstrapButtonTitle(_ request: RepositoryBootstrapRequest) -> String {
        switch (request.shouldInitializeGit, request.hasExistingFiles) {
        case (true, true): "Initialize & Commit Files"
        case (true, false): "Initialize Locally"
        case (false, _): "Create Commit"
        }
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
                Button {
                    model.openProject(in: ide)
                } label: {
                    Label("Open in \(ide.shortDisplayName)", systemImage: "folder")
                }
            }
        } label: {
            Label("Open in IDE", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .help("Open the project in an IDE")
    }

    private var installedIDEs: [ProjectIDE] {
        ProjectIDE.allCases.filter { $0.applicationURL() != nil }
    }
}

private struct EmptyWorkspaceView: View {
    let onCreateProject: () -> Void
    let onChooseProject: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            FoundryMarkView(size: 56)
            Text("Your agents need a place to build")
                .font(.foundry(size: 24, weight: .semibold))
            Text("Open any folder—Git projects open directly, and other folders can be initialized in one step. Every CLI agent works independently.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 510)
                .lineSpacing(4)
            HStack(spacing: 12) {
                Button("Create New Project", action: onCreateProject)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Open Existing Folder…", action: onChooseProject)
                    .buttonStyle(.bordered)
            }
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
