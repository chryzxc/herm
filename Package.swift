// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDirectory)/Sources/HermesAgentDock/Info.plist"

let package = Package(
    name: "HermesAgentDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HermesAgentDock", targets: ["HermesAgentDock"])],
    targets: [
        .executableTarget(
            name: "HermesAgentDock",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        ),
        .testTarget(
            name: "HermesAgentDockTests",
            dependencies: ["HermesAgentDock"]
        )
    ]
)
