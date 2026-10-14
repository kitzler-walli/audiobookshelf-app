// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AbsWatchCore",
    platforms: [.watchOS("27.0"), .macOS(.v15)],
    products: [
        .library(name: "AbsWatchCore", targets: ["AbsWatchCore"])
    ],
    targets: [
        .target(name: "AbsWatchCore"),
        .testTarget(name: "AbsWatchCoreTests", dependencies: ["AbsWatchCore"])
    ]
)
