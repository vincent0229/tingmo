import CryptoKit
import Foundation
import SQLite3

/// Thin wrapper around the adb binary shipped inside the app bundle.
enum Adb {
    static var path: String {
        if let p = Bundle.main.path(forResource: "adb", ofType: nil) { return p }
        for p in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "adb"
    }

    struct Result { let code: Int32; let out: String; let err: String }

    /// Runs adb off the main thread.
    static func run(_ args: [String], timeout: TimeInterval = 120) async -> Result {
        await Task.detached(priority: .utility) { runSync(args, timeout: timeout) }.value
    }

    static func runSync(_ args: [String], timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return Result(code: -1, out: "", err: "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate() }
        group.wait()
        p.waitUntilExit()
        return Result(code: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self).replacingOccurrences(of: "\r", with: ""),
                      err: String(decoding: errData, as: UTF8.self))
    }
}

/// One recording as listed in the pen's own database (/userdata/databases/E1-DATA.db).
struct PenRecording: Hashable {
    let recordId: Int
    let typeName: String        // 会议 / 访谈 / ...
    let title: String           // e.g. 11月10日17点的会议
    let created: Date?
    let durationSec: Int
    let marks: [Int]            // M-key marks, seconds from start
    let wavPath: String         // on the pen
    let mp3Path: String         // on the pen
    /// WiFi access points the pen heard while recording, strongest first (lower-case BSSIDs).
    var bssids: [String] = []
}

/// "aa:bb:cc:dd:ee:ff/-42" lines from the pen's locationWifiList, strongest first.
func parseWifiList(_ json: String) -> [String] {
    let items = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] ?? []
    return items.compactMap { item -> (String, Int)? in
        let parts = item.split(separator: "/")
        guard parts.count == 2, let rssi = Int(parts[1]) else { return nil }
        return (parts[0].lowercased(), rssi)
    }
    .sorted { $0.1 > $1.1 }
    .map(\.0)
}

struct PenInfo {
    let serial: String          // adb serial
    let sn: String              // product SN (from kernel cmdline)
    let clockStatus: String     // rtc_ok / synced / estimated / unknown
    var battery: Int?           // percent
    var charging: Bool = false
    var freeBytes: Int64?       // free space on the recording partition
    var firmware: String = ""
    var wifiInstalled = false   // our uploader is on the pen
    var wifiRunning = false
    var bssid = ""              // network the pen is on right now
    var ssid = ""
}

/// Our programs on the pen, compared with the copies this app carries.
struct PenComponents: Equatable {
    enum State { case missing, current, outdated }
    var clock: State = .missing         // /userdata/e1sync/e1sync.sh — keeps the pen's clock right
    var clockRunning = false
    var uploader: State = .missing      // /userdata/e1wifi/e1wifi — WiFi uploads
    var uploaderRunning = false
    var uploaderVersion: String?
    var hook: State = .missing          // /userdata/cfg/rockchip_test/auto_reboot.sh — starts both at boot
    var anyOutdated: Bool { [clock, uploader, hook].contains(.outdated) }
}

