import SwiftUI

struct PushSettingsPage: View {
    @EnvironmentObject var s: AppSettings
    @ObservedObject private var feishu = FeishuPush.shared
    @State private var appId = FeishuPush.shared.appId
    @State private var appSecret = ""
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("飞书") {
                    HStack {
                        if feishu.isConnected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(feishu.userName.isEmpty ? "已连接" : feishu.userName)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            Text("未连接").foregroundStyle(.secondary)
                        }
                    }
                }
                if feishu.isConnected {
                    Toggle("纪要生成后自动推送", isOn: Binding(
                        get: { feishu.pushEnabled },
                        set: { feishu.pushEnabled = $0 }
                    ))
                    LabeledContent("推送内容") {
                        Text("云文档 + 我的待办 + 消息（只推本人）").foregroundStyle(.secondary)
                    }
                    Button("断开连接", role: .destructive) { feishu.disconnect() }
                }
            } header: {
                Text("飞书推送")
            } footer: {
                Text(feishu.status.isEmpty
                     ? "推送以你本人身份发送，不经过任何第三方服务器。"
                     : feishu.status)
                    .foregroundStyle(.secondary)
            }

            if !feishu.isConnected {
                Section {
                    LabeledContent("App ID") {
                        TextField("cli_…", text: $appId)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .onChange(of: appId) { _, v in feishu.appId = v }
                    }
                    LabeledContent("App Secret") {
                        SecureField("应用密钥", text: $appSecret)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .onChange(of: appSecret) { _, v in feishu.appSecret = v }
                    }
                    Button(connecting ? "连接中…" : "连接飞书") {
                        connecting = true
                        Task {
                            let id = appId.isEmpty ? feishu.appId : appId
                            let sec = appSecret.isEmpty ? feishu.appSecret : appSecret
                            await feishu.connect(appId: id, appSecret: sec)
                            connecting = false
                        }
                    }
                    .disabled(connecting || (appId.isEmpty && feishu.appId.isEmpty) || (appSecret.isEmpty && feishu.appSecret.isEmpty))
                } header: {
                    Text("应用凭证")
                } footer: {
                    Text("在 [飞书开放平台](https://open.feishu.cn) 创建企业自建应用，开通 docx:document、task:task:write、im:message 权限，安全设置 › 重定向 URL 添加：http://127.0.0.1:17890/（必须以 / 结尾）。")
                        .font(.callout)
                }
            }

            Section {
                LabeledContent("钉钉") {
                    Text("即将支持").foregroundStyle(.tertiary)
                }
            } header: {
                Text("钉钉推送")
            }
        }
        .formStyle(.grouped)
        .onAppear { appId = feishu.appId; appSecret = feishu.appSecret }
    }
}