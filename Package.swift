// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tilr",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AppUpdates", targets: ["AppUpdates"])],
    dependencies: [
        .package(path: "native-plugins/SDK"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "AppUpdates", dependencies: ["Sparkle"]),
        // The plugin manager (Rust, ../plugin-manager) as a static library with UniFFI's Swift
        // API. Both are generated and gitignored: scripts/build-gitpm.sh (run.sh and
        // scripts/release.py call it) builds Vendor/ and Sources/Gitpm/Generated/.
        .binaryTarget(name: "GitpmFFI", path: "Vendor/GitpmFFI.xcframework"),
        .target(name: "Gitpm", dependencies: ["GitpmFFI"]),
        .executableTarget(name: "Tilr", dependencies: ["Yams", "Sparkle", "AppUpdates", "Gitpm", .product(name: "TilrPluginABI", package: "SDK")], path: "Sources/Tilr",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
