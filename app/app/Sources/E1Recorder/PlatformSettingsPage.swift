import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 服务平台与接入参数 — set once, rarely touched again.
struct PlatformSettingsPage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    enum Edit: String, Identifiable { case key, appId, endpoint, asrModel, llmModel, bucket, ossEndpoint; var id: String { rawValue } }
    @State private var editing: Edit?
    @State private var testing = false
    @State private var editingPenKey = false
    @State private var editingMacKey = false
    @State private var showGuide = false
    @State private var storageTesting = false
    @State private var storageResult: String?

    var body: some View {
        Form {
            Section("语音转写") {
                Picker(selection: Binding(get: { s.provider }, set: { s.setProvider($0) })) {
                    Text(Provider.tingwu.info.name).tag(Provider.tingwu)
                    Text(Provider.bailian.info.name).tag(Provider.bailian)
                    Divider()
                    Text("自定义…").tag(Provider.custom)
                } label: {
                    Text("服务平台")
                }
                if s.provider == .custom {
                    LabeledContent {
                        HStack { Trailing(text: s.customASRModel); Button("编辑…") { editing = .asrModel } }
                    } label: { Text("识别模型") }
                    LabeledContent {
                        HStack { Trailing(text: s.customLLMModel); Button("编辑…") { editing = .llmModel } }
                    } label: { Text("整理模型") }
                } else {
                    Picker("识别模型", selection: $s.transcriptionModel) {
                        ForEach(s.provider.info.models) { Text($0.label).tag($0.id) }
                    }
                    .disabled(s.provider.info.models.count < 2)
                }
                if s.provider == .bailian {
                    Picker("整理模型", selection: $s.llmModel) {
                        ForEach(PlatformInfo.llmModels) { Text($0.label).tag($0.id) }
                    }
                }
            }

            Section {
                LabeledContent("访问密钥") {
                    HStack { Trailing(text: s.activeMaskedKey ?? "未填写"); Button(s.hasAPIKey ? "修改…" : "填写…") { editing = .key } }
                }
                if s.provider.info.needsAppId {
                    LabeledContent("应用编号") {
                        HStack { Trailing(text: s.appId.isEmpty ? "未填写" : s.appId); Button("编辑…") { editing = .appId } }
                    }
                }
                LabeledContent("接口地址") {
                    HStack {
                        let ep = s.provider == .custom ? s.customEndpoint : s.endpoint
                        Trailing(text: s.provider == .custom ? ep.replacingOccurrences(of: "https://", with: "") : URL(string: ep)?.host ?? ep)
                        Button("编辑…") { editing = .endpoint }
                    }
                }
                LabeledContent("连接状态") {
                    HStack(spacing: 8) {
                        connStatus
                        Button(s.connState.hasPrefix("failed") ? "重试" : "测试连接") {
                            Task { testing = true; await PlatformTest.run(s); testing = false }
                        }
                        .disabled(testing || !s.hasAPIKey)
                    }
                }
            } header: {
                SectionTitle("接入参数", info: "应用编号在百炼控制台 › 应用 › 通义听悟中查看，以 tw_ 开头。访问密钥只存在这台 Mac 的钥匙串里，不写进文件，也不会导出。自定义平台支持任何 OpenAI 兼容接口。[打开百炼控制台…](https://bailian.console.aliyun.com/)")
            }

            Section {
                LabeledContent("存储空间") {
                    HStack { Trailing(text: s.ossBucket.isEmpty ? "未填写" : s.ossBucket); Button("编辑…") { editing = .bucket } }
                }
                LabeledContent("地域节点") {
                    HStack { Trailing(text: s.ossEndpoint.isEmpty ? "未填写" : s.ossEndpoint); Button("编辑…") { editing = .ossEndpoint } }
                }
                LabeledContent("录音笔用钥匙") {
                    HStack { Trailing(text: s.penKeyStored ? "已存入钥匙串" : "未填写"); Button(s.penKeyStored ? "修改…" : "填写…") { editingPenKey = true } }
                }
                LabeledContent("Mac 用钥匙") {
                    HStack { Trailing(text: s.macKeyStored ? "已存入钥匙串" : "未填写"); Button(s.macKeyStored ? "修改…" : "填写…") { editingMacKey = true } }
                }
                LabeledContent("连接测试") {
                    HStack(spacing: 8) {
                        if storageTesting { ProgressView().controlSize(.small) }
                        else if let r = storageResult {
                            if r.isEmpty { HStack(spacing: 6) { Dot(kind: .ok); Text("两把钥匙都正常") } }
                            else { HStack(spacing: 6) { Dot(kind: .bad); Text(r).lineLimit(1).frame(maxWidth: 200, alignment: .trailing) } }
                        }
                        Button("测试") {
                            Task {
                                storageTesting = true
                                storageResult = UIPreview.enabled ? "" : (await pipeline.testWifi() ?? "")
                                if storageResult == "" { s.wifiEnabled = true }
                                storageTesting = false
                            }
                        }
                        .disabled(storageTesting || s.ossBucket.isEmpty || !s.penKeyStored || !s.macKeyStored)
                    }
                }
                Toggle("启用 WiFi 同步", isOn: $s.wifiEnabled).toggleStyle(.switch)
            } header: {
                HStack {
                    SectionTitle("云存储", info: "WiFi 同步用的信箱：录音笔连上 WiFi 后，把新录音传到你阿里云账号里的这个存储空间；这台 Mac 取回、转写后清空。录音笔的钥匙只能上传，Mac 的钥匙只能读取和删除。")
                    Spacer()
                    Button("设置步骤…") { showGuide = true }.buttonStyle(.link).font(.callout)
                }
            }

            Section {
                Picker("预算提醒", selection: $s.budgetYuan) {
                    Text("不提醒").tag(0)
                    ForEach([30, 50, 100, 200], id: \.self) { Text("每月 ¥\($0)").tag($0) }
                }
            } header: {
                SectionTitle("费用与预算", info: "按官方价格估算（通义听悟约 ¥0.79/小时，百炼语音约 ¥0.81/小时），达到预算的 80% 时提醒一次。实际金额以[阿里云费用中心](https://usercenter2.aliyun.com/home)为准。")
            }

        }
        .sheet(item: $editing) { e in sheet(e) }
        .sheet(isPresented: $editingPenKey) { KeyPairSheet(pen: true) }
        .sheet(isPresented: $editingMacKey) { KeyPairSheet(pen: false) }
        .sheet(isPresented: $showGuide) {
            VStack(spacing: 0) {
                WifiGuideView()
                HStack { Spacer(); Button("完成") { showGuide = false }.keyboardShortcut(.defaultAction) }.padding(16)
            }
            .frame(width: 600, height: 720)
        }
    }

    @ViewBuilder private var connStatus: some View {
        if testing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在测试…").foregroundStyle(.secondary) }
        } else if s.connState == "ok" {
            HStack(spacing: 6) { Dot(kind: .ok); Text("正常") }
        } else if s.connState.hasPrefix("failed:") {
            HStack(spacing: 6) { Dot(kind: .bad); Text(String(s.connState.dropFirst(7))).lineLimit(1).frame(maxWidth: 220, alignment: .trailing) }
        } else {
            HStack(spacing: 6) { Dot(kind: .off); Text(s.hasAPIKey ? "未测试" : "未填写密钥").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func sheet(_ e: Edit) -> some View {
        switch e {
        case .key:
            if s.provider == .custom {
                EditSheet(title: "填写访问密钥", help: "自定义平台的 API Key，只保存在本机钥匙串，与百炼的密钥分开存放。",
                          placeholder: "API Key", secure: true, initial: "",
                          validate: { $0.count >= 8 ? nil : "密钥太短" }, save: { s.saveAPIKey($0) })
            } else {
                EditSheet(title: "填写访问密钥", help: "在百炼控制台 › 密钥管理中创建，以 sk- 开头。只保存在本机钥匙串。",
                          placeholder: "sk-…", secure: true, initial: "",
                          validate: { $0.hasPrefix("sk-") && $0.count >= 20 ? nil : "应以 sk- 开头" },
                          save: { s.saveAPIKey($0) })
            }
        case .asrModel:
            EditSheet(title: "编辑识别模型", help: "该平台语音转文字的模型名，例如 whisper-1、gpt-4o-transcribe、FunAudioLLM/SenseVoiceSmall。",
                      placeholder: "whisper-1", initial: s.customASRModel,
                      validate: { $0.contains(" ") ? "模型名不能有空格" : nil }, save: { s.customASRModel = $0; s.connState = "untested" })
        case .llmModel:
            EditSheet(title: "编辑整理模型", help: "用来生成摘要、待办和章节的对话模型名，例如 gpt-4o-mini、deepseek-chat。",
                      placeholder: "gpt-4o-mini", initial: s.customLLMModel,
                      validate: { $0.contains(" ") ? "模型名不能有空格" : nil }, save: { s.customLLMModel = $0; s.connState = "untested" })
        case .appId:
            EditSheet(title: "编辑应用编号", help: "在百炼控制台 › 应用 › 通义听悟·智能纪要 › 我的应用中复制，以 tw_ 开头。",
                      placeholder: "tw_…", initial: s.appId,
                      validate: { $0.hasPrefix("tw_") ? nil : "应以 tw_ 开头" },
                      save: { s.appId = $0; s.connState = "untested" })
        case .bucket:
            EditSheet(title: "存储空间名称", help: "阿里云 OSS 里为 WiFi 同步建的存储空间（Bucket）名称。", placeholder: "存储空间名称",
                      initial: s.ossBucket, validate: { $0.range(of: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil ? nil : "只能用小写字母、数字和短横线，3–63 个字符" },
                      save: { s.ossBucket = $0 })
        case .ossEndpoint:
            EditSheet(title: "地域节点", help: "存储空间所在地域的访问域名，例如 oss-cn-beijing.aliyuncs.com。", placeholder: "oss-cn-beijing.aliyuncs.com",
                      initial: s.ossEndpoint, validate: { $0.hasSuffix(".aliyuncs.com") && !$0.contains("/") ? nil : "应形如 oss-cn-beijing.aliyuncs.com" },
                      save: { s.ossEndpoint = $0 })
        case .endpoint where s.provider == .custom:
            EditSheet(title: "编辑接口地址", help: "OpenAI 兼容接口的根地址，一般以 /v1 结尾，例如 https://api.openai.com/v1。",
                      placeholder: "https://api.openai.com/v1", initial: s.customEndpoint,
                      validate: { $0.hasPrefix("https://") && URL(string: $0)?.host != nil ? nil : "应以 https:// 开头" },
                      save: { s.customEndpoint = $0.hasSuffix("/") ? String($0.dropLast()) : $0; s.connState = "untested" })
        case .endpoint:
            EditSheet(title: "编辑接口地址", help: "一般不用改。国际站账号可改为 https://dashscope-intl.aliyuncs.com。",
                      placeholder: "https://dashscope.aliyuncs.com", initial: s.endpoint,
                      validate: { $0.hasPrefix("https://") && URL(string: $0)?.host != nil ? nil : "应以 https:// 开头" },
                      save: { s.endpoint = $0.hasSuffix("/") ? String($0.dropLast()) : $0; s.connState = "untested" })
        }
    }
}
