import Foundation
@testable import MetaphorCLICore
import XCTest

/// `git describe` 由来の版を比較可能なタグへ畳む規則（#122）。
/// 実行中ビルドの版はビルド環境依存なので、ここで固定するのは**畳み込みの規則**だけ。
final class BuildInfoTests: XCTestCase {
    /// リリースビルドでは stamp された版だけが配布物と一致する。`release.yml` は
    /// 「stamp → ビルド → タグ作成」の順に進み、stamp 自体がワークツリーを dirty に
    /// するので、`git describe` は 1 世代前のタグを名乗る。
    func testDisplayVersionPrefersStampedVersionOverStaleRevision() {
        XCTAssertEqual(
            BuildInfo.displayVersion(version: "0.9.1", revision: "0.9.0-3-gabc1234-dirty"),
            "0.9.1"
        )
    }

    /// 開発ビルドでは `version` がプレースホルダのままなので、リビジョンの方が
    /// 動作中のビルドを特定できる。git が無ければプレースホルダへ戻る。
    func testDisplayVersionFallsBackToRevisionForDevelopmentBuilds() {
        XCTAssertEqual(
            BuildInfo.displayVersion(version: BuildInfo.unstampedVersion, revision: "0.9.0-3-gabc1234"),
            "0.9.0-3-gabc1234"
        )
        XCTAssertEqual(
            BuildInfo.displayVersion(version: BuildInfo.unstampedVersion, revision: ""),
            BuildInfo.unstampedVersion
        )
    }

    /// describe が足すサフィックス（`-<コミット数>-g<短縮SHA>` と `-dirty`）は落とす。
    func testReleaseVersionDropsDescribeSuffix() {
        XCTAssertEqual(BuildInfo.releaseVersion(from: "0.9.0-3-gabc1234"), "0.9.0")
        XCTAssertEqual(BuildInfo.releaseVersion(from: "0.9.0-3-gabc1234-dirty"), "0.9.0")
        XCTAssertEqual(BuildInfo.releaseVersion(from: "0.9.0-dirty"), "0.9.0")
        XCTAssertEqual(BuildInfo.releaseVersion(from: "0.9.0"), "0.9.0")
    }

    /// 真の prerelease タグは describe のサフィックスではないので落とさない。
    /// （落とすと `1.0.0-rc.1` が `1.0.0` 相当に見え、up-to-date 判定が狂う）
    func testReleaseVersionKeepsPrereleaseTag() {
        XCTAssertEqual(BuildInfo.releaseVersion(from: "1.0.0-rc.1"), "1.0.0-rc.1")
        XCTAssertEqual(BuildInfo.releaseVersion(from: "1.0.0-rc.1-3-gabc1234"), "1.0.0-rc.1")
        XCTAssertEqual(BuildInfo.releaseVersion(from: BuildInfo.unstampedVersion), BuildInfo.unstampedVersion)
    }

    /// タグが 1 つも無いリポジトリでは `--always` により短縮 SHA だけが返る。
    func testReleaseVersionKeepsBareCommitHash() {
        XCTAssertEqual(BuildInfo.releaseVersion(from: "abc1234"), "abc1234")
        XCTAssertEqual(BuildInfo.releaseVersion(from: "abc1234-dirty"), "abc1234")
    }

    /// 畳んだ版はリリースタグと同格に比較できる。SemVer では
    /// `0.9.0-3-gabc1234` は prerelease 扱いで `0.9.0` より古いとされるため、
    /// 畳まずに比較するとリリースより進んだビルドに更新を促してしまう。
    func testFoldedVersionIsNotOlderThanItsTag() throws {
        let folded = try XCTUnwrap(SemanticVersion(BuildInfo.releaseVersion(from: "0.9.0-3-gabc1234")))
        let tag = try XCTUnwrap(SemanticVersion("v0.9.0"))
        XCTAssertFalse(folded < tag)
    }
}
