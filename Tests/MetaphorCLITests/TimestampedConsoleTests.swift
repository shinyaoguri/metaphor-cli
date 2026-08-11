import XCTest

@testable import MetaphorCLICore

final class TimestampedConsoleTests: XCTestCase {
    /// 固定時刻（ローカル 09:05:07）を返すクロック。
    private func fixedClock(hour: Int, minute: Int, second: Int) -> () -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 11
        components.hour = hour
        components.minute = minute
        components.second = second
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        return { date }
    }

    func testPrefixesEachMessageWithZeroPaddedLocalTime() {
        let buffer = BufferedConsole()
        let console = TimestampedConsole(
            base: buffer,
            now: fixedClock(hour: 9, minute: 5, second: 7),
            outputIsTTY: false,
            errorIsTTY: false
        )

        console.write("[watch] 変更を検出 — 再ビルド中…")
        console.writeError("[watch] ビルド失敗 (exit 1) — 直前のスケッチを維持します")

        XCTAssertEqual(buffer.output, ["[09:05:07] [watch] 変更を検出 — 再ビルド中…"])
        XCTAssertEqual(
            buffer.errors, ["[09:05:07] [watch] ビルド失敗 (exit 1) — 直前のスケッチを維持します"]
        )
    }

    func testPrefixesEveryLineButLeavesBlankLinesUntouched() {
        let buffer = BufferedConsole()
        let console = TimestampedConsole(
            base: buffer,
            now: fixedClock(hour: 23, minute: 59, second: 0),
            outputIsTTY: false,
            errorIsTTY: false
        )

        // 停止ログは先頭の改行でメトリクスのステータスライン行を確定させている。
        // その空行に時刻だけの行が生まれてはならない。
        console.write("\n[watch] 停止します…")
        console.write("一行目\n二行目")

        XCTAssertEqual(
            buffer.output,
            [
                "\n[23:59:00] [watch] 停止します…",
                "[23:59:00] 一行目\n[23:59:00] 二行目",
            ]
        )
    }

    func testDimsTimestampOnTTYAndKeepsMessageBodyPlain() {
        let buffer = BufferedConsole()
        let console = TimestampedConsole(
            base: buffer,
            now: fixedClock(hour: 0, minute: 0, second: 3),
            outputIsTTY: true,
            errorIsTTY: true
        )

        console.write("[watch] リロードしました")

        XCTAssertEqual(buffer.output, ["\u{1B}[2m[00:00:03]\u{1B}[0m [watch] リロードしました"])
    }

    /// stdout だけリダイレクトした場合など、stdout と stderr で TTY 判定は独立する。
    func testColorizesStdoutAndStderrIndependently() {
        let buffer = BufferedConsole()
        let console = TimestampedConsole(
            base: buffer,
            now: fixedClock(hour: 12, minute: 34, second: 56),
            outputIsTTY: false,
            errorIsTTY: true
        )

        console.write("out")
        console.writeError("err")

        XCTAssertEqual(buffer.output, ["[12:34:56] out"])
        XCTAssertEqual(buffer.errors, ["\u{1B}[2m[12:34:56]\u{1B}[0m err"])
    }
}
