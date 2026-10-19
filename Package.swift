// swift-tools-version: 5.9
import PackageDescription
// The native macOS viewer (the open "shell"). The emulation core it drives is proprietary and is
// not part of this repository — see the README.
let package = Package(name: "RayNeo-io-on-Mac", platforms: [.macOS(.v14)], products: [.executable(name: "RayNeoSimulator", targets: ["RayNeoSimulator"])], targets: [
    .executableTarget(name: "RayNeoSimulator"),
])
