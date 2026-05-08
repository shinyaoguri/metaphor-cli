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
        .target(
            name: "MetaphorCLICore"
        ),
        .executableTarget(
            name: "MetaphorCLI",
            dependencies: ["MetaphorCLICore"]
        ),
        .testTarget(
            name: "MetaphorCLITests",
            dependencies: ["MetaphorCLICore"]
        ),
    ]
)
