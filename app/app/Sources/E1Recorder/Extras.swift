import AppKit
import SwiftUI

// MARK: - 为发言人命名

/// Lets the user replace 发言人1/2… with real names; the note is rewritten in place.
struct SpeakerNamingView: View {
    let jobId: String
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var names: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        let job = pipeline.jobs.first { $0.id == jobId }
        let speakers = job.map { pipeline.speakers(of: $0) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("为发言人命名").font(.title3.weight(.semibold))
                Text(job?.title ?? "").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    ForEach(speakers) { sp in
                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("发言人\(sp.id)", text: binding(sp.id)).textFieldStyle(.roundedBorder).frame(width: 150)
                                if !s.knownSpeakers.isEmpty {
                                    Menu {
                                        ForEach(s.knownSpeakers, id: \.self) { n in Button(n) { names[sp.id] = n } }
                                    } label: { Image(systemName: "person.crop.circle") }
                                    .menuStyle(.borderlessButton).fixedSize().help("用过的名字")
                                }
                            }
                        } label: {
                            Text("发言人\(sp.id)")
                            Text("约 \(sp.chars) 字 · “\(sp.sample)”").lineLimit(1)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("取消") { dismissWindow() }.keyboardShortcut(.cancelAction)
                Button("存储并更新纪要") {
                    if let job { pipeline.nameSpeakers(job, names) }
                    dismissWindow()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job == nil)
            }
            .padding(20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if !loaded { names = job?.speakerNames ?? [:]; loaded = true }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
    }
}

// MARK: - 首次使用引导

