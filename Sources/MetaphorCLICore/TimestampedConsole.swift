import Foundation

/// 各行の先頭へ時刻（`[HH:mm:ss]`）を付けてから委譲する `Console` デコレータ。
///
/// `metaphor watch` のように長時間つけっぱなしで使うコマンド向け。「このリロードは
/// いつのものか」「さっきのビルド失敗は何分前か」をスクロールバックから追えるように
/// する。`new` / `doctor` / `version` のような一発実行コマンドの整形済み出力には
/// 被せない（時刻がノイズになるため）。
///
/// TTY では時刻を dim にして本文とのコントラストを付け、非 TTY（リダイレクト・CI）
/// では ANSI を落として素の文字列にする（`MetricsStatusLine` と同じ方針）。
public struct TimestampedConsole: Console {
    private let base: any Console
    private let now: () -> Date
    private let calendar: Calendar
    private let colorizeOutput: Bool
    private let colorizeError: Bool

    /// - Parameters:
    ///   - base: 実際の出力先。
    ///   - now: 時刻の供給元。テスト用フック。
    ///   - outputIsTTY: 省略時は stdout の isatty 判定。テスト用フック。
    ///   - errorIsTTY: 省略時は stderr の isatty 判定。テスト用フック。
    public init(
        base: any Console,
        now: @escaping () -> Date = Date.init,
        outputIsTTY: Bool? = nil,
        errorIsTTY: Bool? = nil
    ) {
        self.base = base
        self.now = now
        // ロケール設定に振られない 24 時間表記にしたいので DateFormatter ではなく
        // Calendar から組み立てる（値型なのでスレッド安全でもある。watch のログは
        // FSEvents コールバックとシグナルハンドラの双方から流れてくる）。
        self.calendar = Calendar(identifier: .gregorian)
        self.colorizeOutput = outputIsTTY ?? (isatty(STDOUT_FILENO) != 0)
        self.colorizeError = errorIsTTY ?? (isatty(STDERR_FILENO) != 0)
    }

    public func write(_ message: String) {
        base.write(stamped(message, colorize: colorizeOutput))
    }

    public func writeError(_ message: String) {
        base.writeError(stamped(message, colorize: colorizeError))
    }

    /// メッセージの各行へ時刻を付ける。空行はレイアウト目的（停止ログ先頭の改行で
    /// メトリクスのステータスライン行を確定させる等）なので素通しし、時刻だけの行を
    /// 生まないようにする。
    private func stamped(_ message: String, colorize: Bool) -> String {
        let stamp = timestamp()
        // \u{1B}[2m = dim、\u{1B}[0m = reset。
        let prefix = colorize ? "\u{1B}[2m[\(stamp)]\u{1B}[0m" : "[\(stamp)]"
        return message
            .components(separatedBy: "\n")
            .map { line in line.isEmpty ? line : "\(prefix) \(line)" }
            .joined(separator: "\n")
    }

    private func timestamp() -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: now())
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
