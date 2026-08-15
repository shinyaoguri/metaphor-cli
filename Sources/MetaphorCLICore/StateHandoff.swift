import Foundation

/// リロードをまたいで子スケッチの状態を運ぶ受け渡し役（CONTRACT.md 契約点 8）。
///
/// `metaphor watch` は再ビルドのたびに子プロセスを作り直すため、既定では
/// `draw()` が積み上げた状態と時計が毎回ゼロに戻ります。本型は
/// **kill する直前**に子へ保存を要求し、書き上がった `state.json` のパスを
/// 次の子へ `METAPHOR_RESTORE_STATE` として渡します。
///
/// 手順は Probe（契約点 4）と同型:
///
/// 1. `.metaphor/state/save-request.json` へ新しい `id` をアトミックに書く
/// 2. `.metaphor/state/state.json` の `savedRequestId` がその `id` になるまでポーリング
/// 3. 一致したらパスを返す（呼び出し側が子を kill → 新しい子へ env で渡す）
///
/// **失敗は握りつぶす**（保存プラグインが居ない・タイムアウト・書けない）: 状態の
/// 引き継ぎは付加価値であって、リロードそのものを止める理由にはならないためです。
public final class StateHandoff {
    private let stateRoot: URL          // <sketch>/.metaphor/state
    private let saveRequestPath: URL    // stateRoot/save-request.json
    private let statePath: URL          // stateRoot/state.json
    private let timeout: TimeInterval
    private let pollInterval: useconds_t
    private let idPrefix: String
    private var counter = 0

    /// - Parameters:
    ///   - sketchDirectory: スケッチのルート（`.metaphor/` の親）。
    ///   - timeout: 保存完了を待つ最大時間。既定 250ms は「間に合わなければ諦めて
    ///     リロードを進める」という設計判断（CONTRACT.md 契約点 8）。
    public init(sketchDirectory: URL, timeout: TimeInterval = 0.25) {
        let root = MetaphorStateDirectory.root(for: sketchDirectory)
            .appendingPathComponent("state", isDirectory: true)
        self.stateRoot = root
        self.saveRequestPath = root.appendingPathComponent("save-request.json")
        self.statePath = root.appendingPathComponent("state.json")
        self.timeout = timeout
        self.pollInterval = 5_000   // 5ms: 待ち時間そのものがリロードの遅延になる
        self.idPrefix = "watch-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 動作中の子へ保存を要求し、書き上がった `state.json` の絶対パスを返す。
    ///
    /// - Returns: 引き継げる状態があれば `state.json` の絶対パス。保存要求を書けない・
    ///   応答が来ない（プラグイン未登録 / タイムアウト）場合は `nil`。
    public func captureState() -> String? {
        counter += 1
        let id = "\(idPrefix)-\(counter)"

        do {
            try writeSaveRequest(id: id)
        } catch {
            // 書けない = 状態の引き継ぎだけ諦める（リロードは続行）。
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if savedRequestIdMatches(id) { return statePath.path }
            usleep(pollInterval)
        }
        return nil
    }

    /// 新しい子へ渡す環境変数を組み立てる。
    ///
    /// 状態が無ければ環境変数を足さない（子は通常起動 = 初期状態）。
    public func environment(base: [String: String], statePath: String?) -> [String: String] {
        guard let statePath else { return base }
        var environment = base
        environment["METAPHOR_RESTORE_STATE"] = statePath
        return environment
    }

    // MARK: - Private

    /// save-request.json を atomic（tmp → rename）に書く。producer が部分書き込みを
    /// 読まないための規約（契約点 8）。
    private func writeSaveRequest(id: String) throws {
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["id": id])
        let tmp = stateRoot.appendingPathComponent("save-request.json.tmp")
        try data.write(to: tmp)
        try ProbeAtomicFile.replace(tmp: tmp, final: saveRequestPath)
    }

    /// `state.json` が指定 `id` へのエコーになっているか。
    ///
    /// 中身（`runtime` / `user`）は**解釈しない** — cli は運ぶだけで、ペイロードの
    /// 型を知る必要がない（契約点 8）。
    private func savedRequestIdMatches(_ id: String) -> Bool {
        guard let data = try? Data(contentsOf: statePath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return false
        }
        return dict["savedRequestId"] as? String == id
    }
}
