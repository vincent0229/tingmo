import Foundation

/// Turns Tingwu results into an Obsidian meeting note.
/// A custom template (Settings → 纪要模板) may use the same {{placeholders}} as the built-in one.
enum MarkdownRenderer {
    struct Meta {
        var title: String
        var start: Date
        var durationSec: Int
        var scene: String
        var source: String
        var organizer: String
        var marks: [Int]
        var speakerNames: [String: String] = [:]
        var place: String? = nil
        var audioFile: URL?
        var timeUncertain: Bool
    }

    static func render(meta: Meta, results r: TranscriptBundle, template: String) -> String {
        let paragraphs = (r.transcription["paragraphs"] as? [[String: Any]]) ?? []
        // sentence id -> (speaker, start ms, text)
        var sentences: [Int: (spk: String, start: Int, text: String)] = [:]
        var order: [Int] = []
        var speakers: [String] = []
        var transcript: [String] = []
        for p in paragraphs {
            let sid = p["speakerId"].map { "\($0)" } ?? "?"
            let spk = meta.speakerNames[sid].flatMap { $0.isEmpty ? nil : $0 } ?? "发言人\(sid)"
            if !speakers.contains(spk) { speakers.append(spk) }
            let words = (p["words"] as? [[String: Any]]) ?? []
            guard let first = words.first else { continue }
            let text = words.map { $0["text"] as? String ?? "" }.joined()
            transcript.append("**\(spk)** `\(ts((first["start"] as? Int) ?? 0))`\n\(text)")
            for w in words {
                guard let sid = w["sentenceId"] as? Int else { continue }
                if sentences[sid] == nil { sentences[sid] = (spk, (w["start"] as? Int) ?? 0, ""); order.append(sid) }
                sentences[sid]!.text += w["text"] as? String ?? ""
            }
        }

        let summary = clean((r.summarization["paragraphSummary"] as? String) ?? "（无摘要）")
        let actions = ((r.assistance["actions"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        let keywords = ((r.assistance["keywords"] as? [String]) ?? []).prefix(12).joined(separator: "、")
        let chapters = r.chapters.map { c -> String in
            "### `\(ts((c["start"] as? Int) ?? 0))` \(c["headline"] as? String ?? "")\n\n\(c["summary"] as? String ?? "")"
        }
        let marks = meta.marks.map { sec -> String in
            let ms = sec * 1000
            let hit = order.last(where: { (sentences[$0]?.start ?? .max) <= ms }).flatMap { sentences[$0] }
            return "- `\(ts(ms))` " + (hit.map { "\($0.spk)：\($0.text)" } ?? "")
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let end = meta.start.addingTimeInterval(TimeInterval(meta.durationSec))
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let dayf = DateFormatter(); dayf.dateFormat = "yyyy-MM-dd"

        var values: [String: String] = [
            "标题": meta.title,
            "日期": dayf.string(from: meta.start),
            // Obsidian reads this form as a "date & time" property, so notes sort and filter by when the meeting was.
            "日期时间": DateFormatter.cached("yyyy-MM-dd'T'HH:mm").string(from: meta.start),
            "会议时间": "\(df.string(from: meta.start))–\(tf.string(from: end))",
            "时长": duration(meta.durationSec),
            "场景": meta.scene,
            "来源": meta.source,
            "参会人": speakers.isEmpty ? "—" : speakers.joined(separator: "、"),
            "整理人": meta.organizer,
            "关键词": keywords.isEmpty ? "—" : keywords,
            "地点": meta.place ?? "—",
            "录音文件": meta.audioFile.map { "[\($0.lastPathComponent)](<\($0.absoluteString)>)" } ?? "—",
            "时间提示": meta.timeUncertain ? "\n> [!warning] 录音笔当时未联网对时，以上时间可能不准确，请人工核实。\n" : "",
            "摘要": summary,
            "待办": actions.isEmpty ? "（未识别到待办）" : actions.map { "- [ ] \($0)" }.joined(separator: "\n"),
            "待办表格": actions.isEmpty ? "| ⬜️ | （未识别到待办） |" : actions.map { "| ⬜️ | \($0) |" }.joined(separator: "\n"),
            "章节": chapters.isEmpty ? "（无）" : chapters.joined(separator: "\n\n"),
            "重点标记": marks.isEmpty ? "（本次录音没有按 M 键标记）" : marks.joined(separator: "\n"),
            "转写": transcript.isEmpty ? "（无转写内容）" : transcript.joined(separator: "\n\n"),
        ]
        values["标题"] = values["标题"]!.isEmpty ? "录音纪要" : values["标题"]
        var out = template
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }

    /// Title for the note: Tingwu's first chapter headline, else the pen's own title.
    /// Title used when too little was said to name the recording by its content.
    static let emptyTitle = "无实质内容"

    /// Everything recognized in the recording, as one string.
    static func heardText(_ r: TranscriptBundle) -> String {
        let paragraphs = (r.transcription["paragraphs"] as? [[String: Any]]) ?? []
        return paragraphs.flatMap { ($0["words"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
    }

    /// The note's title, one rule for every source. Under 10 characters of real speech → 「无实质内容」 (AI titles for
    /// near-silent audio are made up); otherwise the AI's title, else the first chapter, else the first sentence.
    /// Never the recording's own name — it only repeats the date that leads the note's name anyway.
    static func title(results r: TranscriptBundle, fallback _: String = "") -> String {
        let heard = heardText(r)
        guard heard.filter({ !$0.isPunctuation && !$0.isWhitespace }).count >= 10 else { return emptyTitle }
        if let t = r.summarization["title"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { return String(t.prefix(40)) }
        if let h = r.chapters.first?["headline"] as? String, !h.trimmingCharacters(in: .whitespaces).isEmpty { return String(h.prefix(40)) }
        let first = heard.split(whereSeparator: { "。！？!?；;\n".contains($0) }).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) } ?? ""
        return first.isEmpty ? emptyTitle : String(first.prefix(20))
    }

    /// Tingwu summaries carry "@#" markers and "[n]" paragraph references; drop them.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "@#", with: "")
        t = t.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ts(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func duration(_ sec: Int) -> String {
        if sec >= 3600 { return "\(sec / 3600) 小时 \(sec % 3600 / 60) 分" }
        if sec >= 60 { return sec % 60 == 0 ? "\(sec / 60) 分" : "\(sec / 60) 分 \(sec % 60) 秒" }
        return "\(sec) 秒"
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\n\r")
        return s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}


/// Built-in note templates. Names are four characters so they line up in the picker.
struct NoteTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let summary: String
    let body: String

    static func builtIn(_ id: String) -> NoteTemplate { all.first { $0.id == id } ?? all[0] }

    private static let header = """
---
tags: [会议纪要, 录音转写]
date: {{日期时间}}
source: {{来源}}
duration: {{时长}}
---

# {{标题}}

- **会议时间：** {{会议时间}}（时长 {{时长}}）
- **录音场景：** {{场景}}
- **参会人员：** {{参会人}}
- **整理署名：** {{整理人}}
- **关键词语：** {{关键词}}
- **录音地点：** {{地点}}
- **录音文件：** {{录音文件}}
{{时间提示}}
---
"""

    static let all: [NoteTemplate] = [
        NoteTemplate(id: "standard", name: "标准纪要", icon: "doc.text", summary: "摘要、待办、章节、全文", body: header + """

## 会议摘要

{{摘要}}

## 待办事项

{{待办}}

## 章节速览

{{章节}}

## 重点标记

{{重点标记}}

## 完整转写

{{转写}}
"""),
        NoteTemplate(id: "decision", name: "决策会议", icon: "checkmark.seal", summary: "议题、结论、行动项", body: header + """

## 一、会议结论

{{摘要}}

## 二、议题讨论

{{章节}}

## 三、行动事项

| 状态 | 事项 |
|---|---|
{{待办表格}}

## 四、关键原话

{{重点标记}}

## 附：会议原文

{{转写}}
"""),
        NoteTemplate(id: "interview", name: "访谈记录", icon: "person.2.wave.2", summary: "问答脉络、原话摘录", body: header + """

## 访谈概要

{{摘要}}

## 问答脉络

{{章节}}

## 原话摘录

{{重点标记}}

## 后续跟进

{{待办}}

## 访谈全文

{{转写}}
"""),
        NoteTemplate(id: "lecture", name: "课堂笔记", icon: "book.closed", summary: "知识要点、课后任务", body: header + """

## 课程概要

{{摘要}}

## 知识要点

{{章节}}

## 课堂重点

{{重点标记}}

## 课后任务

{{待办}}

## 课堂原文

{{转写}}
"""),
        NoteTemplate(id: "brief", name: "极简速记", icon: "bolt", summary: "只留摘要与待办", body: """
---
tags: [会议纪要, 录音转写]
date: {{日期时间}}
---

# {{标题}}

> {{会议时间}} · {{时长}} · {{参会人}}

{{摘要}}

**待办**

{{待办}}
"""),
    ]
}
