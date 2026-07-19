import Foundation

/// `ProbePerformance` をステータスライン 1 行に整形する。
///
/// 表示イメージ:
/// `fps 59.8/60 │ mem 141MB │ cpu 23% │ thermal nominal`
public enum MetricsFormatter {
    public static func line(_ perf: ProbePerformance) -> String {
        var parts: [String] = []

        // fps は noLoop 停止中・起動直後に省略される契約なので "--" でフォールバック。
        let fpsText = perf.fps.map { String(format: "%.1f", $0) } ?? "--"
        let targetText = perf.targetFPS.map(compactNumber) ?? "--"
        parts.append("fps \(fpsText)/\(targetText)")

        if let memory = perf.memoryMB {
            parts.append("mem \(Int(memory.rounded()))MB")
        }
        if let cpu = perf.cpuPercent {
            parts.append("cpu \(Int(cpu.rounded()))%")
        }
        if let thermal = perf.thermalState {
            parts.append("thermal \(thermal)")
        }
        return parts.joined(separator: " │ ")
    }

    /// 60.0 → "60"、59.5 → "59.5"（targetFPS は普通整数なので小数を出さない）。
    private static func compactNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// ステータスラインの端末出力。TTY ならカーソル行を `\r` + erase-line で上書きし続け、
/// 非 TTY（リダイレクト・CI）なら内容が変わったときだけ 1 行ずつログする。
///
/// stderr へ出す理由: `run` ではスケッチ自身の stdout（print 等）が端末へ直結して
/// おり、メトリクスは診断情報としてそちらを汚さない側へ流す。子プロセスの出力が
/// 改行付きで挟まるとステータスライン行は乱れるが、erase-line が消せるのはカーソル
/// のいる現在行だけなので確定済みログは消えず、次ティックの再描画で回復する。
public final class MetricsStatusLine {
    private let isTTY: Bool
    private let write: (String) -> Void
    private let lock = NSLock()
    private var lastLoggedText: String?
    private var didRender = false
    private var finished = false

    /// - Parameters:
    ///   - isTTY: 省略時は stderr の isatty 判定。テスト用フック。
    ///   - write: 省略時は stderr へ直接書く。テスト用フック。
    public init(isTTY: Bool? = nil, write: ((String) -> Void)? = nil) {
        self.isTTY = isTTY ?? (isatty(STDERR_FILENO) != 0)
        self.write = write ?? { text in
            FileHandle.standardError.write(Data(text.utf8))
        }
    }

    public func update(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        // finish() 後に実行中サイクルの通知が届いても行を復活させない
        // （停止ログの後ろへ未確定行が紛れ込むのを防ぐ）。
        if finished { return }
        if isTTY {
            // \u{1B}[2K = erase entire line。改行せずカーソル行を差し替え続ける。
            write("\r\u{1B}[2K\(text)")
            didRender = true
        } else {
            // 非 TTY で毎ティック同内容を吐くとログが洪水になるので変化時のみ。
            guard text != lastLoggedText else { return }
            lastLoggedText = text
            write("[metrics] \(text)\n")
        }
    }

    /// 未確定のステータスライン行を改行で確定させ、以後の `update` を無視する
    /// （停止時に呼ぶ。冪等）。
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        if isTTY, didRender {
            write("\n")
            didRender = false
        }
    }
}

/// `--metrics` の配線一式: ポーラー起動 → サンプルをステータスラインへ反映。
/// `run` / `watch`（ビューア・`--no-viewer` 両モード）から共用する。
public final class MetricsReporter {
    private let poller: MetricsPoller
    private let statusLine: MetricsStatusLine

    /// interval は 0.2s 未満を 0.2s にクランプ（producer 側の毎フレーム mtime
    /// ポーリングと PNG 書き出しへの過負荷防止）。nil は既定 1s。
    public init(sketchDirectory: URL, interval: TimeInterval?) {
        let clamped = Swift.max(0.2, interval ?? 1.0)
        let statusLine = MetricsStatusLine()
        self.statusLine = statusLine
        self.poller = MetricsPoller(sketchDirectory: sketchDirectory, interval: clamped) { sample in
            switch sample {
            case .metrics(let performance):
                statusLine.update(MetricsFormatter.line(performance))
            case .unsupported:
                statusLine.update("performance データなし — スケッチの metaphor を 0.7.0+ に更新してください")
            case .noResponse:
                statusLine.update("応答待ち — スケッチ起動中 / noLoop 停止中 / ビルド失敗の可能性")
            case .yielded:
                break  // MCP へ譲ったサイクル。前回表示を維持する。
            }
        }
    }

    public func start() {
        statusLine.update("収集中…")
        poller.start()
    }

    public func stop() {
        poller.stop()
        statusLine.finish()
    }
}
