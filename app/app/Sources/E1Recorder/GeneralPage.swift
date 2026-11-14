import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralPage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSubpage) private var openSubpage
    @State private var msg = ""

    var body: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: Binding(get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 })).toggleStyle(.switch)
                Picker("菜单图标", selection: $s.menuIcon) {
                    ForEach(MenuBarIcon.styles, id: \.id) { st in
                        Image(nsImage: MenuBarIcon.idle(st.id)).tag(st.id)
                    }
                }
                LabeledContent("使用引导") { Button("打开…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "welcome") } }
            } header: {
                Text("启动")
            }

            Section {
                LabeledContent("当前通道") {
                    if pipeline.penConnected {
                        HStack(spacing: 6) { Dot(kind: .ok, size: 6); Image(systemName: "cable.connector").foregroundStyle(.secondary); Trailing(text: "USB 有线 · 已连接") }
                    } else if pipeline.wifiOnline {
                        HStack(spacing: 6) { Dot(kind: .ok, size: 6); Image(systemName: "wifi").foregroundStyle(.secondary); Trailing(text: "WiFi 无线 · 在线") }
                    } else if s.wifiReady, let d = pipeline.wifiStatus?.seen {
                        HStack(spacing: 6) { Dot(kind: .off, size: 6); Trailing(text: "WiFi 离线 · 最后在线 \(relativeTime(d))") }
                    } else {
                        HStack(spacing: 6) { Dot(kind: .off, size: 6); Trailing(text: "未连接") }
                    }
                }
            } header: {
                SectionTitle("通道", info: "插着数据线时走 USB；拔掉后，设置了 WiFi 同步的录音笔联网会自动上传。两者都没有时显示「未连接」，录音留在笔里，下次补传。")
            }

            Section {
                LabeledContent("导出配置") { Button("导出…", action: exportConfig) }
                LabeledContent("导入配置") {
                    HStack { if !msg.isEmpty { Trailing(text: msg) }; Button("导入…", action: importConfig) }
                }
                LabeledContent("诊断信息") { Button("导出…") { Diagnostics.export() } }
                    .help("遇到问题时导出一份运行情况，方便排查；不含密钥、录音标题和网络名称")
            } header: {
                SectionTitle("配置", info: "换电脑：在新电脑安装本应用 → 导入配置 → 按提示填写访问密钥。导出内容包括平台、模型、应用编号、接口地址、热词、模板与目录、云存储、发言人和地点；访问密钥与钥匙只在钥匙串里，不导出。")
            }

            Section {
                LabeledContent("关于听墨") { Button("打开…") { openSubpage("about") } }
            } header: {
                Text("关于")
            }
        }
    }

    private func exportConfig() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSSavePanel()
        p.nameFieldStringValue = "听墨配置.json"
        if p.runModal() == .OK, let u = p.url {
            do { try s.exportConfig(to: u); msg = "已导出" } catch { msg = error.localizedDescription }
        }
    }

    private func importConfig() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url {
            do {
                try s.importConfig(from: u)
                let m = s.missingSecrets
                msg = m.isEmpty ? "已导入" : "已导入，还需填写：" + m.joined(separator: "、")
            } catch { msg = error.localizedDescription }
        }
    }
}
