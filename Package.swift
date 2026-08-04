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
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "CanvasFoundry",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/CanvasFoundry",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CanvasFoundryTests",
            dependencies: ["CanvasFoundry"],
            path: "Tests/CanvasFoundryTests"
        )
    ]
)
