import Foundation
@testable import MetaphorCLICore
import XCTest

// MARK: - Mocks

private final class MockLaunchedProcess: LaunchedProcess {
    private(set) var terminated = false
    private(set) var sentLines: [String] = []
    var isRunning: Bool { !terminated }
    func terminate() { terminated = true }
    func sendLine(_ line: String) { sentLines.append(line) }
}

private final class RecordingLauncher: ProcessLaunching {
    private(set) var launches: [[String]] = []
    private(set) var executables: [String] = []
    private(set) var environments: [[String: String]?] = []
    private(set) var processes: [MockLaunchedProcess] = []
    var shouldThrow = false

    func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> any LaunchedProcess {
        if shouldThrow { throw CLIError("launch boom") }
        launches.append(arguments)
        executables.append(executable)
        environments.append(environment)
        let process = MockLaunchedProcess()
        processes.append(process)
        return process
    }
}

private final class ManualFileWatcher: FileWatching {
    private(set) var started = false
    private(set) var stopped = false
    private var handler: (() -> Void)?

    func start(onChange: @escaping () -> Void) throws {
        started = true
        handler = onChange
    }

    func stop() { stopped = true }

    /// テストから変更を手動発火する。
    func fireChange() { handler?() }
}

/// バイナリ解決を行わないスタブ（テストでは swift run フォールバックを使う）。
private struct NullBinaryResolver: SketchBinaryResolving {
    func resolve(directory: URL, swiftArguments: [String]) -> String? { nil }
}

/// 固定パスを返すバイナリ解決スタブ。
private struct FixedBinaryResolver: SketchBinaryResolving {
    let path: String
    func resolve(directory: URL, swiftArguments: [String]) -> String? { path }
}

/// `run` が必ず throw するプロセスランナー（ビルド実行自体の失敗を再現）。
private struct ThrowingProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        captureOutput: Bool
    ) throws -> ProcessResult {
        throw CLIError("exec boom")
    }
}

// MARK: - Tests

final class WatchSessionTests: XCTestCase {

    private func makeSession(
        runner: RecordingProcessRunner,
        launcher: RecordingLauncher,
        watcher: ManualFileWatcher,
        console: BufferedConsole
    ) -> WatchSession {
        WatchSession(
            directory: URL(fileURLWithPath: "/tmp/sketch"),
            swiftArguments: [],
            console: console,
            processRunner: runner,
            launcher: launcher,
            watcher: watcher,
            binaryResolver: NullBinaryResolver()
        )
    }