struct WelcomeView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var editingKey = false
    @State private var editingAppId = false
    @State private var page = ["pen": 0, "platform": 1, "wifi": 2][UserDefaults.standard.string(forKey: "previewPage") ?? ""] ?? 0

    private let titles = ["欢迎使用 听墨", "转写与纪要", "WiFi 无线同步（可选）"]
    private let subtitles = [
        "先让这台 Mac 认出录音笔，并在笔上装好校时脚本。之后插上录音笔就会自动拷贝录音。",
        "录音在云端转写，生成的会议纪要存进你的笔记库。",
        "设好之后不用插线：录音笔连上 WiFi 自动上传，这台 Mac 开着时自动取回并转写。",
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text(titles[page]).font(.title2.weight(.semibold))
                Text(subtitles[page]).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in Circle().fill(i == page ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2)).frame(width: 6, height: 6) }
                }
                .padding(.top, 4)
            }
            .padding(.top, 24)

            switch page {
            case 2: WifiGuideView()
            case 1: platformPage
            default: penPage
            }

            HStack {
                switch page {
                case 0:
                    Button("稍后再说") { finish() }
                    Spacer()
                    Button("下一步") { page = 1 }.keyboardShortcut(.defaultAction)
                case 1:
                    Button("上一步") { page = 0 }
                    Spacer()
                    Button("下一步：WiFi（可选）") { page = 2 }
                    Button("开始使用") { finish() }.keyboardShortcut(.defaultAction)
                default:
                    Button("上一步") { page = 1 }
                    Spacer()
                    Button("完成") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 760)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .sheet(isPresented: $editingKey) {
            EditSheet(title: "填写访问密钥", help: s.provider == .custom ? "自定义平台的 API Key，只保存在本机钥匙串。" : "在百炼控制台 › 密钥管理中创建，以 sk- 开头。",
                      placeholder: s.provider == .custom ? "API Key" : "sk-…", secure: true, initial: "",
                      validate: { k in s.provider == .custom ? (k.isEmpty ? "密钥不能为空" : nil) : (k.hasPrefix("sk-") && k.count >= 20 ? nil : "应以 sk- 开头") },
                      save: { s.saveAPIKey($0) })
        }
        .sheet(isPresented: $editingAppId) {
            EditSheet(title: "编辑应用编号", help: "在百炼控制台 › 应用 › 通义听悟·智能纪要 › 我的应用中复制，以 tw_ 开头。",
                      placeholder: "tw_…", initial: s.appId, validate: { $0.hasPrefix("tw_") ? nil : "应以 tw_ 开头" },
                      save: { s.appId = $0; s.connState = "untested" })
        }
    }

    /// Page 1: the pen — adb, then our programs on it.
    private var penPage: some View {
        Form {
            Section {
                Text("在录音笔上：通用设置 › 关于本机 › 连续点「MAC 地址」› 开发者模式 › 基本设置 › 打开 adb，然后用数据线连到这台 Mac。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                StepHeader(number: 1, title: "打开录音笔的 adb", done: pipeline.penConnected,
                           status: pipeline.penConnected ? "已检测到录音笔" : "等待连接…")
            }

            Section {
                PenComponentRow(kind: .clock)
            } header: {
                StepHeader(number: 2, title: "在录音笔上安装校时脚本", done: pipeline.penComponents?.clock == .current,
                           status: !pipeline.penConnected ? "先完成第 1 步" : pipeline.penComponents?.clock == .current ? "已安装" : "建议安装")
            } footer: {
                Text("搜狗的对时服务器已关闭，录音笔断电后时间会乱，录音和纪要上的时间就不准。WiFi 上传程序是可选的，在第 3 页设置。这些程序以后都在「偏好 › 设备 › 录音笔上的程序」里查看和更新。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Page 2: transcription service and where notes go.
    private var platformPage: some View {
        Form {
            Section {
                Picker("服务平台", selection: Binding(get: { s.provider }, set: { s.setProvider($0) })) {
                    ForEach(Provider.allCases) { Text($0.info.name).tag($0) }
                }
                LabeledContent("访问密钥") {
                    HStack { Trailing(text: s.activeMaskedKey ?? "未填写"); Button(s.hasAPIKey ? "修改…" : "填写…") { editingKey = true } }
                }
                if s.provider.info.needsAppId {
                    LabeledContent("应用编号") {
                        HStack { Trailing(text: s.appId.isEmpty ? "未填写" : s.appId); Button("编辑…") { editingAppId = true } }
                    }
                }
                if s.provider == .custom {
                    Text("自定义平台的地址和模型请在「偏好 › 转写」中填写。").foregroundStyle(.secondary)
                }
            } header: {
                StepHeader(number: 3, title: "设置转写平台", done: s.isConfigured, status: s.isConfigured ? "已设置" : "需要访问密钥")
            } footer: {
                Text(.init(s.provider == .custom
                     ? "自定义平台的 API Key 为任意非空串，只保存在这台 Mac 的钥匙串里。"
                     : "密钥在阿里云百炼控制台 › 密钥管理中创建，只保存在这台 Mac 的钥匙串里。[打开百炼控制台…](https://bailian.console.aliyun.com/)"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                FolderRow(title: "纪要目录", path: $s.notesFolder)
            } header: {
                StepHeader(number: 4, title: "选择纪要存放位置", done: true, status: "可随时在偏好中更改")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func finish() {
        s.onboardingDone = true
        dismissWindow()
    }
}

struct StepHeader: View {
    let number: Int
    let title: String
    let done: Bool
    let status: String
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(done ? Color.e1Green : Color.primary.opacity(0.12)).frame(width: 20, height: 20)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
            }
            Text(title)
            Spacer()
            Text(status).font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 热词

struct HotwordSheet: View {
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        let count = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑热词").font(.headline)
            Text("每行一个：同事姓名、公司和产品名、行业术语。转写时优先识别成这些写法，整理纪要时也按它们纠正。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(6)
                .background(Color.e1Group, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(height: 220)
            HStack {
                Text("\(count) 个 · 每个不超过 15 个字").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("存储") { s.hotwords = text; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear { text = s.hotwords }
    }
}

// MARK: - 笔内录音

struct PenRecordingsSection: View {
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var s: AppSettings
    @State private var showAll = false

    var body: some View {
        let recs = pipeline.displayRecordings.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        let done = recs.filter { pipeline.status(of: $0) == .done }.count
        Section {
            if recs.isEmpty {
                Text(pipeline.penConnected || pipeline.wifiStatus != nil ? "笔里还没有录音" : "插上录音笔或 WiFi 在线后显示").foregroundStyle(.secondary)
            }
            ForEach(showAll ? recs : Array(recs.prefix(6)), id: \.wavPath) { r in
                LabeledContent {
                    statusView(pipeline.status(of: r))
                } label: {
                    Text(r.title)
                    Text([r.created.map { DateFormatter.cached("M月d日 HH:mm").string(from: $0) }, MarkdownRenderer.duration(r.durationSec),
                          s.place(for: r.bssids)]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            if recs.count > 6 {
                Button(showAll ? "收起" : "显示全部 \(recs.count) 条") { showAll.toggle() }.buttonStyle(.link)
            }
        } header: {
            HStack {
                SectionTitle("笔内录音", info: "每条录音按「待上传 → 已上传·待取回 → 排队中 → 转写中 → 已转写」走一遍；插着数据线时直接从 USB 拷贝。同一条录音只转写一次，不会重复收费。已转写的录音在 Mac 上有纪要，可以放心在笔上删除。")
                Spacer()
                if !recs.isEmpty { Text("\(recs.count) 条 · 已转写 \(done) 条").font(.callout).fontWeight(.regular).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func statusView(_ st: Pipeline.RecordingStatus) -> some View {
        switch st {
        case .done: StatusTag(text: "已转写", color: .e1Green)
        case .working: StatusTag(text: "转写中", color: .e1Blue)
        case .waiting: StatusTag(text: "排队中", color: .secondary)
        case .failed: StatusTag(text: "转写失败", color: .e1Red)
        case .tooShort: StatusTag(text: "太短", color: .secondary)
        case .notCopied: StatusTag(text: "未转写", color: .orange)
        case .uploaded: StatusTag(text: "已上传·待取回", color: .e1Blue)
        case .pendingUpload: StatusTag(text: "待上传", color: .orange)
        case .removed: StatusTag(text: "已移除", color: .secondary)
        case .recording: StatusTag(text: "录音中", color: .e1Red)
        }
    }
}

/// Small coloured capsule label.
struct StatusTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - 新版本提示（面板顶部）

struct UpdateBanner: View {
    @EnvironmentObject var pipeline: Pipeline
    var body: some View {
        if pipeline.showUpdateBanner, let v = pipeline.updateVersion {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.e1Blue)
                Text("有新版本 \(v)").font(.e1Body)
                Spacer()
                Button("下载") { NSWorkspace.shared.open(AppLinks.releases) }.buttonStyle(.e1Link)
                Button { pipeline.dismissUpdate() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(IconButtonStyle()).help("不再提示这个版本")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.e1Blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }
}

// MARK: - WiFi 无线同步：设置与教程（引导第二页、设备页「WiFi 设置」共用）

struct WifiGuideView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var editingPenKey = false
    @State private var editingMacKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var installing = false
    @State private var installResult = ""
    @State private var copied = ""

    var body: some View {
        Form {
            Section {
                Text("录音笔连上 WiFi 后，会把新录音上传到你自己阿里云账号里的一个存储空间（相当于信箱）。这台 Mac 开着本应用时，自动从信箱取回录音、转写成纪要，再清空信箱。Mac 关着时录音就在信箱里等着，30 天内取回即可。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("工作原理") }

            Section {
                LabeledContent("存储空间名称") {
                    TextField("存储空间名称", text: $s.ossBucket, prompt: Text("例如 my-e1-inbox-2026")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
                }
                LabeledContent("地域节点") {
                    TextField("地域节点", text: $s.ossEndpoint, prompt: Text("oss-cn-beijing.aliyuncs.com")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
                }
            } header: {
                StepHeader(number: 1, title: "创建存储空间", done: !s.ossBucket.isEmpty, status: s.ossBucket.isEmpty ? "填写名称" : "已填写")
            } footer: {
                Text(.init("OSS 控制台 › Bucket 列表 › 创建 Bucket：地域选和转写相同的「华北2（北京）」，读写权限「私有」，其余默认。再进入这个存储空间 › 数据管理 › 生命周期 › 创建规则：前缀 `pen/`，最后修改 30 天后删除。[打开 OSS 控制台…](https://oss.console.aliyun.com/bucket)"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }

            Section {
                LabeledContent {
                    HStack { Button("复制") { copy(penPolicy, "pen") }; if copied == "pen" { Text("已复制").foregroundStyle(.secondary) } }
                } label: { Text("录音笔策略 E1PenUploadOnly"); Text("只能往 pen/ 目录上传") }
                LabeledContent {
                    HStack { Button("复制") { copy(macPolicy, "mac") }; if copied == "mac" { Text("已复制").foregroundStyle(.secondary) } }
                } label: { Text("Mac 策略 E1MacReadDelete"); Text("只能列出、读取、删除 pen/ 目录") }
            } header: {
                StepHeader(number: 2, title: "创建两份权限策略", done: false, status: "在阿里云里完成")
            } footer: {
                Text(.init("访问控制 › 权限策略 › 创建权限策略 › 脚本编辑，分别粘贴上面复制的内容（已换成你的存储空间名称），按括号里的名字保存。[打开访问控制…](https://ram.console.aliyun.com/policies)"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }

            Section {
                LabeledContent {
                    HStack { Trailing(text: s.penKeyStored ? "已存入钥匙串" : "未填写"); Button(s.penKeyStored ? "修改…" : "填写…") { editingPenKey = true } }
                } label: { Text("录音笔用钥匙"); Text("子账号 e1-pen-uploader，授权 E1PenUploadOnly") }
                LabeledContent {
                    HStack { Trailing(text: s.macKeyStored ? "已存入钥匙串" : "未填写"); Button(s.macKeyStored ? "修改…" : "填写…") { editingMacKey = true } }
                } label: { Text("Mac 用钥匙"); Text("子账号 e1-mac-reader，授权 E1MacReadDelete") }
            } header: {
                StepHeader(number: 3, title: "创建两个子账号并填写钥匙", done: s.penKeyStored && s.macKeyStored,
                           status: s.penKeyStored && s.macKeyStored ? "已填写" : "需要两把钥匙")
            } footer: {
                Text(.init("访问控制 › 用户 › 创建用户，访问方式只勾「使用永久 AccessKey 访问」，不要开控制台登录；建好后点「添加权限」选对应策略。钥匙只保存在这台 Mac 的钥匙串里。[打开用户列表…](https://ram.console.aliyun.com/users)"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }

            Section {
                LabeledContent("连接测试") {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        if let r = testResult { r.isEmpty ? AnyView(HStack(spacing: 6) { Dot(kind: .ok); Text("两把钥匙都正常") }) : AnyView(HStack(spacing: 6) { Dot(kind: .bad); Text(r).lineLimit(2) }) }
                        Button("测试") { Task { await test() } }.disabled(testing || s.ossBucket.isEmpty || !s.penKeyStored || !s.macKeyStored)
                    }
                }
                LabeledContent {
                    HStack {
                        if installing { ProgressView().controlSize(.small) }
                        Trailing(text: installResult.isEmpty ? installState : installResult)
                        Button(pipeline.pen?.wifiInstalled == true ? "更新…" : "安装…") { confirmInstall() }
                            .disabled(!pipeline.penConnected || installing || !s.penKeyStored || s.ossBucket.isEmpty)
                        if pipeline.pen?.wifiInstalled == true {
                            Button("卸载…") { confirmUninstall() }.disabled(!pipeline.penConnected || installing)
                        }
                    }
                } label: { Text("录音笔上传程序"); Text("需要用数据线连接录音笔") }
                Toggle("启用 WiFi 同步", isOn: $s.wifiEnabled).toggleStyle(.switch)
            } header: {
                StepHeader(number: 4, title: "测试并安装到录音笔", done: s.wifiEnabled && pipeline.pen?.wifiInstalled == true,
                           status: s.wifiEnabled ? "已启用" : "未启用")
            } footer: {
                Text("上传程序只放在录音笔的 /userdata/e1wifi 文件夹（约 6 MB），并在开机脚本里多启动一行；不改系统、不碰原有录音，随时可以在这里卸载。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $editingPenKey) { KeyPairSheet(pen: true) }
        .sheet(isPresented: $editingMacKey) { KeyPairSheet(pen: false) }
    }

    private var installState: String {
        guard pipeline.penConnected, let pen = pipeline.pen else { return "未连接录音笔" }
        if let c = pipeline.penComponents {
            switch c.uploader {
            case .missing: return "未安装"
            case .outdated: return "\(c.uploaderVersion ?? "旧版")，可更新到 \(Bundled.uploaderVersion)"
            case .current: return "\(Bundled.uploaderVersion) · " + (c.uploaderRunning ? "运行中" : "未运行")
            }
        }
        if !pen.wifiInstalled { return "未安装" }
        return pen.wifiRunning ? "已安装 · 运行中" : "已安装 · 未运行"
    }

    private var bucket: String { s.ossBucket.isEmpty ? "你的存储空间名称" : s.ossBucket }
    private var penPolicy: String {
        #"{"Version": "1", "Statement": [{"Effect": "Allow", "Action": ["oss:PutObject"], "Resource": ["acs:oss:*:*:"# + bucket + #"/pen/*"]}]}"#
    }
    private var macPolicy: String {
        #"{"Version": "1", "Statement": [{"Effect": "Allow", "Action": ["oss:ListObjects"], "Resource": ["acs:oss:*:*:"# + bucket +
        #""], "Condition": {"StringLike": {"oss:Prefix": ["pen/*"]}}}, {"Effect": "Allow", "Action": ["oss:GetObject", "oss:DeleteObject"], "Resource": ["acs:oss:*:*:"# +
        bucket + #"/pen/*"]}]}"#
    }

    private func copy(_ text: String, _ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
    }

    private func test() async {
        testing = true
        defer { testing = false }
        if UIPreview.enabled { try? await Task.sleep(nanoseconds: 600_000_000); testResult = ""; return }
        let r = await pipeline.testWifi()
        testResult = r ?? ""
        if r == nil { s.wifiEnabled = true }
    }

    private func confirmInstall() {
        guard PenWrite.confirm(.uploader, update: pipeline.pen?.wifiInstalled == true) else { return }
        Task {
            installing = true
            installResult = await pipeline.installWifi()
            installing = false
        }
    }

    private func confirmUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "从录音笔卸载上传程序？"
        a.informativeText = "会停止上传并删除录音笔上的 /userdata/e1wifi 文件夹。已经上传、还没取回的录音仍在存储空间里，Mac 会照常取回。"
        a.addButton(withTitle: "卸载")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            installing = true
            installResult = await pipeline.uninstallWifi()
            installing = false
        }
    }
}

/// AccessKey ID + Secret for one of the two sub-accounts, stored in the Keychain.
struct KeyPairSheet: View {
    let pen: Bool
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pen ? "录音笔用钥匙" : "Mac 用钥匙").font(.headline)
            Text(pen ? "子账号 e1-pen-uploader 的 AccessKey。安装上传程序时会通过数据线写到录音笔上，它只能往存储空间的 pen/ 目录上传。"
                     : "子账号 e1-mac-reader 的 AccessKey，只保存在这台 Mac 的钥匙串里，用来取回录音。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("AccessKey ID", text: $id).textFieldStyle(.roundedBorder)
            SecureField("AccessKey Secret", text: $secret).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("存储") { s.saveWifiKey(pen: pen, id: id, secret: secret); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(id.count < 16 || secret.count < 16)
            }
        }
        .padding(20).frame(width: 420)
    }
}


// MARK: - 录音地点

/// Networks the pen has been on; naming one turns it into a place shown on recordings and notes.
struct PlacesSection: View {
    @EnvironmentObject var s: AppSettings
    @State private var naming: String?
    @State private var showAll = false

    var body: some View {
        // Named places first, then the networks still waiting for a name.
        let ssids = Set(s.knownNetworks.values.filter { !$0.isEmpty })
        let name = { (ssid: String) in s.placeNames[ssid].flatMap { $0.isEmpty ? nil : $0 } }
        let networks = ssids.sorted { a, b in
            switch (name(a), name(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        Section {
            if networks.isEmpty {
                Text("还没有录音笔连过的 WiFi").foregroundStyle(.secondary)
            }
            ForEach(showAll ? networks : Array(networks.prefix(5)), id: \.self) { ssid in
                HStack(spacing: 10) {
                    if let place = name(ssid) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 15)).foregroundStyle(Color.e1Blue).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place)
                            Text(ssid).font(.e1Sub).foregroundStyle(Color.t2)
                        }
                        Spacer()
                        Button("重命名…") { naming = ssid }
                    } else {
                        Image(systemName: "wifi").font(.system(size: 13)).foregroundStyle(Color.t3).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ssid)
                            Text("未命名").font(.e1Sub).foregroundStyle(Color.t2)
                        }
                        Spacer()
                        Button("命名…") { naming = ssid }
                    }
                }
            }
            if networks.count > 5 {
                Button(showAll ? "收起" : "显示全部 \(networks.count) 个") { withAnimation { showAll.toggle() } }.buttonStyle(.link)
            }
        } header: {
            SectionTitle("录音地点", info: "录音笔会记下录音时周围的 WiFi。给网络起个名字（如「公司」「家」）后，录音和纪要里会显示这个地点；没命名的网络不会写进纪要。只存在这台 Mac 上。")
        }
        .sheet(item: Binding(get: { naming.map { NamedSSID(id: $0) } }, set: { naming = $0?.id })) { item in
            EditSheet(title: "给「\(item.id)」起个地点名", help: "例如：公司、家、客户现场。留空则显示网络名。", placeholder: "地点名",
                      initial: s.placeNames[item.id] ?? "", validate: { $0.count <= 12 ? nil : "最多 12 个字" },
                      save: { s.placeNames[item.id] = $0 })
        }
    }

    struct NamedSSID: Identifiable { let id: String }
}

// MARK: - 录音笔上的程序

/// Asks before anything is written to the pen, saying exactly what goes where.
enum PenWrite {
    @MainActor static func confirm(_ kind: PenComponentRow.Kind, update: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        switch kind {
        case .clock:
            a.messageText = update ? "更新录音笔上的校时脚本？" : "把校时脚本安装到录音笔？"
            a.informativeText = """
            会通过数据线写入录音笔的用户数据分区：
            • /userdata/e1sync/e1sync.sh：校时脚本（几 KB）
            • /userdata/cfg/rockchip_test/auto_reboot.sh：开机时启动它

            搜狗的对时服务器已经关闭。装上后，录音笔联网时会自动对时，断电重启后也能恢复时间，录音的时间才准确。不改系统分区和固件，不动笔里的录音和设置。
            """
        case .uploader:
            a.messageText = update ? "更新录音笔上的上传程序？" : "把上传程序安装到录音笔？"
            a.informativeText = """
            会通过数据线写入录音笔的用户数据分区：
            • /userdata/e1wifi/e1wifi：上传程序（约 6 MB）
            • /userdata/e1wifi/config.json：存储空间名称和「只能上传」的钥匙
            • /userdata/cfg/rockchip_test/auto_reboot.sh：开机时多启动上传程序这一行

            不改系统分区和固件，不动笔里的录音和设置。之后录音笔连上 WiFi 就会自动上传新录音；随时可以卸载。
            """
        case .hook:
            a.messageText = "修复录音笔的开机脚本？"
            a.informativeText = "会重写 /userdata/cfg/rockchip_test/auto_reboot.sh。它在录音笔开机时启动校时脚本和上传程序（装了哪个启动哪个），不做别的事。"
        }
        a.addButton(withTitle: update ? "更新" : (kind == .hook ? "修复" : "安装"))
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// One of our programs on the pen: what it does, whether it's there and current, one click to install or update.
struct PenComponentRow: View {
    enum Kind { case clock, uploader, hook }
    let kind: Kind
    var onSetUpWifi: (() -> Void)? = nil
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var working = false
    @State private var result: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                if let result { Text(result).foregroundStyle(.secondary).lineLimit(1) } else if !working { tag }
                action.disabled(working)
            }
        } label: {
            Text(title)
        }
    }

    private var title: String {
        switch kind { case .clock: "校时脚本"; case .uploader: "WiFi 上传程序"; case .hook: "开机自启" }
    }
    private var subtitle: String {
        switch kind {
        case .clock: "联网自动对时，断电重启后时间也准（建议安装）"
        case .uploader: "录音笔连上 WiFi 自动上传新录音（可选）"
        case .hook: "录音笔开机时启动上面的程序"
        }
    }
    private var comps: PenComponents? { pipeline.penConnected ? pipeline.penComponents : nil }
    private var state: PenComponents.State? {
        guard let c = comps else { return nil }
        switch kind { case .clock: return c.clock; case .uploader: return c.uploader; case .hook: return c.hook }
    }
    private var running: Bool {
        switch kind { case .clock: comps?.clockRunning == true; case .uploader: comps?.uploaderRunning == true; case .hook: true }
    }
    private var wifiConfigured: Bool { s.penKeyStored && !s.ossBucket.isEmpty }

    /// One vocabulary for all three: 已是最新 · 可更新 · 未运行 · 未安装 (versions in the tooltip).
    @ViewBuilder private var tag: some View {
        if !pipeline.penConnected {
            if kind == .uploader, let v = pipeline.wifiStatus?.version {
                // Known from the WiFi heartbeat even without the cable.
                let newer = v.compare(Bundled.uploaderVersion, options: .numeric) == .orderedAscending
                StatusTag(text: newer ? "可更新" : "已是最新", color: newer ? .e1Blue : .e1Green)
                    .help(newer ? "录音笔上是 \(v)，可更新到 \(Bundled.uploaderVersion)" : "版本 \(v)")
            } else {
                Text("未连接").foregroundStyle(.secondary)
            }
        } else if let st = state {
            switch st {
            case .missing: StatusTag(text: "未安装", color: .secondary)
            case .outdated:
                StatusTag(text: "可更新", color: .e1Blue)
                    .help(kind == .uploader ? "录音笔上是 \(comps?.uploaderVersion ?? "旧版")，可更新到 \(Bundled.uploaderVersion)" : "应用里有更新的版本")
            case .current:
                StatusTag(text: running ? "已是最新" : "未运行", color: running ? .e1Green : .orange)
                    .help(kind == .uploader ? "版本 \(comps?.uploaderVersion ?? Bundled.uploaderVersion)" + (running ? "，运行中" : "") : (running && kind != .hook ? "运行中" : ""))
            }
        } else {
            Text("检查中…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if let st = state {
            if kind == .uploader, st != .current, !wifiConfigured {
                if let onSetUpWifi { Button("设置 WiFi…") { onSetUpWifi() } }
            } else {
                switch st {
                case .missing: Button(kind == .hook ? "修复…" : "安装…") { write(update: false) }
                case .outdated: Button("更新…") { write(update: true) }
                case .current: if !running { Button("启动") { start() } }
                }
            }
        }
    }

    private func write(update: Bool) {
        guard PenWrite.confirm(kind, update: update) else { return }
        Task {
            working = true
            let r: String
            switch kind {
            case .clock: r = await pipeline.installClockScript()
            case .uploader: r = await pipeline.installWifi()
            case .hook: r = await pipeline.installHook()
            }
            working = false
            show(r)
        }
    }

    private func start() {
        Task {
            working = true
            let r = await pipeline.startPenProgram(kind == .clock ? .clock : .uploader)
            working = false
            show(r)
        }
    }

    private func show(_ r: String) {
        result = r
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if result == r { result = nil } }
    }
}

/// Everything of ours on the pen in one place (Preferences › 设备).
struct PenComponentsSection: View {
    var onSetUpWifi: (() -> Void)? = nil
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        Section {
            PenComponentRow(kind: .clock)
            PenComponentRow(kind: .uploader, onSetUpWifi: onSetUpWifi)
            PenComponentRow(kind: .hook)
        } header: {
            HStack {
                SectionTitle("录音笔上的程序", info: "都内置在本应用里，只写在录音笔的数据分区（/userdata），不改系统和固件，不动笔里的录音。安装和更新需要用数据线连接；应用升级后，插上录音笔会提示更新。")
                Spacer()
                if pipeline.penConnected {
                    Button("重新检查") { Task { await pipeline.refreshComponents() } }.buttonStyle(.link).font(.callout)
                }
            }
        }
    }
}
