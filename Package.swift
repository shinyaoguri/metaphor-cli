// swift-tools-version: 5.10

import PackageDescription
import Foundation

// Syphon フレームワークの解決。
// ローカルに Frameworks/Syphon.xcframework があればそれを使い（開発用）、
// なければ metaphor 本体と同じ GitHub Release のプリビルドを取得する。
let localSyphonPath = "Frameworks/Syphon.xcframework"
let useLocalSyphon = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(localSyphonPath).path
)

let syphonTarget: Target = useLocalSyphon
    ? .binaryTarget(name: "Syphon", path: localSyphonPath)
    : .binaryTarget(
        name: "Syphon",
        url: "https://github.com/shinyaoguri/metaphor/releases/download/v0.7.0/Syphon.xcframework.zip",
        checksum: "47ddd8a9ec1ce6ea4adb5594549a3471ed99145e14eb64c2d2c753a472ccfb64"
    )

let package = Package(
    name: "metaphor-cli",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "metaphor", targets: ["MetaphorCLI"])
    ],
    targets: [
        .target(
            name: "MetaphorCLICore",
            plugins: ["VersionStampPlugin"]
        ),
        .plugin(
            name: "VersionStampPlugin",
            capability: .buildTool()
        ),
        syphonTarget,
        .target(
            name: "MetaphorViewer",
            dependencies: ["MetaphorCLICore", "Syphon"]
        ),
        .executableTarget(
            name: "MetaphorCLI",
            dependencies: ["MetaphorCLICore", "MetaphorViewer"]
        ),
        .testTarget(
            name: "MetaphorCLITests",
            dependencies: ["MetaphorCLICore"]
        ),
    ]
)
