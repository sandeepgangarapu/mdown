// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MDownCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MDownCore", targets: ["MDownCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "MDownCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "MDownCoreTests",
            dependencies: ["MDownCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
