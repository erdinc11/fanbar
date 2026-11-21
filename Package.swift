// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FanBarSMC", targets: ["FanBarSMC"]),
        .library(name: "FanBarCore", targets: ["FanBarCore"]),
        .executable(name: "FanBarProbe", targets: ["FanBarProbe"]),
        .executable(name: "FanBarApp", targets: ["FanBarApp"]),
        .executable(name: "FanBarHelper", targets: ["FanBarHelper"]),
    ],
    targets: [
        .target(name: "FanBarSMC"),
        .target(name: "FanBarCore", dependencies: ["FanBarSMC"]),
        .executableTarget(name: "FanBarProbe", dependencies: ["FanBarSMC"]),
        .executableTarget(name: "FanBarApp", dependencies: ["FanBarSMC", "FanBarCore"]),
        .executableTarget(name: "FanBarHelper", dependencies: ["FanBarSMC", "FanBarCore"]),
        .testTarget(name: "FanBarSMCTests", dependencies: ["FanBarSMC"]),
        .testTarget(name: "FanBarCoreTests", dependencies: ["FanBarCore"]),
        .testTarget(name: "FanBarHelperTests", dependencies: ["FanBarHelper", "FanBarSMC", "FanBarCore"]),
        .testTarget(name: "FanBarAppTests", dependencies: ["FanBarApp", "FanBarSMC", "FanBarCore"]),
    ]
)
