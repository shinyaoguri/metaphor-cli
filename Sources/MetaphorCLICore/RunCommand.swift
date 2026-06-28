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
              metaphor run [--syphon[=name]] [swift-run-arguments...]

            Runs `swift run` in the current directory and forwards extra arguments.

            Options:
              --syphon[=name]   Publish the sketch's output as a Syphon source so
                                projection-mapping tools (MadMapper, Resolume, VDMX)
                                can read it. With no name, uses the sketch directory
                                name. Sets METAPHOR_SYPHON_NAME for the child.
            """)
            return
        }

        if arguments.contains("--watch") {
            throw CLIError("`metaphor run --watch` は `metaphor watch` に移行しました。`metaphor watch` を使ってください。", exitCode: 2)
        }

        // Extract `--syphon` / `--syphon=name` (a metaphor-cli flag) and forward
        // everything else to `swift run`. We never consume the *next* token as the
        // name (that would swallow a real swift-run argument), so only the `=name`
        // form sets an explicit name; bare `--syphon` falls back to the directory.
        var forwarded: [String] = []
        var syphonName: String?
        let syphonPrefix = "--syphon="
        for arg in arguments {
            if arg == "--syphon" {
                syphonName = SyphonName.stable(for: currentDirectory)
            } else if arg.hasPrefix(syphonPrefix) {
                let name = String(arg.dropFirst(syphonPrefix.count))
                syphonName = name.isEmpty ? SyphonName.stable(for: currentDirectory) : name
            } else {
                forwarded.append(arg)
            }
        }

        var envAssignments: [String] = []
        if let syphonName {
            envAssignments.append("METAPHOR_SYPHON_NAME=\(syphonName)")
            console.write("Publishing Syphon output as \"\(syphonName)\" (readable by MadMapper/Resolume/VDMX).")
        }

        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: envAssignments + ["swift", "run"] + forwarded,
            currentDirectory: currentDirectory,
            captureOutput: false
        )
        if result.exitCode != 0 {
            throw CLIError("swift run failed with exit code \(result.exitCode)", exitCode: result.exitCode)
        }
    }
}
