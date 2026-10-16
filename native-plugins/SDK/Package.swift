// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TilrNativeSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TilrPluginABI", targets: ["TilrPluginABI"]),
        .library(name: "TilrPluginViews", targets: ["TilrPluginViews"]),
    ],
    targets: [
        .target(name: "TilrPluginABI", publicHeadersPath: "include"),
        .target(name: "TilrPluginViews"),
        .testTarget(name: "TilrPluginViewsTests", dependencies: ["TilrPluginViews"]),
    ]
)
