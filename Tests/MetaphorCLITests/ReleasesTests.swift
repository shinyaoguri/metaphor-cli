import Foundation
@testable import MetaphorCLICore
import XCTest

final class ReleasesTests: XCTestCase {

    // NOTE: Releases.swift の URL 構築は以前 force unwrap だったが guard+throw に
    // 変更済み。当環境の Foundation の URL(string:) は極めて寛容で nil を返す入力を
    // 再現できないため、失敗分岐の単体テストは置かない（防御的コードとして保持）。

    /// 正常な owner/repo では HTTP クライアントの応答をデコードして返す。
    private struct StubHTTPClient: HTTPClient {
        let payload: Data
        func get(_ url: URL) throws -> Data { payload }
    }

    func testLatestReleaseDecodesValidResponse() throws {
        let json = """
        {"tag_name":"v1.2.3","name":"Release","prerelease":false,"assets":[]}
        """.data(using: .utf8)!
        let service = GitHubReleaseService(httpClient: StubHTTPClient(payload: json))
        let release = try service.latestRelease(owner: "shinyaoguri", repo: "metaphor")
        XCTAssertEqual(release.tagName, "v1.2.3")
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/shinyaoguri/metaphor/releases/latest")!

    /// User-Agent は注入された版をそのまま名乗る（#137）。
    func testUserAgentUsesInjectedVersion() {
        let client = URLSessionHTTPClient(userAgentVersion: "9.9.9-test")
        let request = client.makeRequest(for: Self.apiURL)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "metaphor-cli/9.9.9-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    /// 既定は実行中ビルドを特定できる版（#137）。ハードコード定数 `BuildInfo.version` を
    /// 直に名乗ると、stamp 前のビルドが全て同じ `0.1.0-dev` を名乗って区別できなくなる。
    func testUserAgentDefaultsToDisplayVersion() {
        let request = URLSessionHTTPClient().makeRequest(for: Self.apiURL)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "metaphor-cli/\(BuildInfo.displayVersion)"
        )
    }
}
