import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StoragePage: View {
    @EnvironmentObject var s: AppSettings
    struct Preview: Identifiable { let id: String; let name: String; let text: String; let customPath: String? }
    @State private var previewing: Preview?
    @State private var editingName = false
    @State private var editingHotwords = false

    private let captions: [String: String] = [
        "standard": "摘要、待办、章节、全文", "decision": "结论、议题、行动事项", "interview": "问答脉络、原话摘录",
        "lecture": "知识要点、课后任务", "brief": "只留摘要与待办",
    ]

    var body: some View {
        Form {
            Section {
                FolderRow(title: "保存位置", path: $s.notesFolder)
                Picker("格式", selection: $s.noteFormat) {
                    Text("Markdown").tag("md")
                    Text("Word").tag("docx")
                    Text("PDF").tag("pdf")
                }
                .pickerStyle(.segmented)
            } header: {
                SectionTitle("纪要", info: "Markdown 适合 Obsidian 等笔记软件，保存位置在 Obsidian 库里时，点开会直接用 Obsidian 打开；Word、PDF 方便转发给同事。")
            }

            Section {
                Toggle("保留录音文件", isOn: $s.keepAudio).toggleStyle(.switch)
                if s.keepAudio { FolderRow(title: "保存位置", path: $s.audioFolder) }
            } header: {
                SectionTitle("录音", info: "关闭后，纪要生成后就删掉这台 Mac 上的录音副本（包括本机录音），纪要里也不再附录音链接；录音笔里的原始录音不受影响。")
            }

            Section("纪要模板") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 12) {
                    ForEach(NoteTemplate.all) { t in
                        TemplateCard(name: t.name, caption: captions[t.id] ?? t.summary, selected: s.template == .builtin(t.id),
                                     onPreview: { previewing = .init(id: t.id, name: t.name, text: t.body, customPath: nil) }) {
                            TemplateThumb(id: t.id)
                        } action: {
                            s.template = .builtin(t.id)
                        }
                    }
                    customCard
                }
                .padding(.vertical, 6)
                TemplateFieldHelp()
            }

            Section {
                LabeledContent {
                    HStack {
                        Trailing(text: s.hotwordList.isEmpty ? "未设置" : "\(s.hotwordList.count) 个")
                        Button("编辑…") { editingHotwords = true }
                    }
                } label: {
                    Text("热词")
                }
                LabeledContent("署名") {
                    HStack { Trailing(text: s.organizer.isEmpty ? "未填写" : s.organizer); Button("编辑…") { editingName = true } }
                }
            } header: {
                SectionTitle("识别与署名", info: "热词：同事姓名、公司和产品名等，转写时优先识别成这些写法（对百炼语音和自定义平台生效；通义听悟的热词在百炼控制台里设置）。署名写进每份纪要的「整理署名」一栏。")
            }
        }
        .sheet(isPresented: $editingHotwords) { HotwordSheet() }
        .sheet(item: $previewing) { p in
            TemplateSheet(title: p.name, original: p.text, isBuiltIn: p.customPath == nil) { saveTemplate($0, preview: p) }
        }
        .sheet(isPresented: $editingName) {
            EditSheet(title: "编辑署名", help: "写进每份纪要的「整理署名」一栏。", placeholder: "姓名", initial: s.organizer,
                      validate: { $0.count <= 20 ? nil : "最多 20 个字" }, save: { s.organizer = $0 })
        }
    }

    @ViewBuilder private var customCard: some View {
        let custom: String? = if case .custom(let p) = s.template { p } else { nil }
        TemplateCard(name: "自定模板", caption: custom == nil ? "载入自己的 .md 文件" : "点按更换文件", selected: custom != nil, dashed: custom == nil,
                     onPreview: custom.map { path in { previewing = .init(id: "custom", name: (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "自定模板", text: s.templateText, customPath: path) } }) {
            ThumbFrame { customThumb(custom) }
        } action: {
            if let p = choose(folder: false) { s.template = .custom(p) }
        }
    }

    @ViewBuilder private func customThumb(_ custom: String?) -> some View {
        if let custom {
            VStack(spacing: 3) {
                Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(.secondary)
                Text((custom as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
        } else {
            Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Built-in templates are never changed: an edit is saved as a custom template and selected.
    private func saveTemplate(_ text: String, preview p: Preview) {
        let path: String
        if let existing = p.customPath {
            path = existing
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("E1Recorder/templates", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("\(p.name)（自定）.md").path
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        s.template = .custom(path)
    }
}

/// Template card: hover darkens the border and shows 预览; the chosen card carries a blue check dot at the bottom-right.
struct TemplateCard<Thumb: View>: View {
    let name: String
    let caption: String
    let selected: Bool
    var dashed = false
    var onPreview: (() -> Void)? = nil
    @ViewBuilder var thumb: Thumb
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb
                .environment(\.cardChrome, CardChrome(dashed: dashed, hover: hover))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        ZStack {
                            Circle().fill(.white).frame(width: 19, height: 19)
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color.e1Blue)
                        }
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hover, let onPreview {
                        Button("预览", action: onPreview).controlSize(.small).padding(5)
                    }
                }
            Text(name).fontWeight(selected ? .semibold : .regular)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

struct CardChrome: Equatable { var dashed = false, hover = false }

private struct CardChromeKey: EnvironmentKey { static let defaultValue = CardChrome() }

extension EnvironmentValues {
    var cardChrome: CardChrome {
        get { self[CardChromeKey.self] }
        set { self[CardChromeKey.self] = newValue }
    }
}

/// Thumbnail frame that reacts to hover; content draws the template's shape.
struct ThumbFrame<Content: View>: View {
    @Environment(\.cardChrome) private var c
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 64)
            .background(c.dashed ? Color.dyn(0xFBFBFB, 0x242424) : Color.e1Content, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(c.hover ? 0.25 : c.dashed ? 0.2 : 0.12),
                                        style: StrokeStyle(lineWidth: 1, dash: c.dashed ? [4, 3] : [])))
    }
}

struct TemplateThumb: View {
    let id: String
    var body: some View {
        ThumbFrame {
            VStack(alignment: .leading, spacing: 5) { lines }
                .padding(.horizontal, 11).padding(.vertical, 9)
        }
    }

    private func bar(_ w: CGFloat, _ dark: Bool = false, h: CGFloat = 3, indent: CGFloat = 0) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(dark ? 0.3 : 0.14))
                .frame(width: max(0, (g.size.width - indent) * w), height: h).offset(x: indent)
        }
        .frame(height: h)
    }

    @ViewBuilder private var lines: some View {
        switch id {
        case "decision":
            bar(0.45, true, h: 4)
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) { bar(1).frame(width: 14); bar(i == 1 ? 0.7 : 1) }
            }
        case "interview":
            bar(0.7, true); bar(0.84, indent: 10); bar(0.58, true); bar(0.8, indent: 10)
        case "lecture":
            bar(0.4, true, h: 4)
            ForEach([1.0, 0.7, 0.82], id: \.self) { w in
                HStack(spacing: 5) { Circle().fill(Color.primary.opacity(0.3)).frame(width: 3, height: 3); bar(w) }
            }
        case "brief":
            bar(0.5, true, h: 4); bar(0.88); bar(0.64)
        default:
            bar(0.55, true, h: 4); bar(0.92); bar(0.8); bar(0.86); bar(0.6)
        }
    }
}

