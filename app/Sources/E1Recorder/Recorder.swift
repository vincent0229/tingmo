import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Records from the Mac's microphone (panel's 录音 button). The file goes into the audio folder and is queued
/// for transcription exactly like an imported file.
@MainActor
final class MacRecorder: NSObject, ObservableObject {
    static let shared = MacRecorder()

    @Published private(set) var isRecording = false
    /// What the 录音 button says under its title while not simply idle.
    @Published private(set) var note: String?
    @Published private(set) var noteIsError = false
    /// Mac minis and Mac Studios have no built-in microphone; this tracks whether any input device is attached.
    @Published private(set) var hasMicrophone = true
    /// Name of the input that will be used, e.g. "AirPods Pro".
    @Published private(set) var micName = ""

    override init() {
        super.init()
        refreshDevices()
        // Screenshot aid: -previewRecording YES (and -previewPaused YES) shows the recorder mid-recording.
        if UIPreview.enabled, UserDefaults.standard.bool(forKey: "previewRecording") {
            isRecording = true
            isPaused = UserDefaults.standard.bool(forKey: "previewPaused")
            elapsed = 754
            history = (0..<40).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.9))) }
            micName = "AirPods Pro"
        }
        for n in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                Task { @MainActor in MacRecorder.shared.refreshDevices() }
            }
        }
        // Follow the system's input device live (System Settings › Sound › Input), which is what gets recorded.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            Task { @MainActor in MacRecorder.shared.refreshDevices() }
        }
    }

    func refreshDevices() {
        guard !(UIPreview.enabled && UserDefaults.standard.bool(forKey: "previewRecording")) else { return }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let system = Self.defaultInputName()
        hasMicrophone = system != nil || !devices.isEmpty
        micName = system ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? devices.first?.localizedName ?? ""
    }

    /// Name of the system's current input device — the one a recording uses.
    static func defaultInputName() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 input level, for a little meter.
    @Published private(set) var level: Float = 0
    /// Paused mid-recording (the file stays open; 继续 carries on in the same file).
    @Published private(set) var isPaused = false
    /// The last few seconds of input levels, oldest first, for the live waveform.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 40)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var started = Date()
    private var fileURL: URL?

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    private func say(_ text: String?, error: Bool = false, clearAfter: Double? = nil) {
        note = text
        noteIsError = error
        if let t = clearAfter, let text {
            Task { try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000)); if note == text { note = nil } }
        }
    }

    func start() async {
        guard !isRecording else { return }
        refreshDevices()
        guard hasMicrophone else {
            say("未接麦克风", error: true, clearAfter: 6)
            explainNoMicrophone()
            return
        }
        Log.recorder.info("开始录音，麦克风权限 \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            say("请求麦克风权限…")
            NSApp.activate(ignoringOtherApps: true)
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            Log.recorder.info("麦克风授权结果：\(ok, privacy: .public)")
            guard ok else { say("没有麦克风权限", error: true, clearAfter: 6); askForMicrophone(); return }
        default:
            say("没有麦克风权限", error: true, clearAfter: 6)
            askForMicrophone()
            return
        }
        say(nil)
        let now = Date()
        let folder = URL(fileURLWithPath: AppSettings.shared.audioFolder)
            .appendingPathComponent("本机录音", isDirectory: true)
            .appendingPathComponent(DateFormatter.cached("yyyy-MM").string(from: now), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(DateFormatter.cached("yyyyMMddHHmmss").string(from: now) + "_mac.m4a")
        // 16 kHz mono AAC: what speech recognition wants, about 22 MB per hour.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record() else { throw AppError("麦克风打不开，可能正被其他应用占用") }
            Log.recorder.info("录音文件：\(url.lastPathComponent, privacy: .public)")
            recorder = r
            fileURL = url
            started = now
            elapsed = 0
            isPaused = false
            history = Array(repeating: 0, count: history.count)
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)   // don't leave an empty file behind
            Log.recorder.error("录音失败：\(error.localizedDescription, privacy: .public)")
            say(error.localizedDescription, error: true, clearAfter: 6)
        }
    }

    func pause() {
        guard isRecording, !isPaused, let r = recorder else { return }
        r.pause()
        isPaused = true
        level = 0
        Log.recorder.info("暂停于 \(Int(r.currentTime), privacy: .public) 秒")
    }

    func resume() {
        guard isRecording, isPaused, let r = recorder else { return }
        guard r.record() else { say("麦克风打不开，可能正被其他应用占用", error: true, clearAfter: 6); return }
        isPaused = false
    }

    func stop() {
        guard isRecording, let r = recorder, let url = fileURL else { return }
        let duration = Int(r.currentTime.rounded())
        r.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        isPaused = false
        level = 0
        history = Array(repeating: 0, count: history.count)
        Log.recorder.info("录音结束，\(duration, privacy: .public) 秒")
        if duration < 3 {
            try? FileManager.default.removeItem(at: url)   // a mis-click, not a recording
            say("太短，已丢弃", clearAfter: 3)
            return
        }
        let title = DateFormatter.cached("M月d日H点mm分").string(from: started) + "的录音"
        Pipeline.shared.addLocalRecording(url: url, title: title, created: started, durationSec: duration)
        say("已保存，开始转写", clearAfter: 4)
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime                           // excludes paused stretches
        guard !isPaused else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)           // -160…0
        level = max(0, min(1, (db + 50) / 50))
        history.removeFirst()
        history.append(level)
    }

    private func explainNoMicrophone() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "这台 Mac 没有可用的麦克风"
        a.informativeText = """
        Mac mini、Mac Studio 没有内置麦克风。接上下面任意一种，就能直接录音：
        • AirPods 或其他蓝牙耳机
        • USB 麦克风、带麦克风的 USB 耳机或摄像头
        • iPhone：同一 Apple 账户、放在旁边，在「系统设置 › 声音 › 输入」里选它

        接好后再点一次「录音」。
        """
        a.addButton(withTitle: "打开声音设置")
        a.addButton(withTitle: "好")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }

    private func askForMicrophone() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "需要麦克风权限"
        a.informativeText = "请在「系统设置 › 隐私与安全性 › 麦克风」里打开「听墨」，然后再点一次录音。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(u)
        }
    }
}
