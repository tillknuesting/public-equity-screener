// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MarketScreener",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MarketScreener",
            path: "Sources/MarketScreener",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
