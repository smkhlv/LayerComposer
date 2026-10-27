// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LayerComposer",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "LayerComposer",
            targets: ["LayerComposer"]
        ),
    ],
    targets: [
        .target(
            name: "LayerComposer",
            path: "Sources/LayerComposer",
            resources: [
                .process("Resources/Compositor.metal")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LayerComposerTests",
            dependencies: ["LayerComposer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
