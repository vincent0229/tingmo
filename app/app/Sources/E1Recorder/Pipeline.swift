import AppKit
import AVFoundation
import Foundation
import UserNotifications

struct Job: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, transcribing, done, failed }
    var id: String
    var title: String
    var scene: String
    var source: String
    var created: Date
    var durationSec: Int
    var marks: [Int]
    var audioPath: String          // what gets uploaded (original wav, or an imported file)
    var listenPath: String?        // denoised mp3 copied from the pen, for listening
    var timeUncertain: Bool
    var state: State
    var dataId: String?
    var provider: String?          // platform that owns dataId (nil = 通义听悟, for jobs made before 1.2)
    var notePath: String?
    var error: String?
    var speakerNames: [String: String]?   // "1" -> "张三"
    var topic: String?                    // meeting topic from the transcript, shown instead of the pen's title
    var bssids: [String]?                 // WiFi heard while recording (strongest first), for the place
    var updated: Date

    var stateLabel: String {
        switch state {
        case .queued: return "排队中"
        case .transcribing: return "转写中"
        case .done: return "已完成"
        case .failed: return "已失败"
        }
    }
}

/// Watches for the pen, copies new recordings, sends them to the cloud and writes notes.
@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    @Published var jobs: [Job] = []
    @Published var penStatus = "未连接录音笔"
    @Published var penConnected = false
    @Published var penClock = ""
    @Published var syncing = false
    @Published var lastMessage = ""
    @Published var pen: PenInfo?
    @Published var lastSync: Date?
    @Published var penRecordingCount = 0
    /// Files being copied from the pen right now (total 0 = not copying).
    @Published var copyDone = 0
    @Published var copyTotal = 0
    /// The user pressed 立即同步 and that sync is still running.
    @Published var manualSync = false
    /// Uploading or waiting for the cloud.
    @Published var busy = false
    @Published var iconFrame = 0
    /// Newer release found by the weekly check (nil = up to date or not checked).
    @Published var updateVersion: String?
    /// Recordings listed in the pen's database at the last sync.
    @Published var penRecordings: [PenRecording] = []
    /// Our programs on the pen (checked once per USB connection and after every install); nil while unknown.
    @Published var penComponents: PenComponents?
    /// Latest heartbeat the pen left in the WiFi mailbox.
    @Published var wifiStatus: WifiStatus?
    @Published var wifiError: String?
    @Published var wifiSyncing = false
    /// When this Mac last looked in the mailbox.
    @Published var lastWifiCheck: Date?
    var lastWifiSync = Date.distantPast

    var wifiOnline: Bool { settings.wifiReady && (wifiStatus?.isOnline ?? false) }
    var settingsWifiReady: Bool { settings.wifiReady }

    var warnedLowBattery = false
    var warnedLowSpace = false

    var processing = false { didSet { busy = processing } }
    /// File names being copied right now (USB and WiFi run side by side): the other channel leaves them alone.
    /// Notes being written again from the cached results (the row shows a spinner meanwhile).
    @Published var regenerating: Set<String> = []
    var inFlight: Set<String> = []
    /// Jobs waiting out a network hiccup or a busy server before the queue tries them again.
    var retryAt: [String: Date] = [:]

    /// Where a job in progress is right now, for the 转写 page.
    enum JobPhase: Equatable {
        case compressing
        case uploading(Double?)          // share sent; nil while unknown
        case transcribing(since: Date)
        case writing
        case waiting(until: Date)        // network trouble or busy server: tries again by itself
    }
    @Published var phases: [String: JobPhase] = [:]

    func setUploadProgress(_ id: String, _ f: Double) {
        if case .uploading(let old)? = phases[id], let old, f < 1, f - old < 0.01 { return }
        phases[id] = .uploading(min(1, f))
    }
    var lastFullSync = Date.distantPast
    var started = false
    let settings = AppSettings.shared

    var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("E1Recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    var storeURL: URL { supportDir.appendingPathComponent("jobs.json") }

    var activeCount: Int { jobs.filter { $0.state == .queued || $0.state == .transcribing }.count }
    var hasFailures: Bool { jobs.contains { $0.state == .failed } }
    var isCopying: Bool { copyTotal > 0 }

    /// Menu bar icon: bars dance while copying or transcribing, a dot appears when something failed.
    var menuBarImage: NSImage {
        let style = settings.menuIcon
        if isCopying || busy { return MenuBarIcon.frame(style, iconFrame) }
        return hasFailures ? MenuBarIcon.attention(style) : MenuBarIcon.idle(style)
    }

    func start() {
        guard !started else { return }
        started = true
        // Nothing this app fetches should come from a cache (status files and task polls reuse their URLs).
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        load()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await loop() }
        Task { await wifiLoop() }
        Task { await animateIcon() }
        Task { await weeklyUpdateCheck() }
        // Check the mailbox right away on launch and whenever the Mac wakes up.
        Task { await syncWifi(force: true); await checkCloud(force: true) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // give the network a moment
                await Pipeline.shared.syncWifi(force: true)
                await Pipeline.shared.checkCloud(force: true)
            }
        }
    }

    // MARK: updates

    func weeklyUpdateCheck() async {
        let d = UserDefaults.standard
        while true {
            let last = d.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 7 * 86400, !UIPreview.enabled {
                if let v = await Self.latestRelease() {
                    d.set(Date(), forKey: "lastUpdateCheck")
                    updateVersion = v.compare(AppLinks.version, options: .numeric) == .orderedDescending ? v : nil
                }
            }
            try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
        }
    }

    /// Latest release tag on GitHub, without the leading "v"; nil when offline or no release yet.
    static func latestRelease() async -> String? {
        var r = URLRequest(url: AppLinks.latestAPI, timeoutInterval: 15)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else { return nil }
        return tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    func dismissUpdate() {
        if let v = updateVersion { UserDefaults.standard.set(v, forKey: "dismissedUpdate") }
        updateVersion = nil
    }

    var showUpdateBanner: Bool {
        guard let v = updateVersion else { return false }
        return UserDefaults.standard.string(forKey: "dismissedUpdate") != v
    }

    // MARK: usage

    /// Rough price per hour of audio, in yuan (2026-11 list prices); nil for platforms we can't price.
    static func pricePerHour(_ p: Provider) -> Double? {
        switch p {
        case .tingwu: 0.6 + 3 * 0.064   // transcription + summary, chapters, to-dos
        case .bailian: 0.79 + 0.02      // Fun-ASR + a Qwen summary
        case .custom: nil
        }
    }

    struct Usage { var hours: Double; var yuan: Double; var unpriced: Double }

    /// This month's transcriptions by where the audio came from (for the usage bar).
    struct UsageSlice: Identifiable { let id: String; var hours: Double; var yuan: Double }
    var monthUsageBySource: [UsageSlice] {
        let cal = Calendar.current
        var slices: [String: UsageSlice] = [:]
        for j in jobs where j.state == .done && cal.isDate(j.updated, equalTo: Date(), toGranularity: .month) {
            let key = j.source.contains("录音笔") ? "录音笔" : j.source.contains("Mac") ? "Mac 录音" : "导入"
            let h = Double(j.durationSec) / 3600
            var s = slices[key] ?? UsageSlice(id: key, hours: 0, yuan: 0)
            s.hours += h
            s.yuan += h * (Self.pricePerHour(Provider(rawValue: j.provider ?? "") ?? .tingwu) ?? 0)
            slices[key] = s
        }
        return ["录音笔", "导入", "Mac 录音"].compactMap { slices[$0] }
    }

    /// The job that just finished, so the 存到本地 step can show done for a moment.
    @Published var lastCompleted: (id: String, durationSec: Int, at: Date)?

    /// Audio transcribed this calendar month and its estimated cost.
    var monthUsage: Usage {
        let cal = Calendar.current
        var u = Usage(hours: 0, yuan: 0, unpriced: 0)
        for j in jobs where j.state == .done && cal.isDate(j.updated, equalTo: Date(), toGranularity: .month) {
            let h = Double(j.durationSec) / 3600
            u.hours += h
            if let price = Self.pricePerHour(Provider(rawValue: j.provider ?? "") ?? .tingwu) { u.yuan += h * price } else { u.unpriced += h }
        }
        return u
    }

    func checkBudget() {
        let budget = settings.budgetYuan
        guard budget > 0 else { return }
        let month = DateFormatter.cached("yyyy-MM").string(from: Date())
        let d = UserDefaults.standard
        guard d.string(forKey: "budgetAlertMonth") != month else { return }
        let used = monthUsage.yuan
        if used >= Double(budget) * 0.8 {
            d.set(month, forKey: "budgetAlertMonth")
            notify("本月转写费用接近预算", String(format: "已约 ¥%.1f，预算 ¥%d。实际金额以阿里云费用中心为准。", used, budget), jobId: "")
        }
    }

    /// Checks for the pen every 5 s; copies new recordings when it first appears and every 30 s after that.
    func loop() async {
        while true {
            if UIPreview.enabled { await previewProbe() } else {
                let wasConnected = penConnected
                await refreshPen()
                if settings.autoSync, penConnected, !wasConnected || Date().timeIntervalSince(lastFullSync) > 30 {
                    await syncPen()
                }
            }
            processQueue()
            if Date().timeIntervalSince(lastCloudCheck) > 1800 { await checkCloud() }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// The WiFi mailbox on its own schedule (「WiFi 检查」), and the heartbeat on a quicker one of its own: the
    /// status icons should turn green soon after the pen wakes up whatever the mailbox interval is, and must not
    /// go grey between two mailbox checks or while this Mac is busy downloading a long recording.
    func wifiLoop() async {
        while true {
            if !UIPreview.enabled {
                if !wifiSyncing, wifiSyncDue {
                    Task { await syncWifi() }      // reads the heartbeat as part of the check
                } else if settings.wifiReady,
                          Date().timeIntervalSince(lastStatusRead) > Self.heartbeatReadInterval(online: wifiOnline, failed: statusReadFailed) - 1 {
                    await refreshWifiStatus()      // awaited here, so two reads never overlap
                }
                noteOnlineChange()
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Seconds between heartbeat reads. Quick while the pen is away, so it shows up soon after its screen comes on
    /// (it beats right then); relaxed once it is online, where a beat only arrives every two minutes; backed off
    /// after a failed read, so a Mac without network doesn't retry and log every few seconds.
    nonisolated static func heartbeatReadInterval(online: Bool, failed: Bool) -> TimeInterval {
        failed ? 60 : online ? 30 : 10
    }

    var statusKey: String? { didSet { if statusKey != oldValue { statusETag = nil } } }
    /// ETag of the heartbeat as last read; sent along so an unchanged one isn't downloaded again.
    var statusETag: String?
    var lastStatusRead = Date.distantPast
    var statusReadFailed = false
    /// Whether the pen counted as online at the last look.
    var wasWifiOnline = false

    /// Reads just the heartbeat, stamped with the time OSS received it.
    func refreshWifiStatus() async {
        guard let k = statusKey, let oss = settings.macOSS() else { return }
        lastStatusRead = Date()
        do {
            if let got = try await oss.getWithDate(k, unless: wifiStatus == nil ? nil : statusETag) {
                var w = try JSONDecoder().decode(WifiStatus.self, from: got.data)
                w.receivedAt = got.received
                wifiStatus = w
                statusETag = got.etag
                Log.sync.debug("心跳：有新的")
            } else {
                Log.sync.debug("心跳：没有变化")
            }
            statusReadFailed = false
        } catch {
            statusReadFailed = true
            Log.sync.error("读取心跳失败：\(error.localizedDescription, privacy: .public)")
        }
        noteOnlineChange()
    }

    /// Logs the moment the pen comes online or drops off (with both clock times, to see how long this Mac took
    /// to notice) and redraws the status icons: going offline is only time passing, which publishes nothing.
    func noteOnlineChange() {
        let online = wifiOnline
        guard online != wasWifiOnline else { return }
        wasWifiOnline = online
        objectWillChange.send()
        let clock = DateFormatter.cached("HH:mm:ss")
        let beat = wifiStatus?.seen.map { clock.string(from: $0) } ?? "—"
        if online {
            let lag = wifiStatus?.seen.map { Int(Date().timeIntervalSince($0).rounded()) } ?? -1
            Log.sync.notice("录音笔上线：心跳 \(beat, privacy: .public) 到云端，\(clock.string(from: Date()), privacy: .public) 读到（隔 \(lag, privacy: .public) 秒）")
        } else {
            Log.sync.notice("录音笔离线：最后一次心跳 \(beat, privacy: .public)")
        }
    }

    func animateIcon() async {
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if isCopying || busy { iconFrame &+= 1 }
        }
    }

    /// Detects the pen without copying anything.
    func refreshPen() async {
        guard !syncing else { return }
        if let p = await Pen.detect() {
            let wasConnected = penConnected
            pen = p
            penConnected = true
            if !wasConnected { Task { await refreshComponents() } }
            settings.learnNetwork(bssid: p.bssid, ssid: p.ssid)
            if let b = p.battery, b <= 20, !p.charging, !warnedLowBattery {
                warnedLowBattery = true
                notify("录音笔电量低", "剩余 \(b)%，开会前记得充电。", jobId: "")
            }
            if let free = p.freeBytes, free < 1_000_000_000, !warnedLowSpace {
                warnedLowSpace = true
                notify("录音笔空间不足", "只剩 \(formatBytes(free))。已转写的录音可以在笔上删除，见「偏好 › 设备 › 笔内录音」。", jobId: "")
            }
            penClock = ["synced": "时间已联网校准", "rtc_ok": "时间正常", "estimated": "时间为估计值（未联网）"][p.clockStatus] ?? ""
        } else {
            pen = nil
            penConnected = false
            penComponents = nil
            penClock = ""
            warnedLowBattery = false
            warnedLowSpace = false
        }
    }

    /// UI preview: pretend a pen is connected so the screens can be checked without hardware.
    func previewProbe() async {
        var p = PenInfo(serial: "preview", sn: "E1PREVIEW0123456", clockStatus: "synced")
        p.battery = 100; p.charging = true; p.freeBytes = 29_045_000_000; p.firmware = "1.2.3"
        p.wifiInstalled = true; p.wifiRunning = true
        pen = p; penConnected = UserDefaults.standard.string(forKey: "previewPen") != "off"
        if penConnected, penComponents == nil { await refreshComponents() }
        if Demo.on, !jobs.contains(where: { $0.id.hasPrefix("demo-") }) {
            jobs = Demo.jobs()
            if let t = jobs.first(where: { $0.state == .transcribing }) { phases[t.id] = .transcribing(since: Date().addingTimeInterval(-102)) }
        }
        // Screenshot aid: -previewPhase upload|transcribe|write shows a job at that step (in memory only).
        if UserDefaults.standard.string(forKey: "previewPhase") == "done" {
            if lastCompleted == nil || Date().timeIntervalSince(lastCompleted!.at) > 8 { lastCompleted = ("preview-job", 2710, Date()) }
        } else if let ph = UserDefaults.standard.string(forKey: "previewPhase"), !jobs.contains(where: { $0.id == "preview-job" }) {
            jobs.insert(Job(id: "preview-job", title: "周会：录音项目进度", scene: "会议", source: "搜狗 E1 录音笔", created: Date().addingTimeInterval(-3000),
                            durationSec: 2710, marks: [], audioPath: "/tmp/preview.wav", listenPath: nil, timeUncertain: false,
                            state: ph == "upload" || ph == "queued" ? .queued : .transcribing, updated: Date()), at: 0)
            if ph != "queued" {
                phases["preview-job"] = ph == "upload" ? .uploading(0.62) : ph == "write" ? .writing : .transcribing(since: Date().addingTimeInterval(-95))
            }
        }
        if wifiStatus == nil {
            let json = #"{"sn":"E1PREVIEW0123456","version":"1.0.0","time":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180)))","battery":86,"charging":false,"freeBytes":29045000000,"ssid":"Office-WiFi","clockStatus":"synced","recordings":[]}"#
            wifiStatus = try? JSONDecoder().decode(WifiStatus.self, from: Data(json.utf8))
        }
        penRecordingCount = 4
        if penRecordings.isEmpty {
            let base = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!
            penRecordings = [("周会：录音项目进度", 2710), ("客户访谈：选品方向", 1835), ("11月10日17点的会议", 65), ("测试", 6)].enumerated().map { i, r in
                PenRecording(recordId: i, typeName: "会议", title: r.0, created: base.addingTimeInterval(Double(-i) * 86400), durationSec: r.1,
                             marks: [], wavPath: "/mnt/sdcard/preview\(i).wav", mp3Path: "")
            }
        }
        if lastSync == nil { lastSync = Calendar.current.date(bySettingHour: 12, minute: 58, second: 0, of: Date()) }
    }

    /// 立即同步 in the panel or the device page: copies from the pen over USB if it's plugged in,
    /// and fetches whatever the pen has uploaded to the WiFi mailbox — both, every time.
    func syncNow() async {
        guard !manualSync else { return }
        manualSync = true
        syncResult = nil
        let before = jobs.count
        let t0 = Date()
        if UIPreview.enabled {
            syncPhase = "检查录音笔"; try? await Task.sleep(nanoseconds: 700_000_000)
            syncPhase = "检查云端"; try? await Task.sleep(nanoseconds: 700_000_000)
        } else {
            if penConnected { syncPhase = "检查录音笔"; await syncPen() }
            if settings.wifiReady { syncPhase = "检查云端"; await syncWifi(force: true) }
        }
        // Keep the progress visible long enough to read, then say what happened.
        let spent = Date().timeIntervalSince(t0)
        if spent < 1.2 { try? await Task.sleep(nanoseconds: UInt64((1.2 - spent) * 1_000_000_000)) }
        let added = jobs.count - before
        let result = wifiError != nil && !penConnected ? "云端出错" : added > 0 ? "新增 \(added) 条" : "已是最新"
        syncResult = result
        syncPhase = nil
        manualSync = false
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if syncResult == result { syncResult = nil } }
    }

    /// Step shown while 立即同步 runs, and its outcome for a few seconds afterwards.
    @Published var syncPhase: String?
    @Published var syncResult: String?

    // MARK: cloud connection (the green/grey cloud at the top of the panel)

    @Published var cloudOK: Bool?
    @Published var cloudDetail = "还没检查"
    var lastCloudCheck = Date.distantPast

    /// Checks the transcription platform and, if set up, the WiFi mailbox.
    func checkCloud(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCloudCheck) > 300 else { return }
        lastCloudCheck = Date()
        if UIPreview.enabled { cloudOK = true; cloudDetail = "通义听悟正常 · WiFi 信箱正常"; return }
        guard settings.isConfigured, let key = Self.key(for: settings.provider) else {
            cloudOK = false; cloudDetail = "转写平台还没设置"; return
        }
        var parts: [String] = []
        var ok = true
        do {
            try await Self.service(settings.provider, settings: settings, key: key).testConnection()
            parts.append("\(settings.provider.info.name)正常")
            settings.connState = "ok"
        } catch {
            ok = false
            parts.append("\(settings.provider.info.name)：\(error.localizedDescription)")
        }
        if settings.wifiReady, let oss = settings.macOSS() {
            do { _ = try await oss.list(prefix: "pen/"); parts.append("WiFi 信箱正常") }
            catch { ok = false; parts.append("WiFi 信箱：\(error.localizedDescription)") }
        }
        cloudOK = ok
        cloudDetail = parts.joined(separator: " · ") + " · " + DateFormatter.cached("HH:mm").string(from: Date())
    }

    /// What we know about the pen right now: from USB if plugged in, else from its last WiFi heartbeat.
    struct PenSnapshot {
        var battery: Int?; var charging = false; var freeBytes: Int64?; var clockStatus = "unknown"
        var recordingCount: Int?; var sn: String?; var firmware: String?; var source: String
    }

    var penSnapshot: PenSnapshot? {
        if penConnected, let p = pen {
            return PenSnapshot(battery: p.battery, charging: p.charging, freeBytes: p.freeBytes, clockStatus: p.clockStatus,
                               recordingCount: penRecordingCount, sn: p.sn, firmware: p.firmware, source: "USB")
        }
        if settings.wifiReady, let w = wifiStatus {
            let when = w.seen.map { relativeTime($0) } ?? ""
            return PenSnapshot(battery: w.battery, charging: w.charging, freeBytes: w.freeBytes, clockStatus: w.clockStatus ?? "unknown",
                               recordingCount: w.recordings?.count, sn: w.sn, firmware: w.firmware,
                               source: w.isOnline ? "WiFi · \(when)" : "WiFi 最后在线 \(when)")
        }
        return nil
    }

    /// "USB" or "WiFi" while files are being copied or fetched.
    @Published var copySource = "USB"

    var canSyncNow: Bool { penConnected || settings.wifiReady }

    // MARK: persistence

    func update(_ id: String, _ f: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        f(&jobs[i])
        jobs[i].updated = Date()
        save()
    }

    func load() {
        guard let d = try? Data(contentsOf: storeURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        jobs = (try? dec.decode([Job].self, from: d)) ?? []
        // Older jobs: take the meeting topic from the cached transcript.
        var changed = false
        for i in jobs.indices where jobs[i].topic == nil && jobs[i].state == .done {
            if let id = jobs[i].dataId, let b = loadResults(id) {
                let t = MarkdownRenderer.title(results: b, fallback: jobs[i].title)
                if t != jobs[i].title { jobs[i].topic = t; changed = true }
            }
        }
        if changed { save() }
        runMigrations()
    }


    /// Most recent recordings first, by when they were recorded.
    /// Most recent recordings first; recordings with nothing in them stay out of the menu bar list.
    var recentJobs: [Job] { Array(jobs.filter { !isEmptyRecord($0) }.sorted { $0.created > $1.created }.prefix(5)) }

    func place(of job: Job) -> String? { settings.place(for: job.bssids) }

    /// Encodes on the main thread (a snapshot), writes on a background queue so a long list never stutters the UI.
    func save() {
        guard !UIPreview.enabled else { return }   // screenshots never touch the real job list
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(jobs) else { return }
        let url = storeURL
        Self.writer.async {
            do { try data.write(to: url, options: .atomic) } catch { Log.app.error("保存转写记录失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated static let writer = DispatchQueue(label: "app.e1recorder.jobs-writer", qos: .utility)

    /// Waits for pending writes (called when the app quits).
    nonisolated static func flushWrites() { writer.sync {} }

    func resultsDir(_ dataId: String) -> URL { supportDir.appendingPathComponent("results/\(dataId)", isDirectory: true) }

    func saveResults(_ dataId: String, _ b: TranscriptBundle) {
        let dir = resultsDir(dataId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let items: [(String, Any)] = [("transcription", b.transcription), ("summarization", b.summarization),
                                      ("chapters", b.chapters), ("assistance", b.assistance)]
        for (n, o) in items {
            try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]).write(to: dir.appendingPathComponent(n + ".json"))
        }
    }

    func loadResults(_ dataId: String) -> TranscriptBundle? {
        let dir = resultsDir(dataId)
        func j(_ n: String) -> Any? { (try? Data(contentsOf: dir.appendingPathComponent(n + ".json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        guard let t = j("transcription") as? [String: Any] else { return nil }
        return TranscriptBundle(transcription: t, summarization: j("summarization") as? [String: Any] ?? [:],
                                chapters: j("chapters") as? [[String: Any]] ?? [], assistance: j("assistance") as? [String: Any] ?? [:])
    }

    /// Clicking the notification opens the note (or, for a failure, explains it and offers a retry).
    func notify(_ title: String, _ body: String, jobId: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        c.userInfo = ["job": jobId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func handleNotification(jobId: String) {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return }
        if job.state == .failed { explainFailure(job) } else { openNote(job) }
    }

    /// Shows why a job failed, with 重试 as the default action.
    func explainFailure(_ job: Job) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "「\(job.title)」转写失败"
        a.informativeText = job.error ?? "未知原因"
        a.addButton(withTitle: "重试")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { retry(job) }
    }
}

extension DateFormatter {
    private static var cache: [String: DateFormatter] = [:]
    static func cached(_ format: String) -> DateFormatter {
        if let f = cache[format] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        cache[format] = f
        return f
    }
}

/// Routes notification clicks back to the pipeline and lets banners show while a window of ours is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["job"] as? String
        Task { @MainActor in
            if let id { Pipeline.shared.handleNotification(jobId: id) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
