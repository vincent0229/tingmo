import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// Copying recordings over USB, and what the pen holds.
extension Pipeline {
    // MARK: pen

    func syncPen() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false; copyDone = 0; copyTotal = 0; lastFullSync = Date() }
        guard let pen = await Pen.detect() else {
            self.pen = nil
            penConnected = false
            penClock = ""
            penStatus = "未连接录音笔（需插 USB 并在开发者模式打开 adb）"
            return
        }
        penConnected = true
        self.pen = pen
        penClock = ["synced": "时间已联网校准", "rtc_ok": "时间正常", "estimated": "时间为估计值（未联网）"][pen.clockStatus] ?? ""
        penStatus = "已连接 E1（SN 尾号 \(pen.sn.suffix(4))）"
        do {
            let recs = try await Pen.recordings(pen)
            penRecordingCount = recs.count
            penRecordings = recs
            // Recordings that came in before places existed: fill in the WiFi they heard.
            var filled = false
            for r in recs where !r.bssids.isEmpty {
                let name = (r.wavPath as NSString).lastPathComponent
                if let i = jobs.firstIndex(where: { $0.bssids == nil && ($0.audioPath as NSString).lastPathComponent == name }) {
                    jobs[i].bssids = r.bssids
                    filled = true
                }
            }
            if filled { save() }
            var added = 0
            // One recording = one job, whichever channel (USB or WiFi) brings it first.
            // Duration 0 = still being recorded: the pen adds the row when recording starts and fills in the length on save.
            var fresh = recs.filter { r in r.durationSec > 0 && r.durationSec >= settings.minDurationSec && !hasJob(sn: pen.sn, wavPath: r.wavPath) }
            // A file written to in the last minute is still being recorded (or saved): take it next round.
            // (If the age can't be read, copy as before rather than never.)
            let ages = await Pen.fileAges(pen, fresh.map(\.wavPath))
            fresh = fresh.filter { (ages[$0.wavPath] ?? 999) >= 60 }
            copyTotal = fresh.count
            copySource = "USB"
            for r in fresh {
                let id = "e1:\(pen.sn):\(r.wavPath)"
                let name = (r.wavPath as NSString).lastPathComponent
                // WiFi may have taken it meanwhile.
                guard !inFlight.contains(name), !hasJob(sn: pen.sn, wavPath: r.wavPath) else { continue }
                inFlight.insert(name)
                defer { inFlight.remove(name) }
                copyDone = added
                let created = r.created ?? Date()
                let month = DateFormatter.cached("yyyy-MM").string(from: created)
                let dir = URL(fileURLWithPath: settings.audioFolder).appendingPathComponent(month, isDirectory: true)
                let wav = dir.appendingPathComponent((r.wavPath as NSString).lastPathComponent)
                let mp3 = dir.appendingPathComponent((r.mp3Path as NSString).lastPathComponent)
                penStatus = "正在拷贝：\(r.title)"
                if !FileManager.default.fileExists(atPath: wav.path) { try await Pen.pull(pen, remote: r.wavPath, to: wav) }
                if !r.mp3Path.isEmpty, !FileManager.default.fileExists(atPath: mp3.path) {
                    try? await Pen.pull(pen, remote: r.mp3Path, to: mp3)
                }
                guard !hasJob(sn: pen.sn, wavPath: r.wavPath) else { continue }
                let uncertain = Calendar.current.component(.year, from: created) < 2024 || pen.clockStatus == "estimated"
                jobs.insert(Job(id: id, title: r.title, scene: r.typeName.isEmpty ? "会议" : r.typeName, source: "搜狗 E1 录音笔",
                                created: created, durationSec: r.durationSec, marks: r.marks, audioPath: wav.path,
                                listenPath: FileManager.default.fileExists(atPath: mp3.path) ? mp3.path : nil,
                                timeUncertain: uncertain, state: .queued, bssids: r.bssids, updated: Date()), at: 0)
                added += 1; copyDone = added
                save()
            }
            penStatus = "已连接 E1（SN 尾号 \(pen.sn.suffix(4))）" + (added > 0 ? "，新增 \(added) 条录音" : "，没有新录音")
            lastSync = Date()
            if pen.wifiInstalled { await tellUploaderAlreadyHave(pen, recs) }
        } catch {
            penStatus = "同步失败：\(error.localizedDescription)"
        }
        processQueue()
    }

    /// A job already exists for this recording (same id, or the same file name from the other channel).
    func hasJob(sn: String, wavPath: String) -> Bool {
        let name = (wavPath as NSString).lastPathComponent
        return isRemoved(wavPath) || jobs.contains { $0.id == "e1:\(sn):\(wavPath)" || ($0.audioPath as NSString).lastPathComponent == name }
    }

    /// Recordings this Mac already has don't need to go over WiFi: add them to the uploader's done-list on the pen.
    func tellUploaderAlreadyHave(_ pen: PenInfo, _ recs: [PenRecording]) async {
        let have = recs.filter { hasJob(sn: pen.sn, wavPath: $0.wavPath) }.map(\.wavPath)
        guard !have.isEmpty else { return }
        let f = "/userdata/e1wifi/state/uploaded"
        let cmd = "touch \(f); " + have.map { "grep -qxF '\($0)' \(f) || echo '\($0)' >> \(f)" }.joined(separator: "; ")
        _ = await Adb.run(["-s", pen.serial, "shell", cmd])
    }


    // MARK: pen recordings

    enum RecordingStatus { case done, working, failed, waiting, tooShort, notCopied, uploaded, pendingUpload, removed, recording }

    /// What's on the pen: from USB when plugged in, otherwise from the WiFi heartbeat.
    var displayRecordings: [PenRecording] {
        if !penRecordings.isEmpty { return penRecordings }
        let iso = ISO8601DateFormatter()
        return (wifiStatus?.recordings ?? []).enumerated().map { i, r in
            PenRecording(recordId: i, typeName: "", title: r.title, created: r.created.flatMap { iso.date(from: $0) }, durationSec: r.durationSec,
                         marks: [], wavPath: r.wavPath, mp3Path: "")
        }
    }

    /// Where one recording on the pen stands: copied to this Mac, transcribed, or still only on the pen.
    func status(of r: PenRecording) -> RecordingStatus {
        let sn = pen?.sn ?? ""
        if let j = jobs.first(where: { $0.id == "e1:\(sn):\(r.wavPath)" }) ?? jobs.first(where: { $0.title == r.title && $0.durationSec == r.durationSec }) {
            switch j.state {
            case .done: return .done
            case .transcribing: return .working
            case .queued: return .waiting
            case .failed: return .failed
            }
        }
        if UIPreview.enabled { return [RecordingStatus.done, .working, .pendingUpload, .tooShort][r.recordId % 4] }
        if isRemoved(r.wavPath) { return .removed }
        if r.durationSec == 0 { return .recording }
        if r.durationSec < settings.minDurationSec { return .tooShort }
        if let w = wifiStatus?.recordings?.first(where: { $0.wavPath == r.wavPath }) { return w.uploaded ? .uploaded : .pendingUpload }
        return .notCopied
    }
}
