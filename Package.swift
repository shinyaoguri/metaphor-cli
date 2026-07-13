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
        url: "https://github.com/shinyaoguri/metaphor/releases/download/v0.5.3/Syphon.xcframework.zip",
        checksum: "a544e32a70e7099661f56ea165446f4666fbe2e5897f966da2813ee74c6d02e7"
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
