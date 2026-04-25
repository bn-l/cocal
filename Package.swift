// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexSwitcher",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodexSwitcher",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .testTarget(
            name: "CodexSwitcherTests",
            dependencies: [
                "CodexSwitcher",
            ]
        ),
    ]
)
