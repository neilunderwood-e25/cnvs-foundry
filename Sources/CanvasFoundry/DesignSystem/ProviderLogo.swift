import AppKit
import SwiftUI

/// Provider brand marks, authored as vectors so they stay crisp at every canvas
/// zoom level and can be tinted per surface instead of shipping flat bitmaps.
struct ProviderLogo: View {
    let provider: AgentProvider
    var size: CGFloat = 14
    var color: Color?

    var body: some View {
        let tint = color ?? provider.brandColor

        Group {
            switch provider {
            case .claude:
                AnthropicBurstMark()
                    .fill(tint)
            case .codex:
                OpenAIBlossomMark()
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: max(0.9, size * 0.072),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(provider.shortName) logo")
    }
}

/// Anthropic's starburst: evenly spaced blades that taper from a small hub out
/// to rounded tips.
struct AnthropicBurstMark: Shape {
    var bladeCount = 11

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tipRadius = radius * 0.98
        let hubRadius = radius * 0.05
        let halfSpread = (.pi / CGFloat(bladeCount)) * 0.36

        func point(_ distance: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + distance * cos(angle),
                y: center.y + distance * sin(angle)
            )
        }

        var path = Path()

        // Fuses the blade bases so the centre reads as solid rather than pinched.
        path.addEllipse(
            in: CGRect(
                x: center.x - hubRadius,
                y: center.y - hubRadius,
                width: hubRadius * 2,
                height: hubRadius * 2
            )
        )

        for index in 0..<bladeCount {
            let angle = (CGFloat(index) / CGFloat(bladeCount)) * 2 * .pi - .pi / 2
            path.move(to: point(hubRadius, angle - halfSpread * 0.55))
            path.addLine(to: point(tipRadius, angle - halfSpread))
            path.addQuadCurve(
                to: point(tipRadius, angle + halfSpread),
                control: point(tipRadius * 1.05, angle)
            )
            path.addLine(to: point(hubRadius, angle + halfSpread * 0.55))
            path.closeSubpath()
        }

        return path
    }
}

/// OpenAI's blossom knot: three congruent loops at sixty-degree offsets, which
/// resolve into the six-petal mark once stroked.
struct OpenAIBlossomMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let petalLength = side * 0.90
        let petalWidth = side * 0.345

        var path = Path()

        for index in 0..<3 {
            let petal = Path(
                roundedRect: CGRect(
                    x: -petalLength / 2,
                    y: -petalWidth / 2,
                    width: petalLength,
                    height: petalWidth
                ),
                cornerRadius: petalWidth / 2
            )
            let placement = CGAffineTransform(rotationAngle: CGFloat(index) * .pi / 3)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            path.addPath(petal, transform: placement)
        }

        return path
    }
}

/// macOS menu items draw an `NSImage` and ignore arbitrary SwiftUI content, so
/// the vector marks are rasterised once per provider and reused from then on.
@MainActor
enum ProviderLogoRaster {
    private static let pointSize: CGFloat = 14
    private static var cache: [AgentProvider: Image] = [:]

    static func menuIcon(for provider: AgentProvider) -> Image {
        if let cached = cache[provider] { return cached }

        let renderer = ImageRenderer(
            content: ProviderLogo(provider: provider, size: pointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let icon: Image
        if let rendered = renderer.nsImage {
            rendered.size = NSSize(width: pointSize, height: pointSize)
            icon = Image(nsImage: rendered)
        } else {
            icon = Image(systemName: provider.symbolName)
        }

        cache[provider] = icon
        return icon
    }
}

extension AgentProvider {
    /// The brand mark as a menu-ready image. See `ProviderLogoRaster`.
    @MainActor
    var menuIcon: Image { ProviderLogoRaster.menuIcon(for: self) }

    /// Mark colours taken from each vendor's own branding: Claude's terracotta,
    /// and OpenAI's monochrome mark rendered near-white for the dark canvas.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: Color(white: 0.94)
        }
    }
}
