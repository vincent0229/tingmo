import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlatformPage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @ObservedObject private var recorder = MacRecorder.shared
    @Environment(\.openSubpage) private var openSubpage
    @State private var testing = false
    @State private var showAll = false
    @State private var dropTargeted = false

    private var active: [Job] {
        pipeline.jobs.filter { $0.state == .queued || $0.state == .transcribing }.sorted { $0.updated < $1.updated }
    }
    private var finished: [Job] {
        pipeline.jobs.filter { $0.state == .done || $0.state == .failed }.sorted { $0.created > $1.created }
    }
    /// The job the steps follow: the one being worked on, else the next in line.
    private var focus: Job? { active.first { pipeline.phases[$0.id] != nil } ?? active.first }

    var body: some View {
        Form {
            serviceSection
            workSection
            recordsSection
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { AudioImport.isAudio($0) }
            guard !audio.isEmpty else { return false }
            Task { await pipeline.importFiles(audio) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { pipeline.refreshNoteLocations() }
    }

    // MARK: service — which platform, is it reachable, what it costs

    private var serviceSection: some View {
        Section {
            HStack(spacing: 12) {
                VendorBadge(vendor: Vendor.of(s))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(s.provider.info.name).font(.e1Title)
                        ConnectionPill(testing: testing, state: s.setupProblem == nil ? s.connState : "notready", checked: PlatformTest.lastChecked,
                                       hasKey: s.hasAPIKey && s.setupProblem == nil) {
                            Task { testing = true; await PlatformTest.run(s); testing = false }
                        }
                    }
                    if s.connState.hasPrefix("failed:"), s.setupProblem == nil {
                        Text(String(s.connState.dropFirst(7))).font(.e1Sub).foregroundStyle(Color.e1Red).lineLimit(1)
                            .help(String(s.connState.dropFirst(7)))
                    } else {
                        Text(providerIntro).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button { openSubpage("platform-settings") } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("服务选项").accessibilityLabel("服务选项")
            }
            .padding(.vertical, 4)
            if let problem = s.setupProblem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).foregroundStyle(Color.t1)
                    Spacer()
                    Button("去设置") { openSubpage("platform-settings") }
                }
            }
            LabeledContent("识别模型", value: asrModel)
            LabeledContent("整理模型", value: llmModel)
            UsageRow(slices: pipeline.monthUsageBySource, budget: s.budgetYuan)
        }
    }

    private var providerIntro: String {
        switch s.provider {
        case .tingwu: "阿里云 · 转写、说话人区分、摘要与待办一次完成"
        case .bailian: "阿里云百炼 · Fun-ASR 语音转写，千问整理成纪要"
        case .custom: "OpenAI 兼容接口 · " + (URL(string: s.customEndpoint)?.host ?? "未填写地址")
        }
    }
    private var asrModel: String {
        if s.provider == .custom { return s.customASRModel }
        return s.provider.info.models.first { $0.id == s.transcriptionModel }?.label ?? s.transcriptionModel
    }
    private var llmModel: String {
        switch s.provider {
        case .custom: s.customLLMModel
        case .bailian: PlatformInfo.llmModels.first { $0.id == s.llmModel }?.label ?? s.llmModel
        case .tingwu: "听悟内置"
        }
    }

    // MARK: record, import, and the way to a note

    private var workSection: some View {
        Section {
            RecorderBar(recorder: recorder, dropTargeted: dropTargeted) { chooseAndImport() }
            PipelineSteps(focus: focus, recorder: recorder, queued: max(0, active.count - 1), blocked: s.setupProblem != nil)
        } header: {
            Text("录音与转写")
        }
    }

    private func confirmClean(_ n: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "清理 \(n) 条无内容记录？"
        a.informativeText = "这些录音没有识别到内容。会从列表移除，相应的纪要和这台 Mac 上的录音副本移到废纸篓（可以找回）。录音笔里的原始录音不受影响，也不会再被导入。"
        a.addButton(withTitle: "清理")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { _ = pipeline.cleanEmptyRecords() }
    }

    private func chooseAndImport() {
        guard let urls = AudioImport.choose() else { return }
        Task { await pipeline.importFiles(urls) }
    }

    // MARK: records

    private var recordsSection: some View {
        Section {
            if finished.isEmpty {
                Text("还没有转写记录").foregroundStyle(.secondary)
            } else {
                ForEach(showAll ? finished : Array(finished.prefix(8))) { JobListRow(job: $0) }
                if finished.count > 8 {
                    Button(showAll ? "收起" : "显示全部 \(finished.count) 条") { withAnimation { showAll.toggle() } }
                        .buttonStyle(.link)
                }
            }
        } header: {
            HStack {
                Text("转写记录")
                Spacer()
                let empty = finished.filter { pipeline.isEmptyRecord($0) }.count
                if empty > 0 {
                    Button("清理无内容记录（\(empty)）") { confirmClean(empty) }.buttonStyle(.link).font(.callout)
                }
            }
        }
    }
}

