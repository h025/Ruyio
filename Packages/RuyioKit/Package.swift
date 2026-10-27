// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuyioKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RuyioCore", targets: ["RuyioCore"]),
        .library(name: "RuyioProtocol", targets: ["RuyioProtocol"]),
        .library(name: "RuyioPluginSDK", targets: ["RuyioPluginSDK"]),
        .library(name: "RuyioPersistence", targets: ["RuyioPersistence"]),
        .library(name: "RuyioSourceTransport", targets: ["RuyioSourceTransport"]),
        .library(name: "RuyioHostKit", targets: ["RuyioHostKit"]),
        .library(name: "RuyioUI", targets: ["RuyioUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "RuyioCore"),
        .target(name: "RuyioProtocol", dependencies: ["RuyioCore"]),
        .target(name: "RuyioPluginSDK", dependencies: ["RuyioCore", "RuyioProtocol"]),
        .target(
            name: "RuyioPersistence",
            dependencies: ["RuyioCore", "RuyioProtocol", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "RuyioSourceTransport", dependencies: ["RuyioCore", "RuyioProtocol"]),
        .target(
            name: "RuyioHostKit",
            dependencies: ["RuyioCore", "RuyioProtocol", "RuyioPersistence", "RuyioSourceTransport"]
        ),
        .target(name: "RuyioUI", dependencies: ["RuyioCore", "RuyioProtocol"]),
        .executableTarget(name: "RuyioTestPlugin", dependencies: ["RuyioPluginSDK"], path: "Tests/Fixtures/RuyioTestPlugin"),

        .testTarget(name: "RuyioCoreTests", dependencies: ["RuyioCore"]),
        .testTarget(name: "RuyioProtocolTests", dependencies: ["RuyioProtocol"]),
        .testTarget(name: "RuyioPersistenceTests", dependencies: ["RuyioPersistence"]),
        .testTarget(name: "RuyioSourceTransportTests", dependencies: ["RuyioSourceTransport"]),
        .testTarget(name: "RuyioHostKitTests", dependencies: ["RuyioHostKit", "RuyioPluginSDK", "RuyioTestPlugin"]),
    ]
)
