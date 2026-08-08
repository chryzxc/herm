// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDirectory)/Sources/HermesAgentDock/Info.plist"

let package = Package(
    name: "HermesAgentDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HermesAgentDock", targets: ["HermesAgentDock"])],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1")
    ],
    targets: [
        .executableTarget(
            name: "HermesAgentDock",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
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
