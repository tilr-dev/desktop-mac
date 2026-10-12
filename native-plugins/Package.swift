// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TilrNativePlugins",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrowserWebKit", type: .dynamic, targets: ["BrowserWebKit"]),
        .library(name: "NativeAudio", type: .dynamic, targets: ["NativeAudio"]),
    ],
    dependencies: [.package(path: "SDK")],
    targets: [
        .target(name: "BrowserWebKit", dependencies: [
            .product(name: "TilrPluginABI", package: "SDK"),
            .product(name: "TilrPluginViews", package: "SDK"),
        ]),
        .target(name: "NativeAudio", dependencies: [.product(name: "TilrPluginABI", package: "SDK")]),
        .testTarget(name: "NativeAudioTests", dependencies: ["NativeAudio", .product(name: "TilrPluginABI", package: "SDK")]),
    ]
)
