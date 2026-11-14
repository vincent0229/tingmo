import Foundation
import Security
import ServiceManagement

// MARK: - Transcription platforms

/// Only platforms that actually work are offered. Both run on Alibaba Cloud Bailian and share one API key.
enum Provider: String, CaseIterable, Identifiable, Codable {
    case tingwu
    case bailian = "bailianASR"
    case custom
    var id: String { rawValue }
    var info: PlatformInfo { PlatformInfo.catalog[self]! }
}

struct ModelOption: Identifiable, Hashable {
    let id: String          // value sent to the API ("" = follow the console configuration)
    let label: String
}

struct PlatformInfo {
    let name: String
    let summary: String
    let needsAppId: Bool
    let models: [ModelOption]
    let consoleURL: URL

    static let catalog: [Provider: PlatformInfo] = [
        .tingwu: .init(name: "通义听悟", summary: "转写、说话人区分、摘要、待办与章节一次完成", needsAppId: true,
                       models: [.init(id: "fun-asr", label: "Fun-ASR 大模型"), .init(id: "cn", label: "中文通用"),
                                .init(id: "multilingual", label: "多语种混合"), .init(id: "", label: "跟随控制台")],
                       consoleURL: URL(string: "https://bailian.console.aliyun.com/?tab=app#/app/app-market/tingwu/tingwu-meeting-summary")!),
        .bailian: .init(name: "百炼语音", summary: "Fun-ASR 转写，再由千问整理成纪要", needsAppId: false,
                        models: [.init(id: "fun-asr", label: "Fun-ASR 大模型"), .init(id: "paraformer-v2", label: "Paraformer v2")],
                        consoleURL: URL(string: "https://bailian.console.aliyun.com/")!),
        .custom: .init(name: "自定义", summary: "任意 OpenAI 兼容接口：自己填写地址、密钥和模型", needsAppId: false,
                       models: [], consoleURL: URL(string: "https://platform.openai.com/docs/api-reference/audio")!),
    ]

    /// Language models that turn a Bailian transcript into a note.
    static let llmModels: [ModelOption] = [.init(id: "qwen-plus", label: "千问 Plus"), .init(id: "qwen-max", label: "千问 Max"),
                                           .init(id: "qwen-turbo", label: "千问 Turbo")]
}

enum AppLinks {
    static let repo = URL(string: "https://github.com/vincent0229/tingmo")!
    static let releases = URL(string: "https://github.com/vincent0229/tingmo/releases")!
    static let issues = URL(string: "https://github.com/vincent0229/tingmo/issues/new")!
    static let license = URL(string: "https://github.com/vincent0229/tingmo/blob/main/LICENSE")!
    static let latestAPI = URL(string: "https://api.github.com/repos/vincent0229/tingmo/releases/latest")!
    static let buildMonth = "2026 年 11 月"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
}

// MARK: - Note templates

enum TemplateChoice: Equatable {
    case builtin(String)
    case custom(String)

    init(raw: String) {
        if raw.hasPrefix("custom:") { self = .custom(String(raw.dropFirst(7))) }
        else { self = .builtin(raw.hasPrefix("builtin:") ? String(raw.dropFirst(8)) : "standard") }
    }
    var raw: String {
        switch self { case .builtin(let id): return "builtin:" + id; case .custom(let p): return "custom:" + p }
    }
}

// MARK: - Settings

