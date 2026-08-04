import SwiftUI

/// Floating project + settings control, parked over the top of the canvas rather
/// than in the window toolbar. Segments are split by hairlines so the capsule
/// reads as one control containing several actions.
struct CanvasProjectBar: View {
    @ObservedObject var model: WorkspaceModel

    @State private var isSettingsPresented = false
    @State private var isSettingsHovered = false
    @State private var isProjectHovered = false

    var body: some View {
        HStack(spacing: 0) {
            projectMenu
            segmentDivider
            settingsButton
        }
        .frame(height: 34)
        // Material alone picks up the backdrop and washes out over the tinted
        // presets, so it is darkened back down to a slate.
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(.black.opacity(0.42))
                }
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.13))
        }
        .shadow(color: .black.opacity(0.34), radius: 11, y: 4)
    }

    private var projectMenu: some View {
        Menu {
            Button(action: model.chooseProject) {
                Label("Add a New Project", systemImage: "plus")
            }

            if !model.recentProjectURLs.isEmpty {
                Divider()
                ForEach(model.recentProjectURLs, id: \.path) { projectURL in
                    Button {
                        model.openRecentProject(projectURL)
                    } label: {
                        Label(
                            projectURL.lastPathComponent,
                            systemImage: projectURL.standardizedFileURL
                                == model.projectURL?.standardizedFileURL
                                ? "checkmark.circle.fill"
                                : "folder"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                FoundryMarkView(size: 15, tint: Color(white: 0.93))
                Text(model.projectURL?.lastPathComponent ?? "Select Project")
                    .font(.foundry(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(isProjectHovered ? 1 : 0.92))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(isProjectHovered ? 0.9 : 0.6))
            }
            .padding(.leading, 14)
            .padding(.trailing, 13)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        // .borderlessButton hides its own label until hover; .button + .plain
        // keeps the pill drawn at all times.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isProjectHovered = $0 }
        .help("Choose from recent projects or add a new one")
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isSettingsHovered ? 1 : 0.82))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSettingsHovered ? Color.white.opacity(0.09) : Color.clear
        )
        .clipShape(Capsule())
        .onHover { isSettingsHovered = $0 }
        .help("Workspace settings")
        .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
            WorkspaceSettingsView(model: model)
        }
    }
}
