import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// Adding, retrying and removing recordings; opening and regenerating notes; speakers.
extension Pipeline {
    // MARK: manual import (e.g. m4a from iPhone Voice Memos)

    func importFiles(_ urls: [URL]) async {
        for src in urls {
            let dir = URL(fileURLWithPath: settings.audioFolder).appendingPathComponent("导入", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dst = dir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                dst = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(src.lastPathComponent)")
            }
            do { try FileManager.default.copyItem(at: src, to: dst) } catch { lastMessage = "导入失败：\(error.localizedDescription)"; continue }
            // When it was recorded: the creation date stored in the audio (Voice Memos and most recorders write the
            // start time there); the file's own date is often when it was exported or copied.
            let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
            let embedded = try? await AVURLAsset(url: src).load(.creationDate)?.load(.dateValue)
            let created = embedded ?? (attrs?[.creationDate] as? Date) ?? Date()
            let dur = (try? await AVURLAsset(url: dst).load(.duration)).map { Int(CMTimeGetSeconds($0)) } ?? 0
            jobs.insert(Job(id: "file:\(dst.path)", title: src.deletingPathExtension().lastPathComponent, scene: "会议",
                            source: "导入文件", created: created, durationSec: dur, marks: [], audioPath: dst.path,
                            listenPath: dst.path, timeUncertain: false, state: .queued, updated: Date()), at: 0)
        }
        save()
        processQueue()
    }

    /// A recording made with the panel's 录音 button.
    func addLocalRecording(url: URL, title: String, created: Date, durationSec: Int) {
        jobs.insert(Job(id: "mac:\(url.path)", title: title, scene: "会议", source: "Mac 录音", created: created,
                        durationSec: durationSec, marks: [], audioPath: url.path, listenPath: url.path,
                        timeUncertain: false, state: .queued, updated: Date()), at: 0)
        save()
        processQueue()
    }

    func notifyUser(_ title: String, _ body: String) { notify(title, body, jobId: "") }

    func retry(_ job: Job) {
        // If the cloud task itself is fine (the failure was on this Mac: network, note folder…), pick it up again
        // instead of uploading and paying for a second transcription.
        let why = job.error ?? ""
        let reuse = job.dataId != nil && !why.hasPrefix("云端转写失败") && !why.hasPrefix("转写超时")
        retryAt[job.id] = nil
        update(job.id) { $0.state = reuse ? .transcribing : .queued; if !reuse { $0.dataId = nil }; $0.error = nil }
        processQueue()
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        // Remember it, or the next USB sync would see the recording on the pen as new and transcribe (and bill) it again.
        if job.id.hasPrefix("e1:") { removedNames.insert((job.audioPath as NSString).lastPathComponent) }
        save()
    }

