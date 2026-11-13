import Foundation
import XCTest
@testable import E1Recorder

/// The rules that decide names, titles and dedupe — pure logic, so a wrong change shows up here first.
@MainActor
final class TitleRuleTests: XCTestCase {
    private func bundle(heard: String, title: String? = nil, chapter: String? = nil) -> TranscriptBundle {
        var b = TranscriptBundle()
        let words = heard.map { ["text": String($0)] as [String: Any] }
        b.transcription = ["paragraphs": heard.isEmpty ? [] : [["speakerId": "1", "words": words]]]
        if let title { b.summarization = ["title": title] }
        if let chapter { b.chapters = [["headline": chapter, "start": 0]] }
        return b
    }

    func testSilenceIsNoContent() {
        XCTAssertEqual(MarkdownRenderer.title(results: bundle(heard: "")), "无实质内容")
    }

    func testMadeUpTitleForNearSilenceIsIgnored() {
        // An AI title for a recording with only a few words is not trusted.
        XCTAssertEqual(MarkdownRenderer.title(results: bundle(heard: "嗯，好的。", title: "无内容对话的中文标题与摘要")), "无实质内容")
    }

    func testAITitleWins() {
        let b = bundle(heard: "今天我们讨论新品发布会的时间安排和分工，大家先说一下各自的进度。", title: "新品发布会筹备与分工")
        XCTAssertEqual(MarkdownRenderer.title(results: b), "新品发布会筹备与分工")
    }

    func testChapterWhenNoTitle() {
        let b = bundle(heard: "今天我们讨论新品发布会的时间安排和分工，大家先说一下各自的进度。", chapter: "发布会时间安排")
        XCTAssertEqual(MarkdownRenderer.title(results: b), "发布会时间安排")
    }

    func testFirstSentenceWhenNothingElse() {
        let b = bundle(heard: "今天我们讨论新品发布会的时间安排和分工以及预算。后面再说别的。")
        XCTAssertEqual(MarkdownRenderer.title(results: b), "今天我们讨论新品发布会的时间安排和分工以")   // 20 characters
    }
}

@MainActor
final class NamingTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-11-12T04:46:00Z")!   // 12:46 in Beijing

    override func setUp() { NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")! }

    func testNoteBase() {
        XCTAssertEqual(Pipeline.noteBase(date, "周会：进度/安排"), "261112 - 周会：进度 安排")   // full-width colon is fine in file names; / is not
    }

    func testClashAddsTimeThenNumber() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Pipeline.freeNoteURL(in: dir, created: date, title: "无实质内容")
        XCTAssertEqual(first.lastPathComponent, "261112 - 无实质内容.md")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = Pipeline.freeNoteURL(in: dir, created: date, title: "无实质内容")
        XCTAssertEqual(second.lastPathComponent, "261112 - 无实质内容（1246）.md")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = Pipeline.freeNoteURL(in: dir, created: date, title: "无实质内容", ext: "md")
        XCTAssertEqual(third.lastPathComponent, "261112 - 无实质内容（1246） (2).md")
        XCTAssertEqual(Pipeline.freeNoteURL(in: dir, created: date, title: "周会", ext: "pdf").pathExtension, "pdf")
    }

    func testSourceIcons() {
        func job(_ source: String) -> Job {
            Job(id: UUID().uuidString, title: "t", scene: "会议", source: source, created: date, durationSec: 1, marks: [],
                audioPath: "/tmp/x.wav", listenPath: nil, timeUncertain: false, state: .done, updated: date)
        }
        XCTAssertEqual(job("搜狗 E1 录音笔 · WiFi").sourceSymbol, "wifi")
        XCTAssertEqual(job("搜狗 E1 录音笔").sourceSymbol, "recordingtape")
        XCTAssertEqual(job("Mac 录音").sourceSymbol, "mic")
        XCTAssertEqual(job("导入文件").sourceSymbol, "square.and.arrow.up")
    }
}

