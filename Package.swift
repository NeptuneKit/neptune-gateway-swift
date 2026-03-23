// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "neptune-gateway-swift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NeptuneGatewaySwift", targets: ["NeptuneGatewaySwift"]),
        .executable(name: "neptune-gateway", targets: ["neptune-gateway"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
    ],
    targets: [
        .target(
            name: "NeptuneGatewaySwift",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .executableTarget(
            name: "neptune-gateway",
            dependencies: ["NeptuneGatewaySwift"]
        ),
        .testTarget(
            name: "NeptuneGatewaySwiftTests",
            dependencies: [
                "NeptuneGatewaySwift",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
