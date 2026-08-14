import Foundation

// MARK: - Watch session (testable core)

/// `metaphor watch` のコアロジック。ビルド・起動・再起動の制御のみを担い、
/// 実行ループやシグナル処理は ``WatchCommand`` 側に置く。注入された
/// ``ProcessRunning`` / ``ProcessLaunching`` / ``FileWatching`` により単体テスト可能。
/// `swift build` の結果サマリ。`metaphor mcp` の `build_status` などが参照する。
public struct BuildOutcome: Equatable, Codable {
    public let succeeded: Bool
    public let exitCode: Int32
    /// ビルド出力（stderr 中心）。`captureBuildOutput=true` のときだけ中身が入る。
    public let output: String
    /// 初回ビルドか（reload ではなく start 時）。
    public let initial: Bool
    /// 変更ファイルの最終更新 → 変更検知までの推定時間（ms）。初回ビルドでは nil。
    /// ポーリング監視では「保存 → 検知」の待ち時間に相当する。
    public let detectMs: Double?
    /// `swift build` の所要時間（ms）。
    public let buildMs: Double?
    /// ビルド成功 → 子プロセス起動完了までの時間（ms）。旧プロセスの終了・
    /// バイナリ解決・sourceStamp 計算を含む。ビルド失敗・起動失敗時は nil。
    public let relaunchMs: Double?

    public init(
        succeeded: Bool,
        exitCode: Int32,
        output: String,
        initial: Bool,
        detectMs: Double? = nil,
        buildMs: Double? = nil,
        relaunchMs: Double? = nil
    ) {
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.output = output
        self.initial = initial
        self.detectMs = detectMs
        self.buildMs = buildMs
        self.relaunchMs = relaunchMs
    }

    /// 分解計時の 1 行サマリ（例: `timings: detect_ms=210.3 build_ms=1450.2 relaunch_ms=180.1`）。
    /// `build_status` ツールと測定ハーネス（measure-roundtrip.py）が同じ形式を読む。
    /// 計時が 1 つもなければ nil。
    public var timingsSummary: String? {
        var fields: [String] = []
        if let detectMs { fields.append(String(format: "detect_ms=%.1f", detectMs)) }
        if let buildMs { fields.append(String(format: "build_ms=%.1f", buildMs)) }
        if let relaunchMs { fields.append(String(format: "relaunch_ms=%.1f", relaunchMs)) }
        guard !fields.isEmpty else { return nil }
        return "timings: " + fields.joined(separator: " ")
    }
}

public final class WatchSession {
    private let directory: URL
    private let swiftArguments: [String]
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let launcher: any ProcessLaunching
    private let watcher: any FileWatching
    private let binaryResolver: any SketchBinaryResolving
    private let extraEnvironment: [String: String]?
    /// true のとき `swift build` の出力を捕捉して `lastBuildOutcome` に残す
    /// （`metaphor mcp` の `build_status` 用）。false（既定 = `watch`）では従来どおり
    /// 端末へ素通しし、出力テキストは記録しない。
    private let captureBuildOutput: Bool
    /// true のとき共有セッション（`metaphor mcp` がアタッチして観測する）として動作する。
    /// 起動時に `.metaphor/session.json` を、毎ビルドで `.metaphor/build-status.json` を
    /// 書き、停止時にマニフェストを削除する。出力テキストも必要なので捕捉を強制する。
    private let shareSession: Bool

    private let buildLock = NSLock()
    private var _lastBuildOutcome: BuildOutcome?
    /// 直近の `swift build` の結果。`captureBuildOutput=true` のときだけ `output` に
    /// ビルド出力（エラー含む）が入る。
    public var lastBuildOutcome: BuildOutcome? {
        buildLock.lock(); defer { buildLock.unlock() }; return _lastBuildOutcome
    }

