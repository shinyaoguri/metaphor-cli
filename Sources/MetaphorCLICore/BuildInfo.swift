import Foundation

public enum BuildInfo {
    public static let name = "metaphor"

    /// CLI 自身の版。リリースビルドでは `release.yml` の "Stamp version" が
    /// 次の行をタグの版へ書き換える（行頭からの定義にだけ当たる正規表現なので、
    /// このコメントに定義の形を書き写さないこと）。
    public static let version = "0.1.0-dev"

    /// stamp 前のプレースホルダ。`version` がこの値のままなら未 stamp = 開発ビルド。
    /// 同じリテラルが 2 か所に並ぶのは意図的で、こちらを `version` の別名にすると
    /// stamp 後も両者が等しくなり、stamp の有無を判定できなくなる。
    static let unstampedVersion = "0.1.0-dev"

    /// `metaphor new` が GitHub から最新リリースを引けなかったときに使う metaphor
    /// ライブラリの版。`version` と同じくプレースホルダで、リリースビルドでは
    /// `release.yml` の "Pin default metaphor library version" が次の行を metaphor の
    /// 最新安定版へ書き換える（行頭からの定義にだけ当たる正規表現なので、このコメントに
    /// 定義の形を書き写さないこと）。**リポジトリ上のこの値は現行版ではない**。
    ///
    /// 生成される依存は `.package(url:from:)` なので、この値は刺さる版ではなく解決範囲の
    /// **下限**。SwiftPM の `from:` は 0.x でも次の major (`<1.0.0`) まで許すため、値が
    /// 数世代古くても実際には最新の 0.x が解決される。
    public static let defaultMetaphorVersion = "0.9.0"

    /// ライブビューアへのフレーム転送（frame IPC、CONTRACT.md 契約点 5）を話せる
    /// metaphor ライブラリの最小版。これより古い本体をリンクしたスケッチは `watch` の
    /// ビューアに接続してこないので、ビューアはこの版を案内する（metaphor#792）。
    public static let minimumMetaphorVersionForViewer = "0.11.0"
    public static let cliRepositoryOwner = "shinyaoguri"
    public static let cliRepositoryName = "metaphor-cli"
    public static let libraryRepositoryOwner = "shinyaoguri"
    public static let libraryRepositoryName = "metaphor"

    /// 実行中バイナリのビルド識別子（実行ファイルの更新時刻）。
    /// どのビルド/インストールが動いているかを実行時に判別するために使う。
    /// 再ビルド/再インストールのたびに変わるので、最新版かどうかが分かる。
    public static var buildStamp: String {
        guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return "unknown"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    /// git から導出したビルドリビジョン（例: `0.1.1-18-g2cc32da`、未コミットは末尾 `-dirty`）。
    /// `VersionStampPlugin` がビルド時に `git describe` で生成する。git が無い環境
    /// （tarball からのビルド等）では空文字列になる。先頭の `v` は落とす。
    public static var revision: String {
        let d = BuildRevision.gitDescribe
        return d.hasPrefix("v") ? String(d.dropFirst()) : d
    }

    /// 表示用のバージョン。stamp 済み（= リリースビルド）ならその版、未 stamp なら
    /// git リビジョン、それも無ければ `version` 定数。
    ///
    /// リリースビルドで `version` を優先するのは、`revision` が 1 世代前を名乗るため。
    /// `release.yml` は「stamp → ビルド → タグ作成」の順に進むので、ビルド時点では
    /// 新しいタグがまだ無く、さらに stamp 自体がワークツリーを dirty にするため
    /// `git describe` は `<前タグ>-<N>-g<sha>-dirty` を返す。stamp された `version`
    /// だけが実際に配布される版と一致する。
    ///
    /// 逆に開発ビルドでは `version` がプレースホルダのままなので、直近タグ + その後の
    /// コミット数 + 短縮 SHA であるリビジョンの方が動作中のビルドを特定できる。
    public static var displayVersion: String {
        displayVersion(version: version, revision: revision)
    }

    static func displayVersion(version: String, revision: String) -> String {
        if version != unstampedVersion { return version }
        return revision.isEmpty ? version : revision
    }

    /// リリースとして配布された版ではないビルド（版が stamp されていない = ローカルの
    /// `swift build` や `make install`）。表示の言い回しを変えるために使う。
    public static var isDevelopmentBuild: Bool {
        version == unstampedVersion
    }

    /// バージョン比較に使う版。`displayVersion` が `git describe` 形式のときに、
    /// describe が足すサフィックスだけを落として素のタグへ畳む。
    ///
    /// SemVer では `0.9.0-3-gabc1234` は prerelease 扱いで `0.9.0` より**古い**と
    /// 判定されるため、畳まずに比較すると「リリースより 3 コミット進んだビルド」に
    /// 更新を促してしまう（`UpdateCommand` の up-to-date 判定）。
    public static var releaseVersion: String {
        releaseVersion(from: displayVersion)
    }

    /// `git describe --tags --always --dirty` の出力からタグ部分だけを取り出す。
    /// 真の prerelease タグ（`1.0.0-rc.1`）は落とさず、describe 固有の
    /// `-<コミット数>-g<短縮SHA>` と末尾の `-dirty` にだけ一致させる。
    static func releaseVersion(from describeOutput: String) -> String {
        var value = describeOutput
        if value.hasSuffix("-dirty") {
            value.removeLast("-dirty".count)
        }

        // タグ自体が `-` を含みうる（`1.0.0-rc.1`）ので、末尾 2 要素の“形”で判定する。
        let parts = value.split(separator: "-")
        guard parts.count >= 3 else { return value }
        let sha = parts[parts.count - 1]
        let commitCount = parts[parts.count - 2]
        guard sha.hasPrefix("g"),
              sha.dropFirst().count >= 4,
              sha.dropFirst().allSatisfy(\.isHexDigit),
              !commitCount.isEmpty,
              commitCount.allSatisfy(\.isNumber) else {
            return value
        }
        return parts.dropLast(2).joined(separator: "-")
    }

    /// CLI であることを明示した1行表記（例: `metaphor-cli 0.1.1-18-g2cc32da (built ...)`）。
    /// `watch` のバナーと `metaphor version` / `doctor` の 1 行目で使う。スケッチ子プロセスは
    /// 別途 `[metaphor] <版>` を出すため、CLI 版とライブラリ版がログ上で区別できるよう
    /// 名前で曖昧さを消す。
    public static var cliIdentifier: String {
        "\(name)-cli \(displayVersion) (built \(buildStamp))"
    }
}
