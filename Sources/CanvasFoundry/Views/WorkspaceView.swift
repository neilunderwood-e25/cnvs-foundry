import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            InfiniteCanvasView(model: model)
                .overlay {
                    if model.projectURL == nil {
                        EmptyWorkspaceView {
                            model.chooseProject()
                        }
                    }
                }
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .onDisappear {
            model.persistWorkspace()
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
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .foregroundStyle(.orange)
                Text("CANVAS FOUNDRY")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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

            Spacer()

            if !model.sessions.isEmpty {
                Label("\(model.activeAgentCount) working", systemImage: "circle.hexagongrid.fill")
                    .font(.caption)
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

private struct EmptyWorkspaceView: View {
    let onChooseProject: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)
            Text("Your agents need a place to build")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
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
