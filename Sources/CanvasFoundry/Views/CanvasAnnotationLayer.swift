import SwiftUI

/// Draws the annotation backdrop beneath the agent cards. Points arrive in world
/// space and are projected with the same `position * zoom + pan` transform the
/// cards use, so ink stays locked to the canvas.
struct CanvasAnnotationLayer: View {
    let annotations: [CanvasAnnotation]
    let draft: CanvasAnnotation?
    let zoom: CGFloat
    let pan: CGSize
    var selectedIDs: Set<UUID> = []
    /// Combined bounds of the selection, in world space.
    var selectionBounds: CGRect?
    /// Live rubber-band rectangle, in world space.
    var marquee: CGRect?
    /// Note currently open in the inline editor, which draws it instead.
    var editingID: UUID?

    var body: some View {
        Canvas { context, _ in
            for annotation in annotations where annotation.id != editingID {
                draw(annotation, in: &context)
            }
            if let draft {
                draw(draft, in: &context)
            }
            drawSelectionChrome(in: &context)
        }
        .allowsHitTesting(false)
    }

    private func drawSelectionChrome(in context: inout GraphicsContext) {
        let accent = GraphicsContext.Shading.color(Color.accentColor)

        // Per-item outlines, so it is obvious which pieces are in the selection.
        for annotation in annotations
        where selectedIDs.contains(annotation.id) && annotation.id != editingID {
            context.stroke(
                Path(
                    roundedRect: screenRect(annotation.boundingBox).insetBy(dx: -3, dy: -3),
                    cornerRadius: 3
                ),
                with: .color(Color.accentColor.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }

        // One box around the whole selection once more than a single item is in
        // play, matching how a grouped move behaves.
        if selectedIDs.count > 1, let selectionBounds {
            context.stroke(
                Path(roundedRect: screenRect(selectionBounds).insetBy(dx: -7, dy: -7), cornerRadius: 4),
                with: accent,
                style: StrokeStyle(lineWidth: 1.5)
            )
        }

        if let marquee {
            let rect = screenRect(marquee)
            context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.12)))
            context.stroke(
                Path(rect),
                with: accent,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
    }

    private func screenRect(_ worldRect: CGRect) -> CGRect {
        let origin = screenPoint(CGPoint(x: worldRect.minX, y: worldRect.minY))
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: worldRect.width * zoom,
            height: worldRect.height * zoom
        )
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    private func draw(_ annotation: CanvasAnnotation, in context: inout GraphicsContext) {
        let projected = annotation.points.map(screenPoint)
        guard let first = projected.first else { return }
        let stroke = StrokeStyle(
            lineWidth: max(1, annotation.lineWidth * zoom),
            lineCap: .round,
            lineJoin: .round
        )
        let shading = GraphicsContext.Shading.color(annotation.color.color)

        switch annotation.kind {
        case .text:
            guard !annotation.text.isEmpty else { return }
            context.draw(
                Text(annotation.text)
                    .font(.foundry(size: CanvasAnnotation.textFontSize * zoom, weight: .medium))
                    .foregroundColor(annotation.color.color),
                at: first,
                anchor: .topLeading
            )

        case .freehand:
            guard projected.count > 1 else {
                // A single tap still leaves a visible dot.
                let radius = max(1, annotation.lineWidth * zoom) / 2
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: first.x - radius,
                            y: first.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    ),
                    with: shading
                )
                return
            }
            var path = Path()
            path.move(to: first)
            for point in projected.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: shading, style: stroke)

        case .line, .arrow:
            guard let last = projected.last, projected.count > 1 else { return }
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
            context.stroke(path, with: shading, style: stroke)
            if annotation.kind == .arrow {
                context.stroke(
                    arrowHead(from: first, to: last, scale: zoom),
                    with: shading,
                    style: stroke
                )
            }

        case .rectangle:
            context.stroke(
                Path(roundedRect: rect(from: projected), cornerRadius: 4 * zoom),
                with: shading,
                style: stroke
            )

        case .ellipse:
            context.stroke(
                Path(ellipseIn: rect(from: projected)),
                with: shading,
                style: stroke
            )
        }
    }

    private func rect(from projected: [CGPoint]) -> CGRect {
        guard let start = projected.first, let end = projected.last else { return .zero }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func arrowHead(from start: CGPoint, to end: CGPoint, scale: CGFloat) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(7, 11 * scale)
        let spread = CGFloat.pi / 7
        var path = Path()
        path.move(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        path.addLine(to: end)
        path.addLine(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        return path
    }
}
