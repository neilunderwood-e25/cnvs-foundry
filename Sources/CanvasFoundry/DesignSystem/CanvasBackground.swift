import SwiftUI

/// Selectable canvas backdrops.
///
/// Raw values are written into the persisted workspace, so renaming a case
/// silently drops a user's choice back to the default.
enum CanvasBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case midnight
    case graphite
    case ink
    case forest
    case plum

    static let fallback = CanvasBackground.midnight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .ink: "Ink"
        case .forest: "Forest"
        case .plum: "Plum"
        }
    }

    /// Flat fill behind the whole canvas.
    var baseColor: Color {
        switch self {
        case .midnight: Color(red: 0.018, green: 0.024, blue: 0.038)
        case .graphite: Color(red: 0.075, green: 0.078, blue: 0.086)
        case .ink: Color(red: 0.020, green: 0.020, blue: 0.023)
        case .forest: Color(red: 0.014, green: 0.045, blue: 0.036)
        case .plum: Color(red: 0.046, green: 0.020, blue: 0.056)
        }
    }

    /// Glow that lifts the top edge. `nil` keeps the backdrop perfectly flat.
    var glowColor: Color? {
        switch self {
        case .midnight: Color(red: 0.035, green: 0.090, blue: 0.170)
        case .graphite: Color(red: 0.160, green: 0.170, blue: 0.195)
        case .ink: nil
        case .forest: Color(red: 0.030, green: 0.130, blue: 0.092)
        case .plum: Color(red: 0.130, green: 0.048, blue: 0.170)
        }
    }

    /// Colour of the canvas dot grid.
    var dotColor: Color {
        switch self {
        case .midnight: .white.opacity(0.10)
        case .graphite: .white.opacity(0.085)
        case .ink: .white.opacity(0.075)
        case .forest: .white.opacity(0.09)
        case .plum: .white.opacity(0.095)
        }
    }

    /// Colour behind the window chrome, kept a touch lighter than `baseColor`
    /// so the canvas still reads as a distinct surface.
    var chromeColor: Color {
        switch self {
        case .midnight: Color(red: 0.022, green: 0.026, blue: 0.038)
        case .graphite: Color(red: 0.082, green: 0.085, blue: 0.093)
        case .ink: Color(red: 0.026, green: 0.026, blue: 0.029)
        case .forest: Color(red: 0.018, green: 0.050, blue: 0.040)
        case .plum: Color(red: 0.052, green: 0.024, blue: 0.062)
        }
    }
}

/// Miniature of a backdrop, used by the settings picker.
struct CanvasBackgroundSwatch: View {
    let background: CanvasBackground
    var isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(background.baseColor)
            .overlay {
                if let glowColor = background.glowColor {
                    RadialGradient(
                        colors: [glowColor.opacity(0.85), .clear],
                        center: .top,
                        startRadius: 1,
                        endRadius: 46
                    )
                }
            }
            .overlay {
                SwatchDots(color: background.dotColor)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .white.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .frame(width: 62, height: 40)
    }
}

private struct SwatchDots: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 9
            var path = Path()
            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                    path.addEllipse(
                        in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)
                    )
                }
            }
            context.fill(path, with: .color(color))
        }
    }
}
