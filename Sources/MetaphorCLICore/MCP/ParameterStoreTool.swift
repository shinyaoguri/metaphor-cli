import Foundation

/// Parameter Store のファイル往復（CONTRACT.md 契約点 7）を自動化し、MCP の
/// `params`（読み取り）/ `set_param`（書き込み）ツールとして公開する。
///
/// producer（スケッチ = `ParameterPlugin`）が `.metaphor/params/params.json` を
/// **唯一書き**、consumer は `set-request.json` を `.tmp` → rename でアトミックに
/// 書いて `appliedRequestId` のエコーを待つ。`ProbeSnapshotTool` と同型の ready
/// 規約——タイムアウトではなく **id 一致**で判定する——であり、全件拒否でも
/// `appliedRequestId` は更新されるので、拒否も待たずに検知できる。
///
/// 値の変更が再ビルドを伴わないため、往復は 1 フレーム（数十 ms）で閉じる。
/// コード構造を変えない探索はこちらが速い。
public final class ParameterStoreTool {
    private let paramsRoot: URL          // <sketch>/.metaphor/params
    private let paramsPath: URL          // paramsRoot/params.json
    private let setRequestPath: URL      // paramsRoot/set-request.json
    private let timeout: TimeInterval
    private let pollInterval: useconds_t
    private let pidPrefix: String
    private var counter = 0

    /// `timeout` は `set_param` 1 回の最大待ち時間。producer は次フレームの `pre()` で
    /// set-request を読み、**即時**に `params.json` を書き直す（GUI ドラッグ由来の
    /// デバウンスは掛からない）ため、動作中のスケッチなら 1 フレームで返る。
    public init(sketchDirectory: URL, timeout: TimeInterval = 5.0) {
        let root = sketchDirectory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("params", isDirectory: true)
        self.paramsRoot = root
        self.paramsPath = root.appendingPathComponent("params.json")
        self.setRequestPath = root.appendingPathComponent("set-request.json")
        self.timeout = timeout
        self.pollInterval = 20_000   // 20ms
        self.pidPrefix = "mcp-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 宣言されたパラメータ（名前・型・現在値・レンジ・`choices`）と `revision` /
    /// `appliedRequestId` / `warnings` を返す。`params.json` を verbatim で渡し、
    /// 意味の正典（型・レンジ）を cli 側で再解釈しない。
    public func params() -> MCPToolResult {
        guard let object = readParamsFile() else {
            return .text(Self.storeMissingMessage(tool: "params"), isError: true)
        }
        guard let text = Self.prettyJSON(object) else {
            return .text("params: params.json を再直列化できませんでした", isError: true)
        }
        return .text(text)
    }

    /// パラメータ値を書き換え、反映後の `params.json` を返す。
    ///
    /// 拒否（未知の名前・型不一致・`choices` 外）は producer 側で起き、理由が
    /// `warnings` に載る。1 件でも拒否があれば `isError` を立てて、エージェントが
    /// 「書いたつもりで書けていない」まま次の観測へ進まないようにする。
    public func setParam(values: [String: Any], timeoutOverride: TimeInterval? = nil) -> MCPToolResult {
        guard !values.isEmpty else {
            return .text("set_param: 'values' が空です。{名前: 値} を 1 つ以上指定してください。", isError: true)
        }
        if let invalid = Self.firstInvalidValueName(in: values) {
            return .text(
                "set_param: '\(invalid)' の値の形が契約に合いません。"
                    + "数値 / 真偽値 / 文字列 / 2〜4 要素の数値配列（vec2 / vec3 / color）のいずれかにしてください。",
                isError: true
            )
        }
        // ストアが無ければ set-request を書いても誰も読まない。タイムアウトを待たせない。
        guard readParamsFile() != nil else {
            return .text(Self.storeMissingMessage(tool: "set_param"), isError: true)
        }

        counter += 1
        let id = "\(pidPrefix)-\(counter)"
        do {
            try writeSetRequest(id: id, values: values)
        } catch {
            return .text("set_param: set-request.json を書けませんでした: \(error)", isError: true)
        }

        let effectiveTimeout = min(60.0, max(1.0, timeoutOverride ?? timeout))
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while Date() < deadline {
            if let object = readParamsFile(), object["appliedRequestId"] as? String == id {
                return buildSetResult(object: object)
            }
            usleep(pollInterval)
        }
        return .text(
            "set_param: タイムアウト (\(effectiveTimeout)s)。値はまだ反映されていません。"
                + "スケッチが描画中か（フレームが進まない間は set-request が読まれません）、"
                + "METAPHOR_PARAMS=0 で無効化されていないかを確認してください。",
            isError: true
        )
    }

    // MARK: - Private

    /// set-request.json を atomic（tmp → rename）に書く。producer は mtime 変化で
    /// 検出して 1 回読むため、部分書き込みを読ませない（契約点 4 の request.json と同じ理由）。
    private func writeSetRequest(id: String, values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: paramsRoot, withIntermediateDirectories: true)
        let object: [String: Any] = ["id": id, "values": values]
        let data = try JSONSerialization.data(withJSONObject: object)

        let tmp = paramsRoot.appendingPathComponent("set-request.json.tmp")
        try data.write(to: tmp)
        try ProbeAtomicFile.replace(tmp: tmp, final: setRequestPath)
    }

    private func readParamsFile() -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: paramsPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    /// 反映後の `params.json` に、拒否の有無を 1 行のサマリで添えて返す。
    private func buildSetResult(object: [String: Any]) -> MCPToolResult {
        let warnings = (object["warnings"] as? [String]) ?? []
        var head = "set_param: 反映を確認しました"
        if let revision = (object["revision"] as? NSNumber)?.intValue {
            head += "（revision \(revision)）"
        }
        // producer が warnings に載せるのは「拒否」（未知の名前・型不一致・choices 外）だけで、
        // min / max のクランプは黙って行われる。実際に入った値は返す params.json 側で確認する。
        head += warnings.isEmpty
            ? "。拒否された項目はありません（数値は min/max にクランプされている場合があります）。"
            : "。拒否: " + warnings.joined(separator: " / ")

        var content: [[String: Any]] = [["type": "text", "text": head]]
        if let text = Self.prettyJSON(object) {
            content.append(["type": "text", "text": text])
        }
        return MCPToolResult(content: content, isError: !warnings.isEmpty)
    }

    /// `set-request.json` の wire 形式（`contract/param-set-request.schema.json`）に
    /// 合わない値を先に弾く。合わない値を書くと producer に無視されるだけで理由が
    /// 残らないため、consumer 側で形の責任を持つ。
    private static func firstInvalidValueName(in values: [String: Any]) -> String? {
        for name in values.keys.sorted() {
            let value = values[name]
            if value is String || value is Bool || value is NSNumber { continue }
            if
                let array = value as? [Any],
                (2...4).contains(array.count),
                array.allSatisfy({ $0 is NSNumber })
            {
                continue
            }
            return name
        }
        return nil
    }

    private static func prettyJSON(_ object: [String: Any]) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .prettyPrinted]
            )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func storeMissingMessage(tool: String) -> String {
        "\(tool): .metaphor/params/params.json がありません。"
            + "スケッチに @Param 宣言が無いか、まだ 1 フレームも描画していない可能性があります"
            + "（オプトアウトは METAPHOR_PARAMS=0）。宣言の書き方は api_reference の doc=sketch を参照してください。"
    }
}
