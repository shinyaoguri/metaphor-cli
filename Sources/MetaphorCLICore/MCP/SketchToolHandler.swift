import Foundation

/// `metaphor mcp` が公開する MCP ツール群。
///
/// - `snapshot`（観測）: 現在フレームの PNG と内部状態を返す。
/// - `capture_sequence`（観測）: 連続フレーム列（時間軸）の contact sheet と manifest を返す。
/// - `input`（操作）: マウス/キーイベントを子スケッチの stdin へ転送する。
/// - `params`（観測）: `@Param` で宣言されたパラメータの現在値・レンジを返す。
/// - `set_param`（操作）: パラメータ値を再ビルドなしで書き換える。
/// - `build_status`: 直近の `swift build` の成否とエラーを返す。
/// - `api_reference`: 依存先 metaphor ライブラリの API ドキュメントを返す。
///
/// 副作用は注入されたクロージャ越しに行うのでユニットテスト可能。
public final class SketchToolHandler: MCPToolHandling {
    private let snapshotTool: ProbeSnapshotTool
    private let sequenceTool: ProbeSequenceTool
    private let parameterStoreTool: ParameterStoreTool
    private let forwardInput: (String) -> Void
    private let buildStatusProvider: () -> BuildOutcome?
    /// 入力注入が可能か。共有セッションへアタッチした `metaphor mcp` では、子の stdin は
    /// watch 側が所有しており、かつ AI からの入力注入は対象外のため false。
    private let inputAvailable: Bool
    /// 依存先 metaphor の docs ルート（`llms.txt` がある場所）を返す。`api_reference` で使う。
    /// 呼び出しごとに評価され、初回ビルド後に出現する `.build/checkouts` も拾える。
    private let docsRootProvider: () -> URL?

    public init(
        snapshotTool: ProbeSnapshotTool,
        sequenceTool: ProbeSequenceTool,
        parameterStoreTool: ParameterStoreTool,
        forwardInput: @escaping (String) -> Void,
        buildStatusProvider: @escaping () -> BuildOutcome?,
        inputAvailable: Bool = true,
        docsRootProvider: @escaping () -> URL? = { nil }
    ) {
        self.snapshotTool = snapshotTool
        self.sequenceTool = sequenceTool
        self.parameterStoreTool = parameterStoreTool
        self.forwardInput = forwardInput
        self.buildStatusProvider = buildStatusProvider
        self.inputAvailable = inputAvailable
        self.docsRootProvider = docsRootProvider
    }

    /// `api_reference` の `doc` 引数 → docs ルート相対のファイルパス。
    static let docFiles: [String: String] = [
        "sketch": "llms-sketch.txt",
        "full": "llms.txt",
        "examples": "docs/ai/examples-index.md",
    ]

    /// 子スケッチが受け取る入力イベント種別（stdin JSON Lines の `t`）。
    private static let inputTypes = [
        "mouseDown", "mouseUp", "mouseMove", "mouseDrag", "scroll", "keyDown", "keyUp",
    ]