    func testInitialStartBuildsAndLaunches() throws {
        let runner = RecordingProcessRunner()  // default exitCode 0
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()

        // 1 回 swift build を呼ぶ
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.arguments, ["swift", "build"])
        // 1 回 swift run --skip-build を起動
        XCTAssertEqual(launcher.launches, [["swift", "run", "--skip-build"]])
        // 監視を開始
        XCTAssertTrue(watcher.started)
    }

    func testSourceStampInjectedIntoChildEnv() throws {
        let runner = RecordingProcessRunner()  // default exitCode 0
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()

        // 子起動の env には provenance スタンプが必ず入る（CONTRACT.md frame.json v4）。
        let env = launcher.environments.first ?? nil
        let stamp = env?["METAPHOR_SOURCE_STAMP"]
        XCTAssertNotNil(stamp)
        XCTAssertEqual(stamp?.count, 16)  // 64-bit FNV-1a を %016llx で出力
    }

    func testComputeSourceStampChangesWhenSourceEdited() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("metaphor-stamp-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("App.swift")
        try "let a = 1\n".write(to: src, atomically: true, encoding: .utf8)

        let session = WatchSession(
            directory: dir,
            swiftArguments: [],
            console: BufferedConsole(),
            processRunner: RecordingProcessRunner(),
            launcher: RecordingLauncher(),
            watcher: ManualFileWatcher(),
            binaryResolver: NullBinaryResolver()
        )

        let stamp1 = session.computeSourceStamp()
        // 同一内容なら再現する。
        XCTAssertEqual(stamp1, session.computeSourceStamp())

        // 内容（とサイズ）を変えると刻印が変わる。
        try "let a = 1\nlet b = 2\n".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(stamp1, session.computeSourceStamp())
    }

    func testParseWatchArgumentsStripsViewerFlags() {
        XCTAssertEqual(parseWatchArguments(["--no-viewer"]), ParsedWatchArguments(syphonName: nil, swiftArguments: []))
        XCTAssertEqual(parseWatchArguments(["--viewer"]), ParsedWatchArguments(syphonName: nil, swiftArguments: []))
        XCTAssertEqual(
            parseWatchArguments(["--no-viewer", "-c", "release", "--viewer"]),
            ParsedWatchArguments(syphonName: nil, swiftArguments: ["-c", "release"])
        )
        XCTAssertEqual(
            parseWatchArguments(["-c", "release"]),
            ParsedWatchArguments(syphonName: nil, swiftArguments: ["-c", "release"])
        )
    }

    func testParseWatchArgumentsHandlesNoProbe() {
        // 既定は Probe 有効（共有セッション可）。
        XCTAssertTrue(parseWatchArguments([]).probeEnabled)
        XCTAssertTrue(parseWatchArguments(["-c", "release"]).probeEnabled)
        // --no-probe で無効化し、swift 引数からは除去される。
        XCTAssertEqual(
            parseWatchArguments(["--no-probe", "-c", "release"]),
            ParsedWatchArguments(syphonName: nil, probeEnabled: false, swiftArguments: ["-c", "release"])
        )
    }

    func testParseWatchArgumentsExtractsSyphonName() {
        // 空白区切り
        XCTAssertEqual(
            parseWatchArguments(["--syphon-name", "MySketch"]),
            ParsedWatchArguments(syphonName: "MySketch", swiftArguments: [])
        )
        // = 区切り
        XCTAssertEqual(
            parseWatchArguments(["--syphon-name=MySketch"]),
            ParsedWatchArguments(syphonName: "MySketch", swiftArguments: [])
        )
        // 他のフラグと混在しても値を巻き込まない／swift 引数は保持
        XCTAssertEqual(
            parseWatchArguments(["--syphon-name", "Live", "-c", "release"]),
            ParsedWatchArguments(syphonName: "Live", swiftArguments: ["-c", "release"])
        )
        // 値が無い末尾の --syphon-name は無視、空文字も無効
        XCTAssertEqual(
            parseWatchArguments(["-c", "release", "--syphon-name"]),
            ParsedWatchArguments(syphonName: nil, swiftArguments: ["-c", "release"])
        )
        XCTAssertEqual(
            parseWatchArguments(["--syphon-name", ""]),
            ParsedWatchArguments(syphonName: nil, swiftArguments: [])
        )
    }

    func testParseWatchArgumentsExtractsFPS() {
        // 空白区切り
        XCTAssertEqual(
            parseWatchArguments(["--fps", "30"]),
            ParsedWatchArguments(syphonName: nil, fps: 30, swiftArguments: [])
        )
        // = 区切り
        XCTAssertEqual(
            parseWatchArguments(["--fps=24"]),
            ParsedWatchArguments(syphonName: nil, fps: 24, swiftArguments: [])
        )
        // 他のフラグと混在しても値を巻き込まない／swift 引数は保持
        XCTAssertEqual(
            parseWatchArguments(["--fps", "60", "-c", "release"]),
            ParsedWatchArguments(syphonName: nil, fps: 60, swiftArguments: ["-c", "release"])
        )
        // 非数値・0 以下・末尾の値なしは無効（nil）
        XCTAssertEqual(
            parseWatchArguments(["--fps", "abc"]),
            ParsedWatchArguments(syphonName: nil, fps: nil, swiftArguments: [])
        )
        XCTAssertEqual(
            parseWatchArguments(["--fps", "0"]),
            ParsedWatchArguments(syphonName: nil, fps: nil, swiftArguments: [])
        )
        XCTAssertEqual(
            parseWatchArguments(["-c", "release", "--fps"]),
            ParsedWatchArguments(syphonName: nil, fps: nil, swiftArguments: ["-c", "release"])
        )
    }

    func testParseWatchArgumentsExtractsMetrics() {
        // 既定は無効。
        XCTAssertFalse(parseWatchArguments([]).metricsEnabled)
        // --metrics で有効化し、swift 引数からは除去される。
        XCTAssertEqual(
            parseWatchArguments(["--metrics", "-c", "release"]),
            ParsedWatchArguments(syphonName: nil, metricsEnabled: true, swiftArguments: ["-c", "release"])
        )
        // 間隔指定（空白区切り / = 区切り）は --metrics を含意する。
        XCTAssertEqual(
            parseWatchArguments(["--metrics-interval", "0.5"]),
            ParsedWatchArguments(
                syphonName: nil, metricsEnabled: true, metricsInterval: 0.5, swiftArguments: []
            )
        )
        XCTAssertEqual(
            parseWatchArguments(["--metrics", "--metrics-interval=2"]),
            ParsedWatchArguments(
                syphonName: nil, metricsEnabled: true, metricsInterval: 2, swiftArguments: []
            )
        )
        // 非数値・0 以下・末尾の値なしは間隔として無効（nil）
        XCTAssertEqual(
            parseWatchArguments(["--metrics", "--metrics-interval", "abc"]),
            ParsedWatchArguments(syphonName: nil, metricsEnabled: true, swiftArguments: [])
        )
        XCTAssertEqual(
            parseWatchArguments(["--metrics-interval", "0"]),
            ParsedWatchArguments(syphonName: nil, metricsEnabled: false, swiftArguments: [])
        )
        XCTAssertEqual(
            parseWatchArguments(["--metrics", "--metrics-interval"]),
            ParsedWatchArguments(syphonName: nil, metricsEnabled: true, swiftArguments: [])
        )
        // --no-probe と併用しても双方が独立にパースされる（Probe 注入の強制は
        // WatchCommand / runViewerWatch 側の責務）。
        XCTAssertEqual(
            parseWatchArguments(["--no-probe", "--metrics"]),
            ParsedWatchArguments(
                syphonName: nil, probeEnabled: false, metricsEnabled: true, swiftArguments: []
            )
        )
    }

    func testForwardInputGoesToCurrentChild() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()
        session.forwardInput(#"{"t":"mouseMove","x":1,"y":2}"#)

        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertEqual(launcher.processes[0].sentLines, [#"{"t":"mouseMove","x":1,"y":2}"#])
    }

    func testForwardInputAfterReloadTargetsNewChild() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()
        watcher.fireChange()  // 子を入れ替え
        session.forwardInput("hi")

        // 新しい子にだけ届き、終了した古い子には届かない。
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertTrue(launcher.processes[0].sentLines.isEmpty)
        XCTAssertEqual(launcher.processes[1].sentLines, ["hi"])
    }

    func testForwardInputWithNoChildIsNoOp() {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        // start していない（子が居ない）状態でもクラッシュしない。
        session.forwardInput("noop")
        XCTAssertTrue(launcher.processes.isEmpty)
    }

    func testReloadTerminatesPreviousAndRelaunches() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()
        watcher.fireChange()

        // 2 回起動（初回 + リロード）
        XCTAssertEqual(launcher.processes.count, 2)
        // 最初のプロセスは終了済み、2 番目は生存
        XCTAssertTrue(launcher.processes[0].terminated)
        XCTAssertFalse(launcher.processes[1].terminated)
        // build は 2 回
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testBuildFailureKeepsPreviousInstance() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        // 初回ビルド成功 → p0 起動
        try session.start()
        XCTAssertEqual(launcher.processes.count, 1)

        // 次のビルドは失敗させる
        runner.result = ProcessResult(exitCode: 1)
        watcher.fireChange()

        // 新規起動なし、前のプロセスは維持（terminate されない）
        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertFalse(launcher.processes[0].terminated)
        XCTAssertTrue(console.errors.joined().contains("ビルド失敗"))
    }

    func testInitialBuildFailureLaunchesNothing() throws {
        let runner = RecordingProcessRunner()
        runner.result = ProcessResult(exitCode: 1)
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()

        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertTrue(watcher.started)  // ビルドが失敗しても監視は続ける
        XCTAssertTrue(console.errors.joined().contains("初回ビルド失敗"))
    }

    func testBuildExecutionErrorIsLoggedNotSwallowed() throws {
        // `swift build` の起動自体が throw しても、サイレントに握り潰さず
        // 明示的にログし、子は起動しない（合成の失敗結果で続行する）。
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = WatchSession(
            directory: URL(fileURLWithPath: "/tmp/sketch"),
            swiftArguments: [],
            console: console,
            processRunner: ThrowingProcessRunner(),
            launcher: launcher,
            watcher: watcher,
            binaryResolver: NullBinaryResolver()
        )

        try session.start()

        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertTrue(console.errors.joined().contains("ビルド実行エラー"))
    }

    func testStateCallbacksFireInOrderOnSuccess() throws {
        let runner = RecordingProcessRunner()  // default exitCode 0
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        var events: [String] = []
        session.onBuildWillStart = { initial in events.append("willStart(initial:\(initial))") }
        session.onBuildFinished = { outcome in events.append("finished(succeeded:\(outcome.succeeded))") }
        session.onChildLaunched = { events.append("launched") }

        try session.start()

        // 初回: ビルド開始 → ビルド完了(成功) → 子起動 の順。
        XCTAssertEqual(events, [
            "willStart(initial:true)",
            "finished(succeeded:true)",
            "launched",
        ])
    }

    func testStateCallbacksReportBuildFailureWithoutLaunch() throws {
        let runner = RecordingProcessRunner()
        runner.result = ProcessResult(exitCode: 1)
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        var events: [String] = []
        session.onBuildWillStart = { initial in events.append("willStart(initial:\(initial))") }
        session.onBuildFinished = { outcome in events.append("finished(succeeded:\(outcome.succeeded))") }
        session.onChildLaunched = { events.append("launched") }

        try session.start()

        // ビルド失敗時は launched が来ない（子を起動しない）。
        XCTAssertEqual(events, [
            "willStart(initial:true)",
            "finished(succeeded:false)",
        ])
    }

    func testReloadFiresBuildCallbacksWithInitialFalse() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()

        var initials: [Bool] = []
        session.onBuildWillStart = { initials.append($0) }
        watcher.fireChange()

        // リロードのビルドは initial:false で通知される。
        XCTAssertEqual(initials, [false])
    }

    func testStopTerminatesProcessAndWatcher() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = makeSession(runner: runner, launcher: launcher, watcher: watcher, console: console)

        try session.start()
        session.stop()

        XCTAssertTrue(watcher.stopped)
        XCTAssertTrue(launcher.processes[0].terminated)
    }

    func testWatchCommandRejectsMissingPackage() {
        let console = BufferedConsole()
        let command = WatchCommand(
            console: console,
            processRunner: RecordingProcessRunner(),
            currentDirectory: URL(fileURLWithPath: "/tmp/definitely-not-a-package-\(UUID().uuidString)")
        )

        XCTAssertThrowsError(try command.run(arguments: [])) { error in
            guard let cliError = error as? CLIError else {
                return XCTFail("expected CLIError, got \(error)")
            }
            XCTAssertEqual(cliError.exitCode, 2)
            XCTAssertTrue(cliError.message.contains("Package.swift"))
        }
    }

    func testWatchCommandHelp() throws {
        let console = BufferedConsole()
        let command = WatchCommand(
            console: console,
            processRunner: RecordingProcessRunner(),
            currentDirectory: URL(fileURLWithPath: "/tmp")
        )
        try command.run(arguments: ["--help"])
        XCTAssertTrue(console.output.joined().contains("metaphor watch"))
    }

    func testLaunchesResolvedBinaryDirectly() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let binary = "/tmp/sketch/.build/debug/Sketch"
        let session = WatchSession(
            directory: URL(fileURLWithPath: "/tmp/sketch"),
            swiftArguments: [],
            console: console,
            processRunner: runner,
            launcher: launcher,
            watcher: watcher,
            binaryResolver: FixedBinaryResolver(path: binary)
        )

        try session.start()

        // swift run ではなくビルド済みバイナリを直接起動する。
        XCTAssertEqual(launcher.executables, [binary])
        XCTAssertEqual(launcher.launches, [[]])
    }

    func testInjectsExtraEnvironmentOnLaunch() throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingLauncher()
        let watcher = ManualFileWatcher()
        let console = BufferedConsole()
        let session = WatchSession(
            directory: URL(fileURLWithPath: "/tmp/sketch"),
            swiftArguments: [],
            console: console,
            processRunner: runner,
            launcher: launcher,
            watcher: watcher,
            binaryResolver: NullBinaryResolver(),
            extraEnvironment: ["METAPHOR_VIEWER": "1", "METAPHOR_SYPHON_NAME": "abc"]
        )

        try session.start()

        // extraEnvironment はそのまま渡る。加えて provenance スタンプが additive に注入される
        // （CONTRACT.md frame.json v4 / METAPHOR_SOURCE_STAMP）。
        let env = launcher.environments.first ?? nil
        XCTAssertEqual(env?["METAPHOR_VIEWER"], "1")
        XCTAssertEqual(env?["METAPHOR_SYPHON_NAME"], "abc")
        XCTAssertNotNil(env?["METAPHOR_SOURCE_STAMP"])
    }
}
