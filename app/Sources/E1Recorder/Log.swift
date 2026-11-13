import AppKit
import Foundation
import OSLog

/// The app's log, readable in Console.app (subsystem app.e1recorder.mac) and exported by 「导出诊断信息」.
/// Titles and paths are logged as private; counts, states and error descriptions as public.
enum Log {
    static let subsystem = "app.e1recorder.mac"
    static let sync = Logger(subsystem: subsystem, category: "同步")
    static let jobs = Logger(subsystem: subsystem, category: "转写")
    static let notes = Logger(subsystem: subsystem, category: "纪要")
    static let recorder = Logger(subsystem: subsystem, category: "录音")
    static let app = Logger(subsystem: subsystem, category: "应用")
}

/// A plain-text report for troubleshooting, with personal details taken out: no keys, no recording titles,
/// no network names, the home folder shown as ~, the storage name and the pen's serial number masked.
@MainActor
enum Diagnostics {
    static func report(_ s: AppSettings, _ p: Pipeline) -> String {
        var out: [String] = []
        func line(_ k: String, _ v: Any?) { out.append("\(k)：\(v.map { "\($0)" } ?? "—")") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("听墨 诊断信息 · " + DateFormatter.cached("yyyy-MM-dd HH:mm").string(from: Date()))
        out.append("")
        line("应用版本", AppLinks.version)
        line("上传程序（内置）", Bundled.uploaderVersion)
        line("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        line("机型", sysctl("hw.model"))
        out.append("")
        out.append("[转写]")
        line("服务平台", s.provider.info.name)
        line("配置状态", s.setupProblem ?? "已就绪")
        line("连接状态", s.connState.hasPrefix("failed:") ? "失败：" + s.connState.dropFirst(7) : s.connState)
        line("纪要格式", s.noteFormat)
        line("保留录音文件", s.keepAudio ? "是" : "否")
        line("纪要目录", tilde(s.notesFolder))
        line("录音目录", tilde(s.audioFolder))
        out.append("")
        out.append("[WiFi 同步]")
        line("已启用", s.wifiEnabled ? "是" : "否")
        line("存储空间", s.ossBucket.isEmpty ? "未填写" : "已填写（已隐藏）")
        line("地域节点", s.ossEndpoint)
        line("录音笔钥匙", s.penKeyStored ? "已存" : "未存")
        line("Mac 钥匙", s.macKeyStored ? "已存" : "未存")
        if let w = p.wifiStatus {
            line("最近心跳", w.seen.map { relativeTime($0) })
            line("录音笔上传程序", w.version)
            line("电量", "\(w.battery)%" + (w.charging ? "（充电中）" : ""))
        } else {
            line("最近心跳", "无")
        }
        if let e = p.wifiError { line("WiFi 错误", e) }
        out.append("")
        out.append("[录音笔]")
        line("USB 连接", p.penConnected ? "是" : "否")
        if let pen = p.pen {
            line("序列号", "…" + pen.sn.suffix(4))
            line("固件", pen.firmware)
            line("时钟", pen.clockStatus)
        }
        if let c = p.penComponents {
            line("校时脚本", "\(c.clock)\(c.clockRunning ? "，运行中" : "")")
            line("上传程序", "\(c.uploader) \(c.uploaderVersion ?? "")\(c.uploaderRunning ? "，运行中" : "")")
            line("开机自启", "\(c.hook)")
        }
        out.append("")
        out.append("[转写记录]")
        let byState = Dictionary(grouping: p.jobs, by: { "\($0.state)" }).mapValues(\.count)
        line("共", "\(p.jobs.count) 条 " + byState.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        let bySource = Dictionary(grouping: p.jobs, by: { $0.sourceSymbol }).mapValues(\.count)
        line("来源", bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        let failures = p.jobs.filter { $0.state == .failed }.prefix(10)
        for j in failures { out.append("  失败 · " + DateFormatter.cached("MM-dd HH:mm").string(from: j.created) + " · " + (j.error ?? "")) }
        out.append("")
        out.append("[最近日志]")
        out.append(contentsOf: recentLog())
        return out.joined(separator: "\n")
    }

    /// This run's log lines (Console.app has older runs).
    private static func recentLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["（读不到日志）"] }
        let since = store.position(timeIntervalSinceEnd: -6 * 3600)
        let entries = (try? store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", Log.subsystem))) ?? AnySequence([])
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            DateFormatter.cached("HH:mm:ss").string(from: $0.date) + " [\($0.category)] " + tilde($0.composedMessage)
        }
        return lines.isEmpty ? ["（本次运行还没有日志）"] : Array(lines.suffix(300))
    }

    private static func tilde(_ s: String) -> String { s.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func export() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "听墨诊断信息.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report(AppSettings.shared, Pipeline.shared).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
