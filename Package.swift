// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Poptart",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PoptartApplication", targets: ["PoptartApplication"]),
        .executable(name: "Poptart", targets: ["Poptart"]),
        .executable(name: "PoptartBenchmark", targets: ["PoptartBenchmark"]),
        // Compatibility harness. Deliberately separate products so that no shipping target ever
        // depends on them.
        .executable(name: "PoptartCompatHost", targets: ["PoptartCompatHost"]),
        .executable(name: "PoptartCompatDriver", targets: ["PoptartCompatDriver"]),
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
            dependencies: ["PoptartApplication", "Persistence", "ModelRuntime", "SystemIntegration"],
            path: "App/Poptart"
        ),
        .executableTarget(
            name: "PoptartBenchmark",
            dependencies: ["PoptartApplication", "DictationCore", "Recognition", "Cleanup",
                .product(name: "CleanupMLX", package: "Cleanup"), "ModelRuntime", "Persistence"],
            path: "Tools/Benchmark"
        ),
        .executableTarget(
            name: "PoptartVerifier",
            path: "Scripts/PoptartVerifier"
        ),
        .target(
            name: "CompatChannel",
            path: "Tools/Compat/Channel"
        ),
        .executableTarget(
            name: "PoptartCompatHost",
            dependencies: ["CompatChannel"],
            path: "Tools/Compat/Host"
        ),
        .executableTarget(
            name: "PoptartCompatDriver",
            dependencies: ["CompatChannel", "SystemIntegration", "DictationCore"],
            path: "Tools/Compat/Driver"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "PoptartBenchmark",
                "PoptartApplication",
                "DictationCore",
                "Persistence",
                "ModelRuntime",
                "SystemIntegration",
            ],
            path: "Tests/Integration"
        ),
    ]
)
