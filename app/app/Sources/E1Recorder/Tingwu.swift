import Foundation
import UniformTypeIdentifiers

/// Results of one finished transcription task, as raw JSON objects in Tingwu's shape.
/// Other platforms convert their output into this shape so one renderer handles every note.
struct TranscriptBundle {
    var transcription: [String: Any] = [:]
    var summarization: [String: Any] = [:]
    var chapters: [[String: Any]] = []
    var assistance: [String: Any] = [:]
}

enum PollResult {
    case running
    case done(TranscriptBundle)
    case failed(String)
}

/// One cloud platform: upload audio, start a task, poll it until the note material is ready.
protocol TranscriptionService {
    func upload(_ file: URL) async throws -> String
    func createTask(fileURL: String) async throws -> String
    func poll(_ taskId: String) async throws -> PollResult
    func testConnection() async throws
}

/// Upload progress for the job being processed, set by the pipeline around an upload (task-local, so it follows
/// the upload into whichever client does it).
enum UploadProgress {
    @TaskLocal static var report: (@Sendable (Double) -> Void)?
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// WAV (or anything Core Audio reads) → mono AAC in a temporary .m4a, without blocking the caller.
enum AudioCompressor {
    static func toAAC(_ path: String, bitrate: Int) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", "-c", "1", "-b", "\(bitrate)", path, out.path]
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; cont.resume(throwing: error) }
        }
        guard status == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            throw AppError("录音压缩失败，无法上传")
        }
        return out
    }
}

/// Shared HTTP helpers for Alibaba Cloud Bailian (DashScope).
struct DashScope {
    let apiKey: String
    let endpoint: String

    func request(_ url: URL, method: String = "GET", json: Any? = nil, async: Bool = false) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 180)
        r.httpMethod = method
        r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        }
        if async { r.setValue("enable", forHTTPHeaderField: "X-DashScope-Async") }
        return r
    }

    func call(_ r: URLRequest, label: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (obj["message"] as? String) ?? (obj["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            let c = (obj["code"] as? String) ?? "HTTP \(code)"
            if code == 401 || c.contains("InvalidApiKey") { throw AppError("访问密钥无效") }
            throw AppError("\(label)出错（\(c)）：\(msg)", transient: code == 429 || code >= 500 || c.contains("Throttling"))
        }
        return obj
    }

    func getJSON(_ s: String?) async throws -> Any? {
        guard let s, let u = URL(string: s) else { return nil }
        let (d, _) = try await URLSession.shared.data(from: u)
        return try JSONSerialization.jsonObject(with: d)
    }

    /// Uploads a local file to Bailian's free temporary storage (kept 48 h) and returns its oss:// URL.
    func upload(_ file: URL, model: String) async throws -> String {
        var comps = URLComponents(string: endpoint + "/api/v1/uploads")!
        comps.queryItems = [.init(name: "action", value: "getPolicy"), .init(name: "model", value: model)]
        let policy = try await call(request(comps.url!), label: "获取上传凭证")
        guard let d = policy["data"] as? [String: Any],
              let host = d["upload_host"] as? String, let dir = d["upload_dir"] as? String else {
            throw AppError("获取上传凭证失败")
        }
        let name = file.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let key = dir + "/" + name
        let fields: [(String, String)] = [
            ("OSSAccessKeyId", d["oss_access_key_id"] as? String ?? ""), ("Signature", d["signature"] as? String ?? ""),
            ("policy", d["policy"] as? String ?? ""), ("x-oss-object-acl", d["x_oss_object_acl"] as? String ?? ""),
            ("x-oss-forbid-overwrite", d["x_oss_forbid_overwrite"] as? String ?? ""), ("key", key),
            ("success_action_status", "200"),
        ]
        let boundary = "----e1" + UUID().uuidString
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var r = URLRequest(url: URL(string: host)!, timeoutInterval: 1800)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body, delegate: UploadProgress.report.map(UploadProgressDelegate.init))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AppError("上传录音失败：\(String(decoding: data.prefix(300), as: UTF8.self))", transient: status >= 500)
        }
        return "oss://" + key
    }

    func testConnection(model: String) async throws {
        var comps = URLComponents(string: endpoint + "/api/v1/uploads")!
        comps.queryItems = [.init(name: "action", value: "getPolicy"), .init(name: "model", value: model)]
        _ = try await call(request(comps.url!), label: "连接测试")
    }
}

