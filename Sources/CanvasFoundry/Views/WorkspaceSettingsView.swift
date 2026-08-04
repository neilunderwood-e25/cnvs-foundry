import SwiftUI

/// Workspace preferences, shown in a popover from the toolbar. Currently just
/// the canvas backdrop; laid out as sections so more settings can slot in.
struct WorkspaceSettingsView: View {
    @ObservedObject var model: WorkspaceModel

    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.foundry(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 10) {
                Text("CANVAS BACKGROUND")
                    .font(.foundry(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(CanvasBackground.allCases) { background in
                        Button {
                            model.canvasBackground = background
                        } label: {
                            VStack(spacing: 5) {
                                CanvasBackgroundSwatch(
                                    background: background,
                                    isSelected: background == model.canvasBackground
                                )
                                Text(background.displayName)
                                    .font(.foundry(size: 9.5, weight: .medium))
                                    .foregroundStyle(
                                        background == model.canvasBackground
                                            ? .primary
                                            : .secondary
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(background.displayName)
                        .accessibilityLabel("\(background.displayName) background")
                        .accessibilityAddTraits(
                            background == model.canvasBackground
                                ? [.isButton, .isSelected]
                                : .isButton
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("DRAWINGS")
                    .font(.foundry(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(
                        model.annotations.isEmpty
                            ? "Nothing drawn yet"
                            : "\(model.annotations.count) item\(model.annotations.count == 1 ? "" : "s") on the canvas"
                    )
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear", action: model.clearAnnotations)
                        .disabled(model.annotations.isEmpty)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 258)
    }
}