    public var tools: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "snapshot",
                description: "動作中のスケッチの現在フレームを 1 枚撮り、PNG 画像と内部状態"
                    + "(frame.json: frameCount / time / probe() 値 / 色・領域統計 / "
                    + "performance / blank 警告)を返す。スケッチが重い/軽いの診断は"
                    + " performance を見る: 実測 fps・targetFPS・frameTimeMs(mean/max)・"
                    + "memoryMB・cpuPercent(1 コア=100%)・thermalState。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "label": [
                            "type": "string",
                            "description": "任意のラベル。frame.json に記録される。",
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "このフレームを待つ最大秒数 (1〜60、既定15)。初回はスケッチの cold-start を待つため長めが安全。",
                        ],
                    ],
                ]
            ),
            MCPToolDefinition(
                name: "capture_sequence",
                description: "動作中のスケッチの連続フレーム列を撮り、時間軸の観測を返す。"
                    + "contact sheet(一覧モンタージュ PNG)と manifest(sequence.json: 各フレームの"
                    + "時刻/サイズ/ファイル名/警告)を返す。アニメーションや時間変化の確認に使う。"
                    + "1 枚だけなら snapshot を使う。性能診断(fps/メモリ/CPU)は snapshot の"
                    + " performance を使う(sequence の per-frame には載らない)。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "frames": [
                            "type": "integer",
                            "description": "採取する枚数 (2 以上)。",
                        ],
                        "every": [
                            "type": "integer",
                            "description": "採取間隔（ストライド、既定 1=毎フレーム）。",
                        ],
                        "label": [
                            "type": "string",
                            "description": "任意のラベル。sequence.json に記録される。",
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "このシーケンスを待つ最大秒数 (1〜120、既定30)。frames×every 枚ぶん + cold-start を見込む。",
                        ],
                    ],
                    "required": ["frames"],
                ]
            ),
            MCPToolDefinition(
                name: "input",
                description: "マウス/キー入力を動作中のスケッチへ送る（キャンバス座標）。"
                    + "再ビルド中で子が居ない瞬間は黙って捨てられる。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": Self.inputTypes,
                                 "description": "イベント種別。"],
                        "x": ["type": "number", "description": "キャンバス X（mouse 系）。"],
                        "y": ["type": "number", "description": "キャンバス Y（mouse 系）。"],
                        "button": ["type": "integer", "description": "0=左 1=右 2=その他（mouse 系）。"],
                        "dx": ["type": "number", "description": "スクロール量 X（scroll）。"],
                        "dy": ["type": "number", "description": "スクロール量 Y（scroll）。"],
                        "code": ["type": "integer", "description": "キーコード（key 系）。"],
                        "chars": ["type": "string", "description": "入力文字（keyDown）。"],
                        "repeat": ["type": "boolean", "description": "リピートか（keyDown）。"],
                    ],
                    "required": ["type"],
                ]
            ),
            MCPToolDefinition(
                name: "params",
                description: "動作中のスケッチが @Param で宣言したパラメータの一覧を返す"
                    + "(名前 / 型 / 現在値 / min・max / choices と、ストアの revision・"
                    + "直近 set_param の warnings)。set_param で何を触れるか・値の形は何かを"
                    + "知るためにまず呼ぶ。値は再ビルドなしで書き換えられるので、"
                    + "数値の調整でソースを編集する前にここを見る。",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            MCPToolDefinition(
                name: "set_param",
                description: "@Param で宣言されたパラメータの値を再ビルドなしで書き換え、"
                    + "反映後の値を返す(ファイル往復のみで往復は 1 フレーム)。値の形は params の"
                    + " type に従う: float/int=数値, bool=真偽値, string=文字列, "
                    + "vec2/vec3/color=2/3/4 要素の数値配列。未知の名前・型不一致・choices 外は"
                    + "拒否され warnings に理由が載る(数値は min/max へクランプ)。"
                    + "反映後の絵は snapshot で確認する。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "values": [
                            "type": "object",
                            "description": "パラメータ名 → 新しい値。複数まとめて 1 回で送れる（同一フレームで適用される）。",
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "反映を待つ最大秒数 (1〜60、既定5)。",
                        ],
                    ],
                    "required": ["values"],
                ]
            ),
            MCPToolDefinition(
                name: "build_status",
                description: "直近の `swift build` の成否・終了コード・エラー出力を返す。"
                    + "ソースを編集した後に、その編集がコンパイルできたかの確認に使う。"
                    + "リロード一巡の分解計時（timings: detect_ms/build_ms/relaunch_ms）も載る。",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            MCPToolDefinition(
                name: "api_reference",
                description: "依存先 metaphor ライブラリの API ドキュメントを返す。"
                    + "新しい API を使う前に必ず参照する。doc=sketch は簡潔な作法ガイド、"
                    + "doc=full は全 API リファレンス、doc=examples は近傍のサンプル索引。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc": [
                            "type": "string",
                            "enum": ["sketch", "full", "examples"],
                            "description": "sketch=作法ガイド(既定) / full=全API / examples=サンプル索引。",
                        ],
                        "grep": [
                            "type": "string",
                            "description": "指定すると一致行のみ返す（大小無視）。full の全文を避けたいとき用。",
                        ],
                    ],
                ]
            ),
        ]
    }

    public func call(name: String, arguments: [String: Any]) -> MCPToolResult {
        switch name {
        case "snapshot":
            let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue
            let result = snapshotTool.snapshot(label: arguments["label"] as? String, timeoutOverride: timeout)
            return annotateWithBuildProvenance(result)
        case "capture_sequence":
            return handleCaptureSequence(arguments)
        case "input":
            return handleInput(arguments)
        case "params":
            return annotateWithBuildProvenance(parameterStoreTool.params())
        case "set_param":
            return handleSetParam(arguments)
        case "build_status":
            return handleBuildStatus()
        case "api_reference":
            return handleAPIReference(arguments)
        default:
            return .text("unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - build provenance

    /// 観測系ツールの結果に「直近ビルドの素性」を 1 行添える。
    ///
    /// 共有セッションで人間/AI が編集中だと、観測対象が**ビルド失敗前の旧バイナリ**の
    /// ものでありうる（撮ったフレームも、そのバイナリが宣言した `@Param` の一覧も）。
    /// 直近ビルドが失敗していれば警告を付け、「あなたの編集はまだ反映されていないかも
    /// しれない」とエージェントに知らせる（`frame.json`＝ライブラリ側には触れない）。
    private func annotateWithBuildProvenance(_ result: MCPToolResult) -> MCPToolResult {
        guard let outcome = buildStatusProvider(), !outcome.succeeded else { return result }
        let note = "note: 直近の swift build は失敗しています (exit \(outcome.exitCode))。"
            + "この応答は編集前のビルドのスケッチによるものの可能性があります。build_status で詳細を確認してください。"
        var content = result.content
        content.append(["type": "text", "text": note])
        return MCPToolResult(content: content, isError: result.isError)
    }

    // MARK: - capture_sequence

    private func handleCaptureSequence(_ arguments: [String: Any]) -> MCPToolResult {
        guard let frames = (arguments["frames"] as? NSNumber)?.intValue else {
            return .text("capture_sequence: 'frames' (整数, 2 以上) が必要です。", isError: true)
        }
        let every = (arguments["every"] as? NSNumber)?.intValue
        let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue
        let result = sequenceTool.captureSequence(
            label: arguments["label"] as? String,
            frames: frames,
            every: every,
            timeoutOverride: timeout
        )
        return annotateWithBuildProvenance(result)
    }

    // MARK: - input

    private func handleInput(_ arguments: [String: Any]) -> MCPToolResult {
        guard inputAvailable else {
            return .text(
                "input: 共有セッション（metaphor watch にアタッチ中）では入力注入は未対応です。"
                    + "コードはファイルを直接編集してください（watch が再ビルドします）。",
                isError: true
            )
        }
        guard let type = arguments["type"] as? String, Self.inputTypes.contains(type) else {
            return .text("input: 'type' が必要です (\(Self.inputTypes.joined(separator: ", ")))", isError: true)
        }

        // 子が期待する JSON Lines（キー `t` + 渡されたフィールドのみ）を組む。
        var event: [String: Any] = ["t": type]
        for key in ["x", "y", "dx", "dy"] {
            if let value = (arguments[key] as? NSNumber)?.doubleValue { event[key] = value }
        }
        for key in ["button", "code"] {
            if let value = (arguments[key] as? NSNumber)?.intValue { event[key] = value }
        }
        if let chars = arguments["chars"] as? String { event["chars"] = chars }
        if let isRepeat = arguments["repeat"] as? Bool { event["repeat"] = isRepeat }

        guard
            JSONSerialization.isValidJSONObject(event),
            let data = try? JSONSerialization.data(withJSONObject: event),
            let line = String(data: data, encoding: .utf8)
        else {
            return .text("input: イベントを直列化できませんでした", isError: true)
        }

        forwardInput(line)
        return .text("sent \(type)")
    }

    // MARK: - set_param

    private func handleSetParam(_ arguments: [String: Any]) -> MCPToolResult {
        guard let values = arguments["values"] as? [String: Any] else {
            return .text(
                "set_param: 'values' (パラメータ名 → 新しい値のオブジェクト) が必要です。"
                    + "触れる名前と値の形は params で確認してください。",
                isError: true
            )
        }
        let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue
        let result = parameterStoreTool.setParam(values: values, timeoutOverride: timeout)
        return annotateWithBuildProvenance(result)
    }

    // MARK: - build_status

    private func handleBuildStatus() -> MCPToolResult {
        guard let outcome = buildStatusProvider() else {
            return .text("build_status: まだビルド結果がありません。")
        }
        var head = outcome.succeeded
            ? "build OK (exit \(outcome.exitCode))"
            : "build FAILED (exit \(outcome.exitCode))"
        if let timings = outcome.timingsSummary {
            head += "\n\(timings)"
        }
        let body = outcome.output.isEmpty ? "" : "\n\n\(outcome.output)"
        return MCPToolResult(
            content: [["type": "text", "text": head + body]],
            isError: !outcome.succeeded
        )
    }

    // MARK: - api_reference

    private func handleAPIReference(_ arguments: [String: Any]) -> MCPToolResult {
        let doc = (arguments["doc"] as? String) ?? "sketch"
        guard let relative = Self.docFiles[doc] else {
            let kinds = Self.docFiles.keys.sorted().joined(separator: ", ")
            return .text("api_reference: 'doc' は \(kinds) のいずれかにしてください。", isError: true)
        }
        guard let root = docsRootProvider() else {
            return .text(
                "api_reference: metaphor ライブラリの場所を解決できませんでした。"
                    + "スケッチを一度 `swift build` してから再試行するか、Package.swift の metaphor 依存を確認してください。",
                isError: true
            )
        }
        let fileURL = root.appendingPathComponent(relative)
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .text(
                "api_reference: \(relative) が見つかりません (\(root.path))。"
                    + "ライブラリ側で `make llms-txt` / `make examples-index` を実行してください。",
                isError: true
            )
        }

        guard let needle = arguments["grep"] as? String, !needle.isEmpty else {
            return .text(contents)
        }
        let matched = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: needle, options: .caseInsensitive) != nil }
        if matched.isEmpty {
            return .text("api_reference(\(doc)) grep \"\(needle)\": 一致する行はありません。")
        }
        return .text(matched.joined(separator: "\n"))
    }
}
