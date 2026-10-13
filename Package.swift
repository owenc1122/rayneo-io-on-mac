// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RayNeo-io-on-Mac", platforms: [.macOS(.v14)], products: [.executable(name: "RayNeoSimulator", targets: ["RayNeoSimulator"])], targets: [
    .executableTarget(name: "RayNeoSimulator"),
    .testTarget(name: "SimulatorTests", dependencies: ["RayNeoSimulator"])
])
