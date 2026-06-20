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

        XCTAssertEqual(launcher.environments.first ?? nil, ["METAPHOR_VIEWER": "1", "METAPHOR_SYPHON_NAME": "abc"])
    }
}