/// The pen-side files shipped inside this app.
enum Bundled {
    static let clockScript = Bundle.main.path(forResource: "e1sync", ofType: "sh")
    static let hook = Bundle.main.path(forResource: "auto_reboot", ofType: "sh")
    static let uploader = Bundle.main.path(forResource: "e1wifi-arm64", ofType: nil)
    static let uploaderVersion = Bundle.main.object(forInfoDictionaryKey: "E1WifiVersion") as? String ?? ""
    static let clockSum = md5(clockScript), hookSum = md5(hook), uploaderSum = md5(uploader)
    private static func md5(_ path: String?) -> String? {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

enum Pen {
    /// What of ours is installed on the pen and whether it matches this app's copies (one adb call).
    static func components(_ pen: PenInfo) async -> PenComponents {
        let r = await Adb.run(["-s", pen.serial, "shell",
            "echo SYNC=$(md5sum /userdata/e1sync/e1sync.sh 2>/dev/null | cut -c1-32); " +
            "echo HOOK=$(md5sum /userdata/cfg/rockchip_test/auto_reboot.sh 2>/dev/null | cut -c1-32); " +
            "echo WIFI=$(md5sum /userdata/e1wifi/e1wifi 2>/dev/null | cut -c1-32); " +
            "echo WIFIVER=$(grep -o 'e1wifi [0-9.]* started' /userdata/e1wifi/log 2>/dev/null | tail -1 | cut -d' ' -f2); " +
            "kill -0 $(cat /tmp/e1sync.pid 2>/dev/null) 2>/dev/null && echo SYNC_RUNNING; pidof e1wifi >/dev/null && echo WIFI_RUNNING"],
            timeout: 30)
        let lines = r.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ k: String) -> String? {
            lines.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func state(_ have: String?, _ want: String?) -> PenComponents.State {
            guard let have else { return .missing }
            return have == want ? .current : .outdated
        }
        var c = PenComponents()
        c.clock = state(value("SYNC"), Bundled.clockSum)
        c.hook = state(value("HOOK"), Bundled.hookSum)
        c.uploaderVersion = value("WIFIVER")
        // The uploader is judged by its version (its file changes with every build); the scripts by their content.
        if value("WIFI") == nil {
            c.uploader = .missing
        } else if let v = c.uploaderVersion, !Bundled.uploaderVersion.isEmpty {
            c.uploader = v.compare(Bundled.uploaderVersion, options: .numeric) == .orderedAscending ? .outdated : .current
        } else {
            c.uploader = state(value("WIFI"), Bundled.uploaderSum)
        }
        c.clockRunning = lines.contains("SYNC_RUNNING")
        c.uploaderRunning = lines.contains("WIFI_RUNNING")
        return c
    }

    /// Finds a connected Sogou E1 (adb enabled in its developer menu).
    static func detect() async -> PenInfo? {
        let r = await Adb.run(["devices"], timeout: 20)
        let serials = r.out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t")
            return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        for s in serials {
            let probe = await Adb.run(["-s", s, "shell",
                "cat /proc/device-tree/model; echo; test -f /userdata/databases/E1-DATA.db && echo HAS_DB; " +
                "grep -o 'androidboot.serialno=[^ ]*' /proc/cmdline; cat /userdata/e1sync/state/clock_status 2>/dev/null; " +
                "echo BAT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); " +
                "echo CHG=$(cat /sys/class/power_supply/battery/status 2>/dev/null); " +
                "echo FREE=$(df /mnt/sdcard | tail -1 | awk '{print $4}'); " +
                "echo FW=$(grep -o '\"system_version\": *\"[^\"]*' /etc/sogou/system_version.info | sed 's/.*\"//'); " +
                "test -x /userdata/e1wifi/e1wifi && echo WIFI_INSTALLED; pidof e1wifi >/dev/null && echo WIFI_RUNNING; " +
                "wpa_cli status 2>/dev/null | grep -E '^(bssid|ssid)='"],
                timeout: 20)
            guard probe.out.contains("RK3308"), probe.out.contains("HAS_DB") else { continue }
            let sn = probe.out.components(separatedBy: "androidboot.serialno=").dropFirst().first?
                .split(whereSeparator: { $0 == "\n" || $0 == " " }).first.map(String.init) ?? s
            let lines = probe.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let clock = ["synced", "rtc_ok", "estimated"].first(where: { lines.contains($0) }) ?? "unknown"
            func value(_ k: String) -> String? {
                lines.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            var info = PenInfo(serial: s, sn: sn, clockStatus: clock)
            info.battery = value("BAT").flatMap(Int.init)
            info.charging = ["Charging", "Full"].contains(value("CHG") ?? "")
            info.freeBytes = value("FREE").flatMap(Int64.init).map { $0 * 1024 }
            info.firmware = value("FW") ?? ""
            info.wifiInstalled = lines.contains("WIFI_INSTALLED")
            info.wifiRunning = lines.contains("WIFI_RUNNING")
            info.bssid = (value("bssid") ?? "").lowercased()
            info.ssid = value("ssid") ?? ""
            return info
        }
        return nil
    }

    /// Pulls the pen's database and returns all user recordings (built-in welcome audio excluded).
    static func recordings(_ pen: PenInfo) async throws -> [PenRecording] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("E1-DATA-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await Adb.run(["-s", pen.serial, "pull", "/userdata/databases/E1-DATA.db", tmp.path], timeout: 60)
        guard r.code == 0 else { throw AppError("读取录音笔数据库失败：\(r.err)") }
        return try readDB(tmp.path)
    }

    static func pull(_ pen: PenInfo, remote: String, to local: URL) async throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy to a side file and move it into place only when complete: if the cable comes out halfway, no
        // truncated recording is left under the real name (which would later look finished and get transcribed).
        let part = local.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        let r = await Adb.run(["-s", pen.serial, "pull", remote, part.path], timeout: 1800)
        guard r.code == 0, FileManager.default.fileExists(atPath: part.path) else {
            try? FileManager.default.removeItem(at: part)
            throw AppError("从录音笔拷贝 \(remote) 失败：\(r.err)")
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: part, to: local)
    }

    /// Seconds since each file on the pen was last written (by the pen's own clock); missing files are left out.
    /// (The pen's busybox has no `stat`; `date -r FILE` gives the modification time.)
    static func fileAges(_ pen: PenInfo, _ paths: [String]) async -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        let list = paths.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: " ")
        let r = await Adb.run(["-s", pen.serial, "shell", "now=$(date +%s); for f in \(list); do m=$(date -r \"$f\" +%s 2>/dev/null) && echo \"$((now-m))|$f\"; done"])
        var ages: [String: Int] = [:]
        for line in r.out.split(separator: "\n") {
            let p = line.split(separator: "|", maxSplits: 1)
            if p.count == 2, let a = Int(p[0].trimmingCharacters(in: .whitespaces)) { ages[String(p[1]).trimmingCharacters(in: .whitespacesAndNewlines)] = a }
        }
        return ages
    }

