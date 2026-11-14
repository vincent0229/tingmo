import Foundation
import AuthenticationServices
import AppKit

/// 飞书原生推送：OAuth 授权 + 文档/任务/消息 API。
/// 设置页填 App ID / App Secret → 扫码授权 → 纪要生成后自动推送（只推本人）。
final class FeishuPush: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = FeishuPush()

    @Published var isConnected = false
    @Published var userName = ""
    @Published var status = ""

    private let defaults = UserDefaults.standard
    private let keychainService = "TingMoFeishu"

    var appId: String {
        get { defaults.string(forKey: "feishuAppId") ?? "" }
        set { defaults.set(newValue, forKey: "feishuAppId") }
    }
    var appSecret: String {
        get { keychainRead("appSecret") ?? "" }
        set { keychainSave("appSecret", value: newValue) }
    }
    var pushEnabled: Bool {
        get { defaults.bool(forKey: "feishuPushEnabled") }
        set { defaults.set(newValue, forKey: "feishuPushEnabled") }
    }

    private var userToken: String? { keychainRead("userToken") }
    private var refreshToken: String? { keychainRead("refreshToken") }
    private var tokenExpiry: Date? {
        get { defaults.object(forKey: "feishuTokenExpiry") as? Date }
        set { defaults.set(newValue, forKey: "feishuTokenExpiry") }
    }
    private var openId: String {
        get { defaults.string(forKey: "feishuOpenId") ?? "" }
        set { defaults.set(newValue, forKey: "feishuOpenId") }
    }

    private let base = "https://open.feishu.cn/open-apis"

    override init() {
        super.init()
        isConnected = userToken != nil && !openId.isEmpty
        userName = defaults.string(forKey: "feishuUserName") ?? ""
    }

    // MARK: - OAuth

    func connect() async {
        guard !appId.isEmpty, !appSecret.isEmpty else {
            status = "请先填写 App ID 和 App Secret"; return
        }
        status = "正在获取应用凭证…"
        do {
            let appToken = try await getAppAccessToken()
            status = "请在浏览器中授权…"
            let code = try await oauthAuthorize()
            status = "正在交换令牌…"
            try await exchangeCode(code, appToken: appToken)
            try await fetchUserInfo()
            isConnected = true
            status = "已连接：\(userName)"
        } catch {
            status = "连接失败：\(error.localizedDescription)"
        }
    }

    func disconnect() {
        keychainDelete("userToken"); keychainDelete("refreshToken"); keychainDelete("appSecret")
        defaults.removeObject(forKey: "feishuTokenExpiry")
        defaults.removeObject(forKey: "feishuOpenId")
        defaults.removeObject(forKey: "feishuUserName")
        isConnected = false; userName = ""; status = "已断开"
    }

    private func getAppAccessToken() async throws -> String {
        let body: [String: Any] = ["app_id": appId, "app_secret": appSecret]
        let res = try await post("/auth/v3/app_access_token/internal", json: body, token: nil)
        guard let t = res["app_access_token"] as? String else {
            throw FeishuError.api(res["msg"] as? String ?? "获取 app_access_token 失败")
        }
        return t
    }

    private func oauthAuthorize() async throws -> String {
        let state = UUID().uuidString
        var comps = URLComponents(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize")!
        comps.queryItems = [
            .init(name: "app_id", value: appId),
            .init(name: "redirect_uri", value: "tingmo://feishu-callback"),
            .init(name: "state", value: state),
        ]
        let url = comps.url!
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "tingmo") { callback, error in
                if let error { cont.resume(throwing: error); return }
                guard let callback,
                      let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    cont.resume(throwing: FeishuError.api("未收到授权码")); return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCode(_ code: String, appToken: String) async throws {
        let body: [String: Any] = ["grant_type": "authorization_code", "code": code]
        let res = try await post("/authen/v1/oidc/access_token", json: body, token: appToken)
        guard let data = res["data"] as? [String: Any],
              let at = data["access_token"] as? String,
              let rt = data["refresh_token"] as? String else {
            throw FeishuError.api(res["msg"] as? String ?? "交换令牌失败")
        }
        keychainSave("userToken", value: at)
        keychainSave("refreshToken", value: rt)
        let expiresIn = data["expires_in"] as? Int ?? 7200
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 300))
    }

    private func fetchUserInfo() async throws {
        let res = try await get("/authen/v1/user_info", token: try await validToken())
        guard let data = res["data"] as? [String: Any] else { return }
        openId = data["open_id"] as? String ?? ""
        let name = data["name"] as? String ?? ""
        userName = name
        defaults.set(name, forKey: "feishuUserName")
    }

    private func validToken() async throws -> String {
        if let t = userToken, let exp = tokenExpiry, Date() < exp { return t }
        guard let rt = refreshToken else { throw FeishuError.api("未授权，请重新连接飞书") }
        let appToken = try await getAppAccessToken()
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt]
        let res = try await post("/authen/v1/oidc/refresh_access_token", json: body, token: appToken)
        guard let data = res["data"] as? [String: Any],
              let at = data["access_token"] as? String,
              let rt2 = data["refresh_token"] as? String else {
            throw FeishuError.api("刷新令牌失败，请重新连接")
        }
        keychainSave("userToken", value: at)
        keychainSave("refreshToken", value: rt2)
        let expiresIn = data["expires_in"] as? Int ?? 7200
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 300))
        return at
    }

    // MARK: - Push API

    func pushNote(title: String, markdown: String, todos: [(String, String?)]) async -> String {
        guard pushEnabled, isConnected else { return "" }
        do {
            let token = try await validToken()
            let docUrl = try await createDoc(title: "听墨·\(title)", token: token)
            for (task, due) in todos {
                _ = try? await createTask(summary: task, due: due, token: token)
            }
            var msg = "【听墨】\(title)\n全文：\(docUrl)\n我的待办：\(todos.count) 条"
            _ = try? await sendMessage(msg, token: token)
            return "飞书推送完成：\(docUrl)"
        } catch {
            return "飞书推送失败：\(error.localizedDescription)"
        }
    }

    private func createDoc(title: String, token: String) async throws -> String {
        let body: [String: Any] = ["title": title, "folder_token": ""]
        let res = try await post("/docx/v1/documents", json: body, token: token)
        guard let data = res["data"] as? [String: Any],
              let doc = data["document"] as? [String: Any],
              let docId = doc["document_id"] as? String else {
            throw FeishuError.api("创建文档失败")
        }
        return "https://www.feishu.cn/docx/\(docId)"
    }

    private func createTask(summary: String, due: String?, token: String) async throws -> String {
        var task: [String: Any] = ["summary": summary]
        if let due, !due.isEmpty {
            task["due"] = ["time": due, "is_all_day": false]
        }
        if !openId.isEmpty {
            task["members"] = [["id": openId, "role": "assignee"]]
        }
        let res = try await post("/task/v2/tasks", json: task, token: token)
        guard let data = res["data"] as? [String: Any],
              let t = data["task"] as? [String: Any],
              let guid = t["guid"] as? String else {
            throw FeishuError.api("创建任务失败")
        }
        return guid
    }

    private func sendMessage(_ text: String, token: String) async throws {
        guard !openId.isEmpty else { return }
        let content = try JSONSerialization.data(withJSONObject: ["text": text])
        let contentStr = String(data: content, encoding: .utf8) ?? "{}"
        let body: [String: Any] = [
            "receive_id": openId,
            "msg_type": "text",
            "content": contentStr,
        ]
        _ = try await post("/im/v1/messages?receive_id_type=open_id", json: body, token: token)
    }

    // MARK: - HTTP

    private func post(_ path: String, json: [String: Any], token: String?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, _) = try await URLSession.shared.data(for: req)
        let res = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        try Self.check(res, path: path)
        return res
    }

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let res = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        try Self.check(res, path: path)
        return res
    }

    ///  surface 飞书真实错误码 + 描述，便于定位（如 20029 redirect_uri 无效）
    private static func check(_ res: [String: Any], path: String) throws {
        let code = res["code"] as? Int ?? -1
        if code != 0 {
            let msg = res["msg"] as? String ?? res["message"] as? String ?? "未知错误"
            throw FeishuError.api("[\(code)] \(msg)（\(path)）")
        }
    }

    // MARK: - Keychain

    private func keychainSave(_ key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func keychainRead(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key,
                                     kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: keychainService,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

enum FeishuError: LocalizedError {
    case api(String)
    var errorDescription: String? {
        switch self { case .api(let msg): msg }
    }
}