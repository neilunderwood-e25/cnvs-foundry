import AppKit
import SwiftUI

struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var isLauncherPresented = false

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
        .sheet(isPresented: $isLauncherPresented) {
            AgentLauncherView(model: model)
        }
        .alert(
            "Canvas Foundry",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
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

            Button {
                if model.projectURL == nil {
                    model.chooseProject()
                } else {
                    isLauncherPresented = true
                }
            } label: {
                Label("New agent", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .keyboardShortcut("n", modifiers: .command)
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
            Text("Choose a Git project. Every agent will get its own branch and worktree, then run independently on this canvas.")
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