/// Preview of one template, with 编辑: editing a built-in template saves a copy as the custom template.
struct TemplateSheet: View {
    let title: String
    let original: String
    let isBuiltIn: Bool
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editing ? "编辑「\(title)」" : title).font(.headline)
                Spacer()
                if editing {
                    Button("取消") { editing = false; text = original }.keyboardShortcut(.cancelAction)
                    Button("存储") { save(text); dismiss() }.keyboardShortcut(.defaultAction).disabled(text == original)
                } else {
                    Button("导出…", action: export)
                    Button("编辑") { text = original; editing = true }
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            if editing {
                TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(8)
                    .background(Color.e1Group, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(isBuiltIn ? "内置模板不会被改动：存储后另存为「自定模板」并设为当前模板。" : "存储后直接写回这份模板文件。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(original).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(Color.e1Group, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(20).frame(width: 600, height: 540)
    }

    private func export() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(title).md"
        if p.runModal() == .OK, let u = p.url { try? original.write(to: u, atomically: true, encoding: .utf8) }
    }
}

/// What each {{placeholder}} becomes in a note.
struct TemplateFieldHelp: View {
    static let fields: [(String, String)] = [
        ("标题", "纪要标题：日期 + 会议主题"), ("日期", "录音日期，如 2026-11-11"), ("日期时间", "开始时间，Obsidian 属性用，如 2026-11-11T17:25"), ("会议时间", "开始–结束时间"),
        ("时长", "录音时长"), ("场景", "笔上选的场景：会议、访谈…"), ("来源", "录音笔或导入文件"),
        ("参会人", "识别出的发言人"), ("整理人", "「整理署名」里的名字"), ("关键词", "自动提取的关键词"),
        ("录音文件", "本机录音文件链接"), ("时间提示", "录音时间不可靠时的提醒"), ("摘要", "全文摘要"),
        ("待办", "待办清单（- [ ] 格式）"), ("待办表格", "待办表格的行"), ("章节", "分章节的标题与概要"),
        ("重点标记", "录音时按 M 键标记的位置"), ("转写", "带发言人和时间的全文"),
    ]
    var body: some View {
        DisclosureGroup("模板字段与写法") {
            VStack(alignment: .leading, spacing: 10) {
                Text("模板是一份 Markdown 文件。写 {{字段}} 的地方，生成纪要时换成对应内容，其余文字原样保留。把鼠标移到卡片上点「预览」可查看和编辑模板，也可以载入自己写的 .md 文件。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Self.fields, id: \.0) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("{{\(f.0)}}").font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                            Text(f.1).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}
