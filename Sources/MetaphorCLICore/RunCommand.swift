import Foundation

public struct RunCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL

    public init(console: any Console, processRunner: any ProcessRunning, currentDirectory: URL) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
    }

    public func run(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            console.write("""
            Usage:
              metaphor run [swift-run-arguments...]

            Runs `swift run` in the current directory and forwards extra arguments.
            """)
            return
        }

        if arguments.contains("--watch") {
            throw CLIError("`metaphor run --watch` は `metaphor watch` に移行しました。`metaphor watch` を使ってください。", exitCode: 2)
        }

        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["swift", "run"] + arguments,
            currentDirectory: currentDirectory,
            captureOutput: false
        )
        if result.exitCode != 0 {
            throw CLIError("swift run failed with exit code \(result.exitCode)", exitCode: result.exitCode)
        }
    }
}