/// Connection state and the test button in one pill: "● 已连接 | ↻".
struct ConnectionPill: View {
    let testing: Bool
    let state: String
    let checked: Date?
    let hasKey: Bool
    let test: () -> Void

    private var ok: Bool { state == "ok" }
    private var failed: Bool { state.hasPrefix("failed:") }

    var body: some View {
        HStack(spacing: 7) {
            if testing {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(ok ? Color.e1Green : failed ? Color.e1Red : state == "notready" ? Color.orange : Color.t3).frame(width: 7, height: 7)
            }
            Text(testing ? "测试中…" : ok ? "已连接" : failed ? "连接失败" : state == "notready" ? "未设置" : hasKey ? "未测试" : "未填密钥")
                .font(.e1Sub.weight(.medium)).foregroundStyle(failed ? Color.e1Red : Color.t1)
            Rectangle().fill(Color.e1Sep).frame(width: 1, height: 12)
            Button(action: test) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Color.t2).disabled(testing || !hasKey)
            .help("测试连接").accessibilityLabel("测试连接")
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(failed ? String(state.dropFirst(7)) : checked.map { "上次检查：" + DateFormatter.cached("M月d日 HH:mm").string(from: $0) } ?? "")
    }
}

/// Who runs the service, for the mark in front of its name.
enum Vendor {
    case aliyun, tencent, iflytek, openai, generic

    @MainActor static func of(_ s: AppSettings) -> Vendor {
        switch s.provider {
        case .tingwu, .bailian: return .aliyun
        case .custom:
            let host = (URL(string: s.customEndpoint)?.host ?? "").lowercased()
            if host.contains("aliyun") || host.contains("dashscope") { return .aliyun }
            if host.contains("tencent") || host.contains("hunyuan") { return .tencent }
            if host.contains("xfyun") || host.contains("iflytek") { return .iflytek }
            if host.contains("openai") { return .openai }
            return .generic
        }
    }
}

/// The vendor's mark on a light tile: Alibaba Cloud's orange bracket, otherwise the vendor's colour and short name.
struct VendorBadge: View {
    let vendor: Vendor
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tileFill)
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            switch vendor {
            case .aliyun:
                Canvas { ctx, sz in
                    // [ — ] in Alibaba Cloud orange
                    let w = sz.width * 0.66, h = sz.height * 0.36, t = sz.width * 0.085
                    let x0 = (sz.width - w) / 2, y0 = (sz.height - h) / 2, arm = w * 0.26
                    let orange = GraphicsContext.Shading.color(Color(red: 1, green: 0.416, blue: 0))
                    var p = Path()
                    p.addRoundedRect(in: CGRect(x: x0, y: y0, width: t, height: h), cornerSize: CGSize(width: t / 3, height: t / 3))
                    p.addRect(CGRect(x: x0, y: y0, width: arm, height: t))
                    p.addRect(CGRect(x: x0, y: y0 + h - t, width: arm, height: t))
                    p.addRoundedRect(in: CGRect(x: x0 + w - t, y: y0, width: t, height: h), cornerSize: CGSize(width: t / 3, height: t / 3))
                    p.addRect(CGRect(x: x0 + w - arm, y: y0, width: arm, height: t))
                    p.addRect(CGRect(x: x0 + w - arm, y: y0 + h - t, width: arm, height: t))
                    p.addRect(CGRect(x: x0 + w * 0.36, y: y0 + h / 2 - t / 2, width: w * 0.28, height: t))
                    ctx.fill(p, with: orange)
                }
            case .tencent: mark("腾讯", .white)
            case .iflytek: mark("讯飞", .white)
            case .openai: mark("AI", .white)
            case .generic:
                Image(systemName: "server.rack").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color.t2)
            }
        }
        .frame(width: size, height: size)
    }

    private var tileFill: Color {
        switch vendor {
        case .aliyun, .generic: Color(nsColor: .controlBackgroundColor)
        case .tencent: Color(red: 0, green: 0.322, blue: 0.851)
        case .iflytek: Color(red: 0.11, green: 0.42, blue: 0.95)
        case .openai: Color.black
        }
    }

    private func mark(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(c)
    }
}

