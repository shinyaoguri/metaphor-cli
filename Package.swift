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
        url: "https://github.com/shinyaoguri/metaphor/releases/download/v0.2.4/Syphon.xcframework.zip",
        checksum: "049e96dbd1152b3f3be679fcdde8a197b41f8aafaa61733588b9f594b4caa203"
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
