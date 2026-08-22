// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "metaphor-cli",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "metaphor", targets: ["MetaphorCLI"])
    ],
    targets: [
        // live viewer の frame IPC のうち Swift から呼べない POSIX API（shm_open / SCM_RIGHTS）
        // を包む C シム。wire だけが契約（CONTRACT.md 契約点 5）で、metaphor 本体の
        // `CMetaphorIPC` とは共有しない。
        .target(
            name: "CMetaphorFrameIPC"
        ),
        .target(
            name: "MetaphorCLICore",
            dependencies: ["CMetaphorFrameIPC"],
            plugins: ["VersionStampPlugin"]
        ),
        .plugin(
            name: "VersionStampPlugin",
            capability: .buildTool()
        ),
        .target(
            name: "MetaphorViewer",
            dependencies: ["MetaphorCLICore", "CMetaphorFrameIPC"]
        ),
        .executableTarget(
            name: "MetaphorCLI",
            dependencies: ["MetaphorCLICore", "MetaphorViewer"]
        ),
        .testTarget(
            name: "MetaphorCLITests",
            dependencies: ["MetaphorCLICore", "MetaphorViewer", "CMetaphorFrameIPC"]
        ),
    ]
)
