import AppKit
import CoreText
import SwiftUI

enum FoundryFontWeight {
    case regular
    case medium
    case semibold
    case bold

    var postScriptName: String {
        switch self {
        case .regular: "Inter-Regular"
        case .medium: "Inter-Medium"
        case .semibold: "Inter-SemiBold"
        case .bold: "Inter-Bold"
        }
    }
}

enum FoundryBrand {
    static let fontResourceNames = [
        "Inter-Regular",
        "Inter-Medium",
        "Inter-SemiBold",
        "Inter-Bold"
    ]

    static func registerBundledFonts() {
        for resourceName in fontResourceNames {
            guard let url = resourceURL(
                named: resourceName,
                extension: "otf",
                subdirectory: "Fonts"
            ) else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func applyApplicationIcon() {
        NSApp.applicationIconImage = appIconImage
    }

    static let appIconImage: NSImage? = {
        guard let iconURL = resourceURL(
            named: "Foundry-App-Icon",
            extension: "svg",
            subdirectory: "Brand"
        ), let sourceImage = NSImage(contentsOf: iconURL) else {
            return nil
        }

        let canvasSize = NSSize(width: 512, height: 512)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        bitmap.size = canvasSize
        let canvasRect = NSRect(origin: .zero, size: canvasSize)
        let iconRect = canvasRect.insetBy(dx: 24, dy: 24)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSBezierPath(rect: canvasRect).fill()
        NSBezierPath(
            roundedRect: iconRect,
            xRadius: 108,
            yRadius: 108
        ).addClip()
        sourceImage.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvasSize)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }()

    static var markImage: NSImage? {
        guard let url = resourceURL(
            named: "Foundry-Mark",
            extension: "svg",
            subdirectory: "Brand"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}

extension Font {
    static func foundry(
        size: CGFloat,
        weight: FoundryFontWeight = .regular
    ) -> Font {
        .custom(weight.postScriptName, size: size)
    }
}

struct FoundryAppIconView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = FoundryBrand.appIconImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                FoundryMarkView(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }
}
