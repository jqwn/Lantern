// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lantern",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "LanternCore", targets: ["LanternCore"]), .executable(name: "Lantern", targets: ["LanternMac"]), .executable(name: "lantern-serve", targets: ["LanternServe"])],
    targets: [.target(name: "LanternCore"), .executableTarget(name: "LanternMac", dependencies: ["LanternCore"]), .executableTarget(name: "LanternServe", dependencies: ["LanternCore"]), .testTarget(name: "LanternCoreTests", dependencies: ["LanternCore"])]
)