/// Everything the user can change. Nothing is tied to one Mac: paths default to folders under the
/// current home, the API key lives in the Keychain, and the rest exports/imports as JSON.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// UI previews read the real settings but write to a throwaway domain, so stray typing can't change them.
    private let d: UserDefaults = UIPreview.enabled ? AppSettings.previewDefaults : .standard
    private static let previewDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "app.e1recorder.preview")!
        d.removePersistentDomain(forName: "app.e1recorder.preview")
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() { d.set(v, forKey: k) }
        return d
    }()

    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var appId: String { didSet { d.set(appId, forKey: "appId") } }
    @Published var endpoint: String { didSet { d.set(endpoint, forKey: "endpoint") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var transcriptionModel: String { didSet { d.set(transcriptionModel, forKey: "transcriptionModel") } }
    @Published var llmModel: String { didSet { d.set(llmModel, forKey: "llmModel") } }
    /// 自定义平台（OpenAI 兼容）：接口根地址、语音识别模型、整理纪要的对话模型。密钥单独存钥匙串。
    @Published var customEndpoint: String { didSet { d.set(customEndpoint, forKey: "customEndpoint") } }
    @Published var customASRModel: String { didSet { d.set(customASRModel, forKey: "customASRModel") } }
    @Published var customLLMModel: String { didSet { d.set(customLLMModel, forKey: "customLLMModel") } }
    @Published private(set) var maskedCustomKey: String?
    /// Menu bar icon style: "ring" (声纹录音键), "bars" (声波), "pen" (录音笔).
    @Published var menuIcon: String { didSet { d.set(menuIcon, forKey: "menuIcon") } }
    /// Open notes in Obsidian when they live inside an Obsidian vault.
    @Published var openInObsidian: Bool { didSet { d.set(openInObsidian, forKey: "openInObsidian") } }
    /// Monthly budget in yuan for the cost estimate (0 = no reminder).
    @Published var budgetYuan: Int { didSet { d.set(budgetYuan, forKey: "budgetYuan") } }
    /// Hotwords, one per line: names, companies, jargon.
    @Published var hotwords: String { didSet { d.set(hotwords, forKey: "hotwords") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// Names typed for speakers before, offered again next time.
    @Published var knownSpeakers: [String] { didSet { d.set(knownSpeakers, forKey: "knownSpeakers") } }
    /// WiFi networks the pen has been on (BSSID → network name), learned over USB and from heartbeats.
    @Published var knownNetworks: [String: String] { didSet { d.set(knownNetworks, forKey: "knownNetworks") } }
    /// What the user calls each network as a place, e.g. "Office-5G" → "公司". Only named networks count as places.
    @Published var placeNames: [String: String] { didSet { d.set(placeNames, forKey: "placeNames") } }

    func learnNetwork(bssid: String, ssid: String) {
        let b = bssid.lowercased()
        guard !b.isEmpty, !ssid.isEmpty, knownNetworks[b] != ssid else { return }
        knownNetworks[b] = ssid
    }

    /// Place for a recording: the strongest access point heard while recording that belongs to a known network.
    func place(for bssids: [String]?) -> String? {
        // A bare network name means nothing to a reader (and tells others which network you use), so only
        // networks the user has named become places.
        for b in bssids ?? [] {
            if let ssid = knownNetworks[b.lowercased()], let name = placeNames[ssid], !name.isEmpty { return name }
        }
        return nil
    }
    /// WiFi mailbox (Aliyun OSS): the pen uploads with an upload-only key, this Mac reads with a read/delete key.
    @Published var wifiEnabled: Bool { didSet { d.set(wifiEnabled, forKey: "wifiEnabled") } }
    @Published var ossEndpoint: String { didSet { d.set(ossEndpoint, forKey: "ossEndpoint") } }
    @Published var ossBucket: String { didSet { d.set(ossBucket, forKey: "ossBucket") } }
    /// How often the Mac checks the WiFi mailbox, in minutes.
    @Published var wifiIntervalMin: Int { didSet { d.set(wifiIntervalMin, forKey: "wifiIntervalMin") } }
    @Published private(set) var penKeyStored = false
    @Published private(set) var macKeyStored = false

    /// Everything the Mac needs to read the mailbox.
    var wifiReady: Bool { wifiEnabled && !ossBucket.isEmpty && !ossEndpoint.isEmpty && macKeyStored }

    func macOSS() -> OSSClient? {
        guard let id = Keychain.read(account: WifiKeys.macId), let sec = Keychain.read(account: WifiKeys.macSecret), !ossBucket.isEmpty else { return nil }
        return OSSClient(endpoint: ossEndpoint, bucket: ossBucket, keyId: id, secret: sec)
    }

    func penOSS() -> OSSClient? {
        guard let id = Keychain.read(account: WifiKeys.penId), let sec = Keychain.read(account: WifiKeys.penSecret), !ossBucket.isEmpty else { return nil }
        return OSSClient(endpoint: ossEndpoint, bucket: ossBucket, keyId: id, secret: sec)
    }

    func saveWifiKey(pen: Bool, id: String, secret: String) {
        Keychain.write(id.trimmingCharacters(in: .whitespacesAndNewlines), account: pen ? WifiKeys.penId : WifiKeys.macId)
        Keychain.write(secret.trimmingCharacters(in: .whitespacesAndNewlines), account: pen ? WifiKeys.penSecret : WifiKeys.macSecret)
        refreshMaskedKey()
    }

    var hotwordList: [String] {
        hotwords.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Result of the last connection test: "untested", "ok", or "failed:<reason>". Reset whenever credentials change.
    @Published var connState: String { didSet { d.set(connState, forKey: "connState") } }
    @Published var notesFolder: String { didSet { d.set(notesFolder, forKey: "notesFolder") } }
    @Published var audioFolder: String { didSet { d.set(audioFolder, forKey: "audioFolder") } }
    @Published var template: TemplateChoice { didSet { d.set(template.raw, forKey: "template") } }
    @Published var organizer: String { didSet { d.set(organizer, forKey: "organizer") } }
    @Published var minDurationSec: Int { didSet { d.set(minDurationSec, forKey: "minDurationSec") } }
    @Published var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    /// What a note is saved as: "md" (Markdown, for Obsidian and other note apps), "docx" (Word) or "pdf".
    @Published var noteFormat: String { didSet { d.set(noteFormat, forKey: "noteFormat") } }
    /// Keep this Mac's copy of each recording after its note is written (the pen's own recording is never touched).
    @Published var keepAudio: Bool { didSet { d.set(keepAudio, forKey: "keepAudio") } }
    @Published private(set) var maskedKey: String?

    private init() {
        let home = NSHomeDirectory()
        let defaultNotes = home + "/Documents/E1录音纪要"
        provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .tingwu
        appId = d.string(forKey: "appId") ?? ""
        endpoint = d.string(forKey: "endpoint") ?? "https://dashscope.aliyuncs.com"
        model = d.string(forKey: "model") ?? "tingwu-meeting"
        transcriptionModel = d.string(forKey: "transcriptionModel") ?? "fun-asr"
        llmModel = d.string(forKey: "llmModel") ?? "qwen-plus"
        customEndpoint = d.string(forKey: "customEndpoint") ?? "https://api.openai.com/v1"
        customASRModel = d.string(forKey: "customASRModel") ?? "whisper-1"
        customLLMModel = d.string(forKey: "customLLMModel") ?? "gpt-4o-mini"
        let savedIcon = d.string(forKey: "menuIcon") ?? "logo"
        menuIcon = (savedIcon == "ring" || savedIcon == "bars") ? "logo" : savedIcon
        openInObsidian = d.object(forKey: "openInObsidian") as? Bool ?? true
        budgetYuan = d.object(forKey: "budgetYuan") as? Int ?? 50
        hotwords = d.string(forKey: "hotwords") ?? ""
        onboardingDone = d.bool(forKey: "onboardingDone") || d.string(forKey: "appId") != nil
        knownSpeakers = d.stringArray(forKey: "knownSpeakers") ?? []
        knownNetworks = d.dictionary(forKey: "knownNetworks") as? [String: String] ?? [:]
        placeNames = d.dictionary(forKey: "placeNames") as? [String: String] ?? [:]
        wifiEnabled = d.bool(forKey: "wifiEnabled")
        ossEndpoint = d.string(forKey: "ossEndpoint") ?? "oss-cn-beijing.aliyuncs.com"
        ossBucket = d.string(forKey: "ossBucket") ?? ""
        wifiIntervalMin = d.object(forKey: "wifiIntervalMin") as? Int ?? 1
        connState = d.string(forKey: "connState") ?? "untested"
        // Pin the folders on first launch so a later change of the defaults never moves anyone's notes.
        let notes = d.string(forKey: "notesFolder") ?? defaultNotes, audio = d.string(forKey: "audioFolder") ?? home + "/Music/E1录音"
        d.set(notes, forKey: "notesFolder"); d.set(audio, forKey: "audioFolder")
        notesFolder = notes
        audioFolder = audio
        if let raw = d.string(forKey: "template") {
            template = TemplateChoice(raw: raw)
        } else if let legacy = d.string(forKey: "templatePath"), !legacy.isEmpty {
            template = .custom(legacy)
        } else {
            template = .builtin("standard")
        }
        organizer = d.string(forKey: "organizer") ?? NSFullUserName()
        minDurationSec = d.object(forKey: "minDurationSec") as? Int ?? 10
        autoSync = d.object(forKey: "autoSync") as? Bool ?? true
        noteFormat = d.string(forKey: "noteFormat") ?? "md"
        keepAudio = d.object(forKey: "keepAudio") as? Bool ?? true
        if UIPreview.enabled {
            // Screenshot aid: -previewNoKey YES shows the app before any key is filled in.
            let none = UserDefaults.standard.bool(forKey: "previewNoKey")
            maskedKey = none ? nil : "sk-" + String(repeating: "•", count: 10) + "AbCd"; maskedCustomKey = maskedKey
            penKeyStored = !none; macKeyStored = !none
            if Demo.on { Demo.apply(to: self) }
            return
        }
        refreshMaskedKey()
        // Launch at login is on by default; ask macOS once, then respect the user's choice.
        if !d.bool(forKey: "loginItemInitialized") {
            d.set(true, forKey: "loginItemInitialized")
            try? SMAppService.mainApp.register()
        }
    }

    /// Key for the platform in use (自定义 has its own).
    var hasAPIKey: Bool { provider == .custom ? maskedCustomKey != nil : maskedKey != nil }
    var activeMaskedKey: String? { provider == .custom ? maskedCustomKey : maskedKey }
    /// What's still missing before recordings can be transcribed; nil when ready.
    var setupProblem: String? {
        if !hasAPIKey { return provider == .custom ? "还没填写自定义平台的访问密钥，录音暂不转写" : "还没填写访问密钥，录音暂不转写" }
        if provider.info.needsAppId && appId.isEmpty { return "还没填写应用编号，录音暂不转写" }
        if provider == .custom && (customEndpoint.isEmpty || customASRModel.isEmpty || customLLMModel.isEmpty) { return "自定义平台的地址或模型没填完" }
        return nil
    }

    var isConfigured: Bool {
        switch provider {
        case .custom: maskedCustomKey != nil && !customEndpoint.isEmpty && !customASRModel.isEmpty && !customLLMModel.isEmpty
        default: maskedKey != nil && (!provider.info.needsAppId || !appId.isEmpty)
        }
    }

    /// Switches platform and keeps the model choice valid for it.
    func setProvider(_ p: Provider) {
        guard p != provider else { return }
        provider = p
        if let first = p.info.models.first, !p.info.models.contains(where: { $0.id == transcriptionModel }) { transcriptionModel = first.id }
        connState = "untested"
    }

    func refreshMaskedKey() {
        func mask(_ k: String?) -> String? {
            guard let k else { return nil }
            return k.count > 10 ? String(k.prefix(3)) + String(repeating: "•", count: 10) + String(k.suffix(4)) : String(repeating: "•", count: 10)
        }
        maskedKey = mask(Keychain.read())
        maskedCustomKey = mask(Keychain.read(account: Keychain.customAccount))
        penKeyStored = Keychain.read(account: WifiKeys.penId) != nil && Keychain.read(account: WifiKeys.penSecret) != nil
        macKeyStored = Keychain.read(account: WifiKeys.macId) != nil && Keychain.read(account: WifiKeys.macSecret) != nil
    }

    /// Saves the key for the platform in use.
    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        let account = provider == .custom ? Keychain.customAccount : Keychain.account
        let ok = Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
        refreshMaskedKey()
        connState = "untested"
        return ok
    }

    func deleteAPIKey() {
        Keychain.delete()
        refreshMaskedKey()
    }

    /// Text of the template currently in use.
    var templateText: String {
        switch template {
        case .builtin(let id): return NoteTemplate.builtIn(id).body
        case .custom(let p): return (try? String(contentsOfFile: p, encoding: .utf8)) ?? NoteTemplate.builtIn("standard").body
        }
    }

    // MARK: launch at login
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.app.error("开机启动设置失败：\(error.localizedDescription, privacy: .public)") }
            objectWillChange.send()
        }
    }

    // MARK: export / import (never includes the API key)
    struct Exported: Codable {
        var provider: String; var appId: String; var endpoint: String; var model: String
        var transcriptionModel: String?; var llmModel: String?; var template: String?
        var customEndpoint: String?; var customASRModel: String?; var customLLMModel: String?; var menuIcon: String?
        var openInObsidian: Bool?; var budgetYuan: Int?; var hotwords: String?
        var wifiEnabled: Bool?; var ossEndpoint: String?; var ossBucket: String?; var wifiIntervalMin: Int?
        var knownSpeakers: [String]?; var placeNames: [String: String]?; var knownNetworks: [String: String]?
        var noteFormat: String?; var keepAudio: Bool?
        var notesFolder: String; var audioFolder: String
        var organizer: String; var minDurationSec: Int; var autoSync: Bool
    }

    func exportConfig(to url: URL) throws {
        var tpl = template
        if case .custom(let p) = template { tpl = .custom(tildify(p)) }
        let e = Exported(provider: provider.rawValue, appId: appId, endpoint: endpoint, model: model,
                         transcriptionModel: transcriptionModel, llmModel: llmModel, template: tpl.raw,
                         customEndpoint: customEndpoint, customASRModel: customASRModel, customLLMModel: customLLMModel, menuIcon: menuIcon,
                         openInObsidian: openInObsidian, budgetYuan: budgetYuan, hotwords: hotwords,
                         wifiEnabled: wifiEnabled, ossEndpoint: ossEndpoint, ossBucket: ossBucket, wifiIntervalMin: wifiIntervalMin,
                         knownSpeakers: knownSpeakers, placeNames: placeNames, knownNetworks: knownNetworks,
                         noteFormat: noteFormat, keepAudio: keepAudio,
                         notesFolder: tildify(notesFolder), audioFolder: tildify(audioFolder),
                         organizer: organizer, minDurationSec: minDurationSec, autoSync: autoSync)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(e).write(to: url)
    }

    /// Secrets an imported configuration still needs on this Mac (they never travel in the file).
    var missingSecrets: [String] {
        var m: [String] = []
        if !hasAPIKey { m.append(provider == .custom ? "自定义平台的访问密钥" : "百炼访问密钥") }
        if wifiEnabled || !ossBucket.isEmpty {
            if !penKeyStored { m.append("WiFi 录音笔用的钥匙") }
            if !macKeyStored { m.append("WiFi Mac 用的钥匙") }
        }
        return m
    }

    func importConfig(from url: URL) throws {
        let e = try JSONDecoder().decode(Exported.self, from: Data(contentsOf: url))
        provider = Provider(rawValue: e.provider) ?? .tingwu
        appId = e.appId; endpoint = e.endpoint; model = e.model
        transcriptionModel = e.transcriptionModel ?? "fun-asr"
        llmModel = e.llmModel ?? "qwen-plus"
        if let v = e.customEndpoint { customEndpoint = v }
        if let v = e.customASRModel { customASRModel = v }
        if let v = e.customLLMModel { customLLMModel = v }
        if let v = e.menuIcon { menuIcon = v }
        if let v = e.openInObsidian { openInObsidian = v }
        if let v = e.budgetYuan { budgetYuan = v }
        if let v = e.hotwords { hotwords = v }
        if let v = e.wifiEnabled { wifiEnabled = v }
        if let v = e.ossEndpoint { ossEndpoint = v }
        if let v = e.ossBucket { ossBucket = v }
        if let v = e.wifiIntervalMin { wifiIntervalMin = v }
        if let v = e.noteFormat { noteFormat = v }
        if let v = e.keepAudio { keepAudio = v }
        if let v = e.knownSpeakers { knownSpeakers = Array(Set(knownSpeakers + v)).sorted() }
        if let v = e.placeNames { placeNames.merge(v) { _, new in new } }
        if let v = e.knownNetworks { knownNetworks.merge(v) { old, _ in old } }
        connState = "untested"
        if let t = e.template {
            var c = TemplateChoice(raw: t)
            if case .custom(let p) = c { c = .custom(untildify(p)) }
            template = c
        }
        notesFolder = untildify(e.notesFolder); audioFolder = untildify(e.audioFolder)
        organizer = e.organizer; minDurationSec = e.minDurationSec; autoSync = e.autoSync
    }

    /// Paths are exported relative to the home folder so they work under another user name.
    private func tildify(_ p: String) -> String {
        let h = NSHomeDirectory()
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    private func untildify(_ p: String) -> String {
        p.hasPrefix("~") ? NSHomeDirectory() + p.dropFirst(1) : p
    }
}

/// All secrets (the platform key, the custom-platform key and the two WiFi AccessKeys) live in ONE Keychain item,
/// so a freshly built copy of the app asks for Keychain access once instead of once per key.
/// The item is read once per launch and kept in memory.
enum Keychain {
    static let service = "E1Recorder"
    static let account = "bailian-api-key"
    static let customAccount = "custom-api-key"
    private static let bundleAccount = "all-keys"
    private static var cache: [String: String]?

    static func read(account: String = account) -> String? {
        load()[account].flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func write(_ value: String, account: String = account) -> Bool {
        var d = load()
        d[account] = value
        cache = d
        return save(d)
    }

    static func delete(account: String = account) {
        var d = load()
        d.removeValue(forKey: account)
        cache = d
        save(d)
    }

    private static func load() -> [String: String] {
        if let c = cache { return c }
        var dict: [String: String] = [:]
        if let json = rawRead(bundleAccount),
           let d = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            dict = d
        } else {
            // One-time move from the separate items older versions used.
            for a in [account, customAccount, WifiKeys.penId, WifiKeys.penSecret, WifiKeys.macId, WifiKeys.macSecret] {
                if let v = rawRead(a) { dict[a] = v }
            }
            if !dict.isEmpty, save(dict) { for a in dict.keys { rawDelete(a) } }
        }
        cache = dict
        return dict
    }

    @discardableResult
    private static func save(_ d: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(d), let json = String(data: data, encoding: .utf8) else { return false }
        return rawWrite(json, bundleAccount)
    }

    // MARK: raw Keychain access

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func rawRead(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func rawWrite(_ value: String, _ account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "听墨 访问密钥"
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func rawDelete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
