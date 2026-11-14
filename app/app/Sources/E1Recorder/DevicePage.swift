import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        let pen = pipeline.penConnected ? pipeline.pen : nil
        Form {
            Section {
                HStack(spacing: 12) {
                    SidebarIcon(glyph: .device, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("录音笔")
                        HStack(spacing: 6) {
                            PenStatusLine()
                            if pipeline.manualSync {
                                Text("· " + (pipeline.syncPhase ?? "同步中") + "…").font(.e1Sub).foregroundStyle(Color.t2)
                            } else if let r = pipeline.syncResult {
                                Text("· 同步完成，\(r)").font(.e1Sub).foregroundStyle(Color.e1Green)
                            } else if !pipeline.isCopying, let t = pipeline.lastSync {
                                Text("· 上次同步 " + DateFormatter.cached("HH:mm").string(from: t)).font(.e1Sub).foregroundStyle(Color.t2)
                            }
                        }
                    }
                    Spacer()
                    Button { Task { await pipeline.syncNow() } } label: {
                        if pipeline.manualSync || pipeline.isCopying {
                            HStack(spacing: 5) { ProgressView().controlSize(.small); Text((pipeline.syncPhase ?? "同步中") + "…") }
                        } else { Text("立即同步") }
                    }
                    .disabled(!pipeline.canSyncNow || pipeline.manualSync || pipeline.isCopying)
                }
                .padding(.vertical, 4)
            }

            Section {
                let snap = pipeline.penSnapshot
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    InfoTile(icon: AnyView(BatteryIcon(level: snap?.battery)), value: snap?.battery.map { "\($0)%" } ?? "—",
                             label: "剩余电量" + ((snap?.charging ?? false) ? " · 充电中" : ""))
                    InfoTile(symbol: "internaldrive", value: snap?.freeBytes.map(formatBytes) ?? "—", label: "可用空间")
                    InfoTile(symbol: "clock", value: snap.map { clockText($0.clockStatus) } ?? "—", label: "时间状态 · 联网对时")
                    InfoTile(symbol: "waveform", value: snap?.recordingCount.map { "\($0) 条" } ?? "—", label: "笔内录音")
                    InfoTile(symbol: "number", value: snap?.sn.map { "…" + $0.suffix(6) } ?? "—", label: "序列号码")
                    InfoTile(symbol: "cpu", value: snap?.firmware.flatMap { $0.isEmpty ? nil : $0 } ?? "—", label: "固件版本")
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("设备信息")
                    Spacer()
                    if let src = pipeline.penSnapshot?.source {
                        Text("来自 " + src).font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent {
                    pen != nil ? StatusTag(text: "已连接", color: .e1Green) : StatusTag(text: "未连接", color: .secondary)
                } label: {
                    Text("USB 有线")
                }
                LabeledContent {
                    HStack {
                        wifiTag
                    }
                } label: {
                    Text("WiFi 无线"); Text(wifiSubtitle)
                }
            } header: {
                SectionTitle("连接方式", info: "两种方式可以同时用：插着数据线走 USB；拔掉后录音笔连上 WiFi 自动上传，这台 Mac 开着时取回并转写。")
            }

            PenComponentsSection(onSetUpWifi: { SettingsNav.openServiceOptions() })

            Section {
                Toggle("自动同步", isOn: $s.autoSync).toggleStyle(.switch)
                Picker("最短时长", selection: $s.minDurationSec) {
                    ForEach([0, 5, 10, 30, 60], id: \.self) { Text($0 == 0 ? "不限" : "\($0) 秒").tag($0) }
                }
                Picker(selection: $s.wifiIntervalMin) {
                    ForEach([1, 5, 15, 30], id: \.self) { Text("每 \($0) 分钟").tag($0) }
                } label: {
                    Text("WiFi 检查")
                }
            } header: {
                Text("同步规则")
            }

            PenRecordingsSection()

            PlacesSection()
        }
    }

    @ViewBuilder private var wifiTag: some View {
        if !s.wifiReady { StatusTag(text: "未设置", color: .secondary) }
        else if pipeline.wifiError != nil { StatusTag(text: "出错", color: .e1Red) }
        else if pipeline.wifiOnline { StatusTag(text: "在线", color: .e1Green) }
        else if pipeline.wifiStatus != nil { StatusTag(text: "离线", color: .secondary) }
        else { StatusTag(text: "等待心跳", color: .orange) }
    }

    private var wifiSubtitle: String {
        if !s.wifiReady { return "录音笔连上 WiFi 自动上传，需要先设置" }
        if let e = pipeline.wifiError { return e }
        let checked = pipeline.lastWifiCheck.map { " · 上次检查 " + DateFormatter.cached("HH:mm").string(from: $0) } ?? ""
        guard let w = pipeline.wifiStatus, let d = w.seen else { return "还没收到录音笔的心跳" + checked }
        return (w.isOnline ? "在线 · \(w.ssid.isEmpty ? "WiFi" : w.ssid) · 心跳 \(relativeTime(d))" : "最后在线 \(relativeTime(d))") + checked
    }

    private func clockText(_ status: String) -> String {
        ["synced": "已校准", "rtc_ok": "时钟正常", "estimated": "估计时间"][status] ?? "未安装"
    }

}
