// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesAgentDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HermesAgentDock", targets: ["HermesAgentDock"])],
    targets: [.executableTarget(name: "HermesAgentDock")]
)