    /// 動作中の子スケッチ。再ビルド（バックグラウンドキュー）から書き換わり、
    /// 入力転送（メインスレッドの `forwardInput`）から読まれるため、頻発する
    /// マウス移動でのデータ競合を避けるようロックで保護する。getter は強参照を
    /// 返すので、読んだ直後に reload が走っても掴んだ子は有効なまま。
    private let currentLock = NSLock()
    private var _current: (any LaunchedProcess)?
    private var current: (any LaunchedProcess)? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); defer { currentLock.unlock() }; _current = newValue }
    }
    /// 解決済みの実行ファイルパス（初回解決後にキャッシュ）。
    private var resolvedBinary: String?

    /// リロードをまたいで子の状態を運ぶ受け渡し役（CONTRACT.md 契約点 8）。
    private let stateHandoff: StateHandoff

    /// 直前の保存要求が無応答だったら、以降のリロードでは要求しない。
    /// 状態保持を使っていないスケッチで毎回タイムアウトぶんの遅延を払わないため。
    private var stateHandoffDisabled = false

    /// 子スケッチを（再）起動したときに呼ばれる。ビューアが Syphon サーバーの
    /// 差し替え（同名・別 UUID）に追従するための通知に使う。バックグラウンドキューから
    /// 呼ばれうるので、受け手はメインスレッドへホップすること。
    public var onChildLaunched: (() -> Void)?

    /// `swift build` を始める直前に呼ばれる（`initial` = 初回ビルドかどうか）。
    /// ビューアが「ビルド中…」のローディング表示へ切り替えるための通知。
    /// `onChildLaunched` 同様バックグラウンドキューから呼ばれうるので、受け手は
    /// メインスレッドへホップすること。
    public var onBuildWillStart: ((_ initial: Bool) -> Void)?

    /// `swift build` が終わった直後に、結果（`BuildOutcome`）とともに呼ばれる。
    /// ビューアがビルド失敗を可視化するための通知。成功時は続けて
    /// `onChildLaunched` が呼ばれる。バックグラウンドキューから呼ばれうる。
    public var onBuildFinished: ((BuildOutcome) -> Void)?

    public init(
        directory: URL,
        swiftArguments: [String],
        console: any Console,
        processRunner: any ProcessRunning,
        launcher: any ProcessLaunching,
        watcher: any FileWatching,
        binaryResolver: (any SketchBinaryResolving)? = nil,
        extraEnvironment: [String: String]? = nil,
        captureBuildOutput: Bool = false,
        shareSession: Bool = false,
        stateHandoff: StateHandoff? = nil
    ) {
        self.directory = directory
        self.swiftArguments = swiftArguments
        self.console = console
        self.processRunner = processRunner
        self.launcher = launcher
        self.watcher = watcher
        // 既定の解決器には console を渡し、解決失敗（swift run への低速フォールバック）を
        // 黙らせず一度だけ通知する。テストはカスタム解決器を注入できる。
        self.binaryResolver = binaryResolver ?? SwiftPMBinaryResolver(console: console)
        self.extraEnvironment = extraEnvironment
        self.stateHandoff = stateHandoff ?? StateHandoff(sketchDirectory: directory)
        // 共有セッションでは build-status.json にエラー文も載せたいので捕捉を強制する。
        self.captureBuildOutput = captureBuildOutput || shareSession
        self.shareSession = shareSession
    }

    /// 初回ビルド+起動を行い、ファイル監視を開始する。
    public func start() throws {
        // どの CLI ビルドが動いているか毎回表示（古いインストールの取り違え防止）。
        // スケッチ子プロセスは自分で `[metaphor] <版>` を出すので、ここは CLI 版のみ。
        console.write("[watch] \(BuildInfo.cliIdentifier)")
        console.write("metaphor watch: \(directory.path)")
        console.write("[watch] Ctrl-C で停止")
        if shareSession {
            publishManifest()
        }
        rebuildAndLaunch(initial: true)
        try watcher.start { [weak self] in
            self?.reload()
        }
    }

    /// 共有セッションのマニフェスト（`.metaphor/session.json`）を書き出す。
    private func publishManifest() {
        let manifest = SharedSession.Manifest(
            pid: ProcessInfo.processInfo.processIdentifier,
            sketchPath: directory.path,
            syphonName: extraEnvironment?["METAPHOR_SYPHON_NAME"],
            probeEnabled: extraEnvironment?["METAPHOR_PROBE"] == "1",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        SharedSession.writeManifest(manifest, for: directory)
        console.write("[watch] 共有セッション: metaphor mcp からアタッチ観測できます")
    }

    /// 変更検出時の再ビルド+再起動。
    public func reload() {
        console.write("[watch] 変更を検出 — 再ビルド中…")
        rebuildAndLaunch(initial: false, detectMs: estimateDetectLatency())
    }

    /// 変更検知の遅延（最新 `.swift` の mtime → 現在）を見積もる（ms）。
    /// mtime は wall clock なので Date() と比較する。走査に失敗したら nil。
    private func estimateDetectLatency() -> Double? {
        guard let latest = latestSwiftModification() else { return nil }
        return max(0, Date().timeIntervalSince(latest) * 1000)
    }

    /// 監視対象（`.build` 除く）の `.swift` で最も新しい更新時刻。
    private func latestSwiftModification() -> Date? {
        var latest: Date?
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { continue }
                if latest.map({ date > $0 }) ?? true { latest = date }
            }
        }
        return latest
    }

    /// 監視と実行中スケッチを停止する。
    public func stop() {
        watcher.stop()
        current?.terminate()
        current = nil
        if shareSession {
            SharedSession.removeManifest(for: directory)
        }
    }

    /// 刻印（provenance）の対象とする拡張子。`.swift`（スケッチ本体）に加えて
    /// `.metal`（シェーダソース）も含める。metaphor 側はシェーダファイルを
    /// ホットリロードするので、`.metal` を落とすと「絵は違うのに同じ刻印」になり、
    /// sourceStamp が名乗る「このフレームがどのソース版か」が嘘になる。
    ///
    /// **リビルドの引き金（``swiftSourceSignature(in:fileManager:)``）とは意図的に
    /// 別集合**。`.metal` の保存で再ビルド＋再起動を起こすと、metaphor のホットリロードが
    /// ただの再起動に化けて価値が消えるため、引き金は `.swift` のままにする。
    private static let stampedSourceExtensions: Set<String> = ["swift", "metal"]

    /// 監視対象スケッチのソース署名を集約した決定論的スタンプ（provenance）。
    /// 対象は ``stampedSourceExtensions``（`.swift` / `.metal`）。
    /// 各ファイルの (パス:mtime:サイズ) を FNV-1a でハッシュする。編集すると mtime/サイズが
    /// 変わるので値が変わり、同一ソースでは再現する。`.build` 配下のビルド生成物は除外する。
    /// `METAPHOR_SOURCE_STAMP` として子スケッチへ渡し、frame.json の sourceStamp に反映される
    /// （契約点 2 / 4。CONTRACT.md の frame.json スキーマ v4 を参照）。
    ///
    /// - Note: 刻印は**子プロセス起動時にしか注入されない**（metaphor 側も起動時に一度だけ
    ///   解決する）。したがって `.metal` 単独編集（再起動を伴わないホットリロード）の反映を
    ///   この刻印で機械検出することはできない。それはリロードの着地時刻を知っている
    ///   producer 側にしか作れないため、metaphor 側の課題として切り出してある（Issue #129）。
    func computeSourceStamp() -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a (64-bit) offset basis
        let prime: UInt64 = 0x100_0000_01b3
        let fm = FileManager.default
        var entries: [String] = []
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
                guard Self.stampedSourceExtensions.contains(url.pathExtension) else { continue }
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values?.fileSize ?? 0
                entries.append("\(url.path):\(mtime):\(size)")
            }
        }
        for entry in entries.sorted() {
            for byte in entry.utf8 { hash = (hash ^ UInt64(byte)) &* prime }
        }
        return String(format: "%016llx", hash)
    }

    /// 入力イベント（JSON Lines 1 行）を現在動作中の子スケッチへ転送する。
    /// 再ビルド中で子が居ない瞬間は黙って捨てる（次の子に引き継がない）。
    public func forwardInput(_ line: String) {
        current?.sendLine(line)
    }

    /// `BuildOutcome` を直近結果として記録する（in-memory + 共有セッションなら
    /// `build-status.json`）。起動完了後の relaunchMs 確定でも再度呼ばれる。
    private func record(_ outcome: BuildOutcome) {
        buildLock.lock()
        _lastBuildOutcome = outcome
        buildLock.unlock()

        if shareSession {
            SharedSession.writeBuildStatus(outcome, for: directory)
        }
    }

    /// 直近ビルドの結果を記録し、その `BuildOutcome` を返す。
    /// `captureBuildOutput=false` のときは出力テキストは空。
    private func recordBuildOutcome(
        _ result: ProcessResult, initial: Bool, detectMs: Double?, buildMs: Double
    ) -> BuildOutcome {
        let output = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let outcome = BuildOutcome(
            succeeded: result.exitCode == 0,
            exitCode: result.exitCode,
            output: output,
            initial: initial,
            detectMs: detectMs,
            buildMs: buildMs
        )
        record(outcome)
        return outcome
    }

    /// DispatchTime（モノトニック）起点からの経過 ms。
    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// 動作中の子へ状態の保存を要求し、次の子へ渡す `state.json` のパスを返す。
    ///
    /// 子が居ない初回起動や、無応答だった後（状態保持を使っていないスケッチ）は
    /// 何もしない。
    private func captureStateForHandoff() -> String? {
        guard current != nil, !stateHandoffDisabled else { return nil }
        guard let path = stateHandoff.captureState() else {
            stateHandoffDisabled = true
            return nil
        }
        return path
    }

    /// ビルドが通った場合のみ、前のスケッチを終了して新しく起動する。
    /// ビルド失敗時は動作中のスケッチを維持する（壊れた編集で窓を消さない）。
    private func rebuildAndLaunch(initial: Bool, detectMs: Double? = nil) {
        onBuildWillStart?(initial)

        let buildStart = DispatchTime.now()
        let build: ProcessResult
        do {
            build = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: ["swift", "build"] + swiftArguments,
                currentDirectory: directory,
                captureOutput: captureBuildOutput
            )
        } catch {
            // `swift build` の起動自体に失敗（env/swift 不在、権限など）。通常のビルド
            // 失敗(exit!=0)と区別がつくよう必ずログし、合成の失敗結果で続行する。
            console.writeError("[watch] ビルド実行エラー: \(error)")
            build = ProcessResult(exitCode: -1)
        }

        let outcome = recordBuildOutcome(
            build, initial: initial, detectMs: detectMs, buildMs: elapsedMs(since: buildStart)
        )
        onBuildFinished?(outcome)

        guard build.exitCode == 0 else {
            if initial {
                console.writeError("[watch] 初回ビルド失敗 (exit \(build.exitCode)) — 変更を待機します")
            } else {
                console.writeError("[watch] ビルド失敗 (exit \(build.exitCode)) — 直前のスケッチを維持します")
            }
            return
        }

        let relaunchStart = DispatchTime.now()
        // 子を kill する前に状態のスナップショットを取る（契約点 8）。応答が無ければ
        // 状態なしで進む — 引き継ぎは付加価値で、リロードを止める理由にはならない。
        let restoreStatePath = captureStateForHandoff()
        current?.terminate()
        current = nil

        // ビルド済みバイナリを直接起動する（swift run はロック競合時に fork して
        // プロセスが二重化しうるため）。解決できなければ swift run にフォールバック。
        if resolvedBinary == nil {
            resolvedBinary = binaryResolver.resolve(directory: directory, swiftArguments: swiftArguments)
        }

        let executable: String
        let arguments: [String]
        if let binary = resolvedBinary {
            executable = binary
            arguments = []
        } else {
            executable = "/usr/bin/env"
            arguments = ["swift", "run", "--skip-build"] + swiftArguments
        }

        // ソース世代の刻印（provenance）を毎起動で更新し、子へ渡す。子スケッチの
        // Probe プラグインがこれを frame.json の sourceStamp に echo するので、AI／
        // 測定ハーネスが「観測フレームが今の編集を反映しているか」を機械判定できる。
        var childEnvironment = extraEnvironment ?? [:]
        childEnvironment["METAPHOR_SOURCE_STAMP"] = computeSourceStamp()
        // watch の子では状態保持プラグインを有効にする（--viewer でないときも運べる
        // ように明示注入する）。ユーザーが環境で切っていればそれを尊重する。
        if childEnvironment["METAPHOR_STATE"] == nil,
           ProcessInfo.processInfo.environment["METAPHOR_STATE"] == nil {
            childEnvironment["METAPHOR_STATE"] = "1"
        }
        // 直前の子が状態を残していれば、その読み戻し先を渡す。
        childEnvironment = stateHandoff.environment(
            base: childEnvironment, statePath: restoreStatePath
        )

        do {
            current = try launcher.launch(
                executable: executable,
                arguments: arguments,
                currentDirectory: directory,
                environment: childEnvironment
            )
            // 起動完了で relaunchMs を確定し、分解計時込みの最終形を記録し直す。
            let final = BuildOutcome(
                succeeded: outcome.succeeded,
                exitCode: outcome.exitCode,
                output: outcome.output,
                initial: outcome.initial,
                detectMs: outcome.detectMs,
                buildMs: outcome.buildMs,
                relaunchMs: elapsedMs(since: relaunchStart)
            )
            record(final)
            console.write(initial ? "[watch] 実行中" : "[watch] リロードしました")
            if let timings = final.timingsSummary {
                console.write("[watch] \(timings)")
            }
            onChildLaunched?()  // ビューアに Syphon サーバーの差し替え追従を促す。
        } catch {
            console.writeError("[watch] 起動失敗: \(error)")
        }
    }
}

