// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDirectory)/Sources/Herm/Info.plist"
// Normal builds do not compile the experimental renderer or its WebKit host.
let generativeUIEnabled = ProcessInfo.processInfo.environment["HERM_EXPERIMENTAL_GENERATIVE_UI"] == "1"
let generativeUISettings: [SwiftSetting] = generativeUIEnabled ? [.define("HERM_EXPERIMENTAL_GENERATIVE_UI")] : []

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
            exclude: ["Info.plist", "Resources/DockAppIcon.icns"] + (generativeUIEnabled ? [] : ["Features/GenerativeUI"]),
            resources: [.copy("Resources/DockAppIcon.png"), .copy("Resources/FileIcons"), .copy("Resources/ProviderIcons"), .copy("Resources/HermesSSHBridge.mjs"), .copy("Resources/HermesSSHBridge.LICENSE"), .copy("Resources/BrowserFinder.js"), .copy("Resources/BrowserFinder.LICENSE"), .copy("Resources/BrowserAnnotate.js")],
            swiftSettings: generativeUISettings,
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
            dependencies: ["Herm"],
            exclude: generativeUIEnabled ? [] : ["Features/GenerativeUI"],
            swiftSettings: generativeUISettings
        )
    ]
)