    private static func readDB(_ path: String) throws -> [PenRecording] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw AppError("无法打开录音笔数据库") }
        defer { sqlite3_close(db) }
        let sql = "SELECT id, recordTypeName, titleName, createTime, aiTagData, waveFormDuration, waveFormPath, playbackPath, ifnull(locationWifiList,'') " +
                  "FROM record_table WHERE recordType != 8 AND waveFormPath LIKE '%.wav' ORDER BY id"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw AppError("录音笔数据库格式不认识") }
        defer { sqlite3_finalize(st) }
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out: [PenRecording] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        while sqlite3_step(st) == SQLITE_ROW {
            let marksJSON = text(4)
            let marks = ((try? JSONSerialization.jsonObject(with: Data(marksJSON.utf8))) as? [String] ?? [])
                .compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "s "))) }
            func onPen(_ p: String) -> String { p.hasPrefix("/sdcard/") ? "/mnt" + p : p }
            out.append(PenRecording(recordId: Int(sqlite3_column_int(st, 0)), typeName: text(1), title: text(2),
                                    created: fmt.date(from: text(3)), durationSec: Int(sqlite3_column_int(st, 5)),
                                    marks: marks, wavPath: onPen(text(6)), mp3Path: onPen(text(7)), bssids: parseWifiList(text(8))))
        }
        return out
    }
}

struct AppError: LocalizedError {
    let message: String
    /// Network trouble or a busy server: worth trying again later by itself, not a failure to report.
    var transient = false
    init(_ m: String, transient: Bool = false) { message = m; self.transient = transient }
    var errorDescription: String? { message }
}