// MARK: - 通义听悟

/// Tingwu meeting API (model "tingwu-meeting"): transcript, summary, to-dos and chapters in one task.
struct TingwuClient: TranscriptionService {
    let ds: DashScope
    let appId: String
    let model: String
    var transcriptionModel: String = ""

    private var genURL: URL { URL(string: ds.endpoint + "/api/v1/services/aigc/multimodal-generation/generation")! }

    func upload(_ file: URL) async throws -> String { try await ds.upload(file, model: model) }

    func createTask(fileURL: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "input": ["task": "createTask", "type": "offline", "appId": appId, "fileUrl": fileURL],
        ]
        if !transcriptionModel.isEmpty { body["parameters"] = ["transcription": ["model": transcriptionModel]] }
        let res = try await ds.call(ds.request(genURL, method: "POST", json: body), label: "听悟接口")
        guard let id = (res["output"] as? [String: Any])?["dataId"] as? String else { throw AppError("创建转写任务失败") }
        return id
    }

    /// Tingwu status: 0 done, 1 running, 2 failed.
    func poll(_ dataId: String) async throws -> PollResult {
        let res = try await ds.call(ds.request(genURL, method: "POST", json: [
            "model": model, "input": ["task": "getTask", "dataId": dataId],
        ]), label: "听悟接口")
        let out = res["output"] as? [String: Any] ?? [:]
        let st = (out["status"] as? Int) ?? Int(out["status"] as? String ?? "") ?? 1
        switch st {
        case 0:
            var b = TranscriptBundle()
            b.transcription = try await ds.getJSON(out["transcriptionPath"] as? String) as? [String: Any] ?? [:]
            b.summarization = try await ds.getJSON(out["summarizationPath"] as? String) as? [String: Any] ?? [:]
            b.chapters = try await ds.getJSON(out["autoChaptersPath"] as? String) as? [[String: Any]] ?? []
            b.assistance = try await ds.getJSON(out["meetingAssistancePath"] as? String) as? [String: Any] ?? [:]
            return .done(b)
        case 2: return .failed(out["errorMessage"] as? String ?? "未知原因")
        default: return .running
        }
    }

    func testConnection() async throws { try await ds.testConnection(model: model) }
}

// MARK: - 百炼语音（Fun-ASR 转写 + 千问整理）

struct BailianClient: TranscriptionService {
    let ds: DashScope
    let asrModel: String
    let llmModel: String
    var hotwords: [String] = []

    func upload(_ file: URL) async throws -> String { try await ds.upload(file, model: asrModel) }

    func createTask(fileURL: String) async throws -> String {
        let url = URL(string: ds.endpoint + "/api/v1/services/audio/asr/transcription")!
        var params: [String: Any] = ["diarization_enabled": true]
        // inline hotwords (no vocabulary list needed); Fun-ASR limits each to 15 non-ASCII characters
        let words = hotwords.filter { $0.count <= 15 }.prefix(500)
        if !words.isEmpty { params["vocabulary"] = Dictionary(words.map { ($0, 4) }, uniquingKeysWith: { a, _ in a }) }
        let body: [String: Any] = ["model": asrModel, "input": ["file_urls": [fileURL]], "parameters": params]
        let res = try await ds.call(ds.request(url, method: "POST", json: body, async: true), label: "语音识别")
        guard let id = (res["output"] as? [String: Any])?["task_id"] as? String else { throw AppError("创建转写任务失败") }
        return id
    }

