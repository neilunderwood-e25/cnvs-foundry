import AppKit
import SwiftUI

/// What a select-tool drag turned out to be, decided on its first movement.
private enum SelectDragMode: Equatable {
    case moving
    case marquee(start: CGPoint)
}

struct InfiniteCanvasView: View {
    @ObservedObject var model: WorkspaceModel
    @GestureState private var panTranslation = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @State private var draftAnnotation: CanvasAnnotation?
    @State private var editingTextID: UUID?
    @State private var editingText = ""
    @State private var editingColor: AnnotationColor = .chalk
    @FocusState private var isEditingTextFocused: Bool
    @AppStorage(CommandBarVisibility.key) private var isCommandBarVisible = true
    @State private var selectDragMode: SelectDragMode?
    @State private var isMovingSelection = false
    @State private var marqueeRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGrid(
                    zoom: effectiveZoom,
                    pan: effectivePan,
                    background: model.canvasBackground
                )
                    .contentShape(Rectangle())
                    .overlay {
                        CanvasInputShim(
                            cursor: model.activeTool.cursor,
                            handlesScroll: { !isOverAgentCard($0) },
                            onPan: { model.panBy($0) },
                            onZoom: { factor, point in
                                model.zoom(by: factor, anchoredAt: point)
                            }
                        )
                    }
                    .gesture(panGesture)
                    .simultaneousGesture(zoomGesture)
                    .simultaneousGesture(canvasDragGesture)
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in handleDoubleClick(at: value.location) }
                    )

                CanvasAnnotationLayer(
                    annotations: model.annotations,
                    draft: draftAnnotation,
                    zoom: effectiveZoom,
                    pan: model.pan,
                    selectedIDs: model.selectedAnnotationIDs,
                    selectionBounds: model.selectionBounds,
                    marquee: marqueeRect,
                    editingID: editingTextID
                )
                .offset(panTranslation)

                ZStack(alignment: .topLeading) {
                    ForEach(model.visibleSessions) { session in
                        CanvasAgentNode(
                            session: session,
                            zoom: effectiveZoom,
                            pan: model.pan
                        ) {
                            model.select(session)
                        } onRelaunch: {
                            model.relaunch(session)
                        } onReview: {
                            model.review(session)
                        } onArchive: {
                            model.archive(session)
                        } onDelete: {
                            model.prepareWorktreeDeletion(session)
                        } onOpenInIDE: { ide in
                            model.openAgentWorktree(session, in: ide)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(panTranslation)
                // Cards step aside for every tool but select, so a stroke can
                // cross a terminal without moving it — and the hand tool can pan
                // from anywhere.
                .allowsHitTesting(model.activeTool == .select)

                if let editingTextID, let anchor = textEditorAnchor(for: editingTextID) {
                    inlineTextEditor(anchor: anchor)
                }

                if model.visibleSessions.isEmpty && model.projectURL != nil {
                    canvasHint
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                if model.projectURL != nil {
                    CanvasToolPalette(model: model)
                        .padding(.leading, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    if isCommandBarVisible {
                        CommandBar(model: model, isVisible: $isCommandBarVisible)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }

                    canvasZoomControls
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipped()
            .accessibilityLabel("Agent canvas")
            .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
            .onAppear { model.updateViewport(proxy.size) }
            .onChange(of: proxy.size) { _, newSize in
                model.updateViewport(newSize)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    /// Panning, now owned by the hand tool so a select drag is free to
    /// rubber-band like tldraw.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($panTranslation) { value, state, _ in
                guard model.activeTool == .hand else { return }
                state = value.translation
            }
            .onEnded { value in
                guard model.activeTool == .hand else { return }
                model.pan = CGSize(
                    width: model.pan.width + value.translation.width,
                    height: model.pan.height + value.translation.height
                )
            }
    }

    /// Selecting, moving, drawing and erasing. Attached alongside `panGesture`;
    /// whichever tool is inactive simply ignores the events.
    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch model.activeTool {
                case .select:
                    updateSelectDrag(value)
                case .eraser:
                    model.eraseAnnotations(
                        near: worldPoint(value.location),
                        tolerance: eraserTolerance
                    )
                case let tool where tool.dragsOutAShape:
                    extendDraft(tool: tool, from: value.startLocation, to: value.location)
                default:
                    break
                }
            }
            .onEnded { value in
                switch model.activeTool {
                case .select:
                    finishSelectDrag(value)
                case .eraser:
                    model.eraseAnnotations(
                        near: worldPoint(value.location),
                        tolerance: eraserTolerance
                    )
                case .text:
                    beginTextNote(at: worldPoint(value.location))
                case let tool where tool.dragsOutAShape:
                    extendDraft(tool: tool, from: value.startLocation, to: value.location)
                    if let draftAnnotation {
                        model.addAnnotation(draftAnnotation)
                    }
                    draftAnnotation = nil
                default:
                    break
                }
            }
    }

    /// Click radius in world units, so it feels the same at any zoom.
    private var hitTolerance: CGFloat { 9 / max(model.zoom, 0.01) }

    /// Cards are laid out at a fixed size and only their centres scale, matching
    /// how `CanvasAgentNode` positions them.
    private func isOverAgentCard(_ screenPoint: CGPoint) -> Bool {
        model.visibleSessions.contains { session in
            let center = CGPoint(
                x: session.position.x * model.zoom + model.pan.width,
                y: session.position.y * model.zoom + model.pan.height
            )
            return CGRect(
                x: center.x - session.size.width / 2,
                y: center.y - session.size.height / 2,
                width: session.size.width,
                height: session.size.height
            ).contains(screenPoint)
        }
    }

    private var isShiftHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func updateSelectDrag(_ value: DragGesture.Value) {
        let start = worldPoint(value.startLocation)

        if selectDragMode == nil {
            if let hit = model.annotation(at: start, tolerance: hitTolerance) {
                // Dragging an unselected item takes it (and its group) first.
                if !model.selectedAnnotationIDs.contains(hit.id) {
                    model.selectAnnotation(hit.id, additive: isShiftHeld)
                }
                selectDragMode = .moving
            } else {
                selectDragMode = .marquee(start: start)
            }
        }

        switch selectDragMode {
        case .moving:
            let translation = CGSize(
                width: value.translation.width / model.zoom,
                height: value.translation.height / model.zoom
            )
            // Deferred so a plain click doesn't push a no-op onto the undo stack.
            if !isMovingSelection, abs(value.translation.width) + abs(value.translation.height) > 1 {
                model.beginSelectionDrag()
                isMovingSelection = true
            }
            if isMovingSelection {
                model.updateSelectionDrag(translation: translation)
            }

        case .marquee(let origin):
            let current = worldPoint(value.location)
            let rect = CGRect(
                x: min(origin.x, current.x),
                y: min(origin.y, current.y),
                width: abs(current.x - origin.x),
                height: abs(current.y - origin.y)
            )
            marqueeRect = rect
            model.selectAnnotations(in: rect, additive: isShiftHeld)

        case nil:
            break
        }
    }

    private func finishSelectDrag(_ value: DragGesture.Value) {
        let travelled = abs(value.translation.width) + abs(value.translation.height)

        switch selectDragMode {
        case .moving:
            if isMovingSelection {
                model.endSelectionDrag()
            } else {
                // A click, not a drag: settle the selection on what was clicked.
                let point = worldPoint(value.location)
                if let hit = model.annotation(at: point, tolerance: hitTolerance) {
                    model.selectAnnotation(hit.id, additive: isShiftHeld)
                }
            }

        case .marquee:
            // A click on empty canvas clears both kinds of selection.
            if travelled <= 1, !isShiftHeld {
                model.clearAnnotationSelection()
                model.select(nil)
            }

        case nil:
            break
        }

        selectDragMode = nil
        isMovingSelection = false
        marqueeRect = nil
    }

    /// Erase radius in world units, so it feels the same at any zoom.
    private var eraserTolerance: CGFloat { 10 / max(model.zoom, 0.01) }

    private func worldPoint(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (screenPoint.x - model.pan.width) / model.zoom,
            y: (screenPoint.y - model.pan.height) / model.zoom
        )
    }

    private func screenPoint(_ worldPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: worldPoint.x * model.zoom + model.pan.width,
            y: worldPoint.y * model.zoom + model.pan.height
        )
    }

    private func extendDraft(tool: CanvasTool, from start: CGPoint, to current: CGPoint) {
        guard let kind = tool.annotationKind else { return }
        let worldCurrent = worldPoint(current)

        guard var existing = draftAnnotation, existing.kind == kind else {
            draftAnnotation = CanvasAnnotation(
                kind: kind,
                points: [worldPoint(start), worldCurrent],
                color: model.annotationColor
            )
            return
        }

        if kind == .freehand {
            // Skip near-duplicate samples so long strokes stay cheap to redraw.
            if let last = existing.points.last,
               CanvasAnnotation.distance(last, worldCurrent) < 1.5 / max(model.zoom, 0.01) {
                return
            }
            existing.points.append(worldCurrent)
        } else {
            existing.points = [worldPoint(start), worldCurrent]
        }
        draftAnnotation = existing
    }

    /// Types directly on the canvas: same font, same colour, same scale as the
    /// committed note, anchored so the first glyph lands where it was clicked.
    private func inlineTextEditor(anchor: CGPoint) -> some View {
        let scale = model.zoom
        let measured = CanvasAnnotation.measuredTextSize(editingText)

        return TextEditor(text: $editingText)
            .font(.foundry(size: CanvasAnnotation.textFontSize * scale, weight: .medium))
            .foregroundStyle(editingColor.color)
            .tint(editingColor.color)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused($isEditingTextFocused)
            // Room to keep typing past the last glyph, and for the caret.
            .frame(
                width: (measured.width + 26) * scale,
                height: (measured.height + 4) * scale
            )
            .overlay {
                Rectangle()
                    .strokeBorder(editingColor.color.opacity(0.45), lineWidth: 1)
            }
            // TextEditor insets its text by ~5pt; cancel that so the glyphs sit
            // exactly where the drawn note will.
            .offset(x: anchor.x - 5 * scale, y: anchor.y - 5 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onExitCommand(perform: commitEditingText)
    }

    private func beginTextNote(at worldLocation: CGPoint) {
        commitEditingText()
        let note = CanvasAnnotation(
            kind: .text,
            points: [worldLocation],
            color: model.annotationColor
        )
        model.addAnnotation(note)
        editingText = ""
        editingColor = model.annotationColor
        editingTextID = note.id
        DispatchQueue.main.async { isEditingTextFocused = true }
    }

    /// Re-opens an existing note for editing, the way a tldraw double-click does.
    private func editExistingNote(_ annotation: CanvasAnnotation) {
        guard annotation.kind == .text else { return }
        commitEditingText()
        editingText = annotation.text
        editingColor = annotation.color
        editingTextID = annotation.id
        DispatchQueue.main.async { isEditingTextFocused = true }
    }

    private func commitEditingText() {
        guard let editingTextID else { return }
        model.updateAnnotationText(editingTextID, to: editingText)
        self.editingTextID = nil
        editingText = ""
        isEditingTextFocused = false
        // tldraw drops you back into select with the new note picked, ready to
        // move or group it.
        model.activeTool = .select
        if model.annotations.contains(where: { $0.id == editingTextID }) {
            model.selectAnnotation(editingTextID, additive: false)
        }
    }

    /// Double-click: edit the note under the cursor, or start a new one.
    private func handleDoubleClick(at location: CGPoint) {
        guard model.activeTool == .select else { return }
        let point = worldPoint(location)
        if let hit = model.annotation(at: point, tolerance: hitTolerance),
           hit.kind == .text {
            editExistingNote(hit)
        } else if model.annotation(at: point, tolerance: hitTolerance) == nil {
            model.clearAnnotationSelection()
            beginTextNote(at: point)
        }
    }

    private func textEditorAnchor(for id: UUID) -> CGPoint? {
        guard let annotation = model.annotations.first(where: { $0.id == id }),
              let anchor = annotation.points.first else {
            return nil
        }
        return screenPoint(anchor)
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                model.zoom = min(1.8, max(0.45, model.zoom * value))
            }
    }

    private var effectivePan: CGSize {
        CGSize(
            width: model.pan.width + panTranslation.width,
            height: model.pan.height + panTranslation.height
        )
    }

    private var effectiveZoom: CGFloat {
        min(1.8, max(0.45, model.zoom * magnification))
    }

    private var canvasHint: some View {
        HStack(spacing: 12) {
            Label("Scroll to pan", systemImage: "hand.draw")
            Label("⌘-scroll to zoom", systemImage: "plus.magnifyingglass")
            Label("Drag to marquee-select", systemImage: "cursorarrow")
        }
        .font(.foundry(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var canvasZoomControls: some View {
        HStack(spacing: 4) {
            Button(action: model.zoomOut) {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
            }
            Text("\(Int(model.zoom * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42)
            Button(action: model.zoomIn) {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)
            Button(action: model.resetView) {
                Image(systemName: "scope")
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.07))
        }
    }
}

private struct CanvasAgentNode: View {
    @ObservedObject var session: AgentSession
    let zoom: CGFloat
    let pan: CGSize
    let onSelect: () -> Void
    let onRelaunch: () -> Void
    let onReview: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onOpenInIDE: (ProjectIDE) -> Void

    var body: some View {
        NativeTerminalCardContainer(
            content: AgentCardView(
                session: session,
                onSelect: onSelect,
                onRelaunch: onRelaunch,
                onReview: onReview,
                onArchive: onArchive,
                onDelete: onDelete,
                onOpenInIDE: onOpenInIDE
            ),
            onInteractionBegan: onSelect,
            onMoveEnded: { translation in
                session.position = CGPoint(
                    x: session.position.x + translation.width / zoom,
                    y: session.position.y + translation.height / zoom
                )
            },
            onResizeEnded: { newSize, centerShift in
                session.size = newSize
                session.position = CGPoint(
                    x: session.position.x + centerShift.width / zoom,
                    y: session.position.y + centerShift.height / zoom
                )
            }
        )
        .frame(width: session.size.width, height: session.size.height)
        .position(
            x: session.position.x * zoom + pan.width,
            y: session.position.y * zoom + pan.height
        )
        .zIndex(session.isSelected ? 10 : 0)
    }
}

private struct CanvasGrid: View {
    let zoom: CGFloat
    let pan: CGSize
    let background: CanvasBackground

    var body: some View {
        Canvas { context, size in
            drawDots(
                spacing: max(18, 42 * zoom),
                context: &context,
                size: size
            )
        }
        .background(
            ZStack {
                background.baseColor
                if let glowColor = background.glowColor {
                    RadialGradient(
                        colors: [glowColor.opacity(0.7), .clear],
                        center: .top,
                        startRadius: 20,
                        endRadius: 850
                    )
                }
            }
        )
    }

    private func drawDots(
        spacing: CGFloat,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let startX = pan.width.truncatingRemainder(dividingBy: spacing)
        let startY = pan.height.truncatingRemainder(dividingBy: spacing)
        var path = Path()
        for x in stride(from: startX, through: size.width, by: spacing) {
            for y in stride(from: startY, through: size.height, by: spacing) {
                path.addEllipse(
                    in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)
                )
            }
        }
        context.fill(path, with: .color(background.dotColor))
    }
}
