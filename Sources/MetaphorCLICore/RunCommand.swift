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
              metaphor run [--syphon[=name]] [--fps <n>] [--metrics] [swift-run-arguments...]

            Runs `swift run` in the current directory and forwards extra arguments.

            Options:
              --syphon[=name]   Publish the sketch's output as a Syphon source so
                                projection-mapping tools (MadMapper, Resolume, VDMX)
                                can read it. With no name, uses the sketch directory
                                name. Sets METAPHOR_SYPHON_NAME for the child.
              --fps <n>         Override the sketch's render FPS (sets METAPHOR_FPS
                                for the child). Defaults to the sketch's config.fps.
              --metrics         Show live fps / frame time / memory / CPU / thermal
                                stats on the terminal (sets METAPHOR_PROBE=1 for the
                                child and polls the Probe files once per second).
              --metrics-interval <sec>
                                Polling interval for --metrics (default 1, min 0.2).
                                Implies --metrics.
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
        var fps: Int?
        var metricsEnabled = false
        var metricsInterval: Double?
        let syphonPrefix = "--syphon="
        let fpsPrefix = "--fps="
        let metricsIntervalPrefix = "--metrics-interval="
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--syphon" {
                syphonName = SyphonName.stable(for: currentDirectory)
            } else if arg.hasPrefix(syphonPrefix) {
                let name = String(arg.dropFirst(syphonPrefix.count))
                syphonName = name.isEmpty ? SyphonName.stable(for: currentDirectory) : name
            } else if arg == "--fps" {
                // 次のトークンを FPS として取り込む（無ければ無視）。
                if i + 1 < arguments.count {
                    fps = Int(arguments[i + 1])
                    i += 1
                }
            } else if arg.hasPrefix(fpsPrefix) {
                fps = Int(arg.dropFirst(fpsPrefix.count))
            } else if arg == "--metrics" {
                metricsEnabled = true
            } else if arg == "--metrics-interval" {
                if i + 1 < arguments.count {
                    metricsInterval = Double(arguments[i + 1])
                    i += 1
                }
            } else if arg.hasPrefix(metricsIntervalPrefix) {
                metricsInterval = Double(arg.dropFirst(metricsIntervalPrefix.count))
            } else {
                forwarded.append(arg)
            }
            i += 1
        }
        // 0 以下の FPS は無効として無視。
        if let value = fps, value <= 0 { fps = nil }
        // 0 以下・非数値の interval は無効として無視。interval 指定は --metrics を含意。
        if let value = metricsInterval, value <= 0 { metricsInterval = nil }
        metricsEnabled = metricsEnabled || metricsInterval != nil

        var envAssignments: [String] = []
        if let syphonName {
            envAssignments.append("METAPHOR_SYPHON_NAME=\(syphonName)")
            console.write("Publishing Syphon output as \"\(syphonName)\" (readable by MadMapper/Resolume/VDMX).")
        }
        if let fps {
            envAssignments.append("METAPHOR_FPS=\(fps)")
        }
        if metricsEnabled {
            // Probe を有効化してメトリクスの供給元（frame.json の performance）を作る。
            envAssignments.append("METAPHOR_PROBE=1")
        }

        // swift run（ビルド含む）が同期ブロックする間、ポーラーは GCD タイマーで
        // 並走する。ビルド中・起動前は「応答待ち」表示になるだけで害はない。
        var reporter: MetricsReporter?
        if metricsEnabled {
            reporter = MetricsReporter(sketchDirectory: currentDirectory, interval: metricsInterval)
            reporter?.start()
        }
        defer { reporter?.stop() }

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
