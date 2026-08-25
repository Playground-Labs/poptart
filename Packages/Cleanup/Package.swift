// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Cleanup",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Cleanup", targets: ["Cleanup"]),
    .library(name: "CleanupMLX", targets: ["CleanupMLX"]),
  ],
  dependencies: [
    .package(path: "../DictationCore"),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm.git",
      exact: "3.31.4"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift.git",
      exact: "0.31.4"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers.git",
      exact: "1.3.3"
    ),
  ],
  targets: [
    .target(
      name: "Cleanup",
      dependencies: ["DictationCore"]
    ),
    .target(
      name: "CleanupMLX",
      dependencies: [
        "Cleanup",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
    .testTarget(
      name: "CleanupTests",
      dependencies: ["Cleanup", "CleanupMLX"]
    ),
  ]
)
