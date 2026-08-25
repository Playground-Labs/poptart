// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SystemIntegration",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SystemIntegration", targets: ["SystemIntegration"])
  ],
  dependencies: [
    .package(path: "../DictationCore")
  ],
  targets: [
    .target(
      name: "SystemIntegration",
      dependencies: ["DictationCore"]
    ),
    .testTarget(
      name: "SystemIntegrationTests",
      dependencies: ["SystemIntegration", "DictationCore"]
    ),
  ]
)