/// This month's use as a storage-style bar: one segment per source, the whole bar = the budget when one is set.
struct UsageRow: View {
    let slices: [Pipeline.UsageSlice]
    let budget: Int

    private static let colors: [String: Color] = ["录音笔": .e1Blue, "导入": .orange, "Mac 录音": .e1Green]
    private var yuan: Double { slices.reduce(0) { $0 + $1.yuan } }
    private var hours: Double { slices.reduce(0) { $0 + $1.hours } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("本月用量")
                Spacer()
                Text(budget > 0 ? String(format: "¥%.1f / ¥%d", yuan, budget) : String(format: "¥%.1f", yuan))
                    .font(.e1Sub).foregroundStyle(Color.t2)
            }
            GeometryReader { geo in
                let total = max(Double(budget), yuan, 0.0001)
                HStack(spacing: 1.5) {
                    ForEach(slices) { sl in
                        Rectangle().fill(Self.colors[sl.id] ?? .gray)
                            .frame(width: max(sl.yuan > 0 ? 3 : 0, geo.size.width * sl.yuan / total))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                if slices.isEmpty {
                    Text("本月还没有转写").font(.e1Sub).foregroundStyle(Color.t3)
                } else {
                    ForEach(slices) { sl in
                        HStack(spacing: 5) {
                            Circle().fill(Self.colors[sl.id] ?? .gray).frame(width: 7, height: 7)
                            Text(sl.id + " " + (sl.hours >= 1 ? String(format: "%.1f 小时", sl.hours) : "\(max(1, Int((sl.hours * 60).rounded()))) 分钟"))
                                .font(.e1Sub).foregroundStyle(Color.t2)
                        }
                    }
                }
                Spacer()
                if budget > 0, yuan / Double(budget) >= 0.8 {
                    Text("已用预算 \(Int(yuan / Double(budget) * 100))%").font(.e1Sub).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .help(String(format: "本月共转写 %.1f 小时，按官方价格估算约 ¥%.1f", hours, yuan))
    }
}

/// 录音 and 导入音频 as ordinary buttons; while recording: pause, stop, level and time.
struct RecorderBar: View {
    @ObservedObject var recorder: MacRecorder
    let dropTargeted: Bool
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if recorder.isRecording {
                Button { recorder.isPaused ? recorder.resume() : recorder.pause() } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.t1)
                        .frame(width: 26, height: 26).background(Circle().strokeBorder(Color.t3, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(recorder.isPaused ? "继续录音" : "暂停")
                .accessibilityLabel(recorder.isPaused ? "继续录音" : "暂停录音")
                Button { recorder.stop() } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white).frame(width: 9, height: 9)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.e1Red))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("停止，开始转写").accessibilityLabel("停止录音")
                LevelBars(levels: Array(recorder.history.suffix(14)), color: recorder.isPaused ? Color.t3 : Color.e1Red, maxHeight: 18)
                    .frame(width: 52, height: 20)
                Text(recorder.elapsedText).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? Color.t2 : Color.t1)
                Text(recorder.isPaused ? "已暂停" : "录音中").font(.e1Sub).foregroundStyle(Color.t2)
            } else {
                Button { Task { await recorder.start() } } label: {
                    Label { Text("开始录音") } icon: { Image(systemName: "mic.fill").foregroundStyle(Color.e1Red) }
                }
                .buttonStyle(CapsuleActionStyle())
                .help("用这台 Mac 的麦克风录音，停止后自动转写")
                Button(action: onImport) {
                    Label { Text("上传音频") } icon: { Image(systemName: "square.and.arrow.up.fill").foregroundStyle(Color.e1Blue) }
                }
                .buttonStyle(CapsuleActionStyle())
                .help("选择本机上的录音文件，也可以直接拖到这一页")
            }
            Spacer(minLength: 8)
            Text(trailing).font(.e1Sub).lineLimit(1)
                .foregroundStyle(recorder.noteIsError || (!recorder.hasMicrophone && !recorder.isRecording) ? Color.e1Red
                                 : dropTargeted ? Color.e1Blue : Color.t2)
        }
        .padding(.vertical, 3)
        .animation(.easeOut(duration: 0.2), value: recorder.isRecording)
    }

    private var trailing: String {
        if let n = recorder.note { return n }
        if dropTargeted { return "松开即可导入" }
        if !recorder.hasMicrophone && !recorder.isRecording { return "没有可用的麦克风" }
        return "麦克风：" + (recorder.micName.isEmpty ? "系统默认" : recorder.micName)
    }
}

