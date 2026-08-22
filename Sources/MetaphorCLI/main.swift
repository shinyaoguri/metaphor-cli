import Darwin
import Foundation
import MetaphorCLICore
import MetaphorViewer

@main
enum MetaphorCLIEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // アップデート通知は watch（ビューア経路）も含む全コマンドが通るここで
        // 起動する。CommandLineTool 内だと既定の watch が素通りしてしまう。
        if UpdateNotifier.shouldRun(forCommand: arguments.first) {
            UpdateNotifier().begin(console: StandardConsole())
        }

        // `metaphor watch`: 既定で常設ライブビューア窓 + 子だけ差し替え（Syphon/AppKit を
        // 要するためここ＝実行ファイル側で処理する）。`--no-viewer` でのみ従来の
        // 「スケッチ自身の窓を再起動する」モード（CommandLineTool 側）に渡す。
        // `--help`/`-h` は CommandLineTool 側の watch ヘルプ表示に流す。
        if arguments.first == "watch",
           !arguments.contains("--no-viewer"),
           !arguments.contains("--help"), !arguments.contains("-h") {
            runWatchViewer(Array(arguments.dropFirst()))
            return
        }

        let tool = CommandLineTool()
        do {
            try tool.run(arguments: arguments)
        } catch let error as CLIError {
            StandardConsole().writeError("error: \(error.message)")
            exit(error.exitCode)
        } catch {
            StandardConsole().writeError("error: \(error)")
            exit(1)
        }
    }

    /// `metaphor watch`（既定のライブビューア）を処理する。`watch` 専用フラグ
    /// （`--viewer` / `--no-viewer` / `--syphon-name <name>`）を解釈し、残りを swift 引数として渡す。
    private static func runWatchViewer(_ watchArguments: [String]) {
        let parsed = parseWatchArguments(watchArguments)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            try runViewerWatch(
                directory: directory,
                swiftArguments: parsed.swiftArguments,
                syphonName: parsed.syphonName,
                probeEnabled: parsed.probeEnabled,
                fps: parsed.fps,
                metricsEnabled: parsed.metricsEnabled,
                metricsInterval: parsed.metricsInterval,
                // watch のログは長時間流れ続けるので時刻を付ける
                // （`--no-viewer` 経路は WatchCommand 側で同じ装飾をしている）。
                console: TimestampedConsole(base: StandardConsole())
            )
        } catch let error as CLIError {
            StandardConsole().writeError("error: \(error.message)")
            exit(error.exitCode)
        } catch {
            StandardConsole().writeError("error: \(error)")
            exit(1)
        }
    }
}