    /// Pen recordings the user removed from the list: never copied or transcribed again.
    var removedNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "removedRecordings") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "removedRecordings") }
    }
    func isRemoved(_ wavPath: String) -> Bool { removedNames.contains((wavPath as NSString).lastPathComponent) }

    /// Opens a finished job's note; if the file was moved or never written, rebuilds it from the cached results first.
    func openNote(_ job: Job) {
        if let n = job.notePath, FileManager.default.fileExists(atPath: n) { Self.openMarkdown(n, obsidian: settings.openInObsidian); return }
        if isEmptyRecord(job) && job.notePath == nil { lastMessage = "这条录音没有识别到内容"; return }
        if relocateMovedNotes(), let n = jobs.first(where: { $0.id == job.id })?.notePath, FileManager.default.fileExists(atPath: n) {
            Self.openMarkdown(n, obsidian: settings.openInObsidian)
            return
        }
        guard job.state == .done, let dataId = job.dataId, let b = loadResults(dataId) else {
            lastMessage = "这条录音没有可用的纪要，请右键选择「重试」重新转写"
            return
        }
        // The note was there once and is gone (deleted, moved out of the vault, or renamed): leave it gone. The lists
        // show 本地 greyed out; 「重新生成本地纪要」 in the right-click menu brings it back from the cached results.
        if job.notePath != nil {
            lastMessage = "本地纪要已不在，可右键选择「重新生成本地纪要」"
            return
        }
        do {
            guard let current = jobs.first(where: { $0.id == job.id }) else { return }
            try writeNote(current, b)
            if let n = jobs.first(where: { $0.id == job.id })?.notePath { Self.openMarkdown(n, obsidian: settings.openInObsidian) }
        } catch { lastMessage = error.localizedDescription }
    }

    /// 「保留录音文件」 off: once the note exists, remove this Mac's copies the app made (in the audio folder only —
    /// never a file the user picked elsewhere, never anything on the pen).
    func dropLocalAudio(_ job: Job) {
        let folder = URL(fileURLWithPath: settings.audioFolder).standardizedFileURL.path + "/"
        for p in Set([job.audioPath, job.listenPath].compactMap { $0 }) where URL(fileURLWithPath: p).standardizedFileURL.path.hasPrefix(folder) {
            try? FileManager.default.removeItem(atPath: p)
        }
    }


    /// A finished job whose note file is no longer where the app last saw it.
    func noteMissing(_ job: Job) -> Bool {
        job.state == .done && job.notePath.map { !Self.noteFileExists($0) } == true
    }

    /// The note is in the vault (an iCloud copy that's only in the cloud right now counts: ".名字.md.icloud").
    static func noteFileExists(_ path: String) -> Bool {
        if Demo.on { return path.hasPrefix(Demo.notesFolder) }   // screenshots: made-up notes "exist"
        if FileManager.default.fileExists(atPath: path) { return true }
        let u = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud").path)
    }

    /// Transcribed in the cloud, with the results kept on this Mac (so the note can always be written again for free).
    func inCloud(_ job: Job) -> Bool { job.state == .done && job.dataId != nil }

    /// Brings back a deleted note from the cached results (no new transcription, no cost).
    func regenerateNote(_ job: Job) {
        guard let dataId = job.dataId, let b = loadResults(dataId) else { lastMessage = "没有保存的转写结果，只能右键「重试」重新转写"; return }
        guard !regenerating.contains(job.id) else { return }
        regenerating.insert(job.id)
        Task {
            let started = Date()
            update(job.id) { $0.notePath = nil }
            if let current = jobs.first(where: { $0.id == job.id }) {
                do { try writeNote(current, b) } catch { lastMessage = error.localizedDescription }
            }
            // Let the spinner be seen; then the row shows its cloud and note icons again.
            let left = 1.6 - Date().timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            regenerating.remove(job.id)
        }
    }

    /// Looks again for notes that moved (when Preferences › 转写 opens).
    func refreshNoteLocations() { relocateMovedNotes() }

    /// Opens a note in Obsidian when it sits inside a vault (a parent folder holds `.obsidian`) and Obsidian is installed.
    static func openMarkdown(_ path: String, obsidian: Bool) {
        if obsidian, path.lowercased().hasSuffix(".md"), NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil,
           vaultRoot(of: path) != nil,
           let q = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "obsidian://open?path=" + q) {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func vaultRoot(of path: String) -> String? {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) { return dir.path }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Done, but almost nothing was said (title 「无实质内容」), with or without a note file from older versions.
    func isEmptyRecord(_ job: Job) -> Bool { job.state == .done && job.topic == MarkdownRenderer.emptyTitle }

    /// 清理无内容记录: removes those records; their notes and this Mac's audio copies go to the Trash (recoverable);
    /// the pen's own recordings stay and are not imported again.
    func cleanEmptyRecords() -> Int {
        let empties = jobs.filter(isEmptyRecord)
        let audioDir = URL(fileURLWithPath: settings.audioFolder).standardizedFileURL.path + "/"
        for j in empties {
            if let n = j.notePath, FileManager.default.fileExists(atPath: n) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: n), resultingItemURL: nil)
            }
            for p in Set([j.audioPath, j.listenPath].compactMap { $0 })
            where URL(fileURLWithPath: p).standardizedFileURL.path.hasPrefix(audioDir) && FileManager.default.fileExists(atPath: p) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
            remove(j)
        }
        Log.notes.info("清理无内容记录 \(empties.count, privacy: .public) 条")
        return empties.count
    }

    func canOpenNote(_ job: Job) -> Bool {
        if isEmptyRecord(job) && job.notePath == nil { return false }
        if let n = job.notePath { return Self.noteFileExists(n) }
        return job.state == .done && job.dataId.map { FileManager.default.fileExists(atPath: resultsDir($0).path) } == true
    }


    // MARK: speakers

    struct SpeakerSample: Identifiable { let id: String; let chars: Int; let sample: String }

    /// Speakers found in a finished transcript, with how much each said and a line to recognise them by.
    func speakers(of job: Job) -> [SpeakerSample] {
        guard let dataId = job.dataId, let b = loadResults(dataId) else { return [] }
        var order: [String] = [], chars: [String: Int] = [:], sample: [String: String] = [:]
        for p in (b.transcription["paragraphs"] as? [[String: Any]]) ?? [] {
            let sid = p["speakerId"].map { "\($0)" } ?? "?"
            if !order.contains(sid) { order.append(sid) }
            let text = ((p["words"] as? [[String: Any]]) ?? []).map { $0["text"] as? String ?? "" }.joined()
            chars[sid, default: 0] += text.count
            if (sample[sid]?.count ?? 0) < 8, text.count >= 6 { sample[sid] = String(text.prefix(36)) + (text.count > 36 ? "…" : "") }
        }
        return order.map { SpeakerSample(id: $0, chars: chars[$0] ?? 0, sample: sample[$0] ?? "") }
    }

    func canNameSpeakers(_ job: Job) -> Bool { job.state == .done && !(speakers(of: job).isEmpty) }

    /// Saves names for the speakers and rewrites the note with them.
    func nameSpeakers(_ job: Job, _ names: [String: String]) {
        let cleaned = names.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
        update(job.id) { $0.speakerNames = cleaned }
        settings.knownSpeakers = Array(NSOrderedSet(array: Array(cleaned.values) + settings.knownSpeakers).array.prefix(30)) as? [String] ?? []
        if let j = jobs.first(where: { $0.id == job.id }) { rerender(j) }
    }

    /// Re-renders a finished note with the current template, from the cached results.
    func rerender(_ job: Job) {
        guard let dataId = job.dataId, let b = loadResults(dataId) else { return }
        do { try writeNote(job, b) } catch { lastMessage = error.localizedDescription }
    }
}
