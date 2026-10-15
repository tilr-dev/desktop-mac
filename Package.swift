// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tilr",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AppUpdates", targets: ["AppUpdates"])],
    dependencies: [
        .package(path: "../../native-plugins/SDK"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "AppUpdates", dependencies: ["Sparkle"]),
        // The plugin manager (Rust, ../../plugin-manager) as a static library with UniFFI's Swift
        // API. Both are generated and gitignored: scripts/build-plugin-manager.sh (run.sh and
        // scripts/release.py call it) builds Vendor/ and Sources/TilrPluginManager/Generated/.
        .binaryTarget(name: "TilrPluginManagerFFI", path: "Vendor/TilrPluginManagerFFI.xcframework"),
        .target(name: "TilrPluginManager", dependencies: ["TilrPluginManagerFFI"]),
        .executableTarget(name: "Tilr", dependencies: ["Yams", "Sparkle", "AppUpdates", "TilrPluginManager", .product(name: "TilrPluginABI", package: "SDK")], path: "Sources/Tilr",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
