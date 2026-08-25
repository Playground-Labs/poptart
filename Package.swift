// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Poptart",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PoptartApplication", targets: ["PoptartApplication"]),
        .executable(name: "Poptart", targets: ["Poptart"]),
    ],
    dependencies: [
        .package(path: "Packages/DictationCore"),
        .package(path: "Packages/Persistence"),
        .package(path: "Packages/ModelRuntime"),
        .package(path: "Packages/Cleanup"),
        .package(path: "Packages/Recognition"),
        .package(path: "Packages/SystemIntegration"),
    ],
    targets: [
        .target(
            name: "PoptartApplication",
            dependencies: [
                "DictationCore",
                "Persistence",
                "ModelRuntime",
                "Cleanup",
                .product(name: "CleanupMLX", package: "Cleanup"),
                "Recognition",
                "SystemIntegration",
            ],
            path: "App/Application"
        ),
        .executableTarget(
            name: "Poptart",
            dependencies: ["PoptartApplication", "Persistence", "SystemIntegration"],
            path: "App/Poptart"
        ),
        .executableTarget(
            name: "PoptartVerifier",
            path: "Scripts/PoptartVerifier"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["PoptartApplication", "DictationCore"],
            path: "Tests/Integration"
        ),
    ]
)
