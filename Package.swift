// swift-tools-version: 6.0
import PackageDescription

// libtdjson.dylib is built by vendor/tdlib/build.sh (git-ignored artifact). Its install name
// is the absolute path below, so binaries find it at runtime without DYLD_LIBRARY_PATH.
// Headers reach the compiler through the committed symlink Sources/CTDLib/include/td.
let tdlibLib = "\(Context.packageDirectory)/vendor/tdlib/lib"

let package = Package(
    name: "telegram-gateway",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TDLibClient", targets: ["TDLibClient"]),
        .library(name: "QRCode", targets: ["QRCode"]),
        .library(name: "GatewayCore", targets: ["GatewayCore"]),
        .library(name: "GatewayLink", targets: ["GatewayLink"]),
        .library(name: "GatewayServer", targets: ["GatewayServer"]),
        .executable(name: "tgw", targets: ["tgw"]),
        .executable(name: "GatewayDaemon", targets: ["GatewayDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.6.0"),
    ],
    targets: [
        // Raw C interface: td_create_client_id / td_send / td_receive / td_execute.
        .target(
            name: "CTDLib",
            path: "Sources/CTDLib",
            linkerSettings: [
                .unsafeFlags(["-L", tdlibLib]),
                .linkedLibrary("tdjson"),
            ]
        ),
        // One actor per TDLib client: request/response correlation, updates, auth state.
        .target(
            name: "TDLibClient",
            dependencies: ["CTDLib"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Small QR encoder (byte mode) used to show the tg://login link in the terminal.
        .target(
            name: "QRCode",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Domain: store, event log, grants, access requests, translator, monitor, webhooks,
        // media cache. Everything except the TDLib edge is testable without an account.
        .target(
            name: "GatewayCore",
            dependencies: [
                "TDLibClient",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The outbound link to Volgenic (docs/link.md): one WebSocket client per base URL.
        .target(
            name: "GatewayLink",
            dependencies: [
                "GatewayCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The HTTP + WebSocket API (docs/api.md) as a library so tests can drive it in-process.
        .target(
            name: "GatewayServer",
            dependencies: [
                "GatewayCore",
                "GatewayLink",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The launchd service: wires TDLib, the store, the monitor, webhooks and the server.
        .executableTarget(
            name: "GatewayDaemon",
            dependencies: [
                "GatewayServer",
                "GatewayCore",
                "GatewayLink",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "tgw",
            dependencies: [
                "TDLibClient",
                "QRCode",
                "GatewayCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TDLibClientTests",
            dependencies: ["TDLibClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QRCodeTests",
            dependencies: ["QRCode"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Fakes (TDLib, webhook HTTP, Telegram session) and fixtures shared by the test targets.
        .target(
            name: "GatewayTestSupport",
            dependencies: ["GatewayCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatewayCoreTests",
            dependencies: ["GatewayCore", "GatewayTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatewayServerTests",
            dependencies: [
                "GatewayServer",
                "GatewayCore",
                "GatewayTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatewayLinkTests",
            dependencies: [
                "GatewayLink",
                "GatewayServer",
                "GatewayCore",
                "GatewayTestSupport",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
