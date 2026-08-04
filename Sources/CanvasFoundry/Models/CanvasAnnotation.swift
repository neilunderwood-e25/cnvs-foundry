import AppKit
import SwiftUI

/// What a canvas drag does. `select` keeps the original pan-and-select behaviour.
enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case select
    case hand
    case pen
    case rectangle
    case ellipse
    case line
    case arrow
    case text
    case eraser

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .pen: "scribble"
        case .rectangle: "square"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "character.textbox"
        case .eraser: "eraser"
        }
    }

    var title: String {
        switch self {
        case .select: "Select, move and group"
        case .hand: "Pan the canvas"
        case .pen: "Draw freehand"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text note"
        case .eraser: "Erase"
        }
    }

    /// Tools that build a shape from a drag between two points.
    var dragsOutAShape: Bool {
        switch self {
        case .pen, .rectangle, .ellipse, .line, .arrow: true
        case .select, .hand, .text, .eraser: false
        }
    }

    var annotationKind: CanvasAnnotation.Kind? {
        switch self {
        case .pen: .freehand
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .select, .hand, .eraser: nil
        }
    }
}

/// Ink colours for annotations. Raw values are persisted.
enum AnnotationColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case chalk
    case amber
    case mint
    case sky
    case rose

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .chalk: Color(red: 0.90, green: 0.91, blue: 0.94)
        case .amber: Color(red: 0.96, green: 0.66, blue: 0.26)
        case .mint: Color(red: 0.36, green: 0.86, blue: 0.60)
        case .sky: Color(red: 0.44, green: 0.68, blue: 0.98)
        case .rose: Color(red: 0.96, green: 0.44, blue: 0.52)
        }
    }
}

/// A drawing on the canvas backdrop. All points are in canvas world space, so
/// annotations pan and zoom with the agent cards.
struct CanvasAnnotation: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case freehand
        case rectangle
        case ellipse
        case line
        case arrow
        case text
    }

    let id: UUID
    var kind: Kind
    /// `freehand` holds the whole stroke, shapes hold two opposite corners or
    /// endpoints, and `text` holds a single anchor.
    var points: [CGPoint]
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String
    /// Shared by every member of a group; `nil` when ungrouped. Selecting one
    /// member selects the whole group.
    var groupID: UUID?

    init(
        id: UUID = UUID(),
        kind: Kind,
        points: [CGPoint],
        color: AnnotationColor,
        lineWidth: CGFloat = 2.5,
        text: String = "",
        groupID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.groupID = groupID
    }

    func translated(by offset: CGSize) -> CanvasAnnotation {
        var copy = self
        copy.points = points.map {
            CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        }
        return copy
    }

    static let textFontSize: CGFloat = 15

    static func textFont(scale: CGFloat = 1) -> NSFont {
        let size = textFontSize * scale
        return NSFont(name: "Inter-Medium", size: size)
            ?? .systemFont(ofSize: size, weight: .medium)
    }

    /// Laid-out size of a note in world units, newlines included. Measured
    /// rather than estimated so the hit box matches what is actually drawn.
    static func measuredTextSize(_ text: String) -> CGSize {
        let probe = text.isEmpty ? " " : text
        let measured = NSAttributedString(
            string: probe,
            attributes: [.font: textFont()]
        ).boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(
            width: max(24, CGFloat(measured.width).rounded(.up)),
            height: max(textFontSize * 1.25, CGFloat(measured.height).rounded(.up))
        )
    }

    var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var minPoint = first
        var maxPoint = first
        for point in points.dropFirst() {
            minPoint.x = min(minPoint.x, point.x)
            minPoint.y = min(minPoint.y, point.y)
            maxPoint.x = max(maxPoint.x, point.x)
            maxPoint.y = max(maxPoint.y, point.y)
        }
        if kind == .text {
            let size = Self.measuredTextSize(text)
            return CGRect(
                x: minPoint.x,
                y: minPoint.y,
                width: size.width,
                height: size.height
            )
        }
        return CGRect(
            x: minPoint.x,
            y: minPoint.y,
            width: maxPoint.x - minPoint.x,
            height: maxPoint.y - minPoint.y
        )
    }

    /// True when `point` is close enough to count as touching this annotation.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .text:
            return boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .freehand, .line, .arrow:
            guard points.count > 1 else {
                guard let only = points.first else { return false }
                return Self.distance(only, point) <= tolerance
            }
            for index in 0..<(points.count - 1) {
                if Self.distanceToSegment(
                    point,
                    start: points[index],
                    end: points[index + 1]
                ) <= tolerance {
                    return true
                }
            }
            return false

        case .rectangle:
            let box = boundingBox
            guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else {
                return false
            }
            // Only the outline is drawn, so ignore the hollow middle.
            let inner = box.insetBy(dx: tolerance, dy: tolerance)
            return inner.width <= 0 || inner.height <= 0 || !inner.contains(point)

        case .ellipse:
            let box = boundingBox
            let radiusX = box.width / 2
            let radiusY = box.height / 2
            guard radiusX > 0, radiusY > 0 else { return false }
            let normalizedX = (point.x - box.midX) / radiusX
            let normalizedY = (point.y - box.midY) / radiusY
            let radial = (normalizedX * normalizedX + normalizedY * normalizedY).squareRoot()
            return abs(radial - 1) * min(radiusX, radiusY) <= tolerance
        }
    }

    /// Rebuilds an annotation from a stored record, rejecting malformed ones —
    /// an unknown kind or colour from a newer file, or coordinate arrays that
    /// disagree on length.
    init?(persisted: PersistedAnnotation) {
        guard let kind = Kind(rawValue: persisted.kind),
              let color = AnnotationColor(rawValue: persisted.color),
              persisted.pointsX.count == persisted.pointsY.count,
              !persisted.pointsX.isEmpty else {
            return nil
        }
        self.init(
            id: persisted.id,
            kind: kind,
            points: zip(persisted.pointsX, persisted.pointsY).map { CGPoint(x: $0, y: $1) },
            color: color,
            lineWidth: CGFloat(persisted.lineWidth),
            text: persisted.text ?? "",
            groupID: persisted.groupID
        )
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func distanceToSegment(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return distance(point, start) }
        let projection =
            ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared
        let clamped = min(1, max(0, projection))
        let closest = CGPoint(
            x: start.x + clamped * deltaX,
            y: start.y + clamped * deltaY
        )
        return distance(point, closest)
    }
}
