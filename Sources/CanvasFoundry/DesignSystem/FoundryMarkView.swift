import SwiftUI

/// The Foundry mark, drawn as vectors so it stays crisp at every size instead of
/// resampling a rasterised SVG.
struct FoundryBlockMark: Shape {
    /// How many blocks the mark is built from. The full lattice matches
    /// `Resources/Brand/Foundry-Mark.svg`; the compact form is a small-size
    /// simplification, since twelve blocks turn to noise below roughly 24pt.
    enum Density {
        case full
        case compact

        var grid: Int {
            switch self {
            case .full: 5
            case .compact: 3
            }
        }

        var cells: [(column: Int, row: Int)] {
            switch self {
            case .full:
                [
                    (1, 0), (3, 0),
                    (0, 1), (2, 1), (4, 1),
                    (1, 2), (3, 2),
                    (0, 3), (2, 3), (4, 3),
                    (1, 4), (3, 4)
                ]
            case .compact:
                [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)]
            }
        }
    }

    var density: Density = .full

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let cell = side / CGFloat(density.grid)
        let gap = cell * 0.08
        let corner = cell * 0.2
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)

        var path = Path()
        for slot in density.cells {
            let block = CGRect(
                x: origin.x + CGFloat(slot.column) * cell + gap,
                y: origin.y + CGFloat(slot.row) * cell + gap,
                width: cell - gap * 2,
                height: cell - gap * 2
            )
            path.addRoundedRect(
                in: block,
                cornerSize: CGSize(width: corner, height: corner)
            )
        }
        return path
    }
}

struct FoundryMarkView: View {
    let size: CGFloat
    var tint: Color = .white
    /// Defaults to the density that stays legible at `size`.
    var density: FoundryBlockMark.Density?

    var body: some View {
        FoundryBlockMark(density: density ?? (size < 24 ? .compact : .full))
            .fill(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
