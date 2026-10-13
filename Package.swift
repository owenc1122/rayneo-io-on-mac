// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RayNeo-io-on-Mac", platforms: [.macOS(.v14)], products: [.executable(name: "RayNeoSimulator", targets: ["RayNeoSimulator"])], targets: [
    .target(name: "NavigationCore", publicHeadersPath: "include"),
    .executableTarget(name: "RayNeoSimulator", dependencies: ["NavigationCore"]),
    .testTarget(name: "SimulatorTests", dependencies: ["RayNeoSimulator", "NavigationCore"])
])
