// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuyioKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RuyioCore", targets: ["RuyioCore"]),
        .library(name: "RuyioProtocol", targets: ["RuyioProtocol"]),
        .library(name: "RuyioPluginSDK", targets: ["RuyioPluginSDK"]),
        .library(name: "RuyioPersistence", targets: ["RuyioPersistence"]),
        .library(name: "RuyioSourceTransport", targets: ["RuyioSourceTransport"]),
        .library(name: "RuyioHostKit", targets: ["RuyioHostKit"]),
        .library(name: "RuyioUI", targets: ["RuyioUI"]),
        .library(name: "ClipboardHistoryKit", targets: ["ClipboardHistoryKit"]),
        .library(name: "FinderEssentialsKit", targets: ["FinderEssentialsKit"]),
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
        .target(name: "ClipboardHistoryKit", dependencies: ["RuyioPluginSDK"]),
        .target(name: "FinderEssentialsKit", dependencies: ["RuyioPluginSDK"]),
        .executableTarget(name: "RuyioTestPlugin", dependencies: ["RuyioPluginSDK"], path: "Tests/Fixtures/RuyioTestPlugin"),

        .testTarget(name: "RuyioCoreTests", dependencies: ["RuyioCore"]),
        .testTarget(name: "RuyioProtocolTests", dependencies: ["RuyioProtocol"]),
        .testTarget(name: "RuyioUITests", dependencies: ["RuyioUI", "RuyioCore", "RuyioProtocol"]),
        .testTarget(name: "RuyioPersistenceTests", dependencies: ["RuyioPersistence"]),
        .testTarget(name: "RuyioSourceTransportTests", dependencies: ["RuyioSourceTransport"]),
        .testTarget(name: "PluginKitTests", dependencies: ["ClipboardHistoryKit", "FinderEssentialsKit"]),
        .testTarget(name: "RuyioHostKitTests", dependencies: ["RuyioHostKit", "RuyioPluginSDK", "RuyioTestPlugin"]),
    ]
)
