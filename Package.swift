// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDirectory)/Sources/Herm/Info.plist"
let package = Package(
    name: "Herm",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herm", targets: ["Herm"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "Herm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            exclude: ["Info.plist", "Resources/DockAppIcon.icns"],
            resources: [.copy("Resources/SimulatorBridge"), .copy("Resources/HermesPlugins"), .copy("Resources/DockAppIcon.png"), .copy("Resources/FileIcons"), .copy("Resources/ProviderIcons"), .copy("Resources/HermesSSHBridge.mjs"), .copy("Resources/HermesSSHBridge.LICENSE"), .copy("Resources/BrowserFinder.js"), .copy("Resources/BrowserFinder.LICENSE"), .copy("Resources/BrowserAnnotate.js"), .copy("Resources/HermesBackdrop.jpg"), .copy("Resources/HermesBackdrop.LICENSE")],
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
            name: "HermTests",
            dependencies: ["Herm"]
        )
    ]
)
