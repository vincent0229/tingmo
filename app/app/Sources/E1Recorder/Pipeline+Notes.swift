import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// Naming and writing notes, and finding notes the user moved.
extension Pipeline {
    /// "261110 - 标题": the recording's date and the AI's title. It is the note's file name and the name shown for the
    /// recording everywhere in the app. The time lives in the note's `date` property and next to the name in lists.
    static func noteBase(_ created: Date, _ title: String) -> String {
        DateFormatter.cached("yyMMdd").string(from: created) + " - " + MarkdownRenderer.safeFileName(title)
    }

    /// A free file name in `folder`: "261110 - 标题.md"; on a clash the time is added ("261110 - 标题（1725）.md").
    static func freeNoteURL(in folder: URL, created: Date, title: String, ext: String = "md", except: URL? = nil) -> URL {
        let base = noteBase(created, title)
        func ok(_ u: URL) -> Bool { u.standardizedFileURL == except?.standardizedFileURL || !FileManager.default.fileExists(atPath: u.path) }
        var u = folder.appendingPathComponent(base + "." + ext)
        if ok(u) { return u }
        let timed = base + "（" + DateFormatter.cached("HHmm").string(from: created) + "）"
        u = folder.appendingPathComponent(timed + "." + ext)
        var n = 2
        while !ok(u) { u = folder.appendingPathComponent("\(timed) (\(n)).\(ext)"); n += 1 }
        return u
    }

    /// What a job is called in the lists: its note's file name once there is one, otherwise the same scheme.
    func displayName(_ job: Job) -> String {
        if job.state == .done, let n = job.notePath, Self.noteFileExists(n) {
            // The 「（1246）」 a same-day clash adds to the file name is left out: lists show the time next to it.
            let base = ((n as NSString).lastPathComponent as NSString).deletingPathExtension
            return base.replacingOccurrences(of: "（\\d{4}）( \\(\\d+\\))?$", with: "", options: .regularExpression)
        }
        let title: String = switch job.state {
        case .queued: "等待转写"
        case .transcribing: "转写中"
        case .failed: "转写失败"
        case .done: job.topic ?? MarkdownRenderer.emptyTitle
        }
        return Self.noteBase(job.created, title)
    }

    /// Notes the user moved to another folder of their vault keep their file name: find them again by name, so the app
    /// opens that file instead of writing a second copy. Searches from the outermost vault around the notes folder.
    @discardableResult
    func relocateMovedNotes() -> Bool {
        let missing = jobs.indices.filter { i in
            jobs[i].state == .done && jobs[i].notePath.map { !Self.noteFileExists($0) } == true
        }
        guard !missing.isEmpty, !UIPreview.enabled else { return false }
        var root = URL(fileURLWithPath: settings.notesFolder), probe = root
        while probe.path.count > 1 {
            if FileManager.default.fileExists(atPath: probe.appendingPathComponent(".obsidian").path) { root = probe }
            probe.deleteLastPathComponent()
        }
        var wanted: [String: [Int]] = [:]
        for i in missing { wanted[(jobs[i].notePath! as NSString).lastPathComponent, default: []].append(i) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return false }
        var found = false
        for case let u as URL in e {
            var name = u.lastPathComponent
            if name == ".obsidian" || name == ".trash" { e.skipDescendants(); continue }
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }   // only in iCloud right now
            else if name.hasPrefix(".") { continue }
            guard let idx = wanted.removeValue(forKey: name) else { continue }
            let real = u.deletingLastPathComponent().appendingPathComponent(name).path
            for i in idx { jobs[i].notePath = real }
            found = true
            if wanted.isEmpty { break }
        }
        if found { save() }
        return found
    }



    func writeNote(_ job: Job, _ b: TranscriptBundle) throws {
        let title = MarkdownRenderer.title(results: b, fallback: job.title)
        if title == MarkdownRenderer.emptyTitle, job.notePath == nil {
            // Nothing was said: no note file, just a grey record that 「清理无内容记录」 can sweep away.
            update(job.id) { $0.state = .done; $0.notePath = nil; $0.error = nil; $0.topic = title }
            lastCompleted = (job.id, job.durationSec, Date())
            if !settings.keepAudio { dropLocalAudio(job) }
            Log.notes.info("没有识别到内容，不生成纪要")
            return
        }
        let template = settings.templateText
        let audio = job.listenPath ?? job.audioPath
        let keep = settings.keepAudio && FileManager.default.fileExists(atPath: audio)
        let md = MarkdownRenderer.render(meta: .init(title: "\(DateFormatter.cached("yyMMdd").string(from: job.created)) - \(title) 会议纪要",
                                                     start: job.created, durationSec: job.durationSec, scene: job.scene,
                                                     source: job.source, organizer: settings.organizer, marks: job.marks,
                                                     speakerNames: job.speakerNames ?? [:], place: settings.place(for: job.bssids),
                                                     audioFile: keep ? URL(fileURLWithPath: audio) : nil, timeUncertain: job.timeUncertain),
                                         results: b, template: template)
        let folder = URL(fileURLWithPath: settings.notesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url: URL
        if let existing = job.notePath, FileManager.default.fileExists(atPath: existing) {
            url = URL(fileURLWithPath: existing)          // re-render in place
        } else {
            url = Self.freeNoteURL(in: folder, created: job.created, title: title, ext: NoteExporter.fileExtension(settings.noteFormat))
        }
        try NoteExporter.write(md, to: url)
        update(job.id) { $0.state = .done; $0.notePath = url.path; $0.error = nil; $0.topic = title }
        lastCompleted = (job.id, job.durationSec, Date())
        if !settings.keepAudio { dropLocalAudio(job) }
        notify("会议纪要已生成", url.lastPathComponent, jobId: job.id)
        checkBudget()
    }
}
