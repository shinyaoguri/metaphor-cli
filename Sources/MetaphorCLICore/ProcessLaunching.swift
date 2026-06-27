import Darwin
import Foundation

// MARK: - Process launching (non-blocking)

/// 起動済みの子プロセスへのハンドル。`ProcessRunning` が完了まで待つのと違い、
/// `watch` はスケッチを動かしたまま次の変更で停止できる必要があるため分離している。
public protocol LaunchedProcess: AnyObject {
    /// プロセスがまだ実行中かどうか。
    var isRunning: Bool { get }
    /// プロセスに終了を要求し、終了まで待つ。
    func terminate()
    /// 子の stdin へ 1 行（末尾改行付き）書き込む。入力イベント（JSON Lines）の転送に使う。
    func sendLine(_ line: String)
}

/// 子プロセスを**ブロックせずに**起動する抽象。テストで差し替え可能。
public protocol ProcessLaunching {
    func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> any LaunchedProcess
}

/// `Foundation.Process` を `waitUntilExit()` せずに起動する実装。
public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> any LaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }
        // stdin は端末を継承させず**パイプ**にする。
        // 重要: 端末(TTY)を継承すると、バックグラウンドの子（ヘッドレス時の
        // InputInjectionPlugin が stdin を読む）が制御端末の読み取りで SIGTTIN を受けて
        // 停止し、レンダリング/フレーム publish が止まる（ビューア窓が黒くなる）。
        // 書き込み端は LaunchedProcess が保持して開いたままにする（将来の入力転送で使う）。
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe.fileHandleForReading
        // ログ/ウィンドウはそのまま端末へ。
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        return FoundationLaunchedProcess(process, stdinWrite: stdinPipe.fileHandleForWriting)
    }
}

/// `FoundationProcessLauncher` が返す `Process` ラッパー。
final class FoundationLaunchedProcess: LaunchedProcess {
    private let process: Process
    /// 子の stdin（パイプ書き込み端）。開いたまま保持し、将来の入力転送に使う。
    private let stdinWrite: FileHandle

    init(_ process: Process, stdinWrite: FileHandle) {
        self.process = process
        self.stdinWrite = stdinWrite
        // 書き込みをノンブロッキングにする。再起動直後の子が stdin を読み始める前は
        // パイプに空きが無くなりうるが、その際 sendLine が**メインスレッドでブロックして
        // ビューアごと固まる**のを防ぐ（満杯ならそのイベントを捨てる）。
        let flags = fcntl(stdinWrite.fileDescriptor, F_GETFL)
        if flags != -1 {
            _ = fcntl(stdinWrite.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        // SIGTERM を無視してハングする子で再ビルドが止まらないよう、有限時間だけ待ち、
        // 終了しなければ SIGKILL へエスカレーションする。
        let deadline = Date().addingTimeInterval(Self.terminateTimeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)  // 20ms ポーリング
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? stdinWrite.close()
    }

    /// SIGTERM 後に SIGKILL へ切り替えるまでの猶予。
    private static let terminateTimeout: TimeInterval = 5

    func sendLine(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        // ノンブロッキング書き込み。1 行は PIPE_BUF(512) 未満なので write はアトミック：
        // 空きが足りなければ EAGAIN で即返るので、その行は捨てる（入力はロスト許容）。
        // 子が消えていれば EPIPE。SIGPIPE はプロセス起動時に無視している（installSIGPIPEIgnore）。
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = Darwin.write(stdinWrite.fileDescriptor, base, raw.count)
        }
    }
}

/// 閉じたパイプ（終了した子の stdin）への書き込みで SIGPIPE に殺されないよう、
/// プロセス全体で SIGPIPE を無視する。入力転送を行う前に一度だけ呼ぶ。
public func installSIGPIPEIgnore() {
    signal(SIGPIPE, SIG_IGN)
}
