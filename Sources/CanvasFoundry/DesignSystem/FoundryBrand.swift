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
        guard let iconURL = resourceURL(
            named: "Foundry-App-Icon",
            extension: "svg",
            subdirectory: "Brand"
        ), let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }

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

struct FoundryMarkView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = FoundryBrand.markImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
