import Foundation
import XCTest
@testable import E1Recorder

/// Writes a made-up sample note (Markdown, Word, PDF) with the app's own template and renderer, for the README and
/// articles. Runs only when E1_DEMO_NOTE_DIR is set: `E1_DEMO_NOTE_DIR=/tmp/demo swift test --filter DemoNoteTests`.
final class DemoNoteTests: XCTestCase {
    @MainActor func testWriteDemoNote() throws {
        guard let dir = ProcessInfo.processInfo.environment["E1_DEMO_NOTE_DIR"] else { throw XCTSkip("set E1_DEMO_NOTE_DIR to write the sample") }
        let lines: [(String, String)] = [
            ("1", "今天主要对一下新品发布会的准备情况，时间定在下周四下午两点。"),
            ("2", "场地已经确认了，可以容纳八十人，下周一前要付定金。"),
            ("1", "好，定金这周就走流程。嘉宾名单现在到哪一步了？"),
            ("3", "邀请函发了六十份，回复确认的有三十二位，周五再统一催一遍。"),
            ("2", "直播这块我们想同步做，需要市场部出两个人负责弹幕和抽奖。"),
            ("1", "可以，直播的脚本周三前给我看一下，重点讲清楚三个卖点。"),
            ("3", "物料方面，展架和手册周二到，样机还差五台，供应商说周三能补齐。"),
            ("1", "样机一定要在周三前到位，不然彩排来不及，我来盯供应商。"),
            ("2", "彩排安排在周三下午，所有讲者都要到场走一遍流程。"),
            ("1", "那今天就这样，大家按分工推进，周五下午再碰一次进度。"),
        ]
        var paragraphs: [[String: Any]] = []
        var sid = 0, t = 0
        for (spk, text) in lines {
            sid += 1
            let words: [[String: Any]] = text.map { ["text": String($0), "sentenceId": sid, "start": t] }
            paragraphs.append(["speakerId": spk, "words": words])
            t += 21_000
        }
        var b = TranscriptBundle()
        b.transcription = ["paragraphs": paragraphs]
        b.summarization = [
            "title": "新品发布会筹备与分工",
            "paragraphSummary": "会议确认新品发布会定于下周四下午两点举行，场地可容纳八十人，需在下周一前支付定金。邀请函已发出六十份，确认三十二位，周五统一催复。同步开展直播，由市场部派两人负责互动；直播脚本周三前定稿。物料周二到位，样机缺口五台需周三前补齐，周三下午全员彩排。",
        ]
        b.chapters = [
            ["start": 0, "headline": "发布会时间与场地", "summary": "时间定在下周四下午两点，场地容纳八十人，下周一前付定金。"],
            ["start": 63_000, "headline": "嘉宾邀请与直播安排", "summary": "已发邀请六十份、确认三十二位；直播需市场部两人支持，脚本周三前定稿。"],
            ["start": 126_000, "headline": "物料、样机与彩排", "summary": "展架和手册周二到，样机周三前补齐五台，周三下午全员彩排。"],
        ]
        b.assistance = [
            "actions": [["text": "本周内完成场地定金付款流程（李明）"], ["text": "周五统一催复嘉宾邀请（张伟）"],
                        ["text": "周三前提交直播脚本，突出三个卖点（王芳）"], ["text": "跟进供应商，周三前补齐五台样机（李明）"]],
            "keywords": ["发布会", "场地", "嘉宾", "直播", "样机", "彩排", "物料"],
        ]
        let start = ISO8601DateFormatter().date(from: "2026-11-12T02:00:00Z")!
        let meta = MarkdownRenderer.Meta(title: "261112 - 新品发布会筹备与分工 会议纪要", start: start, durationSec: 52 * 60, scene: "会议",
                                         source: "搜狗 E1 录音笔", organizer: "李明", marks: [126],
                                         speakerNames: ["1": "李明", "2": "王芳", "3": "张伟"], place: "公司",
                                         audioFile: URL(fileURLWithPath: NSHomeDirectory() + "/Music/E1录音/2026-11/20261112100000_meeting.wav"),
                                         timeUncertain: false)
        let md = MarkdownRenderer.render(meta: meta, results: b, template: NoteTemplate.builtIn("standard").body)
            .replacingOccurrences(of: NSHomeDirectory(), with: "/Users/demo")
        let base = URL(fileURLWithPath: dir).appendingPathComponent("261112 - 新品发布会筹备与分工")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for ext in ["md", "docx", "pdf"] { try NoteExporter.write(md, to: base.appendingPathExtension(ext)) }
    }
}
