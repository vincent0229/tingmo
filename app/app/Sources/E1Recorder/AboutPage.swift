import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutPage: View {
    enum Check: Equatable { case idle, checking, latest, newer(String), failed }
    @State private var check: Check = .idle

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    HStack {
                        switch check {
                        case .idle: Trailing(text: AppLinks.version)
                        case .checking: ProgressView().controlSize(.small); Trailing(text: "检查中…")
                        case .latest: Trailing(text: "\(AppLinks.version) · 已是最新")
                        case .newer(let v): Text("有新版本 \(v)").foregroundStyle(.tint)
                        case .failed: Trailing(text: "检查失败")
                        }
                        if case .newer = check {
                            Button("下载…") { NSWorkspace.shared.open(AppLinks.releases) }
                        } else {
                            Button("检查") { Task { await checkUpdate() } }.disabled(check == .checking)
                        }
                    }
                }
                LabeledContent {
                    Button("打开…") { NSWorkspace.shared.open(AppLinks.repo) }
                } label: {
                    Text("项目主页")
                    Text("github.com/vincent0229/tingmo")
                }
                LabeledContent("数据目录") {
                    Button("在访达中显示") {
                        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("E1Recorder")
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    }
                }
            } header: {
                VStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    Text("听墨").font(.title3.weight(.semibold)).foregroundStyle(.primary).padding(.top, 6)
                    Text("声音落成墨迹。搜狗 E1 录音笔的私有化转写工作站：本地转写、本地纪要，音频不出本机。")
                        .font(.callout).fontWeight(.regular).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 380).padding(.top, 2).padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("MIT 许可 · 内置 adb（Apache-2.0）")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
    }

    private func checkUpdate() async {
        check = .checking
        do {
            var r = URLRequest(url: AppLinks.latestAPI, timeoutInterval: 15)
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let tag = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else {
                check = .failed; return
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            check = latest.compare(AppLinks.version, options: .numeric) == .orderedDescending ? .newer(latest) : .latest
        } catch {
            check = .failed
        }
    }
}
