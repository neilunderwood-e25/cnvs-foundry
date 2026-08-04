// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CanvasFoundry",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CanvasFoundry", targets: ["CanvasFoundry"])
    ],
    targets: [
        .executableTarget(
            name: "CanvasFoundry",
            path: "Sources/CanvasFoundry"
        ),
        .testTarget(
            name: "CanvasFoundryTests",
            dependencies: ["CanvasFoundry"],
            path: "Tests/CanvasFoundryTests"
        )
    ]
)