/// Vertical level bars, newest on the right.
struct LevelBars: View {
    let levels: [Float]
    let color: Color
    var maxHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: 2, height: max(3, CGFloat(levels[i]) * maxHeight))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.linear(duration: 0.1), value: levels)
    }
}

/// 录音/音频 → 上传 → 云端转写 → 存到本地: small nodes on a line, grey at 0% when nothing is going on.
struct PipelineSteps: View {
    @EnvironmentObject var pipeline: Pipeline
    let focus: Job?
    @ObservedObject var recorder: MacRecorder
    var queued = 0
    var blocked = false

    enum StepState: Equatable { case idle, active(Double?), done, waiting }
    struct Step { let symbol: String; let title: String; let state: StepState; let detail: String }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let steps = makeSteps(ctx.date)
            HStack(alignment: .top, spacing: 0) {
                ForEach(steps.indices, id: \.self) { i in
                    VStack(spacing: 5) {
                        ZStack {
                            HStack(spacing: 0) {
                                Rectangle().fill(i == 0 ? Color.clear : line(steps[i - 1])).frame(height: 2)
                                Color.clear.frame(width: 28)
                                Rectangle().fill(i == steps.count - 1 ? Color.clear : line(steps[i])).frame(height: 2)
                            }
                            StepNode(step: steps[i])
                        }
                        .frame(height: 28)
                        Text(steps[i].title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(steps[i].state == .idle ? Color.t2 : Color.t1)
                        Text(steps[i].detail).font(.e1Sub.monospacedDigit()).foregroundStyle(Color.t2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func line(_ from: Step) -> Color { from.state == .done ? Color.e1Green.opacity(0.7) : Color.primary.opacity(0.1) }

    private func makeSteps(_ now: Date) -> [Step] {
        var s1: StepState = .idle, s2: StepState = .idle, s3: StepState = .idle, s4: StepState = .idle
        var d1 = "等待音频", d2 = "0%", d3 = "0%", d4 = "0%"
        if recorder.isRecording {
            s1 = .active(nil); d1 = (recorder.isPaused ? "暂停 " : "") + recorder.elapsedText
        } else if let f = focus {
            s1 = .done; d1 = MarkdownRenderer.duration(f.durationSec) + (queued > 0 ? " · 另 \(queued) 条" : "")
        } else if let c = pipeline.lastCompleted, now.timeIntervalSince(c.at) < 10 {
            // Just saved: show the whole way done for a moment, then back to idle.
            return [
                Step(symbol: "mic.fill", title: "录音 / 音频", state: .done, detail: MarkdownRenderer.duration(c.durationSec)),
                Step(symbol: "arrow.up", title: "上传音频", state: .done, detail: "100%"),
                Step(symbol: "waveform", title: "云端转写", state: .done, detail: "100%"),
                Step(symbol: "doc.text", title: "存到本地", state: .done, detail: "已保存"),
            ]
        }
        if let f = focus {
            switch pipeline.phases[f.id] {
            case .compressing?:
                s2 = .active(nil); d2 = "压缩中"
            case .uploading(let p)?:
                s2 = .active(p); d2 = p.map { "\(Int($0 * 100))%" } ?? "上传中"
            case .transcribing(let since)?:
                s2 = .done; d2 = "100%"; s3 = .active(nil); d3 = "已用 " + JobText.clock(now.timeIntervalSince(since))
            case .writing?:
                s2 = .done; d2 = "100%"; s3 = .done; d3 = "100%"; s4 = .active(nil); d4 = "写入中"
            case .waiting(let until)?:
                let left = "等网络 \(max(0, Int(until.timeIntervalSince(now))))s"
                if f.state == .transcribing { s2 = .done; d2 = "100%"; s3 = .waiting; d3 = left } else { s2 = .waiting; d2 = left }
            case nil:
                if f.state == .transcribing { s2 = .done; d2 = "100%"; s3 = .active(nil); d3 = "云端处理中" }
                else if blocked { s2 = .waiting; d2 = "等待设置" }
                else { d2 = "排队中" }
            }
        }
        return [
            Step(symbol: "mic.fill", title: "录音 / 音频", state: s1, detail: d1),
            Step(symbol: "arrow.up", title: "上传音频", state: s2, detail: d2),
            Step(symbol: "waveform", title: "云端转写", state: s3, detail: d3),
            Step(symbol: "doc.text", title: "存到本地", state: s4, detail: d4),
        ]
    }
}

struct StepNode: View {
    let step: PipelineSteps.Step

    var body: some View {
        ZStack {
            switch step.state {
            case .idle:
                Circle().fill(Color.e1Content)
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1.5)
                Image(systemName: step.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.t3)
            case .done:
                Circle().fill(Color.e1Green)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            case .active(let f):
                Circle().fill(Color.e1Content)
                Circle().fill(Color.e1Blue.opacity(0.14))
                Image(systemName: step.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.e1Blue)
                arc(f, Color.e1Blue)
            case .waiting:   // held up (no network, or not set up yet): orange, standing still
                Circle().fill(Color.e1Content)
                Circle().fill(Color.orange.opacity(0.16))
                Circle().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
                Image(systemName: step.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder private func arc(_ f: Double?, _ c: Color) -> some View {
        if let f {
            Circle().trim(from: 0, to: f).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        } else {
            TimelineView(.animation) { ctx in
                let a = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                Circle().trim(from: 0, to: 0.28).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(a - 90))
            }
        }
    }
}

/// Testing the transcription service (used by the 转写 page and its settings sub-page).
enum PlatformTest {
    /// When the connection was last tested.
    static var lastChecked: Date? { UserDefaults.standard.object(forKey: "connCheckedAt") as? Date }

    @MainActor static func run(_ s: AppSettings) async {
        defer { UserDefaults.standard.set(Date(), forKey: "connCheckedAt") }
        if UIPreview.enabled { try? await Task.sleep(nanoseconds: 800_000_000); s.connState = "ok"; return }
        guard let key = Pipeline.key(for: s.provider) else { s.connState = "failed:未填写访问密钥"; return }
        do {
            try await Pipeline.service(s.provider, settings: s, key: key).testConnection()
            s.connState = (s.provider.info.needsAppId && s.appId.isEmpty) ? "failed:未填写应用编号" : "ok"
        } catch {
            s.connState = "failed:" + error.localizedDescription
        }
    }
}

/// Choosing audio files to transcribe (menu bar panel and the 转写 page).
enum AudioImport {
    static let types: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .movie, .mpeg4Movie]

    @MainActor static func choose() -> [URL]? {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = types
        p.message = "选择本机上的录音文件（如语音备忘录导出的 m4a），可多选"
        p.prompt = "开始转写"
        return p.runModal() == .OK && !p.urls.isEmpty ? p.urls : nil
    }

    static func isAudio(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { t.conforms(to: $0) }
    }
}

/// A finished or failed job. Quiet by default (where it came from, when, how long); hovering offers 「打开」, or
/// 「重新生成」 when the local note is gone. Right-click for everything else.
struct JobListRow: View {
    @EnvironmentObject var pipeline: Pipeline
    let job: Job
    @State private var hover = false

    var body: some View {
        let local = !pipeline.noteMissing(job)
        let empty = pipeline.isEmptyRecord(job)
        HStack(spacing: 10) {
            Image(systemName: job.state == .failed ? "exclamationmark.circle.fill" : sourceSymbol)
                .font(.system(size: 13)).foregroundStyle(job.state == .failed ? Color.e1Red : Color.t2).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.displayName(job)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(empty || (job.state == .done && !local) ? Color.t2 : Color.t1)
                Text(JobText.meta(job, withSource: true)).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if empty {
                Text("没有识别到内容").font(.e1Sub).foregroundStyle(Color.t3)
            } else if pipeline.regenerating.contains(job.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("生成中").font(.e1Sub).foregroundStyle(Color.t2) }
            } else if job.state == .failed {
                Text("转写失败").font(.e1Sub).foregroundStyle(Color.e1Red)
                Button("重试") { pipeline.retry(job) }.controlSize(.small)
            } else if hover {
                if local {
                    Button("打开") { pipeline.openNote(job) }.controlSize(.small)
                } else if pipeline.inCloud(job) {
                    Button("重新生成") { pipeline.regenerateNote(job) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    if pipeline.inCloud(job) {
                        Image(systemName: "icloud.fill").foregroundStyle(Color.e1Blue)
                            .help("已在云端转写，结果也存在这台 Mac 上").accessibilityLabel("已在云端转写")
                    }
                    if local {
                        Image(systemName: "doc.text.fill").foregroundStyle(Color.e1Green).help("纪要在笔记库里").accessibilityLabel("本地有纪要")
                    } else {
                        Image(systemName: "doc.text").foregroundStyle(Color.t3)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color.t2).background(Circle().fill(Color.e1Group)).offset(x: 3, y: 2)
                            }
                            .help("本地纪要已删除或移出笔记库；鼠标移上来可重新生成").accessibilityLabel("本地纪要已删除")
                    }
                }
                .font(.system(size: 12))
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            switch job.state {
            case .done: if local { pipeline.openNote(job) }
            case .failed: pipeline.explainFailure(job)
            default: break
            }
        }
        .contextMenu { JobMenu(job: job) }
        .help(job.error ?? "")
    }

    /// Where the recording came from.
    private var sourceSymbol: String { job.sourceSymbol }
}

extension Job {
    /// Where the recording came from: pen over WiFi, pen over USB, this Mac's microphone, or an uploaded file.
    var sourceSymbol: String {
        if source.contains("WiFi") { return "wifi" }
        if source.contains("录音笔") { return "recordingtape" }
        if source.contains("Mac") { return "mic" }
        if source.contains("导入") { return "square.and.arrow.up" }
        return "waveform"
    }
}

enum JobText {
    /// "今天 09:39 · 29 秒", optionally "· 录音笔 WiFi".
    static func meta(_ job: Job, withSource: Bool = false) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(job.created) ? "今天 " : cal.isDateInYesterday(job.created) ? "昨天 " : DateFormatter.cached("M月d日 ").string(from: job.created)
        var s = day + DateFormatter.cached("HH:mm").string(from: job.created) + " · " + MarkdownRenderer.duration(job.durationSec)
        if withSource {
            s += " · " + job.source.replacingOccurrences(of: "搜狗 E1 ", with: "").replacingOccurrences(of: " · ", with: " ")
                .replacingOccurrences(of: "导入文件", with: "上传")
        }
        return s
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