final class MarkdownExportTests: XCTestCase {
    func testFrontMatterDroppedAndBlocksConverted() {
        let md = """
        ---
        date: 2026-11-12T12:46
        ---

        # 标题

        - **会议时间：** 12:46
        - [ ] 发通知

        | 负责人 | 事项 |
        |---|---|
        | 张三 | 订场地 |

        > [!warning] 时间可能不准
        """
        let html = MarkdownHTML.body(md)
        XCTAssertFalse(html.contains("date:"))
        XCTAssertTrue(html.contains("<h1>标题</h1>"))
        XCTAssertTrue(html.contains("<b>会议时间：</b>"))
        XCTAssertTrue(html.contains("☐ 发通知"))
        XCTAssertTrue(html.contains("<th>负责人</th>") && html.contains("<td>订场地</td>"))
        XCTAssertTrue(html.contains("<blockquote>时间可能不准</blockquote>"))
    }

    func testPageAndWordLayouts() {
        let md = """
        - **会议时间：** 12:46
        - **参会人员：** 张三、李四

        ## 待办事项

        - [ ] 发通知
        - [x] 订场地
        """
        let page = MarkdownHTML.body(md, layout: .page)
        XCTAssertTrue(page.contains("<td class=\"k\">会议时间</td><td class=\"v\">12:46</td>"))     // details become two columns
        XCTAssertTrue(page.contains("<p class=\"task\">☐ 发通知</p>") && page.contains("<p class=\"task\">☑ 订场地</p>"))
        XCTAssertTrue(page.contains("<table class=\"h2\""))
        let word = MarkdownHTML.body(md, layout: .word)
        XCTAssertFalse(word.contains("<table"))                 // the .docx writer leaves tables out
        XCTAssertTrue(word.contains("<span>会议时间</span>") && word.contains("<h2>待办事项</h2>"))
        XCTAssertTrue(MarkdownHTML.body(md).contains("<li><b>会议时间：</b> 12:46</li>"))     // plain output stays semantic
    }

    func testEscapesHTML() {
        XCTAssertEqual(MarkdownHTML.inline("a < b & c"), "a &lt; b &amp; c")
    }
}

final class WifiAndRetryTests: XCTestCase {
    private func status(beat: Int?, secondsAgo: Double) -> WifiStatus {
        let json = #"{"sn":"X","version":"1.2.2","time":"2026-01-01T00:00:00Z","battery":80,"charging":false,"freeBytes":1,"ssid":"","recordings":[]\#(beat.map { ",\"heartbeatSec\":\($0)" } ?? "")}"#
        var w = try! JSONDecoder().decode(WifiStatus.self, from: Data(json.utf8))
        w.receivedAt = Date().addingTimeInterval(-secondsAgo)
        return w
    }

    func testOnlineWindowFollowsHeartbeatInterval() {
        XCTAssertTrue(status(beat: 120, secondsAgo: 290).isOnline)    // 2-minute beat: grey after 5 minutes
        XCTAssertFalse(status(beat: 120, secondsAgo: 310).isOnline)
        XCTAssertTrue(status(beat: nil, secondsAgo: 600).isOnline)    // old uploader (5-minute beat): 11 minutes
        XCTAssertFalse(status(beat: nil, secondsAgo: 700).isOnline)
    }

    func testHeartbeatReadPace() {
        XCTAssertEqual(Pipeline.heartbeatReadInterval(online: false, failed: false), 10)   // away: notice it coming back
        XCTAssertEqual(Pipeline.heartbeatReadInterval(online: true, failed: false), 30)    // online: beats are 2 minutes apart
        XCTAssertEqual(Pipeline.heartbeatReadInterval(online: false, failed: true), 60)    // no network: don't hammer
        XCTAssertEqual(Pipeline.heartbeatReadInterval(online: true, failed: true), 60)
        // 30 s must stay well inside the online window, or a pen that is beating would flicker to offline
        XCTAssertLessThan(Pipeline.heartbeatReadInterval(online: true, failed: false), status(beat: 120, secondsAgo: 0).offlineAfter - 120)
    }

    @MainActor func testTransientErrors() {
        XCTAssertTrue(Pipeline.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Pipeline.isTransient(AppError("busy", transient: true)))
        XCTAssertFalse(Pipeline.isTransient(AppError("访问密钥无效")))
    }
}
