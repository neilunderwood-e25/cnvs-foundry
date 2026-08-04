import SwiftUI

struct InfiniteCanvasView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGrid(zoom: model.zoom, pan: model.pan)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(nil) }
                    .gesture(panGesture)
                    .simultaneousGesture(zoomGesture)

                ForEach(model.sessions) { session in
                    AgentCardView(session: session, zoom: model.zoom) {
                        model.select(session)
                    }
                    .frame(width: 420, height: 300)
                    .position(
                        x: session.position.x * model.zoom + model.pan.width,
                        y: session.position.y * model.zoom + model.pan.height
                    )
                    .scaleEffect(model.zoom, anchor: .center)
                }

                canvasHint
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .clipped()
            .accessibilityLabel("Agent canvas")
            .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panOrigin == nil { panOrigin = model.pan }
                guard let panOrigin else { return }
                model.pan = CGSize(
                    width: panOrigin.width + value.translation.width,
                    height: panOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in panOrigin = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomOrigin == nil { zoomOrigin = model.zoom }
                guard let zoomOrigin else { return }
                model.zoom = min(1.8, max(0.45, zoomOrigin * value))
            }
            .onEnded { _ in zoomOrigin = nil }
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
