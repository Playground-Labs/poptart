// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Recognition",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Recognition", targets: ["Recognition"]),
    ],
    dependencies: [
        .package(path: "../DictationCore"),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        ),
    ],
    targets: [
        .target(
            name: "Recognition",
            dependencies: [
                "DictationCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "RecognitionTests",
            dependencies: ["Recognition", "DictationCore"]
        ),
    ]
)
