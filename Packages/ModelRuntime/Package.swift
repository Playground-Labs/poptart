// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ModelRuntime",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ModelRuntime", targets: ["ModelRuntime"])],
    targets: [
        .target(name: "ModelRuntime"),
        .testTarget(name: "ModelRuntimeTests", dependencies: ["ModelRuntime"]),
    ]
)
