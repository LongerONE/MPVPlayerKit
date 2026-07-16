// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MPVPlayerKit",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "MPVPlayerKit",
            type: .dynamic,
            targets: ["MPVPlayerKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.41.0"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "5.7.1"),
    ],
    targets: [
        .target(
            name: "MPVPlayerKit",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
                .product(name: "SnapKit-Dynamic", package: "SnapKit"),
            ],
            path: ".",
            exclude: [
                "LICENSE",
                "README.md",
                "Demo",
                "Tests",
            ],
            sources: ["Sources/MPVPlayerKit"],
            resources: [
                .process("Resources"),
            ],
            cSettings: [
                .headerSearchPath("Support/MPVKitAMFShim"),
            ]
        ),
        .testTarget(
            name: "MPVPlayerKitTests",
            dependencies: ["MPVPlayerKit"],
            path: "Tests/MPVPlayerKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
