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
            url: "https://github.com/brandon-nextwork/FluidAudio.git",
            revision: "61dc8edf915e528a11d81ded84b83d2709746713"
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
