// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "neptune-gateway-swift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NeptuneGatewaySwift", targets: ["NeptuneGatewaySwift"]),
        .executable(name: "neptune", targets: ["neptune-gateway"]),
        .executable(name: "neptune-ui-tree-mock-builder", targets: ["neptune-ui-tree-mock-builder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/linhay/STJSON.git", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "NeptuneGatewaySwift",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "STJSON", package: "STJSON"),
            ]
        ),
        .executableTarget(
            name: "neptune-gateway",
            dependencies: ["NeptuneGatewaySwift"]
        ),
        .executableTarget(
            name: "neptune-ui-tree-mock-builder",
            dependencies: [
                "NeptuneGatewaySwift",
                .product(name: "STJSON", package: "STJSON"),
            ]
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
