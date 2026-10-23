// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YoloLightMenu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YoloLightMenu", targets: ["YoloLightMenu"]),
        .library(name: "LightCore", targets: ["LightCore"]),
    ],
    targets: [
        .target(name: "LightCore"),
        .executableTarget(name: "YoloLightMenu", dependencies: ["LightCore"]),
        .testTarget(name: "LightCoreTests", dependencies: ["LightCore"]),
        .testTarget(name: "MenuModelTests", dependencies: ["YoloLightMenu", "LightCore"]),
    ]
)
