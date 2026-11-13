import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// The transcription queue: upload, cloud task, polling, retries.
extension Pipeline {
    // MARK: processing

    func processQueue() {
        guard !processing, !UIPreview.enabled else { return }
        let now = Date()
        guard let next = jobs.last(where: { ($0.state == .queued || $0.state == .transcribing) && (retryAt[$0.id] ?? .distantPast) <= now })
        else { return }
        guard settings.isConfigured else {
            lastMessage = "请先在「偏好设置 › 转写」填写访问密钥"
            return
        }
        processing = true
        Task {
            await run(next.id)
            processing = false
            processQueue()
        }
    }

    static func service(_ p: Provider, settings s: AppSettings, key: String) -> TranscriptionService {
        let ds = DashScope(apiKey: key, endpoint: s.endpoint)
        switch p {
        case .custom:
            let base = s.customEndpoint.hasSuffix("/") ? String(s.customEndpoint.dropLast()) : s.customEndpoint
            return CustomClient(ds: DashScope(apiKey: key, endpoint: base), asrModel: s.customASRModel, llmModel: s.customLLMModel,
                                hotwords: s.hotwordList)
        case .tingwu: return TingwuClient(ds: ds, appId: s.appId, model: s.model, transcriptionModel: s.transcriptionModel)
        case .bailian: return BailianClient(ds: ds, asrModel: s.transcriptionModel.isEmpty ? "fun-asr" : s.transcriptionModel,
                                            llmModel: s.llmModel, hotwords: s.hotwordList)
        }
    }

    static func key(for p: Provider) -> String? {
        Keychain.read(account: p == .custom ? Keychain.customAccount : Keychain.account)
    }

    func run(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        do {
            if job.state == .queued || job.dataId == nil {
                lastMessage = "上传中：\(job.title)"
                let p = settings.provider
                guard let key = Self.key(for: p) else { throw AppError("读不到访问密钥，请到「偏好设置 › 转写」重新填写") }
                let c = Self.service(p, settings: settings, key: key)
                // the custom platform takes the file directly, so send the smaller denoised mp3 when there is one
                var source = p == .custom ? (job.listenPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? job.audioPath) : job.audioPath
                guard FileManager.default.fileExists(atPath: source) else { throw AppError("找不到录音文件：\(source)") }
                // Long recordings (over ~50 min of WAV) go up as compact AAC: about 1/5 the size, so the upload is
                // quick and well inside the upload pass's 5-minute validity. Speech recognition is unaffected.
                var temp: URL?
                if p != .custom, source.lowercased().hasSuffix(".wav"),
                   let size = (try? FileManager.default.attributesOfItem(atPath: source)[.size] as? Int) ?? nil, size > 100_000_000 {
                    lastMessage = "压缩中：\(job.title)"
                    phases[id] = .compressing
                    let out = try await Self.compressForUpload(source)
                    temp = out
                    source = out.path
                }
                defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
                lastMessage = "上传中：\(job.title)"
                phases[id] = .uploading(nil)
                let report: @Sendable (Double) -> Void = { f in Task { @MainActor in Pipeline.shared.setUploadProgress(id, f) } }
                let file = URL(fileURLWithPath: source)
                let url = try await UploadProgress.$report.withValue(report) { try await c.upload(file) }
                let dataId = try await c.createTask(fileURL: url)
                update(id) { $0.state = .transcribing; $0.dataId = dataId; $0.provider = p.rawValue }
                job = jobs.first(where: { $0.id == id })!
                phases[id] = .transcribing(since: Date())
            }
            if case .transcribing? = phases[id] {} else { phases[id] = .transcribing(since: job.updated) }
            lastMessage = "转写中：\(job.title)"
            let owner = Provider(rawValue: job.provider ?? "") ?? .tingwu
            guard let key = Self.key(for: owner) else { throw AppError("读不到访问密钥，请到「偏好设置 › 转写」重新填写") }
            let c = Self.service(owner, settings: settings, key: key)
            let deadline = Date().addingTimeInterval(6 * 3600)
            while Date() < deadline {
                switch try await c.poll(job.dataId!) {
                case .done(let b):
                    phases[id] = .writing
                    saveResults(job.dataId!, b)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // so 「存到本地」 is seen working, not a flash
                    try writeNote(job, b)
                    lastMessage = "已完成：\(job.title)"
                    phases[id] = nil
                    return
                case .failed(let why):
                    throw AppError("云端转写失败：\(why)")
                case .running:
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
            throw AppError("转写超时（超过 6 小时）")
        } catch where Self.isTransient(error) {
            // Mac asleep, WiFi dropped, proxy hiccup, busy server: the cloud task (if any) is still fine.
            // Keep the job where it is and pick it up again in a minute — no failure, no notification.
            retryAt[id] = Date().addingTimeInterval(60)
            phases[id] = .waiting(until: retryAt[id]!)
            lastMessage = "网络不通，稍后自动继续：\(job.title)"
            Log.jobs.info("网络或服务繁忙，稍后重试：\(error.localizedDescription, privacy: .public)")
        } catch {
            retryAt[id] = nil
            phases[id] = nil
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            lastMessage = "失败：\(job.title)"
            notify("转写失败：\(job.title)", error.localizedDescription, jobId: id)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? AppError { return e.transient }
        if let e = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork, .dataNotAllowed,
                    .internationalRoamingOff, .callIsActive, .resourceUnavailable].contains(e.code)
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// WAV → AAC (16 kHz mono, 48 kbps) in a temporary file, without blocking the app.
    static func compressForUpload(_ path: String) async throws -> URL {
        try await AudioCompressor.toAAC(path, bitrate: 48_000)
    }
}
