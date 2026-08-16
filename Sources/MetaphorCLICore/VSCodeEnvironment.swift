import Foundation

/// `metaphor doctor` が見る「人間側の編集環境」の判定。
///
/// `.vscode/` を同梱しただけでは補完も hover も出ないことがあり（Swift 拡張が
/// 無い・背景インデックスで `import metaphor` が壊れる・まだ一度もビルドして
/// いない）、しかも失敗の出方が**沈黙**なので利用者が切り分けられない。ここは
/// その 3 つを機械的に見分けるための純関数だけを置く。
///
/// 検出は拡張ディレクトリの走査で行い、PATH 上の `code` には依存しない。
/// VSCode の "Shell Command: Install 'code' command in PATH" を実行していない
/// マシンでは `code --list-extensions` が偽陰性になるため。
public enum VSCodeEnvironment {
    /// 生成プロジェクトの `.vscode/extensions.json` が推奨する Swift 拡張の ID。
    /// テンプレート側の JSON との二重管理にならないよう、一致はテストで縛る。
    public static let swiftExtensionID = "swiftlang.swift-vscode"

    public enum SwiftExtension: Equatable {
        /// 拡張が入っている。`version` はディレクトリ名から読めたときだけ。
        case installed(version: String?)
        /// 拡張ディレクトリはあるが、Swift 拡張が無い。
        case missing
        /// `~/.vscode/extensions` 自体が無い＝このマシンに VSCode が無い。
        case vscodeNotFound
    }

    public enum SourcekitLSPConfig: Equatable {
        case backgroundIndexingDisabled
        /// `true` 明記と**キー欠落**の両方。sourcekit-lsp の既定は `auto`
        /// （Swift 6.1+ で有効）なので、書いていない＝踏むことになる。
        case backgroundIndexingEnabled
        case missing
        case unreadable(String)
    }

    /// `~/.vscode/extensions/<publisher>.<name>-<version>` を走査して Swift 拡張を探す。
    public static func swiftExtension(
        home: URL,
        fileManager: FileManager = .default
    ) -> SwiftExtension {
        let extensionsRoot = home
            .appendingPathComponent(".vscode", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: extensionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .vscodeNotFound
        }

        let entries = (try? fileManager.contentsOfDirectory(atPath: extensionsRoot.path)) ?? []
        // 版が上がるとディレクトリ名も変わるので、ID を前方一致で拾って残りを版として読む。
        // 更新の残骸で複数版が並ぶことがあるため新しい方を採る。辞書順だと
        // 2.10.1 < 2.9.0 になってしまうので、数値として比較する。
        guard let entry = entries
            .filter({ $0 == swiftExtensionID || $0.hasPrefix(swiftExtensionID + "-") })
            .max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        else {
            return .missing
        }

        let version = entry.dropFirst(swiftExtensionID.count).drop(while: { $0 == "-" })
        return .installed(version: version.isEmpty ? nil : String(version))
    }

    /// スケッチ直下の `.sourcekit-lsp/config.json` で背景インデックスが切れているか。
    public static func sourcekitLSPConfig(
        projectRoot: URL,
        fileManager: FileManager = .default
    ) -> SourcekitLSPConfig {
        let configFile = projectRoot
            .appendingPathComponent(".sourcekit-lsp", isDirectory: true)
            .appendingPathComponent("config.json")

        guard fileManager.fileExists(atPath: configFile.path) else { return .missing }

        guard let data = fileManager.contents(atPath: configFile.path) else {
            return .unreadable("cannot read \(configFile.path)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            return .unreadable("not a JSON object")
        }

        return json["backgroundIndexing"] as? Bool == false
            ? .backgroundIndexingDisabled
            : .backgroundIndexingEnabled
    }

    /// 一度でもビルドされているか。補完はビルド成果物を参照するので、未ビルドの
    /// ままだと拡張が入っていても何も出ない。
    ///
    /// 見るのは `.build` ではなく `.build/debug`。`metaphor new` は生成時に
    /// `swift package resolve` まで走らせるので、`.build/`（checkouts・artifacts）は
    /// **一度もビルドしていないスケッチにも存在する**。SwiftPM が `.build/debug` を
    /// 張るのはコンパイルが通ってから。
    public static func hasBuildProducts(
        projectRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: projectRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true).path,
            isDirectory: &isDirectory
        )
        // シンボリックリンク（`.build/debug` → `.build/<triple>/debug`）は追跡される。
        return exists && isDirectory.boolValue
    }
}
