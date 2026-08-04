import SwiftUI

/// Floating tool rail for the drawing layer, pinned to the left of the canvas.
struct CanvasToolPalette: View {
    @ObservedObject var model: WorkspaceModel

    @State private var hoveredTool: CanvasTool?
    @State private var isUndoHovered = false

    var body: some View {
        VStack(spacing: 3) {
            ForEach(CanvasTool.allCases) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(width: 20)
                .opacity(0.35)
                .padding(.vertical, 3)

            ForEach(AnnotationColor.allCases) { color in
                colorButton(color)
            }

            Divider()
                .frame(width: 20)
                .opacity(0.35)
                .padding(.vertical, 3)

            // Only meaningful with a selection, so it stays out of the way until
            // there is one.
            if !model.selectedAnnotationIDs.isEmpty {
                actionButton(
                    symbol: "square.on.square.dashed",
                    label: "Group selection",
                    shortcut: "g",
                    modifiers: .command,
                    isEnabled: model.canGroupSelection,
                    action: model.groupSelection
                )
                actionButton(
                    symbol: "square.on.square.intersection.dashed",
                    label: "Ungroup selection",
                    shortcut: "g",
                    modifiers: [.command, .shift],
                    isEnabled: model.canUngroupSelection,
                    action: model.ungroupSelection
                )
                // Command-Delete, not bare Delete: a plain Backspace shortcut
                // would outrank the agent terminals typing on the same canvas.
                actionButton(
                    symbol: "trash",
                    label: "Delete selection (⌘⌫)",
                    shortcut: .delete,
                    modifiers: .command,
                    isEnabled: true,
                    action: model.deleteSelectedAnnotations
                )

                Divider()
                    .frame(width: 20)
                    .opacity(0.35)
                    .padding(.vertical, 3)
            }

            undoButton
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.42))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.13))
        }
        .shadow(color: .black.opacity(0.34), radius: 11, y: 4)
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        let isActive = model.activeTool == tool
        return Button {
            model.activeTool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : .white.opacity(0.86))
                .frame(width: 28, height: 28)
                .background(
                    isActive
                        ? AnyShapeStyle(Color.white.opacity(0.92))
                        : AnyShapeStyle(
                            hoveredTool == tool ? Color.white.opacity(0.12) : Color.clear
                        ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredTool = $0 ? tool : (hoveredTool == tool ? nil : hoveredTool) }
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func colorButton(_ inkColor: AnnotationColor) -> some View {
        let isActive = model.annotationColor == inkColor
        return Button {
            model.annotationColor = inkColor
            // Picking ink while on select implies an intent to draw.
            if model.activeTool == .select || model.activeTool == .eraser {
                model.activeTool = .pen
            }
        } label: {
            Circle()
                .fill(inkColor.color)
                .frame(width: 14, height: 14)
                .overlay {
                    Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                }
                .frame(width: 28, height: 24)
                .background(
                    isActive ? Color.white.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(inkColor.rawValue.capitalized) ink")
        .accessibilityLabel("\(inkColor.rawValue.capitalized) ink")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func actionButton(
        symbol: String,
        label: String,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 0.86 : 0.3))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .keyboardShortcut(shortcut, modifiers: modifiers)
        .help(label)
        .accessibilityLabel(label)
    }

    private var undoButton: some View {
        Button {
            model.undoAnnotationEdit()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    .white.opacity(model.canUndoAnnotationEdit ? (isUndoHovered ? 1 : 0.8) : 0.3)
                )
                .frame(width: 28, height: 28)
                .background(
                    isUndoHovered && model.canUndoAnnotationEdit
                        ? Color.white.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canUndoAnnotationEdit)
        .onHover { isUndoHovered = $0 }
        .keyboardShortcut("z", modifiers: .command)
        .help("Undo drawing")
        .accessibilityLabel("Undo drawing")
    }
}
