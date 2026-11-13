import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// WiFi mailbox (OSS) and our programs on the pen.
extension Pipeline {
    // MARK: WiFi mailbox

    /// Whether the mailbox is due for its regular look (「WiFi 检查」 on the device page).
    var wifiSyncDue: Bool { Date().timeIntervalSince(lastWifiSync) > Double(max(1, settings.wifiIntervalMin) * 60) }

    /// Fetches the heartbeat, downloads recordings the pen uploaded, queues them, then clears them from the mailbox.
    func syncWifi(force: Bool = false) async {
        guard !UIPreview.enabled, settings.wifiReady, !wifiSyncing, let oss = settings.macOSS() else { return }
        guard force || wifiSyncDue else { return }
        wifiSyncing = true
        defer { wifiSyncing = false; lastWifiSync = Date(); lastWifiCheck = Date() }
        do {
            let keys = try await oss.list(prefix: "pen/")
            wifiError = nil
            let statusKeys = keys.filter { $0.hasSuffix("/status.json") && !$0.contains("/_selftest/") }
            let preferred = statusKeys.first { k in pen.map { k.contains("/\($0.sn)/") } ?? false } ?? statusKeys.first
            statusKey = preferred
            await refreshWifiStatus()
            Log.sync.info("云端信箱：心跳 \(self.wifiStatus?.time ?? "无", privacy: .public)，\(keys.count, privacy: .public) 个对象")
            if let w = wifiStatus, let b = w.bssid { settings.learnNetwork(bssid: b, ssid: w.ssid) }
            var added = 0
            let metas = keys.filter { $0.hasSuffix("/meta.json") && $0.contains("/rec/") }
            copySource = "WiFi"
            copyTotal = metas.count
            copyDone = 0
            defer { copyTotal = 0; copyDone = 0; copySource = "USB" }
            for (i, metaKey) in metas.enumerated() {
                copyDone = i
                let dir = String(metaKey.dropLast("meta.json".count))
                let parts = metaKey.split(separator: "/")
                let sn = parts.count > 1 ? String(parts[1]) : "unknown"
                guard let m = try? JSONDecoder().decode(WifiMeta.self, from: try await oss.get(metaKey)) else { continue }
                let name = (m.wavPath as NSString).lastPathComponent
                let id = "e1:\(sn):\(m.wavPath)"
                if inFlight.contains(name) { continue }        // USB is copying this one right now; look again next round
                inFlight.insert(name)
                defer { inFlight.remove(name) }
                if !hasJob(sn: sn, wavPath: m.wavPath), m.durationSec > 0, m.durationSec >= settings.minDurationSec {
                    let created = m.created.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                    let folder = URL(fileURLWithPath: settings.audioFolder)
                        .appendingPathComponent(DateFormatter.cached("yyyy-MM").string(from: created), isDirectory: true)
                    let wav = folder.appendingPathComponent(name)
                    let mp3 = folder.appendingPathComponent((name as NSString).deletingPathExtension + "_denoise.mp3")
                    penStatus = "正在下载：\(m.title)"
                    if !FileManager.default.fileExists(atPath: wav.path) { try await oss.download(dir + "audio.wav", to: wav) }
                    if keys.contains(dir + "listen.mp3"), !FileManager.default.fileExists(atPath: mp3.path) {
                        try? await oss.download(dir + "listen.mp3", to: mp3)
                    }
                    let uncertain = Calendar.current.component(.year, from: created) < 2024 || wifiStatus?.clockStatus == "estimated"
                    if !hasJob(sn: sn, wavPath: m.wavPath) { jobs.insert(Job(id: id, title: m.title, scene: m.type.isEmpty ? "会议" : m.type, source: "搜狗 E1 录音笔 · WiFi",
                                    created: created, durationSec: m.durationSec, marks: m.marks ?? [], audioPath: wav.path,
                                    listenPath: FileManager.default.fileExists(atPath: mp3.path) ? mp3.path : nil,
                                    timeUncertain: uncertain, state: .queued, bssids: m.bssids, updated: Date()), at: 0)
                        save()
                        added += 1
                    }
                }
                // The mailbox is only a hand-over point: once this Mac has the files, clear them.
                for k in keys where k.hasPrefix(dir) { try? await oss.delete(k) }
            }
            lastSync = Date()
            processQueue()
        } catch {
            wifiError = error.localizedDescription
            Log.sync.error("云端信箱检查失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checks both keys end to end: the Mac key lists, the pen key uploads, the Mac key cleans up.
    func testWifi() async -> String? {
        guard let mac = settings.macOSS() else { return "还没填写 Mac 用的钥匙或存储空间名称" }
        guard let penKey = settings.penOSS() else { return "还没填写录音笔用的钥匙" }
        do {
            _ = try await mac.list(prefix: "pen/")
        } catch { return "Mac 钥匙：" + error.localizedDescription }
        do {
            try await penKey.put("pen/_selftest/ping.txt", Data("ping".utf8))
        } catch { return "录音笔钥匙：" + error.localizedDescription }
        do {
            try await mac.delete("pen/_selftest/ping.txt")
        } catch { return "Mac 钥匙不能删除：" + error.localizedDescription }
        return nil
    }

    /// Installs (or updates) the uploader on the pen over USB. Writes only under /userdata.
    func installWifi() async -> String {
        guard let pen = await Pen.detect() else { return "没检测到录音笔，请用数据线连接并打开 adb" }
        guard let bin = Bundle.main.path(forResource: "e1wifi-arm64", ofType: nil),
              let hook = Bundle.main.path(forResource: "auto_reboot", ofType: "sh") else { return "应用里缺少上传程序" }
        guard let id = Keychain.read(account: WifiKeys.penId), let sec = Keychain.read(account: WifiKeys.penSecret) else {
            return "还没填写录音笔用的钥匙"
        }
        let cfg: [String: Any] = ["endpoint": settings.ossEndpoint, "bucket": settings.ossBucket, "keyId": id, "keySecret": sec,
                                  "minDurationSec": settings.minDurationSec, "intervalSec": 60, "heartbeatSec": 120]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e1wifi-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: tmp.path, contents: try? JSONSerialization.data(withJSONObject: cfg), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let s = pen.serial
        _ = await Adb.run(["-s", s, "shell", "mkdir -p /userdata/e1wifi/state; kill $(cat /tmp/e1wifi.pid 2>/dev/null) 2>/dev/null; true"])
        let a = await Adb.run(["-s", s, "push", bin, "/userdata/e1wifi/e1wifi.new"], timeout: 300)
        let b = await Adb.run(["-s", s, "push", tmp.path, "/userdata/e1wifi/config.json"])
        let c = await Adb.run(["-s", s, "push", hook, "/userdata/cfg/rockchip_test/auto_reboot.sh"])
        guard a.code == 0, b.code == 0, c.code == 0 else { return "写入录音笔失败：" + [a.err, b.err, c.err].joined(separator: " ") }
        let r = await Adb.run(["-s", s, "shell", "mv /userdata/e1wifi/e1wifi.new /userdata/e1wifi/e1wifi && chmod 755 /userdata/e1wifi/e1wifi && " +
                               "chmod 600 /userdata/e1wifi/config.json && sync && " +
                               "(setsid /userdata/e1wifi/e1wifi </dev/null >/dev/null 2>&1 &) ; sleep 2; pidof e1wifi"])
        await refreshPen()
        await refreshComponents()
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已安装，但上传程序没有启动，重启录音笔后会自动运行" : "已安装并开始运行"
    }

    func uninstallWifi() async -> String {
        guard let pen = await Pen.detect() else { return "没检测到录音笔，请用数据线连接" }
        let r = await Adb.run(["-s", pen.serial, "shell", "kill $(cat /tmp/e1wifi.pid 2>/dev/null) 2>/dev/null; rm -rf /userdata/e1wifi; sync; echo OK"])
        await refreshPen()
        await refreshComponents()
        return r.out.contains("OK") ? "已卸载，录音笔不再通过 WiFi 上传" : "卸载失败：" + r.err
    }

    /// Re-reads which of our programs are on the pen. Says so once per app version when something can be updated.
    func refreshComponents() async {
        if UIPreview.enabled {
            penComponents = PenComponents(clock: .current, clockRunning: true, uploader: Demo.on ? .current : .outdated, uploaderRunning: true,
                                          uploaderVersion: Demo.on ? Bundled.uploaderVersion : "1.2.0", hook: .current)
            return
        }
        guard let p = pen else { penComponents = nil; return }
        let c = await Pen.components(p)
        penComponents = c
        let tag = AppLinks.version + "/" + Bundled.uploaderVersion
        if c.anyOutdated, UserDefaults.standard.string(forKey: "componentsUpdateNoticeFor") != tag {
            UserDefaults.standard.set(tag, forKey: "componentsUpdateNoticeFor")
            notify("录音笔上的程序可以更新", "在「偏好 › 设备 › 录音笔上的程序」里一键更新。", jobId: "")
        }
    }

    /// Clock script + boot hook. Restarted right away so the new copy runs now, not after the next reboot
    /// (on start it only re-checks the clock; a correct clock is left alone).
    func installClockScript() async -> String {
        guard let pen = await Pen.detect() else { return "没检测到录音笔，请用数据线连接" }
        guard let script = Bundled.clockScript, let hook = Bundled.hook else { return "应用里缺少校时脚本" }
        _ = await Adb.run(["-s", pen.serial, "shell", "mkdir -p /userdata/e1sync /userdata/cfg/rockchip_test"])
        let a = await Adb.run(["-s", pen.serial, "push", script, "/userdata/e1sync/e1sync.sh"])
        let b = await Adb.run(["-s", pen.serial, "push", hook, "/userdata/cfg/rockchip_test/auto_reboot.sh"])
        guard a.code == 0, b.code == 0 else { return "写入录音笔失败：" + [a.err, b.err].joined(separator: " ") }
        _ = await Adb.run(["-s", pen.serial, "shell",
            "chmod 755 /userdata/e1sync/e1sync.sh; sync; kill $(cat /tmp/e1sync.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/e1sync.pid; " +
            "(setsid /bin/sh /userdata/e1sync/e1sync.sh </dev/null >/dev/null 2>&1 &); sleep 1; true"])
        await refreshPen()
        await refreshComponents()
        return "已安装并开始运行"
    }

    /// Starts an installed program that isn't running (nothing is written to the pen).
    func startPenProgram(_ kind: PenComponentRow.Kind) async -> String {
        guard let pen = await Pen.detect() else { return "没检测到录音笔，请用数据线连接" }
        let cmd = kind == .clock
            ? "rm -f /tmp/e1sync.pid; (setsid /bin/sh /userdata/e1sync/e1sync.sh </dev/null >/dev/null 2>&1 &); sleep 1; true"
            : "(setsid /userdata/e1wifi/e1wifi </dev/null >/dev/null 2>&1 &); sleep 2; true"
        _ = await Adb.run(["-s", pen.serial, "shell", cmd])
        await refreshComponents()
        let ok = kind == .clock ? penComponents?.clockRunning == true : penComponents?.uploaderRunning == true
        return ok ? "已启动" : "没能启动，重启录音笔试试"
    }

    /// Only the boot hook (it starts the clock script and the uploader at boot).
    func installHook() async -> String {
        guard let pen = await Pen.detect() else { return "没检测到录音笔，请用数据线连接" }
        guard let hook = Bundled.hook else { return "应用里缺少开机脚本" }
        _ = await Adb.run(["-s", pen.serial, "shell", "mkdir -p /userdata/cfg/rockchip_test"])
        let r = await Adb.run(["-s", pen.serial, "push", hook, "/userdata/cfg/rockchip_test/auto_reboot.sh"])
        _ = await Adb.run(["-s", pen.serial, "shell", "sync"])
        await refreshComponents()
        return r.code == 0 ? "已修复，下次开机生效" : "写入录音笔失败：" + r.err
    }
}
