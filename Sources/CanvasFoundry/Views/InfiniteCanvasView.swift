import SwiftUI

struct InfiniteCanvasView: View {
    @ObservedObject var model: WorkspaceModel
    @GestureState private var panTranslation = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGrid(zoom: effectiveZoom, pan: effectivePan)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(nil) }
                    .gesture(panGesture)
                    .simultaneousGesture(zoomGesture)

                ZStack(alignment: .topLeading) {
                    ForEach(model.sessions) { session in
                        CanvasAgentNode(
                            session: session,
                            zoom: effectiveZoom,
                            pan: model.pan
                        ) {
                            model.select(session)
                        } onRelaunch: {
                            model.relaunch(session)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(panTranslation)

                canvasHint
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($panTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                model.pan = CGSize(
                    width: model.pan.width + value.translation.width,
                    height: model.pan.height + value.translation.height
                )
            }
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
            Label("Drag the canvas to pan", systemImage: "hand.draw")
            Label("Pinch to zoom", systemImage: "plus.magnifyingglass")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CanvasAgentNode: View {
    @ObservedObject var session: AgentSession
    let zoom: CGFloat
    let pan: CGSize
    let onSelect: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        NativeTerminalCardContainer(
            content: AgentCardView(
                session: session,
                onSelect: onSelect,
                onRelaunch: onRelaunch
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

    var body: some View {
        Canvas { context, size in
            let minor = max(14, 36 * zoom)
            let major = minor * 5

            drawGrid(spacing: minor, opacity: 0.055, context: &context, size: size)
            drawGrid(spacing: major, opacity: 0.10, context: &context, size: size)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.04, blue: 0.055),
                    Color(red: 0.055, green: 0.05, blue: 0.065)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func drawGrid(
        spacing: CGFloat,
        opacity: Double,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        let startX = pan.width.truncatingRemainder(dividingBy: spacing)
        let startY = pan.height.truncatingRemainder(dividingBy: spacing)

        stride(from: startX, through: size.width, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: startY, through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: 0.7)
    }
}
