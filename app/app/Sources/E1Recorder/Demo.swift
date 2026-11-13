import Foundation

/// Made-up content for screenshots (README, articles): `-uiPreview YES -previewDemo YES` in a PREVIEW=1 build.
/// Nothing here is written to the real settings or job list — preview mode never saves.
enum Demo {
    static var on: Bool { UIPreview.enabled && UserDefaults.standard.bool(forKey: "previewDemo") }

    static let notesFolder = NSHomeDirectory() + "/Documents/会议纪要"
    static let audioFolder = NSHomeDirectory() + "/Music/E1录音"

    @MainActor static func apply(to s: AppSettings) {
        s.notesFolder = notesFolder
        s.audioFolder = audioFolder
        s.organizer = "李明"
        s.appId = "tw_DemoAppId01"
        s.ossBucket = "my-e1-inbox"
        s.ossEndpoint = "oss-cn-beijing.aliyuncs.com"
        s.hotwords = "李明\n王芳\n小程序\n选品"
        s.knownNetworks = ["aa:00:00:00:00:01": "Office-5G", "aa:00:00:00:00:02": "Office-5G",
                           "aa:00:00:00:00:03": "Home-WiFi", "aa:00:00:00:00:04": "Cafe-Guest"]
        s.placeNames = ["Office-5G": "公司", "Home-WiFi": "家"]
        s.budgetYuan = 50
        s.connState = "ok"
    }

    /// A week of typical recordings: every source, every state.
    static func jobs() -> [Job] {
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: -daysAgo, to: Date())!)!
        }
        let usb = "搜狗 E1 录音笔", wifi = "搜狗 E1 录音笔 · WiFi", mac = "Mac 录音", file = "导入文件"
        var n = 0
        func job(_ title: String?, _ source: String, _ created: Date, _ minutes: Int, _ state: Job.State = .done,
                 note: Bool = true, error: String? = nil) -> Job {
            n += 1
            let topic = title ?? "录音"
            let day = DateFormatter.cached("yyMMdd").string(from: created)
            var j = Job(id: "demo-\(n)", title: "录音 \(n)", scene: "会议", source: source, created: created,
                        durationSec: minutes * 60, marks: [], audioPath: audioFolder + "/demo-\(n).wav", listenPath: nil,
                        timeUncertain: false, state: state, updated: created.addingTimeInterval(Double(minutes * 60 + 120)))
            if state == .done {
                j.dataId = "demo-\(n)"
                j.provider = "tingwu"
                j.topic = topic
                j.notePath = (note ? notesFolder : NSHomeDirectory() + "/已删除") + "/\(day) - \(topic).md"
            }
            j.error = error
            j.bssids = source.contains("录音笔") ? ["aa:00:00:00:00:01"] : nil
            return j
        }
        return [
            job(nil, wifi, at(0, 16, 40), 12, .queued),
            job(nil, mac, at(0, 15, 50), 18, .transcribing),
            job("客户访谈：选品方向与价格带", usb, at(0, 14, 30), 35),
            job("产品周会：新功能排期与分工", wifi, at(0, 10, 0), 52),
            job("读书分享：《原则》第三章", mac, at(1, 19, 20), 25),
            job("新人培训：工作流程与常用工具", usb, at(1, 15, 0), 41),
            job("季度复盘：销售数据与下季目标", file, at(1, 9, 30), 72),
            job(nil, file, at(2, 17, 10), 33, .failed, error: "网络中断，上传没有完成"),
            job("供应商沟通：交期与质检标准", wifi, at(2, 11, 20), 28),
            job("部门例会：报销流程调整", usb, at(3, 9, 0), 22, note: false),
            job(MarkdownRenderer.emptyTitle, mac, at(3, 12, 5), 0),
            job("直播复盘：转化率与话术优化", file, at(3, 20, 30), 47),
        ]
    }
}