    func poll(_ taskId: String) async throws -> PollResult {
        let res = try await ds.call(ds.request(URL(string: ds.endpoint + "/api/v1/tasks/" + taskId)!), label: "语音识别")
        let out = res["output"] as? [String: Any] ?? [:]
        switch out["task_status"] as? String ?? "" {
        case "SUCCEEDED":
            let first = (out["results"] as? [[String: Any]])?.first ?? [:]
            guard (first["subtask_status"] as? String ?? "SUCCEEDED") == "SUCCEEDED" else {
                return .failed(first["message"] as? String ?? "这段录音没有识别出内容")
            }
            let raw = try await ds.getJSON(first["transcription_url"] as? String) as? [String: Any] ?? [:]
            let sentences = ((raw["transcripts"] as? [[String: Any]])?.first?["sentences"] as? [[String: Any]]) ?? []
            var bundle = TranscriptBundle(transcription: Self.paragraphs(from: sentences))
            try await summarize(sentences, into: &bundle)
            return .done(bundle)
        case "FAILED", "CANCELED", "UNKNOWN":
            return .failed(out["message"] as? String ?? "云端转写失败")
        default:
            return .running
        }
    }

    func testConnection() async throws { try await ds.testConnection(model: asrModel) }

    /// Fun-ASR sentences → Tingwu-style paragraphs (consecutive sentences of one speaker are merged).
    static func paragraphs(from sentences: [[String: Any]]) -> [String: Any] {
        var paragraphs: [[String: Any]] = []
        for (i, s) in sentences.enumerated() {
            let spk = s["speaker_id"] as? Int ?? 0
            let word: [String: Any] = ["text": s["text"] as? String ?? "", "start": s["begin_time"] as? Int ?? 0,
                                       "sentenceId": s["sentence_id"] as? Int ?? i]
            if var last = paragraphs.last, last["speakerId"] as? Int == spk {
                last["words"] = (last["words"] as? [[String: Any]] ?? []) + [word]
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append(["speakerId": spk, "words": [word]])
            }
        }
        return ["paragraphs": paragraphs]
    }

    private func summarize(_ sentences: [[String: Any]], into b: inout TranscriptBundle) async throws {
        let lines = sentences.map { s -> String in
            let sec = (s["begin_time"] as? Int ?? 0) / 1000
            return String(format: "[%02d:%02d] 发言人%d：", sec / 60, sec % 60, s["speaker_id"] as? Int ?? 0) + (s["text"] as? String ?? "")
        }
        try await summarizeTranscript(lines, ds: ds, chatURL: URL(string: ds.endpoint + "/compatible-mode/v1/chat/completions")!,
                                      model: llmModel, hotwords: hotwords, into: &b)
    }
}

