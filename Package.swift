// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "diarize",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "diarize", targets: ["DiarizeCLI"]),
        .executable(name: "diarize-app", targets: ["DiarizeApp"]),
        .library(name: "DiarizeCore", targets: ["DiarizeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        .executableTarget(
            name: "DiarizeCLI",
            dependencies: [
                "DiarizeCore",
                "DiarizeServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/DiarizeCLI"
        ),
        .executableTarget(
            name: "DiarizeApp",
            dependencies: ["DiarizeCore"],
            path: "Sources/DiarizeApp"
        ),
        .target(
            name: "DiarizeCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/DiarizeCore"
        ),
        .target(
            name: "DiarizeServer",
            dependencies: [
                "DiarizeCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/DiarizeServer"
        ),
        .testTarget(
            name: "DiarizeServerTests",
            dependencies: [
                "DiarizeServer",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Tests/DiarizeServerTests"
        ),
        .testTarget(
            name: "DiarizeCoreTests",
            dependencies: [
                "DiarizeCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/DiarizeCoreTests"
        ),
    ]
)
