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
        url: "https://github.com/shinyaoguri/metaphor/releases/download/v0.9.0/Syphon.xcframework.zip",
        checksum: "aa90fa9f6873d05301389653f1e8b82cbc41657cb68e4d9159f858193985c48c"
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