/// Asks a chat model for title, summary, keywords, to-dos and chapters, and stores them in Tingwu's shape.
func summarizeTranscript(_ lines: [String], ds: DashScope, chatURL: URL, model: String, hotwords: [String] = [],
                         into b: inout TranscriptBundle) async throws {
    var transcript = lines.joined(separator: "\n")
    if transcript.isEmpty { return }
    if transcript.count > 100_000 { transcript = String(transcript.prefix(100_000)) }
    let system = """
    你是会议纪要助手。根据用户给出的带时间戳的录音转写，只输出一个 JSON 对象，字段如下：
    {"title": "不超过 20 字的会议主题",
     "summary": "200 到 400 字的摘要，可分段",
     "keywords": ["最多 10 个关键词"],
     "todos": ["待办事项，有负责人或时间就写上"],
     "chapters": [{"start_sec": 章节开始秒数（整数）, "title": "章节标题", "summary": "章节概要"}]}
    只依据转写内容，不要编造；没有待办就给空数组。
    """ + (hotwords.isEmpty ? "" : "\n转写可能把下列专有名词识别错，整理时按这些写法纠正：" + hotwords.joined(separator: "、"))
    let body: [String: Any] = ["model": model, "response_format": ["type": "json_object"],
                               "messages": [["role": "system", "content": system], ["role": "user", "content": transcript]]]
    let res = try await ds.call(ds.request(chatURL, method: "POST", json: body), label: "整理纪要")
    let content = (((res["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? "{}"
    let j = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
    b.summarization = ["paragraphSummary": j["summary"] as? String ?? "", "title": j["title"] as? String ?? ""]
    b.assistance = ["keywords": j["keywords"] as? [String] ?? [],
                    "actions": (j["todos"] as? [String] ?? []).map { ["text": $0] }]
    b.chapters = (j["chapters"] as? [[String: Any]] ?? []).map {
        ["start": (($0["start_sec"] as? Int) ?? Int($0["start_sec"] as? Double ?? 0)) * 1000,
         "headline": $0["title"] as? String ?? "", "summary": $0["summary"] as? String ?? ""]
    }
}

// MARK: - 自定义（OpenAI 兼容接口）

/// Any OpenAI-compatible service: `/audio/transcriptions` for speech, `/chat/completions` for the note.
/// Transcription is synchronous, so createTask does the work and keeps the result until poll() summarizes it.
struct CustomClient: TranscriptionService {
    let ds: DashScope            // used as a plain Bearer-token HTTP helper; endpoint = API base, e.g. https://api.openai.com/v1
    let asrModel: String
    let llmModel: String
    var hotwords: [String] = []

    private var store: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("E1Recorder/custom", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Nothing to upload: the file goes in the transcription request. Files over 24 MB are re-encoded to AAC first.
    func upload(_ file: URL) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 24_000_000 else { return file.path }
        return try await AudioCompressor.toAAC(file.path, bitrate: 32_000).path
    }

    func createTask(fileURL: String) async throws -> String {
        let file = URL(fileURLWithPath: fileURL)
        func send(_ format: String) async throws -> [String: Any] {
            let boundary = "----e1" + UUID().uuidString
            var body = Data()
            var fields = [("model", asrModel), ("response_format", format)]
            if !hotwords.isEmpty { fields.append(("prompt", "专有名词：" + hotwords.prefix(80).joined(separator: "、"))) }
            for (k, v) in fields {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
            }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(try Data(contentsOf: file))
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            var r = URLRequest(url: URL(string: ds.endpoint + "/audio/transcriptions")!, timeoutInterval: 3600)
            r.httpMethod = "POST"
            r.setValue("Bearer " + ds.apiKey, forHTTPHeaderField: "Authorization")
            r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return try await ds.call(r, label: "语音识别")
        }
        // verbose_json gives timestamps; some models only accept json.
        let result: [String: Any]
        do { result = try await send("verbose_json") } catch { result = try await send("json") }
        let id = UUID().uuidString
        try JSONSerialization.data(withJSONObject: result).write(to: store.appendingPathComponent(id + ".json"))
        if fileURL.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(atPath: fileURL) }
        return id
    }

    func poll(_ id: String) async throws -> PollResult {
        let u = store.appendingPathComponent(id + ".json")
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: Any] else {
            return .failed("转写结果丢失，请重试")
        }
        var segments = (raw["segments"] as? [[String: Any]]) ?? []
        if segments.isEmpty, let t = raw["text"] as? String { segments = [["start": 0, "text": t]] }
        let words: [[String: Any]] = segments.enumerated().map { i, s in
            ["text": s["text"] as? String ?? "", "start": Int(((s["start"] as? Double) ?? Double(s["start"] as? Int ?? 0)) * 1000), "sentenceId": i]
        }
        var bundle = TranscriptBundle(transcription: ["paragraphs": [["speakerId": 1, "words": words]]])
        let lines = words.map { w -> String in
            let sec = (w["start"] as? Int ?? 0) / 1000
            return String(format: "[%02d:%02d] ", sec / 60, sec % 60) + (w["text"] as? String ?? "")
        }
        try await summarizeTranscript(lines, ds: ds, chatURL: URL(string: ds.endpoint + "/chat/completions")!, model: llmModel,
                                      hotwords: hotwords, into: &bundle)
        try? FileManager.default.removeItem(at: u)
        return .done(bundle)
    }

    func testConnection() async throws {
        _ = try await ds.call(ds.request(URL(string: ds.endpoint + "/models")!), label: "连接测试")
    }
}
