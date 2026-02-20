// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "supervoxtral",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "supervoxtral", targets: ["supervoxtral"]),
        .executable(name: "voxtral-smoke", targets: ["voxtral-smoke"]),
        .executable(name: "voxtral-stream-file", targets: ["voxtral-stream-file"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.6.0")),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        .target(
            name: "VoxtralRuntime",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .executableTarget(
            name: "supervoxtral",
            dependencies: [
                "VoxtralRuntime",
                "HotKey",
            ]
        ),
        .executableTarget(
            name: "voxtral-smoke",
            dependencies: [
                "VoxtralRuntime",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "voxtral-stream-file",
            dependencies: [
                "VoxtralRuntime",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
    ]
)
